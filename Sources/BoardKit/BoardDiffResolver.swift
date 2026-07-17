import Foundation
import ChessCore

/// Reconciles a Position against a 64-bit presence array reported by the board.
///
/// The board only knows which squares are occupied, not what piece sits where. The
/// resolver searches the legal-move tree starting from the app's current position
/// and returns the move sequences whose resulting occupancy exactly matches the
/// board's snapshot.
///
/// Shared kernel — board-agnostic for any occupancy-sensing board (Square Off,
/// DGT Pegasus, etc.). Renamed from SquareOffDiffResolver on 2026-07-03.
public enum BoardDiffResolver {

    public struct Resolution: Equatable, Sendable {
        /// Sequence of UCI strings that, applied in order, produce a position
        /// whose occupancy matches the board snapshot.
        public let moves: [String]
        /// How many plies past the starting position. 1 = a single move.
        public var depth: Int { moves.count }

        public init(moves: [String]) {
            self.moves = moves
        }
    }

    /// Find every move sequence up to `maxDepth` plies that explains the board's
    /// reported occupancy from the given position. Returns shortest first.
    /// `boardOccupancy` is file-major (a1..a8, b1..b8, ..., h1..h8).
    public static func resolve(
        from position: Position,
        targetOccupancy: [Bool],
        maxDepth: Int = 3,
        limit: Int = 8
    ) -> [Resolution] {
        guard targetOccupancy.count == 64 else { return [] }
        let target = sortedOccupancyKey(targetOccupancy)

        // Quick check: already matches.
        if positionOccupancyKey(position) == target {
            return [Resolution(moves: [])]
        }

        // The squares whose occupancy disagrees between the app and the board — the
        // physical change the resolver must explain.
        let appOccupancy = occupancyArray(for: position)
        var changed = Set<Int>()
        for i in 0..<64 where appOccupancy[i] != targetOccupancy[i] { changed.insert(i) }

        // BFS the legal-move tree; collect every match at the SHALLOWEST depth that has
        // any (bounded so a deep branch can't blow up).
        var matches: [Resolution] = []
        var frontier: [(Position, [String])] = [(position, [])]
        // Frontier-width ceiling. At the intended `maxDepth` (≤ ~4) the frontier
        // stays small and this never triggers; it exists so a caller that raises
        // `maxDepth` can't grow the BFS geometrically into an unbounded allocation.
        let maxFrontierWidth = 50_000
        bfs: for depth in 1...maxDepth {
            var nextFrontier: [(Position, [String])] = []
            for (pos, history) in frontier {
                for move in MoveGenerator.legalMoves(for: pos) {
                    var next = pos
                    MoveGenerator.applyMoveUnchecked(&next, move)
                    let path = history + [move.uci]
                    if positionOccupancyKey(next) == target {
                        matches.append(Resolution(moves: path))
                        if matches.count >= 48 { break bfs }
                    }
                    if depth < maxDepth { nextFrontier.append((next, path)) }
                }
            }
            if !matches.isEmpty { break }   // shallowest depth with any explanation
            if nextFrontier.count > maxFrontierWidth {
                nextFrontier.removeLast(nextFrontier.count - maxFrontierWidth)
            }
            frontier = nextFrontier
        }
        if matches.isEmpty { return [] }

        // Rank by plausibility. A move "wanders" when it touches a square that is
        // neither part of the occupancy change nor a capture target — the signature of
        // a coincidental sequence (e.g. a queen sortie that merely reproduces the
        // bit-count) rather than the move that actually happened. Resolutions that
        // explain the change with NO wandering (a single legal capture into the changed
        // square, a direct catch-up) are preferred and offered alone when present;
        // otherwise only the least-wandering few are surfaced (vs the old raw,
        // arbitrarily-ordered list that buried the plausible move under noise).
        let scored = matches.map { (resolution: $0, wander: wanderCount($0, from: position, changed: changed)) }
        let clean = scored.filter { $0.wander == 0 }.map { $0.resolution }
        if !clean.isEmpty {
            return Array(clean.sorted { $0.depth < $1.depth }.prefix(limit))
        }
        return Array(scored.sorted { ($0.wander, $0.resolution.depth) < ($1.wander, $1.resolution.depth) }
                           .map { $0.resolution }.prefix(min(limit, 3)))
    }

    /// How many move endpoints in a resolution fall outside the changed-squares set
    /// without being a capture — a proxy for "this sequence wandered off the actual
    /// physical change." 0 ⇒ every move directly explains part of the diff (the piece
    /// left a changed square and landed on a changed square or captured).
    private static func wanderCount(_ resolution: Resolution, from position: Position, changed: Set<Int>) -> Int {
        var pos = position
        var wander = 0
        for uci in resolution.moves {
            guard let move = UCIParser.uciToMove(uci, in: pos) else { return 999 }
            let fromIndex = move.from.file * 8 + move.from.rank          // file-major (board layout)
            let toIndex = move.to.file * 8 + move.to.rank
            let capturing = pos.board[move.to.rank * 8 + move.to.file] != nil || move.isEnPassant
            if !changed.contains(fromIndex) { wander += 1 }             // left an unchanged square
            if !changed.contains(toIndex) && !capturing { wander += 1 } // landed off-diff, no capture
            MoveGenerator.applyMoveUnchecked(&pos, move)
        }
        return wander
    }

    // MARK: - Occupancy helpers

    /// Convert a Position into the same file-major 64-element [Bool] the board reports.
    public static func occupancyArray(for position: Position) -> [Bool] {
        var out = [Bool](repeating: false, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                let appIndex = rank * 8 + file       // app's rank-major layout
                let boardIndex = file * 8 + rank     // board's file-major layout
                out[boardIndex] = position.board[appIndex] != nil
            }
        }
        return out
    }

    /// 64-character "0"/"1" string suitable as a fast equality key.
    private static func sortedOccupancyKey(_ occupancy: [Bool]) -> String {
        String(occupancy.map { $0 ? "1" : "0" })
    }

    private static func positionOccupancyKey(_ position: Position) -> String {
        sortedOccupancyKey(occupancyArray(for: position))
    }
}
