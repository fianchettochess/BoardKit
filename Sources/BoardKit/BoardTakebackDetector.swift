import ChessCore

/// Detects a physical MOVE TAKE-BACK on an occupancy-sensing board: the player
/// has picked pieces up and returned them to an EARLIER position on the current
/// game line (common in club/casual play to undo an obvious blunder).
///
/// This is the backward complement to `BoardDiffResolver`, which only searches
/// FORWARD from the app's position. A take-back reverts to an ancestor, so it is
/// never forward-reachable — the session reaches this detector only after the
/// forward paths (legal-candidate match, then `BoardDiffResolver`) have failed,
/// so the two never compete.
///
/// Occupancy-only: a match means the *set of occupied squares* agrees. That is
/// exactly what a take-back restores — including any captured piece the player
/// puts back — and it is correct on identity boards too (they carry a superset
/// of the information). It cannot disambiguate two ancestors with identical
/// occupancy, so the SHALLOWEST (most recent) match is returned, which is the
/// intended single- or few-ply take-back.
public enum BoardTakebackDetector {

    /// Number of plies to undo so the app matches the board, or nil if the board
    /// occupancy matches no ancestor.
    ///
    /// - Parameters:
    ///   - boardOccupancy: the board's reported occupancy (`[Bool]`, 64, file-major
    ///     a1..a8,b1..b8,…,h1..h8 — same layout as `BoardDiffResolver`).
    ///   - ancestorPositions: positions reachable by undoing 1, 2, 3, … plies from
    ///     the app's CURRENT position. Index 0 = one ply back, index 1 = two plies
    ///     back, etc. The caller bounds this list (e.g. the last few plies) so a
    ///     distant coincidental occupancy can't trigger a huge rollback.
    /// - Returns: the shallowest matching depth (1-based), or nil.
    public static func pliesToUndo(
        boardOccupancy: [Bool],
        ancestorPositions: [Position]
    ) -> Int? {
        guard boardOccupancy.count == 64 else { return nil }
        for (index, position) in ancestorPositions.enumerated() {
            if BoardDiffResolver.occupancyArray(for: position) == boardOccupancy {
                return index + 1
            }
        }
        return nil
    }
}
