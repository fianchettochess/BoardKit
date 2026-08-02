import Foundation

// Occupancy-based move inference — shared kernel for all occupancy-sensing boards.
//
// Pure state machine: the caller owns the game and validates candidates against
// the legal-move list.

/// Feedback emitted by the move-inference state machine. This package target
/// has no default global actor, so the enum and its `Equatable` conformance are
/// available from non-main-actor contexts.
public enum OccupancyInferenceFeedback: Sendable {
    case pieceLifted(square: String)
    case moveCandidates(_ uciMoves: [String])
    case noChange
}

extension OccupancyInferenceFeedback: Equatable {
    public static func == (lhs: OccupancyInferenceFeedback, rhs: OccupancyInferenceFeedback) -> Bool {
        switch (lhs, rhs) {
        case let (.pieceLifted(a), .pieceLifted(b)): return a == b
        case let (.moveCandidates(a), .moveCandidates(b)): return a == b
        case (.noChange, .noChange): return true
        default: return false
        }
    }
}

/// Infers chess moves from a sequence of lift/place sensor events.
///
/// The board reports per-square presence transitions but no piece identity. Up to four
/// slots are tracked so simple moves, captures, and castling can be reconstructed:
///   - first lifted square (the mover)
///   - first placed square
///   - second lifted square (e.g., captured piece, or rook in castling)
///   - second placed square
///
/// After every event, `candidates()` produces possible UCI strings for the caller to
/// validate against the current legal-move list.
public final class OccupancyMoveInference {

    public typealias Feedback = OccupancyInferenceFeedback

    private var a: String?
    private var b: String?
    private var c: String?
    private var d: String?

    public init() {}

    /// Session-installed legality oracle consulted by the shape-#2 castle
    /// deferral: given the home corner of a lifted rook ("a1"/"h1"/"a8"/"h8"),
    /// returns whether castling with that rook is still legal in the live
    /// game. The state machine knows nothing about the position, and
    /// deferring shape #2 unconditionally left slots stale after every
    /// king-first castle's physical rook leg (which silently dropped the
    /// opponent's next move) and deferred genuine corner-rook moves like
    /// Rhf1/Rad1 when rights were already gone. Defaults to deferring (true)
    /// when unset so the pure state-machine behavior is unchanged for callers
    /// that haven't bound a game.
    public var isCastlingStillLegal: ((_ rookHomeSquare: String) -> Bool)?

    /// The four castle shapes: the lift pair (king home + same-side rook
    /// home), the two placement-target squares, and the king-castle UCI the
    /// legal-move list encodes the castle as. Shared by the in-progress
    /// deferral check and the completed-shape candidate ordering so the two
    /// can't drift.
    private static let castleShapes: [(lifts: Set<String>, placements: Set<String>, kingUCI: String)] = [
        (["e1", "h1"], ["g1", "f1"], "e1g1"),
        (["e1", "a1"], ["c1", "d1"], "e1c1"),
        (["e8", "h8"], ["g8", "f8"], "e8g8"),
        (["e8", "a8"], ["c8", "d8"], "e8c8"),
    ]

    public func reset() {
        a = nil; b = nil; c = nil; d = nil
    }

    /// Drive the state machine with a field update. Returns one or more candidate moves
    /// when the slot pattern suggests a complete move; `pieceLifted` when only the first
    /// lift has been observed.
    public func handle(square: String, isLift: Bool) -> Feedback {
        if isLift {
            // If the player re-lifts a square that already sits in a slot, treat it
            // as a no-op rather than poisoning the state with a duplicate entry.
            if square == a || square == b || square == c || square == d {
                // Already known. Don't re-record.
            } else if a == nil {
                a = square
                return .pieceLifted(square: square)
            } else if c == nil {
                // Second lift — could be the captured piece in Nxe5, or the rook
                // in castling, or the player changing their mind. Keep both lifts;
                // the legal-move filter on candidates() will pick whichever pair
                // forms a valid move.
                c = square
            } else {
                // Three pieces airborne is unusual — overwrite the oldest second
                // lift slot rather than poisoning further.
                c = square
            }
        } else {
            if square == b || square == d {
                // Same square placed twice — ignore to avoid duplicate slots.
            } else if b == nil {
                b = square
            } else {
                d = square
            }
        }

        // a == b means the player picked up and replaced on the same square. With
        // no other lift in flight, that's a cancel. With a second lift in flight,
        // the placement is actually the attacker landing on the captured square
        // (e.g., Bxd7 when the captured piece was lifted first) — promote `c` to
        // be the mover and keep the placement.
        if let a, let b, a == b {
            if let c {
                self.a = c
                self.c = nil
                // Keep `b` — it's the attacker's destination, not a cancel.
            } else {
                reset()
                return .noChange
            }
        }

        // Detect castling-in-progress: both lifts are on king+same-side-rook squares
        // and only one placement has arrived. Defer committing so a partial rook-leg
        // doesn't get accepted as a regular rook move and silently destroy castling
        // rights.
        if isCastlingInProgress() {
            return .noChange
        }

        let cands = uniqueCandidates()
        return cands.isEmpty ? .noChange : .moveCandidates(cands)
    }

    /// True when the slots match one of the two castling-in-progress
    /// shapes that should defer commit until the second placement
    /// arrives:
    ///
    ///   1. King-first or rook-first **with both lifts already seen**:
    ///      `a` and `c` are the king + same-side rook, only `b` is
    ///      placed so far, and that placement is a legitimate
    ///      castle-target square.
    ///   2. **Rook-first with only one lift**: `a` is the home rook,
    ///      `b` is the matching castle-target square (f-file for
    ///      kingside, d-file for queenside), and the king hasn't
    ///      been lifted yet.
    ///
    /// Shape #2 matters because without it, lifting the rook first
    /// (e.g. h1 → f1) emits a single legal-rook-move candidate that the
    /// session immediately commits, destroying castling rights on the
    /// board while the user is still mid-castle. By deferring, we wait for
    /// the king-leg of the move to arrive (the rook-place then
    /// king-lift then king-place sequence flows through shape #1
    /// naturally). Shape #2 is additionally gated on the
    /// `isCastlingStillLegal` oracle: deferring unconditionally left
    /// the slots stale after every king-first castle (the physical
    /// rook leg matched this shape AFTER the castle had already
    /// committed, and the stale slots then swallowed the opponent's
    /// next lift) and deferred genuine corner-rook moves (Rhf1/Rad1
    /// with rights gone). When castling IS still legal, a genuine
    /// rook-only move sits deferred until the next lift event
    /// flushes it through `handle(...)`; the session re-feeds that
    /// flushing lift after commit so the opponent's move survives.
    private func isCastlingInProgress() -> Bool {
        guard let placed = b, d == nil, let a else { return false }
        if let c {
            // Shape #1: both lifts seen.
            let pair = Set([a, c])
            return Self.castleShapes.contains { $0.lifts == pair && $0.placements.contains(placed) }
        }
        // Shape #2: only one lift (a home rook), placed on a castle-
        // target square. The king-leg lift hasn't arrived yet but
        // the partial shape is exactly what a rook-first castle
        // looks like at this point. Only treat it as castling if
        // `a` is a home rook (the corner squares) AND `placed` is
        // its corresponding castle-target — otherwise a casual rook
        // move (h1 → h4) wouldn't match and would commit normally.
        return Self.castleShapes.contains { castle in
            // `lifts` = {king, rook}. We don't know which is which
            // from the set, so identify the rook end as the corner
            // square and the king-target as the placement that's
            // also in the matching `placements` set.
            guard castle.lifts.contains(a) else { return false }
            // Rook lifted: home corner of one of the four castles.
            let rookEnd = castle.lifts.first { ["a1", "h1", "a8", "h8"].contains($0) }
            guard a == rookEnd else { return false }
            guard castle.placements.contains(placed) else { return false }
            // Only defer when castling with this rook is actually still
            // legal — otherwise this is a genuine corner-rook move (or the
            // physical rook leg of an already-committed castle) and must
            // surface its candidate immediately.
            return isCastlingStillLegal?(a) ?? true
        }
    }

    /// When all four slots are populated and form exactly a castle shape
    /// (lifts = {king home, same-side rook home}, placements = the two
    /// castle-target squares), return the king-castle UCI ("e1g1" form).
    /// Used to order that UCI ahead of the pairwise candidates: the session
    /// commits the FIRST legal candidate, and for rook-first (or rook-placed-
    /// first) physical move orders the plain rook/king move (h1f1 / e1f1) is
    /// also legal and would be emitted first, recording Rf1/Kf1 instead of
    /// O-O.
    private func completedCastleUCI() -> String? {
        guard let a, let b, let c, let d else { return nil }
        let lifts = Set([a, c])
        let placements = Set([b, d])
        return Self.castleShapes.first { $0.lifts == lifts && $0.placements == placements }?.kingUCI
    }

    private func uniqueCandidates() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for base in candidates() {
            // Emit 5-char promotion variants before the 4-char base UCI so the
            // session's "first legal candidate wins" filter sees them first and
            // can trigger the promotion picker instead of silently auto-committing
            // the first legal promotion piece.
            for promo in Self.promotionVariants(for: base) {
                if seen.insert(promo).inserted {
                    result.append(promo)
                }
            }
            if seen.insert(base).inserted {
                result.append(base)
            }
        }
        return result
    }

    /// If `uci` is a 4-char UCI from a pawn's pre-promotion rank (7→8 for
    /// white, 2→1 for black), returns the four 5-char promotion variants in
    /// Q/R/B/N order. Returns empty for any other 4-char UCI, and always
    /// returns empty for 5-char UCIs (preventing double-expansion).
    ///
    /// This is a **geometric check only** — the inference machine carries no
    /// piece-identity state. If a non-pawn piece (e.g. a rook) moves from
    /// rank 7 to rank 8, the four spurious 5-char candidates are generated
    /// here but will be discarded by the session's legal-move filter because
    /// non-pawn moves never have promotion types.
    private static func promotionVariants(for uci: String) -> [String] {
        guard uci.count == 4 else { return [] }
        let chars = Array(uci)
        let fromRank = chars[1], toRank = chars[3]
        // White pawn promotion: from rank '7' to rank '8'.
        // Black pawn promotion: from rank '2' to rank '1'.
        let isPromotionRank = (fromRank == "7" && toRank == "8") ||
                              (fromRank == "2" && toRank == "1")
        guard isPromotionRank else { return [] }
        return ["q", "r", "b", "n"].map { uci + $0 }
    }

    /// Generate UCI strings from the current slots, biggest-information first.
    /// Caller filters against legal moves.
    private func candidates() -> [String] {
        var out: [String] = []

        // A complete castle shape emits the king-castle UCI ahead of the
        // pairwise candidates so the session's first-legal-wins filter picks
        // O-O/O-O-O over the simultaneously-legal plain rook/king move. If
        // castling turns out not to be legal, the pairs below still provide
        // the fallback.
        if let castle = completedCastleUCI() {
            out.append(castle)
        }

        if let a, let b, a != b {
            out.append(a + b)
        }
        if let a, let d, a != d {
            out.append(a + d)
        }
        if let c, let b, c != b {
            out.append(c + b)
        }
        if let c, let d, c != d {
            out.append(c + d)
        }
        // Castling encoded as two non-overlapping moves (king + rook).
        // Caller decides which pair forms the legal castling move.
        return out
    }

    /// Drop confirmed move from the buffer so subsequent events build a fresh move.
    /// Always resets — a committed move closes the bookkeeping for that move, and
    /// leftover slots (e.g. the rook's lift/place during castling, which the UCI
    /// string doesn't mention) would otherwise leak into the next move.
    public func commit(_ uci: String) {
        _ = uci
        reset()
    }
}
