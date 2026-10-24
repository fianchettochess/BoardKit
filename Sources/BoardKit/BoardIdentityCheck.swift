import Foundation
import ChessCore

/// Piece-identity checks for boards that report what stands on each square
/// (`.pieceIdentity`: Chessnut Air/Go/Move, Millennium, a calibrated Certabo
/// RFID board).
///
/// Lift/place inference (`OccupancyMoveInference`) knows only that squares
/// emptied and filled, so a sensor that wrongly reports a neighbouring square
/// occupied can complete a move the player never made. A Chessnut Go capture
/// (2026-10-24) shows it: with the c1 bishop in hand, a faulty d2 sensor
/// flickered "white pawn present", the lift+arrival read as Bc1-d2, and the
/// app committed it while the bishop went to g5. An identity board says WHAT
/// arrived: a pawn on d2 cannot be the bishop that left c1.
///
/// Pure and position-aware, like `BoardDiffResolver`: the session that owns
/// legality decides what to do with a contradicted candidate.
public enum BoardIdentityCheck {

    /// Whether the board's sensed identity contradicts `move` having been
    /// played from `position`: a square the move fills reports a different
    /// piece than the one the move puts there.
    ///
    /// Only a KNOWN contradiction counts. A square the board reports empty
    /// or unreadable (nil) contradicts nothing — the placement may not have
    /// been read yet.
    ///
    /// - Parameters:
    ///   - sensed: file-major (a1, a2, … h8) identity, in game orientation,
    ///     as `BoardEvent.identitySnapshot` carries it.
    public static func contradicts(_ move: Move, in position: Position, sensed: [Piece?]) -> Bool {
        arrivals(of: move, in: position, sensed: sensed).contains { $0 == false }
    }

    /// Whether the board shows `move` played: every square the move fills
    /// reads the piece the move puts there (a promoting pawn may still stand
    /// on the last rank before the swap).
    ///
    /// Stronger than "not contradicted", and what live inference on an
    /// identity board should require: a flickering sensor can read a phantom
    /// piece and then empty again, so a candidate built from that square stops
    /// being contradicted without ever having been played.
    public static func confirms(_ move: Move, in position: Position, sensed: [Piece?]) -> Bool {
        let results = arrivals(of: move, in: position, sensed: sensed)
        return !results.isEmpty && results.allSatisfy { $0 == true }
    }

    /// Whether `position` agrees with every square the board reads a piece
    /// on. A square read as nil (empty or unreadable) is not judged.
    public static func agrees(_ position: Position, sensed: [Piece?]) -> Bool {
        guard sensed.count == 64 else { return true }
        for file in 0..<8 {
            for rank in 0..<8 {
                if let reported = sensed[file * 8 + rank],
                   position[Square(file: file, rank: rank)] != reported { return false }
            }
        }
        return true
    }

    /// The diff resolutions whose resulting position the board's identity
    /// agrees with, in their original order. `BoardDiffResolver` matches
    /// occupancy alone, so with a piece in hand a phantom on a square that
    /// piece can reach is "explained" by moving it there; the identity says
    /// the square holds something else.
    public static func consistent(
        _ resolutions: [BoardDiffResolver.Resolution],
        from position: Position,
        sensed: [Piece?]
    ) -> [BoardDiffResolver.Resolution] {
        resolutions.filter { resolution in
            var after = position
            for uci in resolution.moves {
                guard let move = UCIParser.uciToMove(uci, in: after) else { return false }
                MoveGenerator.applyMoveUnchecked(&after, move)
            }
            return agrees(after, sensed: sensed)
        }
    }

    /// Per square the move fills: true when it reads the arriving piece,
    /// false when it reads another, nil when it reads nothing. Empty when the
    /// input cannot be judged (no mover, or not a 64-square identity).
    private static func arrivals(of move: Move, in position: Position, sensed: [Piece?]) -> [Bool?] {
        guard sensed.count == 64, let mover = position[move.from] else { return [] }
        var arrivals: [(square: Square, piece: Piece)] = [
            (move.to, move.promotion.map { Piece(type: $0, color: mover.color) } ?? mover),
        ]
        if let rook = move.castlingRookTravel {
            arrivals.append((rook.to, Piece(type: .rook, color: mover.color)))
        }
        return arrivals.map { arrival in
            guard let index = ChessBoardGeometry.boardOccupancyIndex(for: arrival.square.algebraic),
                  let reported = sensed[index] else { return nil }
            if reported == arrival.piece { return true }
            // A promoting pawn may stand on the last rank before the swap.
            return move.promotion != nil && arrival.square == move.to && reported == mover
        }
    }
}
