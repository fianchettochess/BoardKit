import Foundation

/// Protocol implemented by each concrete board adapter.
///
/// The adapter owns wire framing, protocol parsing, command encoding,
/// handshake sequencing, and orientation flip. The transport holds a
/// `BoardAdapter` value and calls `feed(bytes:)` on every raw chunk
/// received from the radio, then yields the resulting `[BoardEvent]`
/// into its `AsyncStream<BoardEvent>`.
///
/// ## Design rationale — value type + mutating
///
/// The framer accumulates partial frame bytes across calls (analogous to
/// `SquareOffFramer.buffer`). Making `feed` `mutating` lets concrete
/// adapters be structs (cheaply copied in test harnesses, no heap
/// allocation) while the transport holds `var adapter: SomeAdapter`.
///
/// ## Mapping to SquareOffAdapter (Pass 2 reference)
///
/// When the Square Off adapter arrives in Pass 2, its `feed(bytes:)` will
/// execute:
/// ```
/// SquareOffFramer.append(data) → [SquareOffMessage]
/// SquareOffParser.event(from:) → SquareOffEvent
/// SquareOffEvent → BoardEvent:
///   .fieldUpdate(square:isLift:)  → .squareSensed(square:isLift:piece: nil)
///   .boardState(occupancy:)       → .occupancySnapshot(occupancy)
///   .newGameReady                 → .ready        ← handshake detail absorbed
///   .disconnected                 → .disconnected(error: nil)
///   .raw(msg)                     → .raw(msg.wireRepresentation as Data)
/// ```
public protocol BoardAdapter: Sendable {

    /// Static capabilities, queried once at connect time.
    ///
    /// The transport (or session) reads this immediately after connecting
    /// and stores the result. Capability bits determine which event cases
    /// the session should expect and which kernel paths to activate.
    var capabilities: BoardCapabilities { get }

    /// Decode a raw data chunk and return the resulting semantic events.
    ///
    /// The adapter accumulates partial frames across calls and emits events
    /// only when a complete frame boundary is reached. Callers must invoke
    /// this serially (one call at a time) — concurrent calls are
    /// undefined behaviour for a `mutating` function on a value type.
    ///
    /// - Parameter bytes: Raw bytes as received from the BLE or USB-HID
    ///   transport. May be empty (safe to call with zero bytes).
    /// - Returns: Zero or more decoded events. An empty array means the
    ///   bytes were buffered but no complete frame was available yet.
    mutating func feed(bytes: Data) -> [BoardEvent]

    /// Encode a `BoardCommand` to its wire representation.
    ///
    /// Returns `nil` when the command is unsupported for this board
    /// (the transport silently skips it) — for example, `startSession`
    /// on a board that has no explicit session concept, or `custom(data)`
    /// whose adapter chooses not to forward.
    ///
    /// ## Chessnut Air mapping
    /// ```
    /// .startSession       → Data([0x21, 0x01, 0x00])   (enter realtime)
    /// .requestState       → Data([0x21, 0x01, 0x00])   (re-enter realtime → fresh frame)
    /// .indicateSquares    → 10-byte LED frame (see ChessnutAdapter)
    /// .executeMove(uci:)  → nil  (Air family is not motorised)
    /// .custom(data)       → data verbatim
    /// ```
    ///
    /// ## Square Off mapping (Pass 2 reference)
    /// ```
    /// .startSession       → "14#1*".data(using: .ascii)
    /// .requestState       → "30#R*".data(using: .ascii)
    /// .indicateSquares    → "25#<sq1>,<sq2>*".data(using: .ascii)
    /// .executeMove(uci:)  → nil (QUARANTINED: sendMove wire semantics are
    ///                       hardware-unverified and may auto-move on
    ///                       motorised models; see SquareOffAdapter)
    /// .custom(data)       → data verbatim
    /// ```
    func encode(_ command: BoardCommand) -> Data?

    /// The ordered handshake sequence the transport executes after a link
    /// is established.
    ///
    /// Returning the sequence (rather than executing it) keeps the adapter
    /// pure and testable — no live transport or timer is needed to assert
    /// the handshake steps and their inter-command gaps.
    ///
    /// - Parameter isReconnect: `true` when the link was restored after an
    ///   unexpected drop; `false` on the initial fresh connection.
    ///
    /// ## Chessnut Air mapping
    /// - First connect: `[(.startSession, delayBefore: 0)]`
    /// - Reconnect: `[(.startSession, delayBefore: 0.25)]`
    ///
    /// ## Square Off mapping (Pass 2 reference)
    /// - First connect:
    ///   `[(.startSession, 0.25), (.requestState, 0.15)]`
    ///   (0.25 s = hardware-proven link-settle; matches the shipped adapter)
    /// - Reconnect:
    ///   `[(.requestState, 0.25)]`
    func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)]

    /// Mandatory wire-level responses the adapter queued while parsing the most
    /// recent `feed(bytes:)` input — acknowledgements some board protocols
    /// require *out of band* from the semantic event stream.
    ///
    /// The transport MUST call this immediately after each `feed(bytes:)` and
    /// write every returned value back to the board's write characteristic.
    /// Draining is destructive: each queued response is returned exactly once.
    ///
    /// ## Why this exists (ChessUp)
    /// The ChessUp board **retransmits every `0xA3` move frame until the host
    /// writes a `0x21` ack** (and board-side promotions until a `0x23` ack).
    /// Leaving them unacked wedges the board and floods the notify pipe until
    /// the BLE link drops. Queuing the acks *in the adapter* (co-located with
    /// the frame parser that knows a `0xA3`/`0x97` just arrived) keeps that
    /// protocol detail out of every platform transport.
    ///
    /// ## Default
    /// Empty. Boards with no ack protocol (Square Off, Chessnut) inherit the
    /// default and need not implement it.
    mutating func takePendingResponses() -> [Data]
}

public extension BoardAdapter {
    /// Default: no out-of-band responses. Only ack-based protocols override this.
    mutating func takePendingResponses() -> [Data] { [] }
}
