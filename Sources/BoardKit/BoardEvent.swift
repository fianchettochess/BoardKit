import Foundation
import ChessCore

/// Decoded semantic events emitted by a board adapter.
///
/// All adapters share this event vocabulary regardless of board brand or
/// capability level. The session layer routes events from a concrete
/// `BoardAdapter` (which parses wire bytes) into the kernel stack
/// (BoardExecutionGate, OccupancyMoveInference, etc.).
///
/// Two-pass design note: the kernel types referenced in parameter docs
/// (BoardExecutionGate, OccupancyMoveInference, OccupancyDiffResolver,
/// BoardCorrectionPlanner, BoardSyncGate) currently live in FianchettoKit
/// under their `SquareOff*` names. Pass 2 migrates them to BoardKit with
/// the names used throughout this file.
public enum BoardEvent: Sendable {

    // MARK: - Sensor events

    /// One square's occupancy changed.
    ///
    /// `square` is algebraic ("e4") in the board's **physical frame** —
    /// no orientation correction is applied by the adapter. Orientation
    /// adjustment (for players seated on the black side) is a session
    /// concern: the session applies `ChessBoardGeometry.flippedSquare`
    /// when a user-configurable flip is active, mirroring the existing
    /// `SquareOffSession.orientationFlipped` pattern. This matches the
    /// live kernel behaviour and keeps adapters stateless with respect to
    /// UI preferences.
    ///
    /// The type is `String` — NOT `ChessCore.Square` — to match the
    /// existing kernel parameter types of
    /// `BoardExecutionGate.feed(square:isLift:)` and
    /// `OccupancyMoveInference.handle(square:isLift:)`. The session can
    /// pass `event.square` directly to both kernels without any conversion.
    /// Callers needing a typed Square: `Square(algebraic: event.square)`.
    ///
    /// `piece` is non-nil only for identity-sensing boards (Chessnut,
    /// Certabo, Millennium, DGT Classic). It is nil for Square Off and
    /// DGT Pegasus. The session passes a nil `piece` through to
    /// `OccupancyMoveInference` unchanged (the four-slot occupancy path
    /// runs unmodified). When `piece` is non-nil the session MAY
    /// short-circuit the slot machine and call a future
    /// `resolveWithIdentity` overload on `OccupancyDiffResolver`.
    case squareSensed(square: String, isLift: Bool, piece: Piece? = nil)

    /// Full 64-square occupancy snapshot.
    ///
    /// Array is file-major (a1=0..a8=7, b1=8..h8=63) — the same layout
    /// that `OccupancyDiffResolver.resolve(from:targetOccupancy:)` and
    /// `BoardCorrectionPlanner.corrections(for:boardOccupancy:)` expect.
    ///
    /// Occupancy-only adapters (Square Off, DGT Pegasus) emit this.
    /// Identity boards (Chessnut) emit `identitySnapshot` and can derive
    /// occupancy from it; they do not duplicate-emit this case.
    case occupancySnapshot([Bool])

    /// Full 64-element piece-identity snapshot. `nil` = empty square.
    /// Array is file-major (a1=0..a8=7, b1=8..h8=63).
    ///
    /// Only emitted by identity-sensing boards (Chessnut Air family,
    /// Certabo, Millennium). Never emitted by Square Off or DGT Pegasus.
    ///
    /// Callers that only need occupancy: `map { $0 != nil }`.
    case identitySnapshot([Piece?])

    // MARK: - Connection lifecycle

    /// Physical + protocol link established (characteristics discovered,
    /// CCCD written). The adapter emits this before beginning the
    /// handshake sequence.
    ///
    /// **New behavior vs. SquareOffTransport**: the existing Square Off
    /// transport yields only `.disconnected` into its event stream. Adding
    /// `.connected` requires a transport-side change: yield `.connected`
    /// from the `didDiscoverCharacteristics` / `handleReady` path.
    case connected

    /// Board has completed its initialisation handshake and confirmed state.
    ///
    /// For Chessnut Air: emitted after the realtime-mode command
    /// (`0x21 0x01 0x00`) has been acknowledged and the first board-state
    /// frame has arrived on `1b7e8262`.
    ///
    /// For Square Off: maps from `SquareOffEvent.newGameReady` (the
    /// "14#GO*" response). The `.newGameReady` detail is absorbed here
    /// and never leaks to the session.
    case ready

    /// Physical link dropped.
    ///
    /// `error` is a localized description when the transport has one (e.g.
    /// a CoreBluetooth error), or `nil` for a clean disconnect. Maps from
    /// `SquareOffEvent.disconnected` (which carries no error) as
    /// `disconnected(error: nil)`.
    case disconnected(error: String?)

    // MARK: - Housekeeping

    /// Battery level 0–100, when the board reports it.
    ///
    /// Chessnut Air/Air+/Pro/Go: unsolicited frames and responses to the
    /// `0x29 0x01 0x00` battery-request command both surface here. The
    /// charging flag reported by some firmware is currently not forwarded
    /// (surfacing it requires a separate `BoardEvent` case or a struct
    /// payload — tracked for a future minor version).
    case battery(percent: Int)

    /// Raw undecoded bytes — debug and capture-log research only.
    ///
    /// Session code must NEVER branch on this case. Adapters should emit
    /// it for any opcode they do not recognise so callers can log unknown
    /// frames without losing data.
    case raw(Data)

    // MARK: - Hardware-reported picks

    /// Board-reported promotion piece pick.
    ///
    /// Emitted by the `ChessUpAdapter` when the board sends a `0x97` frame
    /// (board-side promotion frame, piece scale 1=R 2=N 3=B 4=Q).
    ///
    /// When the board reports the promotion piece this way, the session layer
    /// can auto-resolve the picker without asking the human — the board already
    /// answered the question.  The adapter always queues the required `0x23` ack
    /// via `takePendingResponses()` regardless of whether the frame decodes
    /// successfully; this event carries the decoded type.
    ///
    /// `PieceType` is used directly because `BoardEvent` already imports
    /// `ChessCore` (for `Piece`) and `PieceType` satisfies the `Sendable`
    /// requirement via its value-type nature.  Session code MUST handle this
    /// case and MUST NOT treat it the same as `.raw`.
    case promotionPick(piece: PieceType)

    // MARK: - Stored-game import

    /// One game reconstructed from a board's internal storage during a
    /// `BoardCommand.requestStoredGames` import.
    ///
    /// Emitted by adapters that advertise `BoardCapabilities.gameArchive`
    /// (Chessnut Air family) once a stored game has been fully streamed off
    /// the board and diffed back into moves. During an import spanning
    /// several games the adapter emits one such event per game, in the order
    /// the board replays them.
    ///
    /// - `moves`: the reconstructed moves from the standard initial position,
    ///   in order. Empty when the board stored only a power-on frame.
    /// - `sanMoves`: standard algebraic notation for each move (parallel to
    ///   `moves`); the session composes PGN movetext directly from these.
    /// - `isComplete`: `true` when every stored snapshot was explained by a
    ///   legal move; `false` when the replay truncated (corrupt frame or an
    ///   unreconstructable position) and `moves` holds the prefix recovered
    ///   before the break. The session should still import a partial game but
    ///   may flag it.
    ///
    /// The board does not store player names, result, or timestamps, so the
    /// session supplies those (import date, a synthetic event) when creating
    /// the library entry.
    case storedGameImported(moves: [Move], sanMoves: [String], isComplete: Bool)
}
