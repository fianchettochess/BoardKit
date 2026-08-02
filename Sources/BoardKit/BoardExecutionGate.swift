import Foundation
import ChessCore

/// Pure-logic state machine tracking whether the human has physically
/// executed a session-dictated move on a physical chess board.
///
/// After the session plays a move (engine reply, analysis navigation), the
/// session layer instantiates a gate with the expected move and the
/// position before it was applied, then routes every board field event
/// through `feed(square:isLift:)` until the gate reaches `.executed` or
/// `.deviated`. While pending, the session routes field events here instead
/// of into `OccupancyMoveInference`.
///
/// **Physical-effect mapping**
///   - Simple move: lift(from) + place(to)
///   - Capture (capturedSquare == to): lift(from) + lift(to) + place(to).
///     The `to`-place is only credited once the attacker's `from` has been
///     lifted, so a player who lifts and returns the captured piece without
///     executing the attack does not falsely complete the gate.
///   - En passant: lift(from) + lift(capturedPawnSquare) + place(to).
///     The captured pawn square differs from `to` and is inferred from the
///     move geometry (same file as `to`, same rank as `from`).
///   - Castling: lift(kingFrom) + lift(rookFrom) + place(kingTo) + place(rookTo)
///     in any interleaved order.
///   - Promotion: lift(from) + place(to). A subsequent lift+place on `to`
///     after `.executed` is reached (physical queen swap) is absorbed silently.
///
/// **Tolerance rules (mirrors `OccupancyMoveInference` slot tolerance)**
///   - Re-lifts and adjust-in-place events on any *expected* square are no-ops.
///   - Any event on a square *outside* the expected effect set immediately
///     transitions to `.deviated`.
public final class BoardExecutionGate {

    // MARK: - State

    public enum State: Equatable {
        /// Still waiting for one or more expected physical events.
        case inProgress
        /// All required physical changes observed. The gate is done.
        case executed
        /// An unexpected square was touched. Fall through to the occupancy
        /// snapshot / desync flow. The payload lists the offending squares.
        case deviated([String])

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.inProgress, .inProgress), (.executed, .executed): return true
            case let (.deviated(a), .deviated(b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Public interface

    /// The UCI string for the expected move (e.g. "e1g1", "e7e8q").
    public let expectedUCI: String

    /// SAN for the expected move, e.g. "O-O", "Nf3", "exd6 e.p.".
    ///
    /// Provided so a consumer can name the move it is waiting for — in a
    /// prompt, a log line, or an accessibility announcement — without
    /// regenerating legal moves to derive it. The gate does not compose the
    /// sentence: the wording and its language are the consumer's.
    public let san: String

    // MARK: - Immutable effect sets (computed at init)

    /// Every square that may legally be touched during the move execution.
    private let effectSquares: Set<String>
    /// Squares that MUST receive a lift event before the gate can reach .executed.
    private let requiredLifts: Set<String>
    /// Squares that MUST receive a place event before the gate can reach .executed.
    private let requiredPlaces: Set<String>

    /// The mover's from-square, stored for the capture-destination guard.
    private let fromSquare: String
    /// The mover's to-square, stored for the capture-destination guard.
    private let toSquare: String

    // MARK: - Mutable tracking

    private var completedLifts: Set<String> = []
    private var completedPlaces: Set<String> = []
    private var deviatingSquares: [String] = []
    private var currentState: State = .inProgress

    // MARK: - Init

    /// Create a gate for `move` played from `positionBefore`.
    ///
    /// - Parameters:
    ///   - move: The legal move the session has applied to the game tree. Must be
    ///     a move that is legal in `positionBefore`.
    ///   - positionBefore: The board position *before* `move`. Used only to
    ///     derive `san`; the gate's own logic is purely geometric.
    public init(move: Move, positionBefore: Position) {
        self.expectedUCI = move.uci
        self.fromSquare  = move.from.algebraic
        self.toSquare    = move.to.algebraic

        // `algebraicNotation` is pure — no board mutation, no async.
        let legalMoves = MoveGenerator.legalMoves(for: positionBefore)
        self.san = MoveGenerator.algebraicNotation(
            for: move, in: positionBefore, legalMoves: legalMoves
        )

        let (eff, lifts, places) = Self.physicalEffects(move: move)
        self.effectSquares  = eff
        self.requiredLifts  = lifts
        self.requiredPlaces = places
    }

    // MARK: - Public API

    /// Feed one field event (lift or place) into the gate.
    ///
    /// - Returns: `.inProgress` while waiting for more events, `.executed`
    ///   once all physical changes have been observed, or `.deviated` if an
    ///   unexpected square was touched.
    ///
    /// Terminal states (`.executed`, `.deviated`) are sticky — all further
    /// calls return the same value without mutating tracking state.
    @discardableResult
    public func feed(square: String, isLift: Bool) -> State {
        switch currentState {
        case .executed, .deviated: return currentState
        case .inProgress: break
        }

        guard effectSquares.contains(square) else {
            if !deviatingSquares.contains(square) {
                deviatingSquares.append(square)
            }
            currentState = .deviated(deviatingSquares)
            return currentState
        }

        if isLift {
            // Revoke a previously-credited place when the piece lifts back off that
            // square. This handles the castling case where the king rests on the
            // rook-destination square (f1/d1) mid-transit, earning a place credit,
            // and then continues moving — the rook hasn't landed yet so the credit
            // must be revoked to prevent false `.executed`.
            if completedPlaces.contains(square) {
                completedPlaces.remove(square)
            }
            if requiredLifts.contains(square) {
                completedLifts.insert(square)
            }
            // Re-lift of an already-seen or non-required square: no-op beyond above.
        } else {
            // Revoke a previously-credited lift when the piece is returned to a
            // square that is NOT a required place (i.e., the player put the piece
            // back on its origin without completing the move). This handles the
            // attacker-adjust-first capture sequence: lift attacker (c3↑), put it
            // back (c3↓), then interact with the captured piece — without this
            // revocation the c3 lift credit survives and the attacker-absent
            // capture-destination guard passes, causing false `.executed`.
            if completedLifts.contains(square), !requiredPlaces.contains(square) {
                completedLifts.remove(square)
            }
            if requiredPlaces.contains(square) {
                // For normal captures, `to` is in *both* requiredLifts and
                // requiredPlaces. Only credit a place-on-`to` as "attacker
                // arrived" when the attacker's from-square has already been
                // lifted. Without this guard, a player who lifts and returns
                // the captured piece — and then lifts the attacker — would
                // prematurely trigger `.executed` before the attacker lands.
                let isCaptureDestination = requiredLifts.contains(square) && square == toSquare
                if !isCaptureDestination || completedLifts.contains(fromSquare) {
                    completedPlaces.insert(square)
                }
            }
            // Adjust-in-place (place on a non-required-place square, e.g. the
            // from-square): the lift revocation above removes the credit; the
            // gate stays .inProgress.
        }

        if completedLifts == requiredLifts && completedPlaces == requiredPlaces {
            currentState = .executed
        }

        return currentState
    }

    // MARK: - Effect-set computation

    /// Derive the three disjoint-or-overlapping effect sets from a Move.
    ///
    /// `effectSquares` = all squares that may be touched (superset of lifts ∪ places).
    /// `requiredLifts` = squares that MUST be lifted.
    /// `requiredPlaces` = squares that MUST be placed.
    private static func physicalEffects(
        move: Move
    ) -> (effectSquares: Set<String>, requiredLifts: Set<String>, requiredPlaces: Set<String>) {
        let fromSq = move.from.algebraic
        let toSq   = move.to.algebraic

        var effectSquares = Set<String>([fromSq, toSq])
        var requiredLifts  = Set<String>([fromSq])
        var requiredPlaces = Set<String>([toSq])

        // Normal capture: captured piece occupies `to` and must be removed.
        if move.capturedPiece != nil && !move.isEnPassant {
            requiredLifts.insert(toSq)
        }

        // En passant: the captured pawn is on the same file as `to` and the
        // same rank as `from` (holds for both white and black EP).
        if move.isEnPassant {
            let capturedSq = Square(file: move.to.file, rank: move.from.rank).algebraic
            effectSquares.insert(capturedSq)
            requiredLifts.insert(capturedSq)
            // `toSq` remains the pawn's landing square — already in both sets.
        }

        // Castling: rook files are inferred from the king's destination file.
        // King to file 6 = kingside (rook h→f); to file 2 = queenside (rook a→d).
        if move.isCastling {
            let rank = move.from.rank  // king's rank (0 for white, 7 for black)
            let (rookFromFile, rookToFile): (Int, Int) = move.to.file == 6
                ? (7, 5)   // kingside: h-file (7) → f-file (5)
                : (0, 3)   // queenside: a-file (0) → d-file (3)
            let rookFromSq = Square(file: rookFromFile, rank: rank).algebraic
            let rookToSq   = Square(file: rookToFile,   rank: rank).algebraic
            effectSquares.insert(rookFromSq)
            effectSquares.insert(rookToSq)
            requiredLifts.insert(rookFromSq)
            requiredPlaces.insert(rookToSq)
        }

        // Promotion: no additional squares beyond from + to; the physical
        // piece swap (player replaces pawn with a queen) lands back on `to`
        // and is absorbed by the gate's terminal-state sticky behaviour once
        // .executed is reached.

        return (effectSquares, requiredLifts, requiredPlaces)
    }
}
