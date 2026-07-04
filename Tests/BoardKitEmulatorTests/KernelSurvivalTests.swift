// KERNEL SURVIVAL CORPUS — the crown jewel.
//
// Hundreds of seeded (move, profile) cases: chaos-perturbed sensor streams
// are run through the committed BoardKit kernels (`OccupancyMoveInference`
// with the session's first-legal-wins commit mimic, and
// `BoardExecutionGate` with a physical-occupancy mirror) and the outcomes
// asserted per tolerance tier:
//
// - `.casual` / `.clumsy` draw only kernel-tolerated patterns → the
//   inference must resolve the intended move and the gate must reach
//   `.executed` for EVERY case, with zero false completions and zero
//   deviations.
// - `.hostile` adds adversarial patterns (knocked neighbours, slide-through
//   blips) → outcomes are CLASSIFIED and the distribution asserted:
//   * the gate NEVER false-completes (executed ⇒ physical state correct);
//   * the gate deviates IFF the stream really touched a square outside the
//     move's effect set (no false deviation, no missed deviation);
//   * cases whose drawn patterns were all tolerated keep the full casual
//     guarantee;
//   * unresolved cases must be rescued by `BoardDiffResolver` from the
//     final physical occupancy (the session's snapshot/desync flow);
//   * the intended move still resolves for a majority of hostile streams.

import Testing
import Foundation
import ChessCore
import BoardKit
import BoardKitTestSupport

/// Patterns guaranteed tolerated by both kernels.
private let toleratedPatterns: Set<ChaosPatternID> = [
    .adjustInPlace, .sensorChatter, .captureOrderSwap, .captureLiftReturnRedo,
    .slowCastle, .promotionSwap, .promotionNoSwap, .midMoveStall,
]

// MARK: - Tolerated tiers: casual + clumsy

@Test(arguments: [
    ("casual", ChaosProfile.casual),
    ("clumsy", ChaosProfile.clumsy),
])
func toleratedProfilesNeverBreakTheKernels(_ label: String, _ profile: ChaosProfile) async throws {
    var totalCases = 0
    var patternedCases = 0

    for gameSeed: UInt64 in [1, 2, 3, 4] {
        let cases = try await generateGameCases(seed: gameSeed, maxPlies: 40)
        let engine = ChaosEngine(profile: profile)
        var rng = SeededRNG(seed: gameSeed &* 0x9E37)

        for corpusCase in cases {
            totalCases += 1
            let perturbation = engine.perturb(corpusCase.context, rng: &rng)
            if !perturbation.appliedPatterns.isEmpty { patternedCases += 1 }

            // Only tolerated patterns may ever be drawn from these profiles.
            #expect(toleratedPatterns.isSuperset(of: perturbation.appliedPatterns),
                    "\(label): adversarial pattern drawn: \(perturbation.appliedPatterns)")

            // Inference must resolve the intended move.
            let outcome = inferenceOutcome(events: perturbation.events,
                                           positionBefore: corpusCase.positionBefore,
                                           intended: corpusCase.uci)
            #expect(outcome == .resolvedIntended,
                    "\(label) seed \(gameSeed) \(corpusCase.uci) patterns \(perturbation.appliedPatterns): \(outcome)")

            // Gate must execute with no false completion and no deviation.
            let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
            #expect(!gateRun.touchedOutsideEffectSet,
                    "\(label) \(corpusCase.uci): tolerated stream touched outside the effect set")
            #expect(gateRun.finalState == .executed,
                    "\(label) seed \(gameSeed) \(corpusCase.uci) patterns \(perturbation.appliedPatterns): gate \(gateRun.finalState)")
            #expect(!gateRun.falseComplete,
                    "\(label) \(corpusCase.uci): gate executed before the physical move was complete")
        }
    }

    #expect(totalCases >= 140, "corpus unexpectedly small: \(totalCases)")
    #expect(patternedCases > 20, "\(label) corpus barely perturbed anything (\(patternedCases)) — probabilities off?")
}

// MARK: - Adversarial tier: hostile

@Test func hostileProfileOutcomesAreClassifiedAndBounded() async throws {
    var resolvedIntended = 0
    var resolvedOther = 0
    var unresolved = 0
    var deviatedGates = 0
    var totalCases = 0

    for gameSeed: UInt64 in [10, 11, 12] {
        let cases = try await generateGameCases(seed: gameSeed, maxPlies: 40)
        let engine = ChaosEngine(profile: .hostile)
        var rng = SeededRNG(seed: gameSeed &* 0x51D3)

        for corpusCase in cases {
            totalCases += 1
            let perturbation = engine.perturb(corpusCase.context, rng: &rng)
            let onlyTolerated = toleratedPatterns.isSuperset(of: perturbation.appliedPatterns)

            let outcome = inferenceOutcome(events: perturbation.events,
                                           positionBefore: corpusCase.positionBefore,
                                           intended: corpusCase.uci)
            let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)

            // ── Universal invariants (hold even under hostility) ─────────
            // 1. The gate NEVER falsely completes.
            #expect(!gateRun.falseComplete,
                    "hostile \(corpusCase.uci) \(perturbation.appliedPatterns): FALSE COMPLETE")
            // 2. The gate deviates exactly when the stream really touched
            //    outside the effect set — never spuriously, never missed.
            //    (An outside touch AFTER completion is absorbed by the
            //    sticky .executed state, which is also correct behaviour —
            //    so assert the two implications separately.)
            if case .deviated = gateRun.finalState {
                deviatedGates += 1
                #expect(gateRun.touchedOutsideEffectSet,
                        "hostile \(corpusCase.uci): gate deviated on a fully in-effect stream (false deviation)")
            }
            if !gateRun.touchedOutsideEffectSet {
                #expect(gateRun.finalState == .executed,
                        "hostile \(corpusCase.uci): in-effect stream did not execute (\(gateRun.finalState))")
            }

            // ── Tolerated-only draws keep the full casual guarantee ──────
            if onlyTolerated {
                #expect(outcome == .resolvedIntended,
                        "hostile-but-tolerated \(corpusCase.uci) \(perturbation.appliedPatterns): \(outcome)")
                #expect(gateRun.finalState == .executed)
            }

            // ── Classification ───────────────────────────────────────────
            switch outcome {
            case .resolvedIntended:
                resolvedIntended += 1
            case .resolvedOther:
                resolvedOther += 1
                #expect(!onlyTolerated, "tolerated pattern set mis-resolved \(corpusCase.uci)")
            case .unresolved:
                unresolved += 1
                // Resolver-class rescue: the perturbed stream always ends
                // with the board physically in the post-move state, so the
                // snapshot flow must be able to explain it from the
                // pre-move position — with the intended move among the
                // explanations.
                var after = corpusCase.positionBefore
                MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
                let resolutions = BoardDiffResolver.resolve(
                    from: corpusCase.positionBefore,
                    targetOccupancy: BoardDiffResolver.occupancyArray(for: after)
                )
                #expect(resolutions.contains { $0.moves.first.map { candidate in
                    candidate == corpusCase.uci ||
                    (candidate.count == 5 && corpusCase.uci.count == 5 &&
                     candidate.prefix(4) == corpusCase.uci.prefix(4))
                } ?? false },
                        "hostile \(corpusCase.uci): resolver could not rescue the unresolved stream")
            }
        }
    }

    // Distribution assertions — deterministic because everything is seeded.
    print("[survival] hostile corpus: \(totalCases) cases — intended \(resolvedIntended), other \(resolvedOther), unresolved \(unresolved), gate deviations \(deviatedGates)")
    #expect(totalCases >= 100, "hostile corpus too small: \(totalCases)")
    let intendedFraction = Double(resolvedIntended) / Double(totalCases)
    #expect(intendedFraction >= 0.5,
            "hostile intended-resolution collapsed: \(resolvedIntended)/\(totalCases)")
    // Hostility must actually bite somewhere in the corpus, or the tier
    // isn't testing anything beyond casual.
    #expect(deviatedGates > 0, "hostile corpus never deviated the gate")
    #expect(resolvedOther + unresolved > 0, "hostile corpus never pushed inference off the intended move")
}

// MARK: - Directed pattern probes (one per pattern, fixed positions)

/// Force a single pattern via a probability-1 profile and check the
/// documented kernel behaviour on a canonical move. These pin each
/// pattern's shape independently of the corpus draw.
private func forcedProfile(_ configure: (inout ChaosProfile) -> Void) -> ChaosProfile {
    var profile = ChaosProfile.clean
    profile.name = "forced"
    configure(&profile)
    return profile
}

private func contextFor(uci: String, fen: String?) async throws -> (CorpusCase, ChaosMoveContext) {
    let position = fen.flatMap { Position(fen: $0) } ?? Position.initial()
    let legal = MoveGenerator.legalMoves(for: position)
    let move = try #require(UCIParser.uciToMove(uci, in: legal))
    let sim = SimulatedBoard(position: position, capabilities: [.occupancySensing, .pieceIdentity])
    let events = try await sim.executeMove(uci: uci)
    let context = ChaosMoveContext(move: move, positionBefore: position, cleanEvents: events)
    return (CorpusCase(uci: uci, move: move, positionBefore: position, context: context), context)
}

@Test func captureOrderSwapShapeSurvivesBothKernels() async throws {
    // Italian-ish position with an immediate capture: e4xd5.
    let (corpusCase, context) = try await contextFor(
        uci: "e4d5",
        fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    )
    let engine = ChaosEngine(profile: forcedProfile { $0.captureOrderSwapProbability = 1 })
    var rng = SeededRNG(seed: 1)
    let perturbation = engine.perturb(context, rng: &rng)
    #expect(perturbation.appliedPatterns == [.captureOrderSwap])
    // Shape: lift(captured d5), lift(attacker e4), place(d5).
    #expect(perturbation.events.map(\.square) == ["d5", "e4", "d5"])
    #expect(perturbation.events.map(\.isLift) == [true, true, false])

    #expect(inferenceOutcome(events: perturbation.events,
                             positionBefore: corpusCase.positionBefore,
                             intended: "e4d5") == .resolvedIntended)
    let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
    #expect(gateRun.finalState == .executed)
    #expect(!gateRun.falseComplete)
}

@Test func captureLiftReturnRedoNeverFalseCompletesTheGate() async throws {
    let (corpusCase, context) = try await contextFor(
        uci: "e4d5",
        fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    )
    let engine = ChaosEngine(profile: forcedProfile { $0.captureLiftReturnRedoProbability = 1 })
    var rng = SeededRNG(seed: 1)
    let perturbation = engine.perturb(context, rng: &rng)
    #expect(perturbation.appliedPatterns == [.captureLiftReturnRedo])
    // lift(d5), place(d5) [put back], lift(e4), lift(d5), place(d5).
    #expect(perturbation.events.map(\.square) == ["d5", "d5", "e4", "d5", "d5"])
    #expect(perturbation.events.map(\.isLift) == [true, false, true, true, false])

    #expect(inferenceOutcome(events: perturbation.events,
                             positionBefore: corpusCase.positionBefore,
                             intended: "e4d5") == .resolvedIntended)
    let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
    #expect(gateRun.finalState == .executed)
    #expect(!gateRun.falseComplete, "gate credited the capture before the attacker landed")
}

@Test func slowCastleBothOrdersResolveAsCastle() async throws {
    let fen = "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"
    for seed: UInt64 in 1...8 {   // covers both king-first and rook-first draws
        let (corpusCase, context) = try await contextFor(uci: "e1g1", fen: fen)
        let engine = ChaosEngine(profile: forcedProfile { $0.slowCastleProbability = 1 })
        var rng = SeededRNG(seed: seed)
        let perturbation = engine.perturb(context, rng: &rng)
        #expect(perturbation.appliedPatterns == [.slowCastle])
        #expect(inferenceOutcome(events: perturbation.events,
                                 positionBefore: corpusCase.positionBefore,
                                 intended: "e1g1") == .resolvedIntended,
                "seed \(seed): slow castle failed to resolve as O-O")
        let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
        #expect(gateRun.finalState == .executed)
        #expect(!gateRun.falseComplete)
    }
}

@Test func enPassantCaptureOrderSwapSurvives() async throws {
    let (corpusCase, context) = try await contextFor(
        uci: "e5d6",
        fen: "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 2"
    )
    let engine = ChaosEngine(profile: forcedProfile { $0.captureOrderSwapProbability = 1 })
    var rng = SeededRNG(seed: 1)
    let perturbation = engine.perturb(context, rng: &rng)
    // lift(captured d5), lift(e5), place(d6).
    #expect(perturbation.events.map(\.square) == ["d5", "e5", "d6"])
    #expect(inferenceOutcome(events: perturbation.events,
                             positionBefore: corpusCase.positionBefore,
                             intended: "e5d6") == .resolvedIntended)
    let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
    #expect(gateRun.finalState == .executed)
    #expect(!gateRun.falseComplete)
}

@Test func promotionSwapIsAbsorbedAfterExecution() async throws {
    let (corpusCase, context) = try await contextFor(uci: "e7e8q", fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1")
    let engine = ChaosEngine(profile: forcedProfile { $0.promotionSwapProbability = 1 })
    var rng = SeededRNG(seed: 1)
    let perturbation = engine.perturb(context, rng: &rng)
    #expect(perturbation.appliedPatterns == [.promotionSwap])
    #expect(perturbation.events.map(\.square) == ["e7", "e8", "e8", "e8"])
    #expect(inferenceOutcome(events: perturbation.events,
                             positionBefore: corpusCase.positionBefore,
                             intended: "e7e8q") == .resolvedIntended)
    let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
    #expect(gateRun.finalState == .executed)
    #expect(!gateRun.falseComplete)
}

@Test func knockedNeighborDeviatesTheGateLegitimately() async throws {
    let (corpusCase, context) = try await contextFor(uci: "e2e4", fen: nil)
    let engine = ChaosEngine(profile: forcedProfile {
        $0.knockedNeighborProbability = 1
        $0.knockedNeighborInterleavedProbability = 0   // wrapped-before variant
    })
    var rng = SeededRNG(seed: 1)
    let perturbation = engine.perturb(context, rng: &rng)
    #expect(perturbation.appliedPatterns == [.knockedNeighbor])

    // Wrapped knock: inference still resolves (lift+place elsewhere is a
    // j'adoube cancel), gate legitimately deviates on the outside square.
    #expect(inferenceOutcome(events: perturbation.events,
                             positionBefore: corpusCase.positionBefore,
                             intended: "e2e4") == .resolvedIntended)
    let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
    #expect(gateRun.touchedOutsideEffectSet)
    if case .deviated(let squares) = gateRun.finalState {
        // The offending square is exactly the knocked neighbour.
        #expect(squares.count == 1)
        #expect(!corpusCase.context.effectSquares.contains(squares[0]))
    } else {
        Issue.record("expected .deviated, got \(gateRun.finalState)")
    }
}

@Test func slideThroughBlipsIsHostileClass() async throws {
    // White queen slide d1–h5 after e4/e5: blips on intermediate squares.
    let (corpusCase, context) = try await contextFor(
        uci: "d1h5",
        fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    )
    let engine = ChaosEngine(profile: forcedProfile { $0.slideThroughBlipsProbability = 1 })
    var rng = SeededRNG(seed: 2)
    let perturbation = engine.perturb(context, rng: &rng)
    #expect(perturbation.appliedPatterns == [.slideThroughBlips])
    #expect(perturbation.events.count > 2, "no blips inserted")

    // The gate deviates on the first intermediate square — by design.
    let gateRun = runGate(events: perturbation.events, corpusCase: corpusCase)
    #expect(gateRun.touchedOutsideEffectSet)
    #expect(!gateRun.falseComplete)

    // Inference outcome is classified (any of the three) — but must not crash
    // and must never be a false gate completion. Document the actual value.
    let outcome = inferenceOutcome(events: perturbation.events,
                                   positionBefore: corpusCase.positionBefore,
                                   intended: "d1h5")
    #expect(outcome == .resolvedIntended || outcome == .resolvedOther("d1e2")
            || outcome == .resolvedOther("d1f3") || outcome == .resolvedOther("d1g4")
            || outcome == .unresolved)
}
