// Shared helpers for the emulator + chaos test suites: seeded random-game
// corpus generation and session-mimicking harnesses for the two kernels.

import Foundation
import ChessCore
import BoardKit
import BoardKitTestSupport
import BoardKitEmulator

// MARK: - Corpus generation

/// One (move, position, context) case from a seeded random game.
struct CorpusCase {
    let uci: String
    let move: Move
    let positionBefore: Position
    let context: ChaosMoveContext
}

/// Play a seeded legal-random game and return a corpus case per ply.
/// Deterministic: same seed → same game.
func generateGameCases(seed: UInt64, maxPlies: Int) async throws -> [CorpusCase] {
    var rng = SeededRNG(seed: seed)
    var position = Position.initial()
    var cases: [CorpusCase] = []
    for _ in 0..<maxPlies {
        let legal = MoveGenerator.legalMoves(for: position)
        guard !legal.isEmpty else { break }
        let move = legal[Int(rng.next() % UInt64(legal.count))]
        let sim = SimulatedBoard(position: position, capabilities: [.occupancySensing, .pieceIdentity])
        let cleanEvents = try await sim.executeMove(uci: move.uci)
        let context = ChaosMoveContext(move: move, positionBefore: position, cleanEvents: cleanEvents)
        cases.append(CorpusCase(uci: move.uci, move: move, positionBefore: position, context: context))
        position = await sim.position
    }
    return cases
}

// MARK: - Inference harness (mimics the session's first-legal-wins commit)

enum InferenceOutcome: Equatable {
    case resolvedIntended
    /// Session would have committed a different legal move.
    case resolvedOther(String)
    /// No legal candidate surfaced — session falls through to the
    /// snapshot / BoardDiffResolver flow.
    case unresolved
}

/// Feed a perturbed stream into `OccupancyMoveInference` exactly as the
/// session does: bind the castling oracle to live legality, filter
/// candidates against the legal-move list, commit the first legal one.
///
/// Promotion nuance: the real session opens a piece picker when the first
/// legal candidate is a promotion, so any promotion candidate sharing the
/// intended from/to counts as resolving the intended move.
func inferenceOutcome(
    events: [ChaosMoveEvent],
    positionBefore: Position,
    intended: String
) -> InferenceOutcome {
    let inference = OccupancyMoveInference()
    let legal = MoveGenerator.legalMoves(for: positionBefore)
    let legalSet = Set(legal.map(\.uci))
    inference.isCastlingStillLegal = { rookHome in
        let castleUCI: String?
        switch rookHome {
        case "h1": castleUCI = "e1g1"
        case "a1": castleUCI = "e1c1"
        case "h8": castleUCI = "e8g8"
        case "a8": castleUCI = "e8c8"
        default:   castleUCI = nil
        }
        guard let castleUCI else { return false }
        return legalSet.contains(castleUCI)
    }
    for event in events {
        let feedback = inference.handle(square: event.square, isLift: event.isLift)
        if case .moveCandidates(let candidates) = feedback {
            if let first = candidates.first(where: { legalSet.contains($0) }) {
                if first == intended { return .resolvedIntended }
                if first.count == 5, intended.count == 5, first.prefix(4) == intended.prefix(4) {
                    return .resolvedIntended   // promotion picker
                }
                return .resolvedOther(first)
            }
        }
    }
    return .unresolved
}

// MARK: - Gate harness

struct GateRun {
    let finalState: BoardExecutionGate.State
    /// Gate reported `.executed` while the physical occupancy did not yet
    /// match the post-move position (the false-complete failure class).
    let falseComplete: Bool
    /// The perturbed stream touched at least one square outside the move's
    /// effect set (the only legitimate reason for `.deviated`).
    let touchedOutsideEffectSet: Bool
}

/// Feed a perturbed stream into `BoardExecutionGate` while tracking a
/// physical occupancy mirror, so false completion can be detected at the
/// exact event where the gate flips to `.executed`.
func runGate(events: [ChaosMoveEvent], corpusCase: CorpusCase) -> GateRun {
    let gate = BoardExecutionGate(move: corpusCase.move, positionBefore: corpusCase.positionBefore)

    var occupancy = BoardDiffResolver.occupancyArray(for: corpusCase.positionBefore)
    var after = corpusCase.positionBefore
    MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
    let expected = BoardDiffResolver.occupancyArray(for: after)

    let effect = corpusCase.context.effectSquares
    var falseComplete = false
    var touchedOutside = false
    var alreadyExecuted = false
    var state = BoardExecutionGate.State.inProgress

    for event in events {
        if !effect.contains(event.square) { touchedOutside = true }
        if let index = fileMajorIndex(event.square) {
            occupancy[index] = !event.isLift
        }
        state = gate.feed(square: event.square, isLift: event.isLift)
        if state == .executed, !alreadyExecuted {
            alreadyExecuted = true
            if occupancy != expected { falseComplete = true }
        }
    }
    return GateRun(finalState: state,
                   falseComplete: falseComplete,
                   touchedOutsideEffectSet: touchedOutside)
}

// MARK: - Small shared helpers

/// File-major index (a1=0…h8=63) for an algebraic square.
func fileMajorIndex(_ square: String) -> Int? {
    guard let sq = Square(algebraic: square) else { return nil }
    return sq.file * 8 + sq.rank
}

/// Extract (square, isLift, piece) tuples from a BoardEvent list.
func sensedTuples(_ events: [BoardEvent]) -> [(square: String, isLift: Bool, piece: Piece?)] {
    events.compactMap {
        if case .squareSensed(let square, let isLift, let piece) = $0 {
            return (square, isLift, piece)
        }
        return nil
    }
}
