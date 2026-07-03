import Foundation
import ChessCore

/// Computes the **minimal, identity-aware** set of physical corrections needed to
/// bring a physical chess board back into agreement with the app's expected Position.
///
/// The board only senses occupancy (occupied / empty per square), never piece
/// identity. But the app *does* know the full expected Position — so corrections
/// can be reasoned about by identity (which piece type + color belongs on a
/// square) rather than by the blunt "this square disagrees" that the old
/// occupancy-only path emitted.
///
/// Two properties this delivers over the old logic:
///   (a) **identity-aware** — a square that needs a piece placed names the exact
///       piece (e.g. "white knight on f3"), and a stray piece + a missing piece
///       that pair up are surfaced as a single *relocate* action rather than two
///       independent prompts.
///   (b) **changed-squares-based** — only squares whose occupancy actually
///       differs from the expected Position produce corrections. A board that is
///       95% correct gets a 3-square correction list, not a full reset; squares
///       that already match are never re-prompted.
///
/// Pure value logic with no actor isolation so it is unit-testable without
/// standing up a session. Occupancy arrays are file-major (a1..a8, b1..b8, …,
/// h1..h8) — the same layout the board reports and `BoardDiffResolver` uses.
/// Renamed from SquareOffCorrectionPlanner on 2026-07-03.
public enum BoardCorrectionPlanner {

    /// A single physical action the user should take to re-sync one square.
    public nonisolated struct Correction: Equatable, Sendable, Hashable {
        public nonisolated enum Kind: Equatable, Sendable, Hashable {
            /// The expected square holds a piece but the board reports it empty —
            /// the user must place `piece` on `square`. `from` is set when a stray
            /// piece elsewhere can supply it (a relocate), nil when the piece must
            /// come from off-board (e.g. a promotion or a piece sitting in a
            /// completely wrong, also-listed square).
            case place(piece: Piece, from: String?)
            /// The board reports a piece on a square the expected position leaves
            /// empty — the user must take that piece off `square`. The board can't
            /// report what the stray piece is, so no identity is carried.
            case remove
        }

        public let square: String
        public let kind: Kind

        public init(square: String, kind: Kind) {
            self.square = square
            self.kind = kind
        }

        /// The expected piece for this square when known (`place`), else nil.
        public var expectedPiece: Piece? {
            if case .place(let piece, _) = kind { return piece }
            return nil
        }

        /// The square a relocate should source the piece from, when known.
        public var fromSquare: String? {
            if case .place(_, let from) = kind { return from }
            return nil
        }
    }

    /// Build the minimal correction set that reconciles `boardOccupancy` (the
    /// board's reported per-square presence) with `expected` (the app's Position).
    ///
    /// Returns an empty array when occupancy already matches — no work, no
    /// prompts. Corrections are emitted ONLY for the squares whose occupancy
    /// differs; correct squares are silently skipped.
    ///
    /// `boardOccupancy` is file-major and must be 64 elements; a malformed
    /// snapshot yields no corrections (the caller keeps the old state).
    public static func corrections(for expected: Position, boardOccupancy: [Bool]) -> [Correction] {
        guard boardOccupancy.count == 64 else { return [] }
        let expectedOccupancy = BoardDiffResolver.occupancyArray(for: expected)

        // Partition the changed squares into "needs a piece placed" (expected
        // occupied, board empty) and "needs clearing" (board occupied, expected
        // empty). Squares whose occupancy already agrees are never touched.
        var needsPlace: [(square: String, piece: Piece)] = []
        var needsRemove: [String] = []
        for file in 0..<8 {
            for rank in 0..<8 {
                let boardIndex = file * 8 + rank          // board's file-major frame
                if expectedOccupancy[boardIndex] == boardOccupancy[boardIndex] { continue }
                let name = squareName(file: file, rank: rank)
                let appIndex = rank * 8 + file            // Position's rank-major frame
                if expectedOccupancy[boardIndex] {
                    // Expected has a piece here, board doesn't → place it. Identity
                    // comes straight from the expected Position.
                    if let piece = expected.board[appIndex] {
                        needsPlace.append((name, piece))
                    }
                } else {
                    needsRemove.append(name)
                }
            }
        }

        // Identity-aware pairing: a stray piece on one square plus a missing
        // piece elsewhere is, physically, usually one relocate rather than a
        // remove + a fetch-from-the-box. The board can't confirm the stray's
        // identity, so we pair greedily and conservatively — each `remove`
        // square can supply at most one `place`, and we prefer the *nearest*
        // missing square so the relocate hint reads naturally (a piece that
        // slid one square over reads as "move e2 → e4", not "move e2 → h7").
        var corrections: [Correction] = []
        var remainingRemoves = needsRemove

        for placement in needsPlace {
            if let strayIndex = nearestStray(to: placement.square, among: remainingRemoves) {
                let from = remainingRemoves.remove(at: strayIndex)
                corrections.append(Correction(
                    square: placement.square,
                    kind: .place(piece: placement.piece, from: from)
                ))
            } else {
                corrections.append(Correction(
                    square: placement.square,
                    kind: .place(piece: placement.piece, from: nil)
                ))
            }
        }

        // Any stray squares left over after pairing are genuine removes (more
        // pieces on the board than the position calls for).
        for square in remainingRemoves {
            corrections.append(Correction(square: square, kind: .remove))
        }

        // Stable ordering: placements first (the actionable "put a piece here"
        // steps), removes last, each group sorted by square name so the list is
        // deterministic across runs and reads top-to-bottom predictably.
        return corrections.sorted { lhs, rhs in
            let lhsPlace = lhs.expectedPiece != nil
            let rhsPlace = rhs.expectedPiece != nil
            if lhsPlace != rhsPlace { return lhsPlace }
            return lhs.square < rhs.square
        }
    }

    /// Index into `strays` of the square geometrically closest to `target`
    /// (Chebyshev distance — king moves), or nil when `strays` is empty. Used to
    /// pick the most plausible source for a relocate hint.
    private static func nearestStray(to target: String, among strays: [String]) -> Int? {
        guard !strays.isEmpty,
              let t = coordinate(of: target) else { return strays.isEmpty ? nil : 0 }
        var best: (index: Int, dist: Int)?
        for (i, stray) in strays.enumerated() {
            guard let s = coordinate(of: stray) else { continue }
            let dist = max(abs(s.file - t.file), abs(s.rank - t.rank))
            if best == nil || dist < best!.dist {
                best = (i, dist)
            }
        }
        return best?.index
    }

    private static func coordinate(of square: String) -> (file: Int, rank: Int)? {
        let chars = Array(square)
        guard chars.count == 2,
              let fileScalar = chars[0].asciiValue,
              let rankScalar = chars[1].asciiValue,
              let aScalar = Character("a").asciiValue,
              let oneScalar = Character("1").asciiValue else { return nil }
        let file = Int(fileScalar) - Int(aScalar)
        let rank = Int(rankScalar) - Int(oneScalar)
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        return (file, rank)
    }

    private static func squareName(file: Int, rank: Int) -> String {
        let files = Array("abcdefgh")
        return "\(files[file])\(rank + 1)"
    }
}
