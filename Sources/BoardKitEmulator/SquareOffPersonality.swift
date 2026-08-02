import Foundation
import BoardKit
import SquareOffAdapter

/// Peripheral-side impersonation of a Square Off Pro board.
///
/// Reuses the `SquareOffAdapter` codec types in both directions:
/// - **Board→host** frames are built with `SquareOffMessage.wireRepresentation`
///   (`"0#e2u*"` field updates, `"30#<64 bits>*"` board state, `"14#GO*"`
///   new-game ACK) — the exact strings `SquareOffParser` decodes.
/// - **Host→board** writes are the `SquareOffCommand` wire strings the host
///   adapter emits (`"14#1*"`, `"30#R*"`, `"25#<squares>*"`, quarantined
///   `"0#<uci>*"` / `"24#<from>,<to>*"`), split from the byte stream with the
///   same `SquareOffFramer` the host uses — the framing grammar is symmetric.
///
/// ## Transport identity
///
/// GATT + name per the hardware-verified host transport constants:
/// - Advertised marker service `D804B643-6CE7-4E81-9F8A-CE0F699085EB`
///   (broadcast in the scan response by real boards; no characteristics used).
/// - Nordic UART Service `6e400001-…` as the data channel:
///   RX `6e400002-…` (host writes commands), TX `6e400003-…` (board
///   notifies frames).
/// - The host filter matches names case-insensitively containing "square"
///   (boards have shipped as both "Square Off" and "Squareoff").
public struct SquareOffPersonality: BoardPersonality {

    // MARK: - Transport constants (mirrors the host transport)

    public static let advertisedServiceUUID = SquareOffGATT.advertisedService
    public static let nusServiceUUID = SquareOffGATT.nordicUART
    /// Host→board command characteristic (write / writeWithoutResponse).
    public static let rxCharUUID = SquareOffGATT.nusRX
    /// Board→host frame characteristic (notify).
    public static let txCharUUID = SquareOffGATT.nusTX

    // MARK: - State

    /// Occupancy mirror (file-major, a1=0…h8=63) so `"30#R*"` requests can
    /// be answered from the personality alone. Seeded to the standard
    /// initial position; updated by every event routed through
    /// `frames(for:)`.
    private var occupancy: [Bool]

    /// Reuses the host-side framer to split fragmented host writes into
    /// whole `<code>#<body>*` frames — the wire grammar is identical in
    /// both directions.
    private var framer = SquareOffFramer()

    public let advertisedName: String

    public init(advertisedName: String = "Squareoff Pro") {
        self.advertisedName = advertisedName
        // Standard initial position occupancy: ranks 1, 2, 7, 8 of every file.
        var occ = [Bool](repeating: false, count: 64)
        for file in 0..<8 {
            for rank in [0, 1, 6, 7] {
                occ[file * 8 + rank] = true
            }
        }
        self.occupancy = occ
    }

    // MARK: - BoardPersonality

    public var gattLayout: GATTLayout {
        GATTLayout(
            services: [
                GATTServiceSpec(uuid: Self.nusServiceUUID, characteristics: [
                    GATTCharacteristicSpec(uuid: Self.rxCharUUID, roles: [.write, .writeWithoutResponse]),
                    GATTCharacteristicSpec(uuid: Self.txCharUUID, roles: [.notify]),
                ]),
            ],
            advertisedServiceUUIDs: [Self.advertisedServiceUUID, Self.nusServiceUUID]
        )
    }

    public mutating func frames(for event: BoardEvent) -> [PersonalityFrame] {
        switch event {
        case .squareSensed(let square, let isLift, _):
            // Update the mirror, then emit the field-update frame.
            if let index = Self.fileMajorIndex(square) {
                occupancy[index] = !isLift
            }
            let message = SquareOffMessage(code: "0", body: square.lowercased() + (isLift ? "u" : "d"))
            return [txFrame(message)]

        case .occupancySnapshot(let snapshot):
            if snapshot.count == 64 { occupancy = snapshot }
            return [txFrame(boardStateMessage())]

        case .identitySnapshot(let identity):
            // Square Off has no identity sensing — degrade to occupancy.
            if identity.count == 64 { occupancy = identity.map { $0 != nil } }
            return [txFrame(boardStateMessage())]

        case .ready:
            // The "14#GO*" new-game ACK — also sent in response to "14#1*".
            return [txFrame(SquareOffMessage(code: "14", body: "GO"))]

        case .battery, .connected, .disconnected, .raw, .promotionPick, .storedGameImported:
            // Square Off reports no battery; lifecycle is radio-level.
            // .promotionPick is a ChessUp-specific event; Square Off never emits it.
            return []
        }
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        let messages = framer.append(data)
        var actions: [PeripheralAction] = []
        for message in messages {
            switch (message.code, message.body) {
            case ("14", "1"):
                // Start new game. Respond GO (what SquareOffParser maps to
                // .newGameReady → BoardEvent.ready on the host).
                actions.append(.startNewGame)
                actions.append(.notify(txFrame(SquareOffMessage(code: "14", body: "GO"))))

            case ("30", "R"):
                actions.append(.notify(txFrame(boardStateMessage())))

            case ("25", let body):
                // LED set: body is the lowercased concatenation of algebraic
                // squares (see SquareOffCommand.setLeds). Empty body = all off.
                actions.append(.setLEDs(Self.parseSquareList(body)))

            case ("0", let body):
                // Quarantined on the host side, but a real host might send it;
                // treat as a motorised move request.
                actions.append(.executeMove(uci: body))

            case ("24", let body):
                let parts = body.split(separator: ",", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    actions.append(.executeMove(uci: parts[0].lowercased() + parts[1].lowercased()))
                } else {
                    actions.append(.log("squareoff: malformed 24# body '\(body)'"))
                }

            default:
                actions.append(.log("squareoff: unhandled host command \(message.wireRepresentation)"))
            }
        }
        return actions
    }

    // MARK: - Helpers

    private func txFrame(_ message: SquareOffMessage) -> PersonalityFrame {
        PersonalityFrame(characteristicUUID: Self.txCharUUID,
                         data: Data(message.wireRepresentation.utf8))
    }

    /// `"30#<64 chars>*"` — one '0'/'1' per square in file-major a1…h8 order,
    /// matching `SquareOffParser`'s board-state decode.
    private func boardStateMessage() -> SquareOffMessage {
        SquareOffMessage(code: "30", body: String(occupancy.map { $0 ? "1" : "0" }))
    }

    /// Split a concatenated square list ("e2e4") into ["e2", "e4"].
    /// Non-square residue is dropped (defensive; the host only sends valid
    /// squares).
    static func parseSquareList(_ body: String) -> [String] {
        var squares: [String] = []
        var rest = Substring(body.lowercased())
        while rest.count >= 2 {
            let candidate = String(rest.prefix(2))
            if candidate.range(of: "^[a-h][1-8]$", options: .regularExpression) != nil {
                squares.append(candidate)
            }
            rest = rest.dropFirst(2)
        }
        return squares
    }

    /// File-major index for an algebraic square, nil when malformed.
    static func fileMajorIndex(_ square: String) -> Int? {
        let chars = Array(square.lowercased())
        guard chars.count == 2,
              let file = "abcdefgh".firstIndex(of: chars[0])?.utf16Offset(in: "abcdefgh"),
              let rank = chars[1].wholeNumberValue, (1...8).contains(rank) else { return nil }
        return file * 8 + (rank - 1)
    }
}
