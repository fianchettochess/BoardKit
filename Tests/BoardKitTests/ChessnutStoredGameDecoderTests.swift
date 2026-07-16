import Testing
import Foundation
import ChessCore
@testable import ChessnutAdapter

/// Reconstruction of stored games from Chessnut board-identity snapshot lists.
///
/// Fixtures are generated the same way a real board records them: play a legal
/// line through ChessCore and take a full file-major identity snapshot after
/// each move. Feeding those snapshots back through the decoder must recover the
/// original moves — the round-trip that proves the diff logic.
struct ChessnutStoredGameDecoderTests {

    // MARK: - Fixture helpers

    /// Play `sans` from the initial position and return the ordered file-major
    /// identity snapshots (one anchor for the start, then one per move).
    private func snapshots(playing sans: [String]) -> [[Piece?]] {
        var position = Position.initial()
        var snaps: [[Piece?]] = [ChessnutStoredGameDecoder.fileMajorIdentity(of: position)]
        for san in sans {
            let legal = MoveGenerator.legalMoves(for: position)
            guard let uci = UCIParser.sanToUCI(san, in: position),
                  let move = legal.first(where: { $0.uci == uci }) else {
                Issue.record("illegal fixture move \(san) in \(position.fen)")
                return snaps
            }
            MoveGenerator.applyMoveUnchecked(&position, move)
            snaps.append(ChessnutStoredGameDecoder.fileMajorIdentity(of: position))
        }
        return snaps
    }

    private func reconstruction(playing sans: [String]) -> ChessnutStoredGameDecoder.Reconstruction {
        switch ChessnutStoredGameDecoder.reconstruct(snapshots: snapshots(playing: sans)) {
        case .success(let r): return r
        case .failure(let f): Issue.record("unexpected failure \(f)"); fatalError()
        }
    }

    // MARK: - Happy path

    @Test func reconstructsMainlineOpening() {
        let sans = ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"]
        let r = reconstruction(playing: sans)
        #expect(r.isComplete)
        #expect(r.stopReason == nil)
        #expect(r.sanMoves == sans)
        #expect(r.moves.count == 6)
        #expect(r.moves.first?.uci == "e2e4")
        #expect(r.pgnMoveText == "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")
    }

    @Test func reconstructsCapture() {
        // Scotch: 3...exd4 is a pawn capture — the vacated e5 and filled d4 must
        // resolve to the single capturing move.
        let sans = ["e4", "e5", "Nf3", "Nc6", "d4", "exd4"]
        let r = reconstruction(playing: sans)
        #expect(r.isComplete)
        #expect(r.sanMoves == sans)
        #expect(r.moves.last?.uci == "e5d4")
    }

    @Test func reconstructsKingsideCastle() {
        // O-O moves TWO pieces (king + rook). Full-identity match must pick the
        // castling move, not a plain king step.
        let sans = ["e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "O-O"]
        let r = reconstruction(playing: sans)
        #expect(r.isComplete)
        #expect(r.moves.last?.isCastling == true)
        #expect(r.moves.last?.uci == "e1g1")
        #expect(r.sanMoves.last == "O-O")
    }

    @Test func reconstructsEnPassant() {
        // 1. e4 d5 2. e5 f5 3. exf6 e.p. removes the f-pawn from f5 while the
        // capturer lands on f6 — a three-square change no plain move produces.
        let sans = ["e4", "d5", "e5", "f5", "exf6"]
        let r = reconstruction(playing: sans)
        #expect(r.isComplete)
        #expect(r.moves.last?.isEnPassant == true)
        #expect(r.moves.last?.uci == "e5f6")
    }

    @Test func reconstructsPromotion() {
        // A pawn queens by capturing the g8 knight. Only the promote-to-queen
        // move yields a queen on g8; the underpromotions produce different
        // identities, so the full-identity match must pick queen.
        let sans = ["h4", "g5", "hxg5", "h6", "gxh6", "a5", "h7", "a4", "hxg8=Q"]
        let r = reconstruction(playing: sans)
        #expect(r.isComplete)
        #expect(r.moves.last?.promotion == .queen)
        #expect(r.moves.last?.uci == "h7g8q")
    }

    // MARK: - Robustness

    @Test func skipsDuplicateFrames() {
        // Firmware heartbeats resend the current board. Injected duplicates must
        // collapse away without breaking move recovery.
        var snaps = snapshots(playing: ["e4", "e5", "Nf3"])
        snaps.insert(snaps[0], at: 1)   // duplicate the start anchor
        snaps.append(snaps.last!)       // duplicate the tail
        snaps.insert(snaps[2], at: 3)   // duplicate a mid frame
        let r: ChessnutStoredGameDecoder.Reconstruction
        switch ChessnutStoredGameDecoder.reconstruct(snapshots: snaps) {
        case .success(let value): r = value
        case .failure(let f): Issue.record("unexpected failure \(f)"); return
        }
        #expect(r.isComplete)
        #expect(r.sanMoves == ["e4", "e5", "Nf3"])
    }

    @Test func emptySnapshotsFails() {
        #expect(ChessnutStoredGameDecoder.reconstruct(snapshots: []) == .failure(.empty))
    }

    @Test func allDuplicateStartCollapsesToZeroMoves() {
        // A capture of nothing but the initial frame (board powered on, no play)
        // reconstructs to a valid empty game.
        let initial = ChessnutStoredGameDecoder.fileMajorIdentity(of: Position.initial())
        switch ChessnutStoredGameDecoder.reconstruct(snapshots: [initial, initial, initial]) {
        case .success(let r):
            #expect(r.isComplete)
            #expect(r.moves.isEmpty)
            #expect(r.pgnMoveText.isEmpty)
        case .failure(let f):
            Issue.record("unexpected failure \(f)")
        }
    }

    @Test func nonInitialFirstSnapshotFails() {
        // Drop the start anchor so the stream begins after 1. e4 — no anchor to
        // walk from.
        var snaps = snapshots(playing: ["e4", "e5"])
        snaps.removeFirst()
        #expect(ChessnutStoredGameDecoder.reconstruct(snapshots: snaps) == .failure(.firstSnapshotNotInitial))
    }

    @Test func partialReconstructionOnUnreachableSnapshot() {
        // Valid start + 1. e4, then a corrupt board (an extra white queen appears
        // out of nowhere) no legal move can produce → partial import.
        var snaps = snapshots(playing: ["e4"])
        var garbage = snaps.last!
        garbage[ChessnutPersonalityIndexHelper.index("d5")] = Piece(type: .queen, color: .white)
        snaps.append(garbage)
        switch ChessnutStoredGameDecoder.reconstruct(snapshots: snaps) {
        case .success(let r):
            #expect(!r.isComplete)
            #expect(r.stopReason != nil)
            #expect(r.sanMoves == ["e4"])   // everything up to the corruption survives
        case .failure(let f):
            Issue.record("unexpected failure \(f)")
        }
    }

    @Test func pgnMoveTextHandlesOddPlyCount() {
        let r = reconstruction(playing: ["e4", "e5", "Nf3"])
        #expect(r.pgnMoveText == "1. e4 e5 2. Nf3")
    }
}

/// Small file-major index helper so the corruption test doesn't reach into the
/// decoder's private conversion. a1=0…h8=63, index = file*8 + rank.
enum ChessnutPersonalityIndexHelper {
    static func index(_ algebraic: String) -> Int {
        let sq = Square(algebraic: algebraic)!
        return sq.file * 8 + sq.rank
    }
}
