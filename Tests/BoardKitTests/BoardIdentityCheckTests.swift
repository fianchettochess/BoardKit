import Testing
import BoardKit
import ChessCore

/// `BoardIdentityCheck`: a candidate whose destination reports a different
/// piece than the one the move puts there is contradicted.
struct BoardIdentityCheckTests {

    /// 1.d4 Nf6 2.c4 e6 3.Nc3 d5 4.Nf3 Be7, White to play — d2 empty, the c1
    /// bishop able to reach both d2 and g5, as in the Chessnut Go capture.
    private let beforeBg5 = "rnbqk2r/ppp1bppp/4pn2/3p4/2PP4/2N2N2/PP2PPPP/R1BQKB1R w KQkq - 2 5"

    /// File-major identity of `position`, then the edits a board reports.
    private func sensed(_ position: Position, _ edits: [String: Piece?]) -> [Piece?] {
        var out: [Piece?] = []
        for file in 0..<8 {
            for rank in 0..<8 { out.append(position[Square(file: file, rank: rank)]) }
        }
        for (square, piece) in edits {
            out[ChessBoardGeometry.boardOccupancyIndex(for: square)!] = piece
        }
        return out
    }

    private func move(_ uci: String, _ position: Position) -> Move {
        UCIParser.uciToMove(uci, in: MoveGenerator.legalMoves(for: position))!
    }

    private let whitePawn = Piece(type: .pawn, color: .white)
    private let whiteBishop = Piece(type: .bishop, color: .white)

    @Test func aPhantomPawnOnTheDestinationContradictsTheBishopMove() {
        let position = Position(fen: beforeBg5)!
        // Bishop in hand: c1 empty, the faulty d2 sensor reads a white pawn.
        let board = sensed(position, ["c1": nil, "d2": whitePawn])
        #expect(BoardIdentityCheck.contradicts(move("c1d2", position), in: position, sensed: board))
        // The bishop arriving on g5 is what the board will then show.
        let landed = sensed(position, ["c1": nil, "d2": whitePawn, "g5": whiteBishop])
        #expect(!BoardIdentityCheck.contradicts(move("c1g5", position), in: position, sensed: landed))
        #expect(BoardIdentityCheck.confirms(move("c1g5", position), in: position, sensed: landed))
        // Once the phantom reads empty again, Bd2 is no longer contradicted —
        // but nothing shows it played.
        let flickeredOff = sensed(position, ["c1": nil, "g5": whiteBishop])
        #expect(!BoardIdentityCheck.contradicts(move("c1d2", position), in: position, sensed: flickeredOff))
        #expect(!BoardIdentityCheck.confirms(move("c1d2", position), in: position, sensed: flickeredOff))
    }

    @Test func anUnreadDestinationContradictsNothing() {
        let position = Position(fen: beforeBg5)!
        let board = sensed(position, ["c1": nil])
        #expect(!BoardIdentityCheck.contradicts(move("c1d2", position), in: position, sensed: board))
        #expect(!BoardIdentityCheck.contradicts(move("c1d2", position), in: position, sensed: []))
        #expect(!BoardIdentityCheck.confirms(move("c1d2", position), in: position, sensed: board))
        #expect(!BoardIdentityCheck.confirms(move("c1d2", position), in: position, sensed: []))
    }

    @Test func aCaptureIsJudgedByThePieceThatLands() {
        // 1.e4 d5, White to play exd5.
        let position = Position(fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2")!
        let captured = sensed(position, ["e4": nil])   // the black pawn still reads on d5
        #expect(BoardIdentityCheck.contradicts(move("e4d5", position), in: position, sensed: captured))
        let landed = sensed(position, ["e4": nil, "d5": whitePawn])
        #expect(!BoardIdentityCheck.contradicts(move("e4d5", position), in: position, sensed: landed))
    }

    @Test func castlingChecksTheKingAndTheRook() {
        let position = Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!
        let king = Piece(type: .king, color: .white), rook = Piece(type: .rook, color: .white)
        let castled = sensed(position, ["e1": nil, "h1": nil, "g1": king, "f1": rook])
        #expect(BoardIdentityCheck.confirms(move("e1g1", position), in: position, sensed: castled))
        // King across, rook not yet: not contradicted, not confirmed.
        let kingOnly = sensed(position, ["e1": nil, "g1": king])
        #expect(!BoardIdentityCheck.contradicts(move("e1g1", position), in: position, sensed: kingOnly))
        #expect(!BoardIdentityCheck.confirms(move("e1g1", position), in: position, sensed: kingOnly))
        let wrongRook = sensed(position, ["e1": nil, "h1": nil, "g1": king, "f1": whitePawn])
        #expect(BoardIdentityCheck.contradicts(move("e1g1", position), in: position, sensed: wrongRook))
    }

    @Test func aPromotionAcceptsThePawnBeforeTheSwapAndTheNewPiece() {
        let position = Position(fen: "8/4P3/8/8/8/8/k7/4K3 w - - 0 1")!
        let queen = Piece(type: .queen, color: .white)
        let pawnFirst = sensed(position, ["e7": nil, "e8": whitePawn])
        #expect(BoardIdentityCheck.confirms(move("e7e8q", position), in: position, sensed: pawnFirst))
        let swapped = sensed(position, ["e7": nil, "e8": queen])
        #expect(!BoardIdentityCheck.contradicts(move("e7e8q", position), in: position, sensed: swapped))
        #expect(BoardIdentityCheck.contradicts(move("e7e8n", position), in: position, sensed: swapped))
    }

    @Test func aResolutionToThePhantomSquareIsInconsistent() {
        let position = Position(fen: beforeBg5)!
        // Bishop in hand, phantom pawn on d2: occupancy alone says Bd2.
        let board = sensed(position, ["c1": nil, "d2": whitePawn])
        let occupancy = board.map { $0 != nil }
        let resolutions = BoardDiffResolver.resolve(from: position, targetOccupancy: occupancy, maxDepth: 1)
        #expect(resolutions.map(\.moves) == [["c1d2"]])
        #expect(BoardIdentityCheck.consistent(resolutions, from: position, sensed: board).isEmpty)
        // A bishop really on d2 is consistent.
        let real = sensed(position, ["c1": nil, "d2": whiteBishop])
        #expect(BoardIdentityCheck.consistent(resolutions, from: position, sensed: real) == resolutions)
    }
}
