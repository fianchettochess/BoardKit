import Foundation
import ChessCore
import BoardKit

// ── ChaosEngine — deterministic fallible-human physical-behaviour model ─────
//
// Transforms the CLEAN physical-event sequence for one chess move (as emitted
// by `SimulatedBoard.executeMove`) into a PERTURBED sequence that models how
// a real human actually handles pieces on a sensor board: j'adoube adjusts,
// captures executed in either order, lift-and-put-back second thoughts, slow
// two-phase castles, pieces slid across intermediate squares, sensor chatter,
// knocked neighbours, promotion piece-swaps, and mid-move stalls.
//
// Shared between the Tier-0 BLE emulator (Sources/BoardKitEmulator) and the
// kernel-survival unit tests, so the exact same fallible human batters both
// the live radio path and CI.
//
// ## Determinism contract
//
// Pure + Sendable + seeded: `perturb` is a pure function of
// (context, profile, RNG state). No `Date`, no default randomness. The same
// `SeededRNG` seed yields byte-identical perturbation streams on every run.
//
// ## Kernel-tolerance classes
//
// Patterns fall into two classes with respect to the shared kernels
// (`OccupancyMoveInference`, `BoardExecutionGate`):
//
// - **Tolerated** (`.casual` / `.clumsy` draw only from these): the inference
//   must still resolve the intended move and the gate must reach `.executed`
//   with no false completion and no deviation. adjustInPlace,
//   sensorChatter (at the mover's own squares), captureOrderSwap,
//   captureLiftReturnRedo, slowCastle (either order), promotionSwap,
//   promotionNoSwap, midMoveStall.
//
// - **Adversarial** (`.hostile` adds these): touches squares outside the
//   move's physical effect set (knockedNeighbor) or blips intermediate
//   squares (slideThroughBlips). The gate LEGITIMATELY deviates (that is its
//   design: hand off to the snapshot/desync flow) and the inference may
//   resolve a different-but-legal move or defer to the resolver class —
//   the survival corpus classifies and asserts that distribution.

// MARK: - Perturbed event

/// One perturbed physical sensor event plus the pause that precedes it.
///
/// `piece` is carried for identity-sensing board emulation (Chessnut frames
/// need to know what landed); occupancy-only consumers ignore it. It is the
/// ground-truth piece for events copied from the clean sequence and a
/// best-effort identity for chaos-inserted events (e.g. the knocked
/// neighbour's occupant).
public struct ChaosMoveEvent: Equatable, Sendable {
    public var square: String
    public var isLift: Bool
    public var piece: Piece?
    /// Pause before this event fires, in milliseconds.
    public var delayBeforeMs: Int

    public init(square: String, isLift: Bool, piece: Piece? = nil, delayBeforeMs: Int = 0) {
        self.square = square
        self.isLift = isLift
        self.piece = piece
        self.delayBeforeMs = delayBeforeMs
    }

    public var delayBefore: Duration { .milliseconds(delayBeforeMs) }
}

// MARK: - Pattern identifiers

/// Named chaos patterns. Every transform the engine can apply is listed
/// here so perturbation results are self-describing (`appliedPatterns`)
/// and test corpora can classify outcomes per pattern.
public enum ChaosPatternID: String, CaseIterable, Sendable {
    /// Lift + replace the mover on its own square before moving (j'adoube).
    case adjustInPlace
    /// Rapid lift/place oscillation at the mover's from-square (bouncy
    /// sensor or nervous fingers).
    case sensorChatter
    /// Capture executed captured-piece-first: lift(captured), lift(attacker),
    /// place(attacker on destination).
    case captureOrderSwap
    /// Lift the captured piece, put it back, then execute the capture
    /// properly (second thoughts).
    case captureLiftReturnRedo
    /// Castle as two sequential piece moves in either order with long pauses.
    case slowCastle
    /// Brief occupancy blips on intermediate squares along a sliding move's
    /// path (piece dragged, not lifted). Adversarial.
    case slideThroughBlips
    /// Spurious lift+place of an adjacent occupied square outside the move's
    /// effect set. Adversarial.
    case knockedNeighbor
    /// Promotion executed physically: pawn placed on the last rank, then
    /// swapped for the promoted piece (lift pawn, place queen).
    case promotionSwap
    /// Promotion where the player never swaps the pawn for the promoted
    /// piece. Identical occupancy stream to a clean promotion; identity
    /// boards keep reporting a pawn on the back rank until re-sync.
    case promotionNoSwap
    /// A long stall in the middle of the move (phone rang, thinking).
    case midMoveStall
}

// MARK: - Profile

/// Escalating probabilities + parameters for each chaos pattern.
///
/// `Equatable` so tests can assert profile identity; all fields are plain
/// values (no closures) to keep the profile `Sendable` and serialisable in
/// failure messages.
public struct ChaosProfile: Equatable, Sendable {

    /// Human-readable profile name (used by the emulator CLI + logs).
    public var name: String

    // Tolerated patterns.
    public var adjustInPlaceProbability: Double
    public var sensorChatterProbability: Double
    /// Lift/place oscillation pairs per chatter burst.
    public var chatterRepetitions: ClosedRange<Int>
    public var captureOrderSwapProbability: Double
    public var captureLiftReturnRedoProbability: Double
    public var slowCastleProbability: Double
    public var promotionSwapProbability: Double
    public var promotionNoSwapProbability: Double
    public var midMoveStallProbability: Double
    /// Stall length, milliseconds.
    public var stallMs: ClosedRange<Int>

    // Adversarial patterns (zero except .hostile).
    public var slideThroughBlipsProbability: Double
    public var knockedNeighborProbability: Double
    /// Given a knock fires, probability it lands MID-move (between the
    /// mover's lift and place) rather than wrapped before the move.
    public var knockedNeighborInterleavedProbability: Double

    // Pacing.
    /// Pause between consecutive events of a normal move, milliseconds.
    public var interEventDelayMs: ClosedRange<Int>
    /// Pause between the two legs of a slow castle, milliseconds.
    public var slowCastleLegPauseMs: ClosedRange<Int>
    /// Chatter oscillation gap, milliseconds.
    public var chatterGapMs: ClosedRange<Int>

    /// True when the profile can draw adversarial patterns; the survival
    /// corpus keys its assertion tier off this.
    public var isAdversarial: Bool {
        slideThroughBlipsProbability > 0 || knockedNeighborProbability > 0
    }

    public init(
        name: String,
        adjustInPlaceProbability: Double,
        sensorChatterProbability: Double,
        chatterRepetitions: ClosedRange<Int>,
        captureOrderSwapProbability: Double,
        captureLiftReturnRedoProbability: Double,
        slowCastleProbability: Double,
        promotionSwapProbability: Double,
        promotionNoSwapProbability: Double,
        midMoveStallProbability: Double,
        stallMs: ClosedRange<Int>,
        slideThroughBlipsProbability: Double,
        knockedNeighborProbability: Double,
        knockedNeighborInterleavedProbability: Double,
        interEventDelayMs: ClosedRange<Int>,
        slowCastleLegPauseMs: ClosedRange<Int>,
        chatterGapMs: ClosedRange<Int>
    ) {
        self.name = name
        self.adjustInPlaceProbability = adjustInPlaceProbability
        self.sensorChatterProbability = sensorChatterProbability
        self.chatterRepetitions = chatterRepetitions
        self.captureOrderSwapProbability = captureOrderSwapProbability
        self.captureLiftReturnRedoProbability = captureLiftReturnRedoProbability
        self.slowCastleProbability = slowCastleProbability
        self.promotionSwapProbability = promotionSwapProbability
        self.promotionNoSwapProbability = promotionNoSwapProbability
        self.midMoveStallProbability = midMoveStallProbability
        self.stallMs = stallMs
        self.slideThroughBlipsProbability = slideThroughBlipsProbability
        self.knockedNeighborProbability = knockedNeighborProbability
        self.knockedNeighborInterleavedProbability = knockedNeighborInterleavedProbability
        self.interEventDelayMs = interEventDelayMs
        self.slowCastleLegPauseMs = slowCastleLegPauseMs
        self.chatterGapMs = chatterGapMs
    }

    // MARK: Presets

    /// No perturbation at all — the clean sequence with steady pacing.
    public static let clean = ChaosProfile(
        name: "clean",
        adjustInPlaceProbability: 0, sensorChatterProbability: 0,
        chatterRepetitions: 1...1,
        captureOrderSwapProbability: 0, captureLiftReturnRedoProbability: 0,
        slowCastleProbability: 0,
        promotionSwapProbability: 0, promotionNoSwapProbability: 0,
        midMoveStallProbability: 0, stallMs: 0...0,
        slideThroughBlipsProbability: 0,
        knockedNeighborProbability: 0, knockedNeighborInterleavedProbability: 0,
        interEventDelayMs: 250...600,
        slowCastleLegPauseMs: 500...900,
        chatterGapMs: 10...30
    )

    /// Ordinary careful player: occasional j'adoube, captures sometimes
    /// executed captured-piece-first, castles at human speed. Every pattern
    /// is kernel-tolerated — the inference must resolve and the gate must
    /// execute for 100 % of casual streams.
    public static let casual = ChaosProfile(
        name: "casual",
        adjustInPlaceProbability: 0.10, sensorChatterProbability: 0.05,
        chatterRepetitions: 1...2,
        captureOrderSwapProbability: 0.25, captureLiftReturnRedoProbability: 0.05,
        slowCastleProbability: 0.50,
        promotionSwapProbability: 0.60, promotionNoSwapProbability: 0.10,
        midMoveStallProbability: 0.05, stallMs: 4_000...12_000,
        slideThroughBlipsProbability: 0,
        knockedNeighborProbability: 0, knockedNeighborInterleavedProbability: 0,
        interEventDelayMs: 250...900,
        slowCastleLegPauseMs: 700...2_500,
        chatterGapMs: 10...40
    )

    /// Fumbling player: same tolerated pattern set as `.casual` at much
    /// higher rates (still zero adversarial patterns, so the kernel
    /// guarantees hold for 100 % of clumsy streams too).
    public static let clumsy = ChaosProfile(
        name: "clumsy",
        adjustInPlaceProbability: 0.35, sensorChatterProbability: 0.25,
        chatterRepetitions: 1...3,
        captureOrderSwapProbability: 0.40, captureLiftReturnRedoProbability: 0.25,
        slowCastleProbability: 0.85,
        promotionSwapProbability: 0.70, promotionNoSwapProbability: 0.20,
        midMoveStallProbability: 0.15, stallMs: 5_000...20_000,
        slideThroughBlipsProbability: 0,
        knockedNeighborProbability: 0, knockedNeighborInterleavedProbability: 0,
        interEventDelayMs: 200...1_200,
        slowCastleLegPauseMs: 900...3_000,
        chatterGapMs: 8...60
    )

    /// Worst realistic human: everything in `.clumsy` plus dragged pieces
    /// (slide-through blips) and knocked neighbours. Streams from this
    /// profile MAY legitimately deviate the gate and push the inference to
    /// resolver-class outcomes; the survival corpus asserts the outcome
    /// distribution rather than perfection.
    public static let hostile = ChaosProfile(
        name: "hostile",
        adjustInPlaceProbability: 0.35, sensorChatterProbability: 0.30,
        chatterRepetitions: 1...4,
        captureOrderSwapProbability: 0.40, captureLiftReturnRedoProbability: 0.30,
        slowCastleProbability: 0.85,
        promotionSwapProbability: 0.70, promotionNoSwapProbability: 0.25,
        midMoveStallProbability: 0.20, stallMs: 5_000...30_000,
        slideThroughBlipsProbability: 0.35,
        knockedNeighborProbability: 0.30, knockedNeighborInterleavedProbability: 0.5,
        interEventDelayMs: 150...1_500,
        slowCastleLegPauseMs: 900...4_000,
        chatterGapMs: 5...80
    )

    /// Lookup by CLI name.
    public static func named(_ name: String) -> ChaosProfile? {
        switch name.lowercased() {
        case "clean":   return .clean
        case "casual":  return .casual
        case "clumsy":  return .clumsy
        case "hostile": return .hostile
        default:        return nil
        }
    }
}

// MARK: - Move context

/// Everything the engine needs to know about one move to perturb it:
/// the clean sensor sequence, the move's geometry, and the position it is
/// played from (for neighbour selection and identity tagging).
public struct ChaosMoveContext: Sendable {
    public let intendedUCI: String
    public let fromSquare: String
    public let toSquare: String
    /// Square the captured piece physically sits on (== `toSquare` for a
    /// normal capture, the passed pawn's square for en passant, nil for a
    /// non-capture).
    public let capturedSquare: String?
    public let isEnPassant: Bool
    public let isCastle: Bool
    public let rookFromSquare: String?
    public let rookToSquare: String?
    public let isPromotion: Bool
    /// Promoted piece for identity tagging (nil for non-promotions).
    public let promotedPiece: Piece?
    /// Intermediate squares strictly between from and to along a straight or
    /// diagonal path (empty for knight moves and single steps).
    public let pathSquares: [String]
    /// File-major (a1=0…h8=63) identity of the position BEFORE the move.
    public let identityBefore: [Piece?]
    /// The clean sensor sequence, extracted from `SimulatedBoard` events.
    public let cleanEvents: [ChaosMoveEvent]

    /// Every square the move may legitimately touch — mirrors
    /// `BoardExecutionGate`'s effect-set geometry so adversarial patterns
    /// know what counts as "outside".
    public var effectSquares: Set<String> {
        var set: Set<String> = [fromSquare, toSquare]
        if let capturedSquare { set.insert(capturedSquare) }
        if let rookFromSquare { set.insert(rookFromSquare) }
        if let rookToSquare { set.insert(rookToSquare) }
        return set
    }

    /// Build a context from a ChessCore move + the position it is played
    /// from + the clean `BoardEvent` sequence `SimulatedBoard.executeMove`
    /// produced for it.
    ///
    /// `cleanEvents` non-`squareSensed` cases are ignored; sensed events are
    /// copied with their piece identity (when the SimulatedBoard was created
    /// with `.pieceIdentity`).
    public init(move: Move, positionBefore: Position, cleanEvents: [BoardEvent]) {
        self.intendedUCI = move.uci
        self.fromSquare = move.from.algebraic
        self.toSquare = move.to.algebraic
        self.isEnPassant = move.isEnPassant
        self.isCastle = move.isCastling
        self.isPromotion = move.promotion != nil

        if move.isEnPassant {
            self.capturedSquare = Square(file: move.to.file, rank: move.from.rank).algebraic
        } else if move.capturedPiece != nil {
            self.capturedSquare = move.to.algebraic
        } else {
            self.capturedSquare = nil
        }

        if move.isCastling {
            let rank = move.from.rank
            let (rookFromFile, rookToFile): (Int, Int) = move.to.file == 6 ? (7, 5) : (0, 3)
            self.rookFromSquare = Square(file: rookFromFile, rank: rank).algebraic
            self.rookToSquare = Square(file: rookToFile, rank: rank).algebraic
        } else {
            self.rookFromSquare = nil
            self.rookToSquare = nil
        }

        let moverColor = positionBefore.board[move.from.rank * 8 + move.from.file]?.color
        if let promo = move.promotion, let color = moverColor {
            self.promotedPiece = Piece(type: promo, color: color)
        } else {
            self.promotedPiece = nil
        }

        self.pathSquares = Self.intermediateSquares(from: move.from, to: move.to)

        // File-major identity (a1=0…h8=63) from the rank-major Position board.
        var identity = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                identity[file * 8 + rank] = positionBefore.board[rank * 8 + file]
            }
        }
        self.identityBefore = identity

        self.cleanEvents = cleanEvents.compactMap { event in
            if case .squareSensed(let square, let isLift, let piece) = event {
                return ChaosMoveEvent(square: square, isLift: isLift, piece: piece)
            }
            return nil
        }
    }

    /// Squares strictly between two squares along a rank, file, or diagonal.
    /// Empty for knight moves, king steps, and non-aligned pairs.
    static func intermediateSquares(from: Square, to: Square) -> [String] {
        let df = to.file - from.file
        let dr = to.rank - from.rank
        let aligned = df == 0 || dr == 0 || abs(df) == abs(dr)
        guard aligned else { return [] }
        let steps = max(abs(df), abs(dr))
        guard steps > 1 else { return [] }
        let stepF = df == 0 ? 0 : df / abs(df)
        let stepR = dr == 0 ? 0 : dr / abs(dr)
        return (1..<steps).map { i in
            Square(file: from.file + stepF * i, rank: from.rank + stepR * i).algebraic
        }
    }
}

// MARK: - Perturbation result

/// The perturbed sensor stream plus the patterns that produced it.
public struct ChaosPerturbation: Equatable, Sendable {
    public var events: [ChaosMoveEvent]
    public var appliedPatterns: [ChaosPatternID]

    public init(events: [ChaosMoveEvent], appliedPatterns: [ChaosPatternID]) {
        self.events = events
        self.appliedPatterns = appliedPatterns
    }
}

// MARK: - Engine

/// Applies a `ChaosProfile` to one move's clean sensor sequence.
///
/// Composition order per move:
///  1. Pre-move fidgets: knockedNeighbor (wrapped variant), adjustInPlace,
///     sensorChatter — each an independent probability draw.
///  2. One CORE transform, drawn from the patterns applicable to the move
///     type (captureOrderSwap / captureLiftReturnRedo for captures,
///     slowCastle for castles, promotionSwap / promotionNoSwap for
///     promotions, slideThroughBlips for sliding moves).
///  3. Mid-move insertions: knockedNeighbor (interleaved variant).
///  4. Timing: pacing on every event, midMoveStall on one interior event.
public struct ChaosEngine: Sendable {

    public var profile: ChaosProfile

    public init(profile: ChaosProfile) {
        self.profile = profile
    }

    /// Perturb one move. Pure: identical (context, profile, rng-state)
    /// triples produce identical results.
    public func perturb(_ context: ChaosMoveContext, rng: inout SeededRNG) -> ChaosPerturbation {
        var applied: [ChaosPatternID] = []

        // ── 2. Core transform (drawn first so pre-move fidgets can be
        //       prepended to the transformed body) ─────────────────────────
        var body = context.cleanEvents.map { ChaosMoveEvent(square: $0.square, isLift: $0.isLift, piece: $0.piece) }

        if context.capturedSquare != nil {
            // Captures: at most one of the two capture transforms.
            if rng.chance(profile.captureOrderSwapProbability) {
                body = captureOrderSwapped(context)
                applied.append(.captureOrderSwap)
            } else if rng.chance(profile.captureLiftReturnRedoProbability) {
                body = captureLiftReturnRedone(context)
                applied.append(.captureLiftReturnRedo)
            }
        } else if context.isCastle {
            if rng.chance(profile.slowCastleProbability) {
                body = slowCastled(context, rng: &rng)
                applied.append(.slowCastle)
            }
        } else if context.isPromotion {
            if rng.chance(profile.promotionSwapProbability) {
                body = promotionSwapped(context)
                applied.append(.promotionSwap)
            } else if rng.chance(profile.promotionNoSwapProbability) {
                body = promotionUnswapped(context)
                applied.append(.promotionNoSwap)
            }
        } else if !context.pathSquares.isEmpty {
            if rng.chance(profile.slideThroughBlipsProbability) {
                body = slideThroughBlipped(context, rng: &rng)
                applied.append(.slideThroughBlips)
            }
        }

        // ── 3. Mid-move knocked neighbour (adversarial) ───────────────────
        //
        // Wrapped-before knocks are handled in step 1 below; draw the knock
        // once and remember its flavour.
        var wrappedKnock: [ChaosMoveEvent] = []
        if rng.chance(profile.knockedNeighborProbability),
           let neighbor = knockableNeighbor(context, rng: &rng) {
            let piece = pieceAt(neighbor, in: context)
            let pair = [
                ChaosMoveEvent(square: neighbor, isLift: true, piece: piece),
                ChaosMoveEvent(square: neighbor, isLift: false, piece: piece),
            ]
            if rng.chance(profile.knockedNeighborInterleavedProbability), body.count >= 2 {
                // Insert the knock between the first and second body events
                // (mid-move: the mover is airborne).
                body.insert(contentsOf: pair, at: 1)
            } else {
                wrappedKnock = pair
            }
            applied.append(.knockedNeighbor)
        }

        // ── 1. Pre-move fidgets ───────────────────────────────────────────
        var prefix: [ChaosMoveEvent] = wrappedKnock
        if rng.chance(profile.adjustInPlaceProbability) {
            let piece = pieceAt(context.fromSquare, in: context)
            prefix += [
                ChaosMoveEvent(square: context.fromSquare, isLift: true, piece: piece),
                ChaosMoveEvent(square: context.fromSquare, isLift: false, piece: piece),
            ]
            applied.append(.adjustInPlace)
        }
        if rng.chance(profile.sensorChatterProbability) {
            let reps = rng.int(in: profile.chatterRepetitions)
            let piece = pieceAt(context.fromSquare, in: context)
            for _ in 0..<reps {
                prefix += [
                    ChaosMoveEvent(square: context.fromSquare, isLift: true, piece: piece,
                                   delayBeforeMs: rng.int(in: profile.chatterGapMs)),
                    ChaosMoveEvent(square: context.fromSquare, isLift: false, piece: piece,
                                   delayBeforeMs: rng.int(in: profile.chatterGapMs)),
                ]
            }
            applied.append(.sensorChatter)
        }

        var events = prefix + body

        // ── 4. Timing ─────────────────────────────────────────────────────
        for i in events.indices where events[i].delayBeforeMs == 0 {
            events[i].delayBeforeMs = rng.int(in: profile.interEventDelayMs)
        }
        if events.count > 1, rng.chance(profile.midMoveStallProbability) {
            let stallIndex = rng.int(in: 1...(events.count - 1))
            events[stallIndex].delayBeforeMs += rng.int(in: profile.stallMs)
            applied.append(.midMoveStall)
        }

        return ChaosPerturbation(events: events, appliedPatterns: applied)
    }

    // MARK: - Core transforms

    /// lift(captured), lift(attacker), place(destination).
    private func captureOrderSwapped(_ c: ChaosMoveContext) -> [ChaosMoveEvent] {
        guard let captured = c.capturedSquare else { return c.cleanEvents }
        let capturedPiece = pieceAt(captured, in: c)
        let mover = pieceAt(c.fromSquare, in: c)
        return [
            ChaosMoveEvent(square: captured, isLift: true, piece: capturedPiece),
            ChaosMoveEvent(square: c.fromSquare, isLift: true, piece: mover),
            ChaosMoveEvent(square: c.toSquare, isLift: false, piece: mover),
        ]
    }

    /// lift(captured), place(captured) [put it back], then the proper
    /// capture: lift(attacker), lift(captured), place(destination).
    private func captureLiftReturnRedone(_ c: ChaosMoveContext) -> [ChaosMoveEvent] {
        guard let captured = c.capturedSquare else { return c.cleanEvents }
        let capturedPiece = pieceAt(captured, in: c)
        let mover = pieceAt(c.fromSquare, in: c)
        return [
            ChaosMoveEvent(square: captured, isLift: true, piece: capturedPiece),
            ChaosMoveEvent(square: captured, isLift: false, piece: capturedPiece),
            ChaosMoveEvent(square: c.fromSquare, isLift: true, piece: mover),
            ChaosMoveEvent(square: captured, isLift: true, piece: capturedPiece),
            ChaosMoveEvent(square: c.toSquare, isLift: false, piece: mover),
        ]
    }

    /// Castle as two complete piece-moves, king-first or rook-first, with a
    /// long human pause between the legs.
    private func slowCastled(_ c: ChaosMoveContext, rng: inout SeededRNG) -> [ChaosMoveEvent] {
        guard let rookFrom = c.rookFromSquare, let rookTo = c.rookToSquare else { return c.cleanEvents }
        let king = pieceAt(c.fromSquare, in: c)
        let rook = pieceAt(rookFrom, in: c)
        let kingFirst = rng.chance(0.5)
        let legPause = rng.int(in: profile.slowCastleLegPauseMs)
        let kingLeg = [
            ChaosMoveEvent(square: c.fromSquare, isLift: true, piece: king),
            ChaosMoveEvent(square: c.toSquare, isLift: false, piece: king),
        ]
        let rookLeg = [
            ChaosMoveEvent(square: rookFrom, isLift: true, piece: rook),
            ChaosMoveEvent(square: rookTo, isLift: false, piece: rook),
        ]
        var events = kingFirst ? kingLeg + rookLeg : rookLeg + kingLeg
        events[2].delayBeforeMs = legPause
        return events
    }

    /// lift(from), place(to)[pawn], lift(to)[pawn], place(to)[promoted].
    private func promotionSwapped(_ c: ChaosMoveContext) -> [ChaosMoveEvent] {
        let pawn = pieceAt(c.fromSquare, in: c)
        return [
            ChaosMoveEvent(square: c.fromSquare, isLift: true, piece: pawn),
            ChaosMoveEvent(square: c.toSquare, isLift: false, piece: pawn),
            ChaosMoveEvent(square: c.toSquare, isLift: true, piece: pawn),
            ChaosMoveEvent(square: c.toSquare, isLift: false, piece: c.promotedPiece),
        ]
    }

    /// lift(from), place(to) — but the placed piece stays a PAWN (the player
    /// never swapped). Occupancy-identical to clean; identity boards report
    /// a pawn on the back rank.
    private func promotionUnswapped(_ c: ChaosMoveContext) -> [ChaosMoveEvent] {
        let pawn = pieceAt(c.fromSquare, in: c)
        return [
            ChaosMoveEvent(square: c.fromSquare, isLift: true, piece: pawn),
            ChaosMoveEvent(square: c.toSquare, isLift: false, piece: pawn),
        ]
    }

    /// Insert brief place/lift blips on intermediate squares between the
    /// mover's lift and its final placement (piece dragged across the board).
    private func slideThroughBlipped(_ c: ChaosMoveContext, rng: inout SeededRNG) -> [ChaosMoveEvent] {
        guard c.cleanEvents.count == 2, !c.pathSquares.isEmpty else { return c.cleanEvents }
        let mover = pieceAt(c.fromSquare, in: c)
        var events = [c.cleanEvents[0]]
        // Blip a deterministic subset: each intermediate square independently
        // with p = 0.7, but at least one.
        var blipped = c.pathSquares.filter { _ in rng.chance(0.7) }
        if blipped.isEmpty, let forced = rng.pick(c.pathSquares) { blipped = [forced] }
        for square in c.pathSquares where blipped.contains(square) {
            events.append(ChaosMoveEvent(square: square, isLift: false, piece: mover,
                                         delayBeforeMs: rng.int(in: 20...120)))
            events.append(ChaosMoveEvent(square: square, isLift: true, piece: mover,
                                         delayBeforeMs: rng.int(in: 20...120)))
        }
        events.append(c.cleanEvents[1])
        return events
    }

    // MARK: - Helpers

    /// An occupied square adjacent (8-neighbourhood) to the mover's from- or
    /// to-square that is OUTSIDE the move's effect set. Deterministic pick.
    private func knockableNeighbor(_ c: ChaosMoveContext, rng: inout SeededRNG) -> String? {
        let effect = c.effectSquares
        var candidates: [String] = []
        for anchor in [c.fromSquare, c.toSquare] {
            guard let sq = Square(algebraic: anchor) else { continue }
            for df in -1...1 {
                for dr in -1...1 where !(df == 0 && dr == 0) {
                    let f = sq.file + df, r = sq.rank + dr
                    guard (0..<8).contains(f), (0..<8).contains(r) else { continue }
                    let neighbor = Square(file: f, rank: r)
                    let algebraic = neighbor.algebraic
                    guard !effect.contains(algebraic) else { continue }
                    guard c.identityBefore[f * 8 + r] != nil else { continue }
                    if !candidates.contains(algebraic) { candidates.append(algebraic) }
                }
            }
        }
        candidates.sort()   // deterministic order before the seeded pick
        return rng.pick(candidates)
    }

    /// Identity of the piece on `square` before the move (nil off-board or
    /// empty).
    private func pieceAt(_ square: String, in c: ChaosMoveContext) -> Piece? {
        guard let sq = Square(algebraic: square) else { return nil }
        return c.identityBefore[sq.file * 8 + sq.rank]
    }
}
