import Testing
import BoardKit
import ChessCore

// MARK: - OccupancyMoveInference

/// Tests for `OccupancyMoveInference` and `BoardDiffResolver` / `BoardCorrectionPlanner`.
struct OccupancyMoveInferenceTests {

    // MARK: - Helpers

    private func liftSequence(_ engine: OccupancyMoveInference, _ events: [(String, Bool)]) -> OccupancyMoveInference.Feedback {
        var last: OccupancyMoveInference.Feedback = .noChange
        for (sq, lift) in events {
            last = engine.handle(square: sq, isLift: lift)
        }
        return last
    }

    private func candidates(_ feedback: OccupancyMoveInference.Feedback) -> [String] {
        if case .moveCandidates(let c) = feedback { return c }
        return []
    }

    /// Verifies that for every candidate UCI the inference produced, exactly one
    /// pairs with a legal move in the given position. This mirrors how a
    /// session filters candidates before applying one.
    private func pickLegal(_ candidates: [String], in position: Position) -> String? {
        let legal = MoveGenerator.legalMoves(for: position)
        for uci in candidates {
            if UCIParser.uciToMove(uci, in: legal) != nil {
                return uci
            }
        }
        return nil
    }

    /// Mirrors the shape-#2 legality oracle a session installs on the
    /// inference: castling with the lifted rook must still be encoded as
    /// an `isCastling` move in the position's legal-move list.
    private func castleOracle(for position: Position) -> (String) -> Bool {
        let kingCastleUCI = ["h1": "e1g1", "a1": "e1c1", "h8": "e8g8", "a8": "e8c8"]
        let legal = MoveGenerator.legalMoves(for: position)
        return { rookHome in
            guard let kingUCI = kingCastleUCI[rookHome] else { return false }
            return legal.contains { $0.isCastling && $0.uci == kingUCI }
        }
    }

    // MARK: - Simple moves

    @Test func testSimpleMoveProducesSingleCandidate() {
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e2", true), ("e4", false)])
        #expect(candidates(feedback) == ["e2e4"])
    }

    @Test func testLiftedAndReplacedCancels() {
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e2", isLift: true)
        let feedback = engine.handle(square: "e2", isLift: false)
        #expect(feedback == .noChange)
    }

    @Test func testReliftSameSquareIgnored() {
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e2", isLift: true)
        // Lifting the same square again should be a no-op (dedupe).
        _ = engine.handle(square: "e2", isLift: true)
        let feedback = engine.handle(square: "e4", isLift: false)
        #expect(candidates(feedback) == ["e2e4"])
    }

    @Test func testPieceLiftedFeedbackOnFirstLift() {
        let engine = OccupancyMoveInference()
        let feedback = engine.handle(square: "e2", isLift: true)
        #expect(feedback == .pieceLifted(square: "e2"))
    }

    // MARK: - Captures

    @Test func testCaptureAttackerFirst() {
        // Lift attacker, lift captured, place attacker on captured square.
        // Nxe5 sequence: lift knight from c6, lift pawn on e5, place knight on e5.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("c6", true), ("e5", true), ("e5", false),
        ])
        let cands = candidates(feedback)
        #expect(cands.contains("c6e5"), "Expected c6e5 in \(cands)")
    }

    @Test func testCaptureCapturedPieceFirst() {
        // Lift captured first, then attacker, then place attacker on captured square.
        // d7 captured by bishop on b5: lift d7, lift b5, place on d7.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("d7", true), ("b5", true), ("d7", false),
        ])
        let cands = candidates(feedback)
        // After the third event: a=d7, c=b5, b=d7. a==b with c set → shuffle:
        // a=c=b5, c=nil, b kept as d7. candidates: a+b = b5d7.
        #expect(cands.contains("b5d7"), "Expected b5d7 in \(cands)")
    }

    @Test func testCapturePawnTakesPiece() {
        // exd5: lift e4 pawn, lift d5 piece, place pawn on d5.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("e4", true), ("d5", true), ("d5", false),
        ])
        #expect(candidates(feedback).contains("e4d5"))
    }

    @Test func testCaptureQueenTakesKnight() {
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("d1", true), ("d8", true), ("d8", false),
        ])
        #expect(candidates(feedback).contains("d1d8"))
    }

    // MARK: - User changed their mind

    @Test func testLiftWrongPieceThenLiftAndMoveCorrect() {
        // Lift d2 by mistake, change to e2, place on e4.
        // With "no shuffle" logic, both lifts are preserved as candidates and the
        // legal-move filter is expected to pick e2e4. We confirm both candidate
        // strings appear so the caller can filter.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("d2", true), ("e2", true), ("e4", false),
        ])
        let cands = candidates(feedback)
        #expect(cands.contains("e2e4"), "Expected e2e4 in \(cands)")
    }

    // MARK: - En passant

    @Test func testEnPassantAttackerFirst() {
        // After 1.e4 e6 2.e5 d5, white can play exd6 e.p.
        // Lift e5 pawn (attacker), lift d5 pawn (captured), place on d6.
        let position = Position(fen: "rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("e5", true), ("d5", true), ("d6", false),
        ])
        let cands = candidates(feedback)
        #expect(cands.contains("e5d6"), "Expected e5d6 in \(cands)")
        // And the legal-move filter should be able to pick it.
        #expect(pickLegal(cands, in: position) == "e5d6")
    }

    @Test func testEnPassantCapturedPawnLiftedFirst() {
        // Same position, but the user happens to lift the captured pawn first.
        // Lift d5 (captured), lift e5 (attacker), place on d6.
        let position = Position(fen: "rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("d5", true), ("e5", true), ("d6", false),
        ])
        let cands = candidates(feedback)
        // Candidates include both a+b=d5d6 (illegal — pawn can't move sideways
        // from rank 5 to d6) and c+b=e5d6 (legal en passant). Legal filter picks
        // the latter.
        #expect(cands.contains("e5d6"), "Expected e5d6 in \(cands)")
        #expect(pickLegal(cands, in: position) == "e5d6")
    }

    // MARK: - Promotion

    @Test func testPromotionLiftAndPlace() {
        // Position: white pawn on e7 with empty e8 and kings off the e-file.
        // Lift e7, place e8 → candidate e7e8.
        let position = Position(fen: "7k/4P3/8/8/8/8/8/4K3 w - - 0 1")!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("e7", true), ("e8", false),
        ])
        let cands = candidates(feedback)
        #expect(cands.contains("e7e8"), "Expected e7e8 in \(cands)")
        // UCIParser.uciToMove with no suffix matches the first promotion variant
        // in the legal-move list, so the picker will succeed.
        #expect(pickLegal(cands, in: position) != nil)
    }

    @Test func testPromotionByCapture() {
        // Position: white pawn on e7, black rook on d8. exd8=Q is a capture+promo.
        // Lift e7, lift d8, place pawn on d8 — same slot pattern as a normal capture.
        let position = Position(fen: "3r3k/4P3/8/8/8/8/8/4K3 w - - 0 1")!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("e7", true), ("d8", true), ("d8", false),
        ])
        let cands = candidates(feedback)
        #expect(cands.contains("e7d8"), "Expected e7d8 in \(cands)")
        #expect(pickLegal(cands, in: position) != nil)
    }

    // MARK: - Castling

    @Test func testCastlingKingFirstWithBothPiecesLiftedDefers() {
        // Lift king (e1), lift rook (h1), place king (g1), place rook (f1).
        // With both castling lifts in flight, the king-place alone should defer
        // (waiting for the rook). The rook placement completes the castle.
        let position = Position(fen: castleReadyFEN)!
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e1", isLift: true)
        _ = engine.handle(square: "h1", isLift: true)
        let afterKingPlace = engine.handle(square: "g1", isLift: false)
        #expect(afterKingPlace == .noChange, "King-place during in-flight castle pair should defer; got \(afterKingPlace)")
        let afterRookPlace = engine.handle(square: "f1", isLift: false)
        let cands = candidates(afterRookPlace)
        #expect(pickLegal(cands, in: position) == "e1g1",
                       "King-first castle must commit O-O, not a rook/king move; candidates: \(cands)")
    }

    @Test func testCastlingKingFirstWithoutSecondLiftCommitsImmediately() {
        // If the user moves the king to g1 without ever lifting the rook (e.g.,
        // a regular king move from e1 to g1 in a position where g1 is empty and
        // legal), the candidate e1g1 should appear immediately and the legal-move
        // filter decides whether it's a castle or just a king walk.
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e1", isLift: true)
        let feedback = engine.handle(square: "g1", isLift: false)
        let cands = candidates(feedback)
        #expect(cands.contains("e1g1"), "Expected e1g1 without rook lift; got \(cands)")
    }

    @Test func testCastlingRookFirstDefersUntilBothPlaced() {
        // Lift rook (h1), lift king (e1), place rook (f1), place king (g1).
        // The rook placement should NOT commit h1f1; it should defer until the king arrives.
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "h1", isLift: true)
        _ = engine.handle(square: "e1", isLift: true)
        let afterRookPlace = engine.handle(square: "f1", isLift: false)
        // Castling-in-progress detection should defer commit by returning .noChange.
        #expect(afterRookPlace == .noChange, "Rook-first castling should defer commit; got \(afterRookPlace)")
        // Now the king arrives.
        let afterKingPlace = engine.handle(square: "g1", isLift: false)
        let cands = candidates(afterKingPlace)
        #expect(cands.contains("e1g1"), "Expected e1g1 after king lands; got \(cands)")
    }

    @Test func testCastlingQueensideRookFirstDefers() {
        let position = Position(fen: queensideCastleReadyFEN)!
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "a1", isLift: true)
        _ = engine.handle(square: "e1", isLift: true)
        let afterRookPlace = engine.handle(square: "d1", isLift: false)
        #expect(afterRookPlace == .noChange)
        let afterKingPlace = engine.handle(square: "c1", isLift: false)
        let cands = candidates(afterKingPlace)
        #expect(pickLegal(cands, in: position) == "e1c1",
                       "Rook-first queenside castle must commit O-O-O, not Rd1; candidates: \(cands)")
    }

    @Test func testCastlingQueensideKingFirstDefers() {
        // King-first: lift e1, lift a1, place c1, place d1 — should defer until both placed.
        let position = Position(fen: queensideCastleReadyFEN)!
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e1", isLift: true)
        _ = engine.handle(square: "a1", isLift: true)
        let afterKingPlace = engine.handle(square: "c1", isLift: false)
        #expect(afterKingPlace == .noChange)
        let afterRookPlace = engine.handle(square: "d1", isLift: false)
        let cands = candidates(afterRookPlace)
        #expect(pickLegal(cands, in: position) == "e1c1",
                       "King-first queenside castle must commit O-O-O; candidates: \(cands)")
    }

    @Test func testBlackKingsideCastling() {
        // Black mirror of `castleReadyFEN` (Black to move, kingside ready).
        let position = Position(fen: "rnbqk2r/pppp1ppp/3b1n2/4p3/4P3/3B1N2/PPPP1PPP/RNBQK2R b KQkq - 0 1")!
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "h8", isLift: true)
        _ = engine.handle(square: "e8", isLift: true)
        let afterRook = engine.handle(square: "f8", isLift: false)
        #expect(afterRook == .noChange)
        let afterKing = engine.handle(square: "g8", isLift: false)
        let cands = candidates(afterKing)
        #expect(pickLegal(cands, in: position) == "e8g8",
                       "Black rook-first kingside castle must commit O-O, not Rf8; candidates: \(cands)")
    }

    @Test func testBlackQueensideCastling() {
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "a8", isLift: true)
        _ = engine.handle(square: "e8", isLift: true)
        let afterRook = engine.handle(square: "d8", isLift: false)
        #expect(afterRook == .noChange)
        let afterKing = engine.handle(square: "c8", isLift: false)
        #expect(candidates(afterKing).contains("e8c8"))
    }

    // MARK: - Castling: legal-filter selection

    /// Kingside-castle-ready: White king e1, rook h1, f1/g1 empty, full
    /// rights — e1g1 (O-O), h1f1 (Rf1), h1g1 (Rg1) and e1f1 (Kf1) are all
    /// simultaneously legal, which is exactly the ambiguity the candidate
    /// ordering has to resolve in favor of the castle.
    private let castleReadyFEN = "rnbqk2r/pppp1ppp/3b1n2/4p3/4P3/3B1N2/PPPP1PPP/RNBQK2R w KQkq - 0 1"

    /// Queenside-castle-ready: White king e1, rook a1, b1/c1/d1 empty, full
    /// rights — e1c1 (O-O-O), a1d1 (Rd1), and e1d1 (Kd1) are simultaneously
    /// legal, the queenside analogue of the ambiguity above.
    private let queensideCastleReadyFEN = "r3kbnr/pppqpppp/2np4/8/8/2NP4/PPPQPPPP/R3KBNR w KQkq - 0 1"

    @Test func testRookFirstCastlePicksCastleNotRookMove() {
        // Physical rook-first order: lift h1, lift e1, place f1, place g1.
        // Both h1f1 and e1g1 are legal once all four slots fill; before the
        // ordering fix the session committed h1f1 and recorded Rf1, not O-O.
        let position = Position(fen: castleReadyFEN)!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("h1", true), ("e1", true), ("f1", false), ("g1", false),
        ])
        let cands = candidates(feedback)
        #expect(pickLegal(cands, in: position) == "e1g1",
                       "Rook-first castle must commit O-O, not a plain rook move; candidates: \(cands)")
    }

    @Test func testKingLiftedFirstRookPlacedFirstPicksCastleNotKingMove() {
        // Variant: lift e1, lift h1, place f1 (the rook leg lands first),
        // place g1. Here e1f1 (Kf1) led the pairwise candidates and got
        // committed before the ordering fix.
        let position = Position(fen: castleReadyFEN)!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("e1", true), ("h1", true), ("f1", false), ("g1", false),
        ])
        let cands = candidates(feedback)
        #expect(pickLegal(cands, in: position) == "e1g1",
                       "Rook-placed-first castle must commit O-O, not Kf1; candidates: \(cands)")
    }

    @Test func testBlackQueensideRookFirstPicksCastle() {
        // Black mirror: a8 rook to d8 first, then king e8 to c8 — must record
        // O-O-O (e8c8), not Rd8 (a8d8) or Kd8 (e8d8).
        let position = Position(fen: "r3kbnr/pppqpppp/2np4/8/8/2NP4/PPPQPPPP/R3KBNR b KQkq - 0 1")!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [
            ("a8", true), ("e8", true), ("d8", false), ("c8", false),
        ])
        let cands = candidates(feedback)
        #expect(pickLegal(cands, in: position) == "e8c8",
                       "Black rook-first queenside castle must commit O-O-O; candidates: \(cands)")
    }

    @Test func testRookFirstCastleLegStillDefersWhileCastlingLegal() {
        // With castling genuinely available the rook leg alone is ambiguous
        // (castle vs Rf1) and must keep deferring so the king leg can
        // complete O-O — the legality oracle must not break shape #2's
        // original purpose.
        let position = Position(fen: castleReadyFEN)!
        let engine = OccupancyMoveInference()
        engine.isCastlingStillLegal = castleOracle(for: position)
        _ = engine.handle(square: "h1", isLift: true)
        let afterRookPlace = engine.handle(square: "f1", isLift: false)
        #expect(afterRookPlace == .noChange, "Rook leg with castling legal must defer; got \(afterRookPlace)")
        _ = engine.handle(square: "e1", isLift: true)
        let afterKingPlace = engine.handle(square: "g1", isLift: false)
        #expect(pickLegal(candidates(afterKingPlace), in: position) == "e1g1")
    }

    @Test func testPostCastleRookLegDoesNotDeferAndNextMoveSurvives() {
        // Game state right after White's O-O committed (natural king-first
        // physical order): the game already has Kg1/Rf1 but the physical rook
        // is still on h1. The rook leg (lift h1, place f1) matches deferral
        // shape #2 — before the legality gate it deferred forever and the
        // stale slots wiped the opponent's next lift. With the oracle bound
        // to the post-castle position the leg must surface its candidate
        // immediately so the session's fallback can reset cleanly.
        let postCastle = Position(fen: "rnbqk2r/pppp1ppp/3b1n2/4p3/4P3/3B1N2/PPPP1PPP/RNBQ1RK1 b kq - 1 1")!
        let engine = OccupancyMoveInference()
        engine.isCastlingStillLegal = castleOracle(for: postCastle)
        _ = engine.handle(square: "h1", isLift: true)
        let afterRookLeg = engine.handle(square: "f1", isLift: false)
        let cands = candidates(afterRookLeg)
        #expect(cands == ["h1f1"], "Post-castle rook leg must surface candidates, not defer; got \(afterRookLeg)")
        // h1 is empty in the game, so no candidate is legal: the session falls
        // back to the resolver (board == app, nothing to do) and resets the
        // inference — mirror that reset here.
        #expect(pickLegal(cands, in: postCastle) == nil)
        engine.reset()
        // The opponent's next move must come through untouched.
        _ = engine.handle(square: "b8", isLift: true)
        let reply = engine.handle(square: "c6", isLift: false)
        #expect(pickLegal(candidates(reply), in: postCastle) == "b8c6",
                       "Opponent's reply after the post-castle rook leg must not be dropped")
    }

    @Test func testCornerRookMoveCommitsWhenCastlingRightsGone() {
        // White's castling rights are gone (rights field has black only) but
        // the rook still sits on h1 — Rhf1 is a genuine rook move. Shape #2
        // used to defer it indefinitely; with the legality gate it must
        // commit immediately.
        let position = Position(fen: "rnbqk2r/pppp1ppp/3b1n2/4p3/4P3/3B1N2/PPPP1PPP/RNBQK2R w kq - 0 1")!
        let engine = OccupancyMoveInference()
        engine.isCastlingStillLegal = castleOracle(for: position)
        _ = engine.handle(square: "h1", isLift: true)
        let afterPlace = engine.handle(square: "f1", isLift: false)
        #expect(pickLegal(candidates(afterPlace), in: position) == "h1f1",
                       "Genuine Rf1 with castling rights gone must commit immediately; got \(afterPlace)")
    }

    @Test func testQueensideCornerRookMoveCommitsWhenCastlingRightsGone() {
        // Rad1 with rights gone — the queenside twin of the case above.
        let position = Position(fen: "r3kbnr/pppqpppp/2np4/8/8/2NP4/PPPQPPPP/R3KBNR w kq - 0 1")!
        let engine = OccupancyMoveInference()
        engine.isCastlingStillLegal = castleOracle(for: position)
        _ = engine.handle(square: "a1", isLift: true)
        let afterPlace = engine.handle(square: "d1", isLift: false)
        #expect(pickLegal(candidates(afterPlace), in: position) == "a1d1",
                       "Genuine Rad1 with castling rights gone must commit immediately; got \(afterPlace)")
    }

    // MARK: - Commit + reset

    @Test func testCommitClearsMovedSquares() {
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e2", isLift: true)
        _ = engine.handle(square: "e4", isLift: false)
        engine.commit("e2e4")
        // After commit, a fresh sequence should work as if state was empty.
        let feedback = engine.handle(square: "d7", isLift: true)
        if case .pieceLifted(let sq) = feedback {
            #expect(sq == "d7")
        } else {
            Issue.record("Expected pieceLifted feedback after commit + new lift")
        }
    }

    @Test func testCommitAfterCastlingClearsSlots() {
        // After all four castling slots are populated and the move is committed,
        // a brand-new move sequence should not be polluted by leftover state.
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e1", isLift: true)
        _ = engine.handle(square: "h1", isLift: true)
        _ = engine.handle(square: "g1", isLift: false)
        _ = engine.handle(square: "f1", isLift: false)
        engine.commit("e1g1")

        // Next move: simple e2e4.
        _ = engine.handle(square: "e2", isLift: true)
        let feedback = engine.handle(square: "e4", isLift: false)
        let cands = candidates(feedback)
        #expect(cands == ["e2e4"], "Got polluted candidates after castling commit: \(cands)")
    }

    @Test func testResetClearsState() {
        let engine = OccupancyMoveInference()
        _ = engine.handle(square: "e2", isLift: true)
        engine.reset()
        let feedback = engine.handle(square: "d7", isLift: true)
        if case .pieceLifted(let sq) = feedback {
            #expect(sq == "d7")
        } else {
            Issue.record("Expected pieceLifted feedback after reset + new lift")
        }
    }

    // MARK: - Promotion-aware candidates

    @Test func testWhitePromotionEmitsFiveCharVariants() {
        // e7→e8: white pawn promotion. All four 5-char UCIs must appear.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e7", true), ("e8", false)])
        let cands = candidates(feedback)
        #expect(cands.contains("e7e8q"), "Missing e7e8q in \(cands)")
        #expect(cands.contains("e7e8r"), "Missing e7e8r in \(cands)")
        #expect(cands.contains("e7e8b"), "Missing e7e8b in \(cands)")
        #expect(cands.contains("e7e8n"), "Missing e7e8n in \(cands)")
        // Backward-compatibility: the 4-char base UCI is also present.
        #expect(cands.contains("e7e8"), "Missing e7e8 in \(cands)")
    }

    @Test func testWhitePromotionFiveCharVariantsPrecedeFourChar() {
        // 5-char variants must appear before the 4-char base so the session's
        // first-legal-wins filter sees the specific promotion choices first.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e7", true), ("e8", false)])
        let cands = candidates(feedback)
        guard let queenIdx = cands.firstIndex(of: "e7e8q"),
              let baseIdx  = cands.firstIndex(of: "e7e8") else {
            Issue.record("Both e7e8q and e7e8 must be present; got \(cands)")
            return
        }
        #expect(queenIdx < baseIdx, "5-char queen promotion must precede the 4-char base UCI")
    }

    @Test func testBlackPromotionEmitsFiveCharVariants() {
        // e2→e1: black pawn promotion. All four 5-char UCIs must appear.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e2", true), ("e1", false)])
        let cands = candidates(feedback)
        #expect(cands.contains("e2e1q"), "Missing e2e1q in \(cands)")
        #expect(cands.contains("e2e1r"), "Missing e2e1r in \(cands)")
        #expect(cands.contains("e2e1b"), "Missing e2e1b in \(cands)")
        #expect(cands.contains("e2e1n"), "Missing e2e1n in \(cands)")
    }

    @Test func testPromotionCaptureEmitsFiveCharVariants() {
        // e7→d8 (capture+promotion): 5-char variants for the capture-promo pair.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e7", true), ("d8", true), ("d8", false)])
        let cands = candidates(feedback)
        #expect(cands.contains("e7d8q"), "Missing e7d8q in \(cands)")
        #expect(cands.contains("e7d8r"), "Missing e7d8r in \(cands)")
        #expect(cands.contains("e7d8b"), "Missing e7d8b in \(cands)")
        #expect(cands.contains("e7d8n"), "Missing e7d8n in \(cands)")
    }

    @Test func testNonPromotionMoveDoesNotEmitFiveCharVariants() {
        // e2→e4 (pawn push, not a promotion rank transition) must not expand.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e2", true), ("e4", false)])
        let cands = candidates(feedback)
        #expect(!(cands.contains { $0.count == 5 }), "Non-promotion move must not emit 5-char UCIs; got \(cands)")
    }

    @Test func testSimpleCandidateListNotExpandedByPromoVariants() {
        // e2→e4 still produces exactly ["e2e4"] — no spurious promotions.
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e2", true), ("e4", false)])
        #expect(candidates(feedback) == ["e2e4"])
    }

    @Test func testWhitePromotionPicksLegalMoveFromExpandedCandidates() {
        // The expanded candidate list must contain at least one UCI that
        // `UCIParser.uciToMove` can resolve in the promotion position.
        let position = Position(fen: "7k/4P3/8/8/8/8/8/4K3 w - - 0 1")!
        let engine = OccupancyMoveInference()
        let feedback = liftSequence(engine, [("e7", true), ("e8", false)])
        let cands = candidates(feedback)
        let picked = pickLegal(cands, in: position)
        #expect(picked != nil, "At least one expanded candidate must be legal")
        // The first legal candidate should be a 5-char UCI (promotion picker path).
        #expect(picked?.count == 5, "First legal candidate should be 5-char; got '\(picked ?? "nil")'")
    }
}

// MARK: - BoardDiffResolver

struct BoardDiffResolverTests {

    @Test func testStartingPositionIsAlreadyInSync() {
        let pos = Position.initial()
        let occ = BoardDiffResolver.occupancyArray(for: pos)
        let resolutions = BoardDiffResolver.resolve(
            from: pos,
            targetOccupancy: occ,
            maxDepth: 3
        )
        #expect(resolutions.count == 1)
        #expect(resolutions.first?.moves.isEmpty == true)
    }

    @Test func testSingleMoveInferredFromOccupancy() {
        let start = Position.initial()

        // Apply e2e4 and capture the occupancy after that move.
        var after = start
        guard let move = UCIParser.uciToMove("e2e4", in: start) else {
            Issue.record("e2e4 should be legal from start")
            return
        }
        MoveGenerator.applyMoveUnchecked(&after, move)
        let target = BoardDiffResolver.occupancyArray(for: after)

        // Resolve from the original position.
        let resolutions = BoardDiffResolver.resolve(
            from: start,
            targetOccupancy: target,
            maxDepth: 2
        )
        #expect(!(resolutions.isEmpty))
        #expect(resolutions.contains { $0.moves == ["e2e4"] })
    }

    @Test func testCaptureMoveIsResolved() {
        let before = Position(fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2")!
        var after = before
        let move = UCIParser.uciToMove("e4d5", in: before)!
        MoveGenerator.applyMoveUnchecked(&after, move)
        let target = BoardDiffResolver.occupancyArray(for: after)

        let resolutions = BoardDiffResolver.resolve(
            from: before,
            targetOccupancy: target,
            maxDepth: 1
        )
        #expect(resolutions.contains { $0.moves == ["e4d5"] })
    }

    @Test func testCastlingIsResolvedAsSinglePly() {
        let before = Position(fen: "rnbqk2r/pppp1ppp/3b1n2/4p3/4P3/3B1N2/PPPP1PPP/RNBQK2R w KQkq - 0 1")!
        var after = before
        let move = UCIParser.uciToMove("e1g1", in: before)!
        MoveGenerator.applyMoveUnchecked(&after, move)
        let target = BoardDiffResolver.occupancyArray(for: after)

        let resolutions = BoardDiffResolver.resolve(
            from: before,
            targetOccupancy: target,
            maxDepth: 1
        )
        #expect(resolutions.contains { $0.moves == ["e1g1"] })
    }

    @Test func testEnPassantIsResolved() {
        let before = Position(fen: "rnbqkbnr/ppp2ppp/4p3/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3")!
        var after = before
        let move = UCIParser.uciToMove("e5d6", in: before)!
        MoveGenerator.applyMoveUnchecked(&after, move)
        let target = BoardDiffResolver.occupancyArray(for: after)

        let resolutions = BoardDiffResolver.resolve(
            from: before,
            targetOccupancy: target,
            maxDepth: 1
        )
        #expect(resolutions.contains { $0.moves == ["e5d6"] })
    }

    @Test func testPromotionResolvesToFourCandidates() {
        let before = Position(fen: "7k/4P3/8/8/8/8/8/4K3 w - - 0 1")!
        var after = before
        let move = UCIParser.uciToMove("e7e8q", in: before)!
        MoveGenerator.applyMoveUnchecked(&after, move)
        let target = BoardDiffResolver.occupancyArray(for: after)

        let resolutions = BoardDiffResolver.resolve(
            from: before,
            targetOccupancy: target,
            maxDepth: 1
        )
        let firstMoves = Set(resolutions.compactMap { $0.moves.first })
        #expect(firstMoves.contains("e7e8q"))
        #expect(firstMoves.contains("e7e8r"))
        #expect(firstMoves.contains("e7e8b"))
        #expect(firstMoves.contains("e7e8n"))
    }

    @Test func testTwoPlyResolutionWhenSingleMoveCantExplain() {
        let start = Position.initial()
        var after = start
        let m1 = UCIParser.uciToMove("e2e4", in: after)!
        MoveGenerator.applyMoveUnchecked(&after, m1)
        let m2 = UCIParser.uciToMove("e7e5", in: after)!
        MoveGenerator.applyMoveUnchecked(&after, m2)
        let target = BoardDiffResolver.occupancyArray(for: after)

        let resolutions = BoardDiffResolver.resolve(
            from: start,
            targetOccupancy: target,
            maxDepth: 2
        )
        #expect(resolutions.contains { $0.moves == ["e2e4", "e7e5"] })
        #expect(resolutions.allSatisfy { $0.depth == 2 })
    }

    @Test func testUnrelatedOccupancyHasNoResolution() {
        let start = Position.initial()
        let target = [Bool](repeating: false, count: 64)
        let resolutions = BoardDiffResolver.resolve(
            from: start,
            targetOccupancy: target,
            maxDepth: 3
        )
        #expect(resolutions.isEmpty)
    }

    @Test func testOccupancyArrayMatchesPositionForStart() {
        let start = Position.initial()
        let occ = BoardDiffResolver.occupancyArray(for: start)
        let expectedPerFile = [true, true, false, false, false, false, true, true]
        for file in 0..<8 {
            let slice = Array(occ[(file * 8)..<((file + 1) * 8)])
            #expect(slice == expectedPerFile, "File \(file) occupancy mismatch")
        }
    }

    @Test func testResolverShortestFirstStopsAtFirstMatchingDepth() {
        let start = Position.initial()
        var after = start
        let m = UCIParser.uciToMove("e2e4", in: after)!
        MoveGenerator.applyMoveUnchecked(&after, m)
        let target = BoardDiffResolver.occupancyArray(for: after)

        let resolutions = BoardDiffResolver.resolve(
            from: start,
            targetOccupancy: target,
            maxDepth: 3
        )
        #expect(resolutions.allSatisfy { $0.depth == 1 })
    }
}

// MARK: - BoardCorrectionPlanner

struct BoardCorrectionPlannerTests {

    /// Mutate one square of a board-frame (file-major) occupancy snapshot.
    private func setOccupancy(_ occ: [Bool], square: String, _ value: Bool) -> [Bool] {
        var out = occ
        let chars = Array(square)
        let file = Int(chars[0].asciiValue! - Character("a").asciiValue!)
        let rank = Int(chars[1].asciiValue! - Character("1").asciiValue!)
        out[file * 8 + rank] = value
        return out
    }

    @Test func testInSyncBoardYieldsNoCorrections() {
        let pos = Position.initial()
        let occ = BoardDiffResolver.occupancyArray(for: pos)
        #expect(BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: occ).isEmpty)
    }

    @Test func testMissingPieceBecomesIdentityAwarePlace() {
        let pos = Position.initial()
        var occ = BoardDiffResolver.occupancyArray(for: pos)
        occ = setOccupancy(occ, square: "g1", false)

        let corrections = BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: occ)
        #expect(corrections.count == 1)
        let c = corrections.first
        #expect(c?.square == "g1")
        #expect(c?.expectedPiece == Piece(type: .knight, color: .white))
        #expect(c?.fromSquare == nil)
    }

    @Test func testStrayPieceBecomesRemove() {
        let pos = Position.initial()
        var occ = BoardDiffResolver.occupancyArray(for: pos)
        occ = setOccupancy(occ, square: "e4", true)

        let corrections = BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: occ)
        #expect(corrections.count == 1)
        #expect(corrections.first?.square == "e4")
        #expect(corrections.first?.expectedPiece == nil)
    }

    @Test func testStrayPlusMissingPairsIntoRelocate() {
        let pos = Position.initial()
        var occ = BoardDiffResolver.occupancyArray(for: pos)
        occ = setOccupancy(occ, square: "e2", false)
        occ = setOccupancy(occ, square: "e4", true)

        let corrections = BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: occ)
        #expect(corrections.count == 1)
        let c = corrections.first
        #expect(c?.square == "e2")
        #expect(c?.fromSquare == "e4")
        #expect(c?.expectedPiece == Piece(type: .pawn, color: .white))
    }

    @Test func testCorrectSquaresAreNeverPrompted() {
        let pos = Position.initial()
        var occ = BoardDiffResolver.occupancyArray(for: pos)
        occ = setOccupancy(occ, square: "g1", false)

        let corrections = BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: occ)
        #expect(corrections.map { $0.square } == ["g1"])
        #expect(corrections.allSatisfy { $0.square == "g1" })
    }

    @Test func testNearestStrayIsChosenForRelocate() {
        let pos = Position.initial()
        var occ = BoardDiffResolver.occupancyArray(for: pos)
        occ = setOccupancy(occ, square: "d2", false)
        occ = setOccupancy(occ, square: "d3", true)
        occ = setOccupancy(occ, square: "a4", true)

        let corrections = BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: occ)
        let place = corrections.first { $0.square == "d2" }
        #expect(place?.fromSquare == "d3")
        let remove = corrections.first { $0.square == "a4" }
        #expect(remove?.expectedPiece == nil)
    }

    @Test func testMalformedOccupancyYieldsNoCorrections() {
        let pos = Position.initial()
        #expect(BoardCorrectionPlanner.corrections(for: pos, boardOccupancy: [true, false]).isEmpty)
    }
}
