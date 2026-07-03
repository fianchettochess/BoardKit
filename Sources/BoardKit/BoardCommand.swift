import Foundation
import ChessCore

/// Commands sent from the session layer down to a board adapter for encoding
/// and subsequent transmission over the wire.
///
/// The adapter's `encode(_:) -> Data?` translates each case into the
/// board-specific wire bytes. Returning `nil` signals that the command is
/// unsupported for that board (e.g., `startSession` on a board that has no
/// concept of a game session) so the transport can silently skip it.
public enum BoardCommand: Sendable {

    /// Begin a new game / enter the active-play state.
    ///
    /// Square Off wire: `"14#1*"`.
    /// Chessnut Air wire: `0x21 0x01 0x00` (enter realtime mode).
    ///
    /// On the reconnect path, `BoardAdapter.handshakeCommands(isReconnect:
    /// true)` omits this so the board's game state is preserved across
    /// temporary disconnections.
    case startSession

    /// Request a full occupancy (or identity) snapshot.
    ///
    /// Square Off wire: `"30#R*"`.
    /// Chessnut Air: the board streams continuously in realtime mode, so
    /// this maps to re-entering realtime mode (`0x21 0x01 0x00`) which
    /// causes the board to emit a fresh frame immediately.
    case requestState

    /// Illuminate a set of squares on the board's LEDs.
    ///
    /// `squares` is an array of algebraic strings (e.g. `["e2", "e4"]`),
    /// consistent with `SquareOffCommand.setLeds(squares: [String])` that
    /// this generalises. Using `[String]` avoids forced conversion at
    /// every adapter call site; callers with typed `Square` values call
    /// `.algebraic` first.
    ///
    /// `style` is advisory. Occupancy-LED adapters (Square Off, DGT
    /// Pegasus) use a single on/off LED per square and ignore the style.
    /// Multi-colour adapters (Chessnut Air+, GoChess) map `.moveFrom` and
    /// `.moveTo` to their respective colour codes.
    ///
    /// To clear all LEDs, pass an empty array.
    case indicateSquares([String], style: LEDStyle)

    /// Ask the board's motorised mechanism to physically execute a move.
    ///
    /// `uci` is a UCI-format move string (e.g. `"e2e4"`, `"e7e8q"`).
    ///
    /// **Non-motorised boards** (Chessnut Air/Air+/Pro/Go, DGT Pegasus,
    /// Square Off Gen 1) return `nil` from `encode(_:)` for this case.
    /// The transport silently skips unsupported commands — the existing
    /// unimplemented-command contract. This case is defined now so the
    /// motorised surface is stable before 1.0; adding it later would
    /// break every adapter's exhaustive `encode` switch (including
    /// community adapters invited by the README).
    ///
    /// **Motorised boards (Pass 2+)**:
    /// - Square Off GKS / Pro: maps to `SquareOffCommand.sendMove(uci:)` /
    ///   `.sendMoveWithComma(from:to:)`.
    /// - Chessnut Move: extended-profile auto-move command (TBD in Pass 3).
    ///
    /// **Note on BoardEvent**: after the mechanism completes, the board
    /// emits normal board-state frames confirming piece placement. A
    /// dedicated `BoardEvent.moveExecuted(uci:)` case may be added before
    /// 1.0 if a reliable hardware ACK frame can be demarcated; until then
    /// session code handling the motorised response path should carry a
    /// `default:` arm on `BoardEvent` switches for forward compatibility.
    case executeMove(uci: String)

    /// Adapter-specific payload not yet modelled above.
    ///
    /// `data` is the complete wire frame in the adapter's encoding.
    /// Use this to send board-specific commands (e.g. Chessnut beep,
    /// BLE version query) without extending the shared `BoardCommand`
    /// vocabulary.
    case custom(Data)
}

/// Advisory illumination style for `BoardCommand.indicateSquares`.
///
/// Adapters that support only a single LED colour (Square Off, DGT Pegasus)
/// treat all non-`.highlight` values as `.highlight`. Adapters that support
/// per-square colour (Chessnut Air family, GoChess) map the cases to their
/// board-specific colour encoding.
public enum LEDStyle: Sendable {
    /// Plain on/off illumination. Universally supported.
    case highlight
    /// Source-square emphasis (e.g. green on Chessnut).
    case moveFrom
    /// Destination-square emphasis (e.g. yellow on Chessnut).
    case moveTo
    /// Check or threat emphasis (e.g. red on Chessnut).
    case danger
    /// Board-specific colour index for adapters with extended colour support.
    case custom(UInt8)
}
