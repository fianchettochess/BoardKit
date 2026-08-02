import Foundation
import ChessCore
import BoardKit

// ── Chessnut stored-game reconstruction ──────────────────────────────────────
//
// Chessnut Air-family boards (Air, Air+, Pro, Go) record games to internal
// flash and can replay them to a host over the file characteristic. This file
// turns that replay — an ordered list of full board-identity snapshots — back
// into a move list and PGN.
//
// Wire background (facts only, both sources MIT-licensed):
//   [C-REF]     chessnutech/EasyLinkSDK  `ChessLink::getFile`
//   [SWIFT-REF] NSStudent/EasyLinkSwiftSDK
//
// A stored game streams as the SAME `0x01` board-state frames the board emits
// in realtime mode, bracketed by `0x37 01 BE` (begin) / `0x37 01 ED` (end).
// Each frame is a full 64-square piece-identity snapshot (piece type + colour
// per square); the board stores positions, NOT algebraic moves. Reconstructing
// the game therefore means diffing consecutive snapshots — logic original to
// this package, not derived from any board vendor's software.

/// Reconstructs a played game from the ordered board-identity snapshots a
/// Chessnut board streams back during a stored-game ("OTB") import.
///
/// ## Strategy
///
/// Walk forward from the standard initial position. For each successive
/// *distinct* snapshot, find the single legal move whose resulting board
/// matches it. A full-identity match (not mere occupancy) resolves captures,
/// castling, en passant, and promotion unambiguously — the promoted piece
/// type distinguishes the four promotion moves, and a move from a given
/// position uniquely determines its resulting board.
///
/// Snapshots identical to the current position (firmware heartbeats or
/// duplicate sends) are skipped. If a snapshot is reached that no legal move
/// explains, the walk stops and returns the moves decoded so far with
/// `isComplete == false` — a partial import beats none, and the caller can
/// surface the truncation.
public enum ChessnutStoredGameDecoder {

    /// A reconstructed game.
    public struct Reconstruction: Sendable, Equatable {
        /// Reconstructed moves, in order.
        public let moves: [Move]
        /// Standard algebraic notation for each move (parallel to `moves`).
        public let sanMoves: [String]
        /// The position reached after the last reconstructed move.
        public let finalPosition: Position
        /// `true` when every snapshot after the first was explained by exactly
        /// one legal move; `false` on a partial reconstruction.
        public let isComplete: Bool
        /// Human-readable reason the walk stopped early, or `nil` when complete.
        public let stopReason: String?

        public init(
            moves: [Move],
            sanMoves: [String],
            finalPosition: Position,
            isComplete: Bool,
            stopReason: String?
        ) {
            self.moves = moves
            self.sanMoves = sanMoves
            self.finalPosition = finalPosition
            self.isComplete = isComplete
            self.stopReason = stopReason
        }

        /// PGN movetext, e.g. `"1. e4 e5 2. Nf3 Nc6"`. Empty when no moves were
        /// reconstructed. No result token is appended — the caller owns tags.
        public var pgnMoveText: String {
            var out = ""
            for (ply, san) in sanMoves.enumerated() {
                if ply % 2 == 0 {
                    if !out.isEmpty { out += " " }
                    out += "\(ply / 2 + 1). \(san)"
                } else {
                    out += " \(san)"
                }
            }
            return out
        }
    }

    /// Why a reconstruction could not even begin.
    public enum Failure: Error, Sendable, Equatable {
        /// No snapshots were supplied.
        case empty
        /// The first snapshot is not the standard initial position, so there is
        /// no anchor to walk from. (Stored games on these boards always begin
        /// from the standard setup; a non-initial first frame means the capture
        /// was partial or the board was mid-game when recording started.)
        case firstSnapshotNotInitial
    }

    /// File-major (a1=0…h8=63) identity of the initial chess position — the
    /// anchor every stored game is validated against.
    static let initialIdentity: [Piece?] = fileMajorIdentity(of: Position.initial())

    /// Reconstruct a game from `snapshots` (each a 64-element file-major
    /// piece-identity array, a1=0…h8=63 — the layout `chessnutDecodeBoard`
    /// produces and `BoardEvent.identitySnapshot` carries).
    public static func reconstruct(
        snapshots: [[Piece?]]
    ) -> Result<Reconstruction, Failure> {
        // Drop leading duplicates so a stream that repeats the initial frame
        // (common: the board sends a heartbeat before the first move) collapses
        // to a single anchor. This never drops a move: only frames identical to
        // their predecessor are removed.
        let deduped = collapseAdjacentDuplicates(snapshots)
        guard let first = deduped.first else { return .failure(.empty) }
        guard first == initialIdentity else { return .failure(.firstSnapshotNotInitial) }

        var position = Position.initial()
        var moves: [Move] = []
        var sanMoves: [String] = []

        for index in 1..<deduped.count {
            let target = deduped[index]
            let legal = MoveGenerator.legalMoves(for: position)

            guard let (move, next) = matchingMove(from: position, legal: legal, target: target) else {
                // Nothing legal reaches this board. Return what we have; the
                // import is partial, and the caller reports the truncation.
                return .success(Reconstruction(
                    moves: moves,
                    sanMoves: sanMoves,
                    finalPosition: position,
                    isComplete: false,
                    stopReason: "snapshot #\(index) is not reachable by a legal move from the reconstructed position"
                ))
            }

            let san = MoveGenerator.algebraicNotation(for: move, in: position, legalMoves: legal)
            moves.append(move)
            sanMoves.append(san)
            position = next
        }

        return .success(Reconstruction(
            moves: moves,
            sanMoves: sanMoves,
            finalPosition: position,
            isComplete: true,
            stopReason: nil
        ))
    }

    // MARK: - Internals

    /// The legal move (and resulting position) whose board matches `target`, or
    /// `nil` if none does. A move from a fixed position uniquely determines its
    /// resulting board, so the first match is the only match.
    static func matchingMove(
        from position: Position,
        legal: [Move],
        target: [Piece?]
    ) -> (move: Move, next: Position)? {
        for move in legal {
            var next = position
            MoveGenerator.applyMoveUnchecked(&next, move)
            if fileMajorIdentity(of: next) == target {
                return (move, next)
            }
        }
        return nil
    }

    /// Convert a `Position` (rank-major board, index = rank*8+file) to a
    /// 64-element file-major identity array (index = file*8+rank) — the layout
    /// board snapshots use. Mirrors `ChessnutPersonality`'s seeding.
    static func fileMajorIdentity(of position: Position) -> [Piece?] {
        var identity = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                identity[file * 8 + rank] = position.board[rank * 8 + file]
            }
        }
        return identity
    }

    /// Remove runs of identical adjacent snapshots, keeping the first of each
    /// run. Duplicate frames carry no move and would otherwise force a
    /// "no legal move" stop.
    static func collapseAdjacentDuplicates(_ snapshots: [[Piece?]]) -> [[Piece?]] {
        var out: [[Piece?]] = []
        out.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if out.last == snapshot { continue }
            out.append(snapshot)
        }
        return out
    }
}
