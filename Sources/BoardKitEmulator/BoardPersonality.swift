import Foundation
import BoardKit

// ── BoardPersonality — the peripheral-side counterpart of BoardAdapter ──────
//
// A `BoardAdapter` sits on the HOST side of the wire: it parses board→host
// notification bytes into `BoardEvent`s and encodes `BoardCommand`s into
// host→board writes. A `BoardPersonality` is the mirror image, sitting on
// the BOARD side: it encodes `BoardEvent`s into board→host notification
// payloads and parses host→board writes into `PeripheralAction`s.
//
//                    host  ──write──►  board
//   BoardAdapter.encode(_:)            BoardPersonality.handleHostWrite(_:)
//
//                    host  ◄─notify──  board
//   BoardAdapter.feed(bytes:)          BoardPersonality.frames(for:)
//
// The loop-back law (enforced by BoardKitEmulatorTests): frames produced by
// a personality for a ground-truth event stream, fed through the matching
// adapter's `feed(bytes:)`, must reproduce that event stream. This catches
// asymmetric codec bugs no one-directional fixture can.
//
// Everything in this file is platform-free — no CoreBluetooth. The BLE
// peripheral server maps `GATTLayout` onto CBMutableService/Characteristic
// on macOS only.
//
// ## Designing for the fleet
//
// Future personalities (Pegasus, Millennium, Certabo, ChessUp — adapters
// arriving in a parallel stream) implement this same protocol: pick the
// GATT layout + advertised name from the board's transport constants, reuse
// the adapter target's codec in the encode direction, and parse the host
// writes the adapter emits. Nothing in `PeripheralServer` or `GameDriver`
// is Square Off- or Chessnut-specific.

// MARK: - GATT layout description

/// One characteristic in a peripheral's GATT database.
public struct GATTCharacteristicSpec: Equatable, Sendable {
    /// What the host may do with the characteristic.
    public enum Role: String, Equatable, Sendable {
        case notify
        case write
        case writeWithoutResponse
        case read
    }

    /// 128-bit UUID string (the transports' canonical lowercase/uppercase
    /// form is preserved verbatim for log readability).
    public let uuid: String
    public let roles: [Role]

    public init(uuid: String, roles: [Role]) {
        self.uuid = uuid
        self.roles = roles
    }
}

/// One primary service in a peripheral's GATT database.
public struct GATTServiceSpec: Equatable, Sendable {
    public let uuid: String
    public let characteristics: [GATTCharacteristicSpec]

    public init(uuid: String, characteristics: [GATTCharacteristicSpec]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}

/// The full GATT surface a personality asks the peripheral server to expose.
///
/// `advertisedServiceUUIDs` may include UUIDs that are not in `services`
/// (Square Off advertises a marker service, `D804B643-…`, whose
/// characteristics are never used by the host — the data channel is the
/// Nordic UART Service).
///
/// **macOS peripheral-advertising limitation (documented, load-bearing):**
/// `CBPeripheralManager.startAdvertising` supports exactly two keys —
/// `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`.
/// Manufacturer data, TX power, and scan-response control are not available
/// to peripheral-mode apps. Both Fianchetto host transports discover by
/// (name prefix + service UUID), so those two keys are sufficient.
public struct GATTLayout: Equatable, Sendable {
    public let services: [GATTServiceSpec]
    public let advertisedServiceUUIDs: [String]

    public init(services: [GATTServiceSpec], advertisedServiceUUIDs: [String]) {
        self.services = services
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
    }

    /// All characteristics the host can write to (either write role).
    public var writableCharacteristicUUIDs: Set<String> {
        var out = Set<String>()
        for service in services {
            for characteristic in service.characteristics
            where characteristic.roles.contains(.write) || characteristic.roles.contains(.writeWithoutResponse) {
                out.insert(characteristic.uuid)
            }
        }
        return out
    }
}

// MARK: - Board→host frame

/// One notification payload addressed to a specific notify characteristic.
public struct PersonalityFrame: Equatable, Sendable {
    public let characteristicUUID: String
    public let data: Data

    public init(characteristicUUID: String, data: Data) {
        self.characteristicUUID = characteristicUUID
        self.data = data
    }
}

// MARK: - Host→board actions

/// What the personality wants done in response to a host write.
public enum PeripheralAction: Equatable, Sendable {
    /// Send a notification frame back to the host.
    case notify(PersonalityFrame)
    /// The host set the board's LEDs. The game driver interprets a lit
    /// from/to pair as "the app dictates this move — execute it physically
    /// after a human delay".
    case setLEDs([String])
    /// The host asked the board to start a new game (Square Off "14#1*").
    case startNewGame
    /// The host asked a motorised board to physically execute a move
    /// (Square Off "0#<uci>*" / "24#<from>,<to>*"; Chessnut Move in a
    /// future personality). The Tier-0 driver executes it like an
    /// LED-dictated move, minus the human delay.
    case executeMove(uci: String)
    /// Something worth logging (unknown opcode, beep, version query…).
    case log(String)
}

// MARK: - Personality protocol

/// Peripheral-side board impersonation: GATT surface, advertising identity,
/// event→frame encoding, and host-write handling.
///
/// Implementations are value types with `mutating` members (mirroring
/// `BoardAdapter`): they carry a framing buffer for fragmented host writes
/// and a board-state mirror so state-request commands can be answered
/// without a round trip to the game driver.
public protocol BoardPersonality: Sendable {

    /// Local name for the BLE advertisement. Must satisfy the matching host
    /// transport's discovery filter.
    var advertisedName: String { get }

    /// GATT database + advertised service UUIDs.
    var gattLayout: GATTLayout { get }

    /// Encode a board event into zero or more notification frames, updating
    /// the personality's board-state mirror as a side effect.
    ///
    /// Feed `SimulatedBoard` output (or chaos-perturbed `squareSensed`
    /// streams) here; the personality decides per-protocol what actually
    /// goes on the wire (Square Off: one text frame per event; Chessnut: a
    /// full 36-byte board frame per occupancy change).
    mutating func frames(for event: BoardEvent) -> [PersonalityFrame]

    /// Parse one host write (possibly a fragment) and return the actions it
    /// triggers. Accumulates fragments across calls exactly like
    /// `BoardAdapter.feed(bytes:)` does on the host side.
    mutating func handleHostWrite(_ data: Data) -> [PeripheralAction]
}
