import Testing
import BoardKit
import ChessCore

/// Tests for `BoardTakebackDetector` — recognizing a physical take-back as a
/// match against an ancestor position on the current game line.
struct BoardTakebackDetectorTests {

    /// Build a game from SAN and return the mainline nodes (each carries
    /// `positionBefore` / `positionAfter`).
    private func line(_ sans: [String]) -> Game {
        let game = Game()
        for san in sans {
            guard let move = PGNParser.parseMove(san, in: game.position) else {
                Issue.record("illegal SAN in test line: \(san)")
                break
            }
            game.applyMoveFromPGN(move)
        }
        return game
    }

    /// Ancestor positions (1 ply back, 2 plies back, …) from the game's current node.
    private func ancestors(_ game: Game, maxPlies: Int = 6) -> [Position] {
        var result: [Position] = []
        let main = game.mainLine
        var idx = main.count - 1
        while idx >= 0 && result.count < maxPlies {
            result.append(main[idx].positionBefore)
            idx -= 1
        }
        return result
    }

    @Test func singlePlyTakeback() {
        let game = line(["e4"])
        // Board reverted to the position before e4 (pawn back on e2).
        let boardOcc = BoardDiffResolver.occupancyArray(for: game.mainLine.last!.positionBefore)
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: boardOcc,
                                                  ancestorPositions: ancestors(game)) == 1)
    }

    @Test func twoPlyTakeback() {
        let game = line(["e4", "e5"])
        let anc = ancestors(game)               // [before e5, before e4 == initial]
        // Board reverted two plies (both pawns home) → depth 2.
        let initialOcc = BoardDiffResolver.occupancyArray(for: Position.initial())
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: initialOcc, ancestorPositions: anc) == 2)
        // Board reverted one ply (only e5 taken back) → depth 1.
        let afterE4Occ = BoardDiffResolver.occupancyArray(for: game.mainLine[0].positionAfter)
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: afterE4Occ, ancestorPositions: anc) == 1)
    }

    @Test func takebackOfACaptureRestoresBothPieces() {
        // 1.e4 d5 2.exd5 — white pawn captures on d5. Taking it back means the
        // white pawn returns to e4 AND the black pawn returns to d5.
        let game = line(["e4", "d5", "exd5"])
        let beforeCapture = game.mainLine.last!.positionBefore   // after 1.e4 d5
        let boardOcc = BoardDiffResolver.occupancyArray(for: beforeCapture)
        // The occupancy must include the restored black pawn on d5 to match.
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: boardOcc,
                                                  ancestorPositions: ancestors(game)) == 1)
    }

    @Test func forwardOrUnrelatedPositionIsNotATakeback() {
        let game = line(["e4", "e5"])
        // A position that is NOT on the line's ancestry (a different 2nd move).
        let other = line(["e4", "c5"])
        let otherOcc = BoardDiffResolver.occupancyArray(for: other.position)
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: otherOcc,
                                                  ancestorPositions: ancestors(game)) == nil)
    }

    @Test func shallowestMatchWins() {
        // Two identical ancestor positions → the more recent (index 0 → depth 1).
        let game = line(["e4"])
        let before = game.mainLine.last!.positionBefore
        let occ = BoardDiffResolver.occupancyArray(for: before)
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: occ,
                                                  ancestorPositions: [before, before]) == 1)
    }

    @Test func malformedOccupancyReturnsNil() {
        #expect(BoardTakebackDetector.pliesToUndo(boardOccupancy: [true, false],
                                                  ancestorPositions: [Position.initial()]) == nil)
    }
}
