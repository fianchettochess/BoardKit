import Testing
import BoardKit
import ChessCore

/// Tests for `BoardExecutionGate` — the pure-logic state machine that
/// verifies the human has physically executed a session-dictated move on the
/// physical chess board.
///
/// Coverage:
///   • Simple move
///   • Capture — attacker-first order
///   • Capture — captured-piece-first order
///   • En passant
///   • Castling — king-first
///   • Castling — rook-first
///   • Promotion without physical piece swap
///   • Promotion with physical piece swap (absorbed)
///   • Adjust-in-place tolerance (lift + put back, then move correctly)
///   • Deviation on an unexpected square
///   • Deviation is terminal
///   • Executed is terminal (all further calls return .executed)
///   • expectedUCI and san
struct BoardExecutionGateTests {

    // MARK: - Helpers

    /// Resolve a UCI string to a legal Move or fail the test.
    private func move(_ uci: String, in position: Position) -> Move {
        guard let m = UCIParser.uciToMove(uci, in: position) else {
            Issue.record("'\(uci)' is not legal in position \(position.fen)")
            // Return a dummy that won't be used (test already fails).
            return Move(from: .init(file: 0, rank: 0), to: .init(file: 0, rank: 1), piece: .pawn)
        }
        return m
    }

    /// Drive the gate with a sequence of (square, isLift) events and
    /// return the final state.
    @discardableResult
    private func feed(
        _ gate: BoardExecutionGate,
        _ events: [(String, Bool)]
    ) -> BoardExecutionGate.State {
        var state: BoardExecutionGate.State = .inProgress
        for (sq, lift) in events {
            state = gate.feed(square: sq, isLift: lift)
        }
        return state
    }

    // MARK: - Positions

    /// Starting position.
    private let start = Position.initial()

    /// White pieces ready for kingside castle: king e1, rook h1, f1/g1 empty.
    private let castleKingsideFEN =
        "rnbqk2r/pppp1ppp/3b1n2/4p3/4P3/3B1N2/PPPP1PPP/RNBQK2R w KQkq - 0 1"

    /// White pieces ready for queenside castle: king e1, rook a1, b1/c1/d1 empty.
    private let castleQueensideFEN =
        "r3kbnr/pppqpppp/2np4/8/8/2NP4/PPPQPPPP/R3KBNR w KQkq - 0 1"

    /// White pawn on e7 about to promote; lone black king on h8.
    private let promotionFEN = "7k/4P3/8/8/8/8/8/4K3 w - - 0 1"

    /// White pawn on e7, black rook on d8 — promotion capture.
    private let promoCaptFEN = "3r3k/4P3/8/8/8/8/8/4K3 w - - 0 1"

    /// En passant: white pawn on e5, black pawn on d5, d6 is the e.p. square.
    private let enPassantFEN =
        "rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"

    /// White knight on c3, black pawn on d5 — Nc3xd5 is a legal capture.
    private let knightCaptureFEN =
        "rnbqkbnr/ppp1pppp/8/3p4/8/2N5/PPPPPPPP/R1BQKBNR w KQkq - 0 1"

    // MARK: - Simple move

    @Test func testSimpleMoveInProgress() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        #expect(gate.feed(square: "e2", isLift: true) == .inProgress)
    }

    @Test func testSimpleMoveExecutedOnPlace() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        #expect(gate.feed(square: "e2", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e4", isLift: false) == .executed)
    }

    @Test func testSimpleMoveOnlyFromAndToAccepted() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        // d3 is not an expected square → deviate immediately.
        #expect(gate.feed(square: "d3", isLift: true) == .deviated(["d3"]))
    }

    // MARK: - Adjust-in-place tolerance

    @Test func testAdjustInPlaceDoesNotFalseTrigger() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        // Player lifts e2, puts it back, then lifts again and places on e4.
        #expect(gate.feed(square: "e2", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e2", isLift: false) == .inProgress,
                       "Placing back on from-square (adjust-in-place) must not advance the gate")
        #expect(gate.feed(square: "e2", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e4", isLift: false) == .executed)
    }

    @Test func testReliftExpectedSquareIsNoOp() {
        // Repeated lift events on the same expected square are tolerated.
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        gate.feed(square: "e2", isLift: true)
        gate.feed(square: "e2", isLift: true)   // re-lift
        #expect(gate.feed(square: "e4", isLift: false) == .executed)
    }

    // MARK: - Capture: attacker first

    @Test func testCaptureAttackerFirstReachesExecuted() {
        // Nc3xd5: lift knight (c3), lift pawn (d5), place knight on d5.
        let position = Position(fen: knightCaptureFEN)!
        let m = move("c3d5", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "c3", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d5", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d5", isLift: false) == .executed)
    }

    // MARK: - Capture: captured-piece first

    @Test func testCaptureCapturedFirstReachesExecuted() {
        // Lift captured pawn (d5) first, then lift knight (c3), then place on d5.
        let position = Position(fen: knightCaptureFEN)!
        let m = move("c3d5", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "d5", isLift: true) == .inProgress)
        #expect(gate.feed(square: "c3", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d5", isLift: false) == .executed)
    }

    @Test func testCaptureAttackerAdjustFirstDoesNotFalseTrigger() {
        // Regression for LENS 1a: if the attacker lifts, is placed back (adjust-in-place),
        // and then the captured piece is lifted and returned, the gate must NOT report
        // .executed — both pieces are still on their original squares.
        // Sequence: c3↑ c3↓ d5↑ d5↓ → .inProgress throughout.
        let position = Position(fen: knightCaptureFEN)!
        let m = move("c3d5", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "c3", isLift: true) == .inProgress,
                       "Attacker lift: still in progress")
        #expect(gate.feed(square: "c3", isLift: false) == .inProgress,
                       "Attacker placed back (adjust): must not credit the lift")
        #expect(gate.feed(square: "d5", isLift: true) == .inProgress,
                       "Captured-piece lift after attacker returned: still in progress")
        // Captured piece returned — the attacker's lift credit was revoked in step 2,
        // so the capture-destination guard must block this place from completing the gate.
        #expect(gate.feed(square: "d5", isLift: false) == .inProgress,
                       "Captured piece returned without attacker present: gate must stay inProgress")
        // Now execute correctly: lift attacker, then place on d5.
        #expect(gate.feed(square: "c3", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d5", isLift: false) == .executed)
    }

    @Test func testCaptureLiftingAndReturningCapturedPieceDoesNotFalseTrigger() {
        // If the player lifts the captured piece, returns it, then lifts the
        // attacker — the gate must NOT report .executed until the attacker
        // actually lands on the destination.
        let position = Position(fen: knightCaptureFEN)!
        let m = move("c3d5", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        // Captured piece lifted and returned.
        gate.feed(square: "d5", isLift: true)
        gate.feed(square: "d5", isLift: false)
        // Attacker lifted but NOT yet placed.
        #expect(gate.feed(square: "c3", isLift: true) == .inProgress,
                       "Gate must not execute before the attacker lands")
        // Attacker placed — now done.
        #expect(gate.feed(square: "d5", isLift: false) == .executed)
    }

    // MARK: - En passant

    @Test func testEnPassantAttackerFirstExecutes() {
        // e5xd6 e.p.: lift e5 pawn, lift d5 captured pawn, place on d6.
        let position = Position(fen: enPassantFEN)!
        let m = move("e5d6", in: position)
        #expect(m.isEnPassant, "Sanity: e5d6 should be en passant")
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "e5", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d5", isLift: true) == .inProgress,
                       "Captured pawn (d5) must be an expected square for en passant")
        #expect(gate.feed(square: "d6", isLift: false) == .executed)
    }

    @Test func testEnPassantCapturedPawnFirstExecutes() {
        // Lift captured pawn (d5) before the attacker (e5).
        let position = Position(fen: enPassantFEN)!
        let m = move("e5d6", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "d5", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e5", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d6", isLift: false) == .executed)
    }

    @Test func testEnPassantTouchingNonEnPassantSquareDeviates() {
        // The en passant move involves e5, d5, d6.  Touching e6 is a deviation.
        let position = Position(fen: enPassantFEN)!
        let m = move("e5d6", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "e5", isLift: true) == .inProgress)
        let result = gate.feed(square: "e6", isLift: false)
        if case .deviated(let squares) = result {
            #expect(squares.contains("e6"))
        } else {
            Issue.record("Expected .deviated; got \(result)")
        }
    }

    // MARK: - Castling king-first

    @Test func testCastlingKingsideKingFirstExecutes() {
        // King e1 first: lift e1, lift h1, place g1, place f1.
        let position = Position(fen: castleKingsideFEN)!
        let m = move("e1g1", in: position)
        #expect(m.isCastling, "Sanity: e1g1 should be castling")
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "e1", isLift: true) == .inProgress)
        #expect(gate.feed(square: "h1", isLift: true) == .inProgress)
        #expect(gate.feed(square: "g1", isLift: false) == .inProgress)
        #expect(gate.feed(square: "f1", isLift: false) == .executed)
    }

    @Test func testCastlingKingsideIntermediateStepsNotExecuted() {
        // After two lifts and only one place, the gate should still be inProgress.
        let position = Position(fen: castleKingsideFEN)!
        let m = move("e1g1", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        gate.feed(square: "e1", isLift: true)
        gate.feed(square: "h1", isLift: true)
        #expect(gate.feed(square: "g1", isLift: false) == .inProgress,
                       "Only one of two required places done — gate must stay inProgress")
    }

    // MARK: - Castling rook-first

    @Test func testCastlingKingsideRookFirstExecutes() {
        // Rook first: lift h1, lift e1, place f1, place g1.
        let position = Position(fen: castleKingsideFEN)!
        let m = move("e1g1", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "h1", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e1", isLift: true) == .inProgress)
        #expect(gate.feed(square: "f1", isLift: false) == .inProgress)
        #expect(gate.feed(square: "g1", isLift: false) == .executed)
    }

    @Test func testCastlingQueensideRookFirstExecutes() {
        // Queenside rook first: lift a1, lift e1, place d1, place c1.
        let position = Position(fen: castleQueensideFEN)!
        let m = move("e1c1", in: position)
        #expect(m.isCastling)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "a1", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e1", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d1", isLift: false) == .inProgress)
        #expect(gate.feed(square: "c1", isLift: false) == .executed)
    }

    @Test func testCastlingKingRestOnF1DoesNotFalseComplete() {
        // Regression for LENS 1a castling: the king physically slides through
        // f1 (place), then continues to g1 (lifts f1 again). f1 is also the
        // rook's required destination. The intermediate f1↓ must not be
        // counted as the rook having landed there.
        // Sequence: e1↑ f1↓ f1↑ g1↓ h1↑ → .inProgress; then f1↓ → .executed.
        let position = Position(fen: castleKingsideFEN)!
        let m = move("e1g1", in: position)
        #expect(m.isCastling, "Sanity: e1g1 should be castling")
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "e1", isLift: true) == .inProgress, "King lift")
        #expect(gate.feed(square: "f1", isLift: false) == .inProgress, "King rests on f1")
        // King lifts off f1 — must revoke the f1 place credit so the rook's
        // eventual landing on f1 is still required.
        #expect(gate.feed(square: "f1", isLift: true) == .inProgress,
                       "King continues off f1: place credit must be revoked")
        #expect(gate.feed(square: "g1", isLift: false) == .inProgress, "King lands on g1")
        #expect(gate.feed(square: "h1", isLift: true) == .inProgress,
                       "Rook lift: both lifts done but rook not yet placed — must stay inProgress")
        // Rook lands on f1 — now all required events observed.
        #expect(gate.feed(square: "f1", isLift: false) == .executed,
                       "Rook lands on f1: gate must reach .executed")
    }

    @Test func testCastlingDeviatesOnNonCastleSquare() {
        // During a kingside castle, touching d1 (not involved) is a deviation.
        let position = Position(fen: castleKingsideFEN)!
        let m = move("e1g1", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        gate.feed(square: "e1", isLift: true)
        let result = gate.feed(square: "d1", isLift: true)
        if case .deviated(let squares) = result {
            #expect(squares.contains("d1"))
        } else {
            Issue.record("Expected .deviated on non-castle square; got \(result)")
        }
    }

    // MARK: - Promotion without physical piece swap

    @Test func testPromotionExecutesOnPawnPlace() {
        // Lift pawn from e7, place it on e8 → .executed (no piece swap needed).
        let position = Position(fen: promotionFEN)!
        // Get the queen promotion move (typically first in the legal list).
        let legalMoves = MoveGenerator.legalMoves(for: position)
        let m = legalMoves.first { $0.from.algebraic == "e7" && $0.to.algebraic == "e8" }!
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "e7", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e8", isLift: false) == .executed)
    }

    // MARK: - Promotion with physical piece swap

    @Test func testPromotionPieceSwapAbsorbedAfterExecution() {
        // After .executed, a further lift+place on the to-square (player swapping
        // the physical pawn for a queen) must be absorbed — not cause a deviation.
        let position = Position(fen: promotionFEN)!
        let legalMoves = MoveGenerator.legalMoves(for: position)
        let m = legalMoves.first { $0.from.algebraic == "e7" && $0.to.algebraic == "e8" }!
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        let completionState = feed(gate, [("e7", true), ("e8", false)])
        #expect(completionState == .executed, "Gate must reach .executed before piece swap")
        // Piece swap: lift pawn off e8, place queen on e8.
        #expect(gate.feed(square: "e8", isLift: true) == .executed,
                       "Post-completion lift on to-square must be absorbed")
        #expect(gate.feed(square: "e8", isLift: false) == .executed,
                       "Post-completion place on to-square must be absorbed")
    }

    @Test func testPromotionCaptureExecutes() {
        // Pawn on e7 captures rook on d8: lift e7, lift d8, place e7-pawn on d8.
        let position = Position(fen: promoCaptFEN)!
        let m = move("e7d8q", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "e7", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d8", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d8", isLift: false) == .executed)
    }

    @Test func testPromotionCaptureCapturedFirstExecutes() {
        // Captured rook lifted first, then pawn, then placed.
        let position = Position(fen: promoCaptFEN)!
        let m = move("e7d8q", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.feed(square: "d8", isLift: true) == .inProgress)
        #expect(gate.feed(square: "e7", isLift: true) == .inProgress)
        #expect(gate.feed(square: "d8", isLift: false) == .executed)
    }

    // MARK: - Deviation

    @Test func testDeviationOnUnexpectedSquare() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        let result = gate.feed(square: "f4", isLift: false)
        if case .deviated(let squares) = result {
            #expect(squares == ["f4"])
        } else {
            Issue.record("Expected .deviated; got \(result)")
        }
    }

    @Test func testDeviationIsTerminal() {
        // After .deviated, all further calls return the same deviated state.
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        gate.feed(square: "g5", isLift: true)         // deviation
        let second = gate.feed(square: "e2", isLift: true)  // expected square, but terminal
        if case .deviated(let squares) = second {
            #expect(squares == ["g5"], "Subsequent calls must not add more squares")
        } else {
            Issue.record("Gate must stay in .deviated; got \(second)")
        }
    }

    @Test func testMultipleDeviationsAccumulateSquares() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        gate.feed(square: "g5", isLift: true)
        // Second unexpected square is NOT added (gate is already terminal).
        let result = gate.feed(square: "h6", isLift: false)
        if case .deviated(let squares) = result {
            #expect(squares.count == 1, "Only the first deviating square is captured")
        } else {
            Issue.record("Expected .deviated")
        }
    }

    // MARK: - Executed is terminal

    @Test func testExecutedIsTerminal() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        gate.feed(square: "e2", isLift: true)
        gate.feed(square: "e4", isLift: false)
        // Any further event — even on an unexpected square — must return .executed.
        #expect(gate.feed(square: "g5", isLift: true) == .executed)
        #expect(gate.feed(square: "e4", isLift: false) == .executed)
    }

    // MARK: - Metadata

    @Test func testExpectedUCIMatchesMoveUCI() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        #expect(gate.expectedUCI == "e2e4")
    }

    @Test func testSANIsTheMovesAlgebraicNotation() {
        let m = move("e2e4", in: start)
        let gate = BoardExecutionGate(move: m, positionBefore: start)
        #expect(gate.san == "e4", "SAN for a pawn push is the destination square; got '\(gate.san)'")
    }

    @Test func testCastlingSANIsTheCastleGlyph() {
        let position = Position(fen: castleKingsideFEN)!
        let m = move("e1g1", in: position)
        let gate = BoardExecutionGate(move: m, positionBefore: position)
        #expect(gate.san == "O-O", "Castling SAN must be O-O; got '\(gate.san)'")
    }
}
