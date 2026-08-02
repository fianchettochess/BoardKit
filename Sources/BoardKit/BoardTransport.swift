import Foundation

/// Protocol for the platform-specific BLE (or USB-HID) transport layer.
///
/// **This protocol is declared in BoardKit but implemented by the
/// consumer**, in a target where `CoreBluetooth` (iOS/macOS) or `SkipFuse`
/// (Android) is available. BoardKit intentionally never imports
/// CoreBluetooth — the protocol definition here is pure Swift, carrying
/// only `Foundation` types.
///
/// ## Relationship to BoardAdapter
///
/// The transport owns the radio link (scan / connect / disconnect) and holds
/// a concrete `BoardAdapter` value. On raw data arrival it calls
/// `adapter.feed(bytes:)` and yields each resulting `BoardEvent` into the
/// `events` stream. On link changes it injects lifecycle synthetics
/// (`.connected`, `.disconnected`).
///
/// ```
/// ┌─────────────┐  raw bytes  ┌───────────────┐  BoardEvent  ┌──────────────┐
/// │  BLE radio  │ ──────────► │ BoardAdapter  │ ────────────► │BoardTransport│
/// └─────────────┘             └───────────────┘               │  .events     │
///                                                              └──────────────┘
/// ```
///
/// ## Implementation contract
///
/// - On raw data: call `adapter.feed(bytes:)` → yield `[BoardEvent]`.
/// - On link established: yield `.connected`, execute
///   `adapter.handshakeCommands(isReconnect:)` with inter-command delays,
///   then let `adapter.feed()` emit `.ready` when the board ACKs.
/// - On link drop: yield `.disconnected(error:)`.
/// - Note: This protocol is `@MainActor` because its implementers are
///   `@Observable` classes observed by SwiftUI (or SkipFuse on Android)
///   and its synchronous properties (`state`, `discovered`, …) are not
///   safe to read off the main thread.  `@MainActor` isolation makes
///   every conformer implicitly `Sendable`, so an explicit `Sendable`
///   constraint is unnecessary.  A non-main-actor transport (e.g. a
///   background-thread HID driver) should document its conformance
///   pattern: `@preconcurrency` + `@unchecked Sendable` with an
///   internal lock guarding the sync properties.
@MainActor
public protocol BoardTransport: AnyObject {

    /// Current state of the transport / radio link.
    var state: BoardTransportState { get }

    /// Boards discovered during the most-recent scan that have not yet
    /// connected (or have since disconnected).
    var discovered: [DiscoveredBoardDevice] { get }

    /// Name of the currently connected board, if any.
    var connectedDeviceName: String? { get }

    /// The most-recent transport-level error, if any. Nil after a clean
    /// connect or when no error has occurred since the last scan.
    var lastError: String? { get }

    /// Decoded event stream. Every `BoardEvent` emitted by the adapter,
    /// plus lifecycle synthetics (`.connected`, `.disconnected`), arrive
    /// here in order.
    var events: AsyncStream<BoardEvent> { get }

    /// Start scanning for connectable boards matching the adapter's profile.
    func startScan()
    /// Stop an in-progress scan.
    func stopScan()
    /// Initiate a connection to a previously discovered device.
    func connect(_ device: DiscoveredBoardDevice)
    /// Disconnect from the currently connected board.
    func disconnect()
    /// Encode and transmit a command through the adapter.
    func send(_ command: BoardCommand)
}

/// Observable state of a `BoardTransport`.
public enum BoardTransportState: Equatable, Sendable {
    /// Bluetooth radio is off. All other operations are unavailable.
    case poweredOff
    /// The host application lacks Bluetooth permission.
    case unauthorized
    /// Ready to scan; not currently connected or scanning.
    case idle
    /// Actively scanning for boards.
    case scanning
    /// Connection attempt in progress.
    case connecting
    /// The transport link is writable and notifications are subscribed.
    ///
    /// The adapter handshake may still be in progress. Consumers that need
    /// live sensor readiness must wait for ``BoardEvent/ready``.
    case connected
    /// Link is down after a disconnect or failure.
    case disconnected
    /// Auto-reconnect is in progress.
    ///
    /// `attempt` is 1-indexed and counts from the most-recent unexpected
    /// drop. Pair it with the `maxAttempts` of the ``BoardReconnectPolicy``
    /// driving the loop if you want to report progress.
    case reconnecting(attempt: Int)
}

/// A board visible during a BLE scan.
public struct DiscoveredBoardDevice: Identifiable, Equatable, Sendable {
    /// A stable UUID assigned by the OS for this peripheral across scans.
    public let id: UUID
    /// The advertised device name (e.g. "Chessnut Air", "Square Off").
    public let name: String
    /// Signal strength in dBm at scan time. Use for proximity sorting.
    public let rssi: Int
    /// Opaque transport token. The transport uses this for reconnect;
    /// callers should not interpret its contents.
    public let token: String

    public init(id: UUID, name: String, rssi: Int, token: String) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.token = token
    }
}
