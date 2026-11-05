import Testing
import ChessCore
@testable import BoardKit

struct BoardRecoveryRegressionTests {
    /// Losing an earlier lift on the third sensor event dropped the owner's
    /// Bxc5 and made the rest of the recorded game refer to the wrong pieces.
    @Test(arguments: [["b5", "b6", "c5"], ["b6", "b5", "c5"], ["c5", "b5", "b6"]])
    func anExtraLiftDoesNotEraseTheCaptureOrigin(lifts: [String]) throws {
        let position = try #require(Position(fen: "3k4/5p2/1b3p1p/1pP2P2/4PN2/8/4K2P/8 b - - 0 31"))
        let inference = OccupancyMoveInference()
        for square in lifts { _ = inference.handle(square: square, isLift: true) }
        guard case .moveCandidates(let candidates) = inference.handle(square: "c5", isLift: false) else {
            Issue.record("Capture landing must retain its possible origins"); return
        }
        let legal = candidates.filter { UCIParser.uciToMove($0, in: position) != nil }
        #expect(legal == ["b6c5"])
    }

    /// Occupancy cannot justify moving a knight away and back to fit a king
    /// correction. Offering those histories risks corrupting the recorded game.
    @Test func aKingCorrectionDoesNotInventKnightRoundTrips() throws {
        let before = try #require(Position(fen: "r3r1k1/ppp2ppp/2n2nb1/8/2P3P1/P4N1P/PB3PB1/3RK2R b - - 0 20"))
        var target = BoardDiffResolver.occupancyArray(for: before)
        target[4 * 8] = false // e1
        target[3 * 8 + 1] = true // d2
        #expect(BoardDiffResolver.resolve(from: before, targetOccupancy: target).isEmpty)
    }

    /// Removing unsupported detours must preserve useful three-ply catch-up.
    @Test func distinctRecordedMovesStillResolve() throws {
        let before = Position.initial()
        let moves = ["e2e4", "e7e5", "g1f3"]
        var after = before
        for uci in moves {
            let move = try #require(UCIParser.uciToMove(uci, in: after))
            MoveGenerator.applyMoveUnchecked(&after, move)
        }
        let resolutions = BoardDiffResolver.resolve(from: before, targetOccupancy: BoardDiffResolver.occupancyArray(for: after))
        #expect(resolutions.contains { $0.moves == moves })
    }
}
