import Foundation
import ChessCore
import BoardKit

// ── Square Off board adapter ──────────────────────────────────────────────────
//
// Covers Square Off Pro, Kingdom Set (GKS), and Gen-1 motorised boards.
//
// HARDWARE STATUS: Battle-tested in-app (Fianchetto iOS/Android production).
// Protocol codec migrated from the FianchettoKit SquareOffTransport on
// 2026-07-03; field-verified against physical Square Off Pro and GKS hardware.
// executeMove quarantined (motor semantics unverified); all other BoardAdapter
// methods are production-grade.
//
// Sources:
//   Protocol reverse-engineered in-app from captured BLE traffic and field
//   testing on physical Square Off Pro and Kingdom Set boards. No third-party
//   driver consulted (first-party reverse engineering only).

/// `BoardAdapter` implementation for the Square Off Pro (and compatible GKS / Gen-1)
/// family of boards.
///
/// ## Protocol mapping
///
/// **feed(bytes:)** runs incoming raw bytes through `SquareOffFramer` → `SquareOffParser`
/// → `SquareOffEvent` → `BoardEvent`:
///   - `.fieldUpdate(square:isLift:)` → `.squareSensed(square:isLift:piece: nil)`
///   - `.boardState(occupancy:)` → `.occupancySnapshot(occupancy)`
///   - `.newGameReady` → `.ready`  (handshake detail absorbed; never leaks to session)
///   - `.disconnected` → `.disconnected(error: nil)`
///   - `.raw(_)` → `.raw(msg.wireRepresentation.data(using: .utf8) ?? Data())`
///
/// **encode(_ command:)** maps `BoardCommand` → `SquareOffCommand` wire bytes:
///   - `.startSession` → `SquareOffCommand.startNewGame` ("14#1*")
///   - `.requestState` → `SquareOffCommand.requestBoardState` ("30#R*")
///   - `.indicateSquares(squares, style:)` → `SquareOffCommand.setLeds(squares:)` ("25#<sq>*")
///     (style is ignored — Square Off supports only on/off LEDs)
///   - `.executeMove(uci:)` → **nil** with a quarantine warning. The `sendMove` ("0#<uci>*")
///     and `sendMoveWithComma` ("24#<from>,<to>*") commands are reverse-engineered
///     with unknown semantics. Their wire effect on motorised Square Off GKS units
///     has NOT been hardware-verified. Returning nil causes the transport to silently
///     skip the command, preventing an inadvertent motor trigger during app development.
///     Remove this guard only after physical-board verification confirms safe behaviour.
///   - `.custom(data)` → `data` verbatim
///
/// **handshakeCommands(isReconnect:)** encodes the safe reconnect rule:
///   - First connect:  `[(.startSession, 250ms), (.requestState, 150ms)]`
///     (the 250ms is the hardware-proven link-settle delay both app
///     transports used as `asyncAfter(0.25)` — do NOT "optimize" it away)
///   - Reconnect:      `[(.requestState, 250ms)]`  (NO startNewGame — board state preserved)
///
/// ## Capabilities
///
/// Square Off boards are occupancy-only (no piece identity). All models support
/// per-square LEDs and move indication. The GKS / original motorised variant
/// supports auto-move, but `executeMove` is kept nil-returning until hardware
/// verification is complete.
public struct SquareOffAdapter: BoardAdapter {

    public var capabilities: BoardCapabilities { .squareOff }

    private var framer = SquareOffFramer()

    public init() {}

    public mutating func feed(bytes: Data) -> [BoardEvent] {
        let messages = framer.append(bytes)
        return messages.compactMap { msg -> BoardEvent? in
            let event = SquareOffParser.event(from: msg)
            switch event {
            case .fieldUpdate(let square, let isLift):
                return .squareSensed(square: square, isLift: isLift, piece: nil)
            case .boardState(let occupancy):
                return .occupancySnapshot(occupancy)
            case .newGameReady:
                // Absorbed into the handshake — surfaces as .ready so the session
                // knows the board has completed its initialisation sequence.
                return .ready
            case .disconnected:
                return .disconnected(error: nil)
            case .raw(let raw):
                return .raw(Data((raw.wireRepresentation).utf8))
            }
        }
    }

    public func encode(_ command: BoardCommand) -> Data? {
        switch command {
        case .startSession:
            return SquareOffCommand.startNewGame.data
        case .requestState:
            return SquareOffCommand.requestBoardState.data
        case .indicateSquares(let squares, _):
            // style is advisory — Square Off only supports on/off per-square LEDs.
            return SquareOffCommand.setLeds(squares: squares).data
        case .executeMove:
            // QUARANTINE: sendMove ("0#<uci>*") and sendMoveWithComma ("24#<from>,<to>*")
            // are reverse-engineered wire commands with unknown hardware semantics.
            // They may trigger the auto-move motor on motorised GKS / Pro models,
            // causing an unexpected physical board-state change during a game.
            // Sessions currently use setLeds for outbound move indication (confirmed
            // LED effect only). Returning nil causes the transport to silently skip
            // this command until hardware-verified behaviour is documented.
            return nil
        case .custom(let data):
            return data
        }
    }

    public func handshakeCommands(isReconnect: Bool) -> [(command: BoardCommand, delayBefore: TimeInterval)] {
        if isReconnect {
            // Mid-game reconnect: request the current board state ONLY so the session
            // can reconcile the occupancy snapshot. Do NOT send startSession (startNewGame)
            // — the board would reset its game state, disrupting the in-progress game.
            // Hardware-verified safe reconnect rule, shipped 2026-07-03.
            return [(.requestState, 0.25)] // 250ms
        } else {
            // Fresh connection: 250ms link-settle before startSession (mirrors the
            // hardware-verified sequence: iOS SquareOffTransport.swift asyncAfter(0.25)
            // before sendInitHandshake, Android SquareOffTransport.swift asyncAfter(0.25)
            // before sendInitHandshake), then 150ms before requestBoardState so the board
            // has time to process the new-game command (iOS/Android sendInitHandshake inner
            // asyncAfter(0.15) pattern).  Pass 2 reference: HEAD iOS:498/519, Android:373/395.
            return [
                (.startSession, 0.25), // 250ms
                (.requestState, 0.15), // 150ms
            ]
        }
    }
}
