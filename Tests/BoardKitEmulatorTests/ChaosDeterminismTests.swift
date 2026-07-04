// Chaos determinism — the contract of the chaos layer: same seed + profile
// = byte-identical perturbation streams; different seeds diverge.

import Testing
import Foundation
import ChessCore
import BoardKit
import BoardKitTestSupport

/// Run a full seeded game corpus through the engine and collect every
/// perturbation.
private func perturbCorpus(
    gameSeed: UInt64,
    chaosSeed: UInt64,
    profile: ChaosProfile,
    plies: Int = 30
) async throws -> [ChaosPerturbation] {
    let cases = try await generateGameCases(seed: gameSeed, maxPlies: plies)
    let engine = ChaosEngine(profile: profile)
    var rng = SeededRNG(seed: chaosSeed)
    return cases.map { engine.perturb($0.context, rng: &rng) }
}

@Test func sameSeedSameProfileIsIdentical() async throws {
    for profile in [ChaosProfile.clean, .casual, .clumsy, .hostile] {
        let first  = try await perturbCorpus(gameSeed: 7, chaosSeed: 42, profile: profile)
        let second = try await perturbCorpus(gameSeed: 7, chaosSeed: 42, profile: profile)
        #expect(first == second, "profile \(profile.name) not deterministic")
        #expect(!first.isEmpty)
    }
}

@Test func differentSeedsDiverge() async throws {
    let a = try await perturbCorpus(gameSeed: 7, chaosSeed: 1, profile: .hostile)
    let b = try await perturbCorpus(gameSeed: 7, chaosSeed: 2, profile: .hostile)
    #expect(a != b, "different chaos seeds should perturb differently")
}

@Test func cleanProfileIsIdentityTransformWithPacing() async throws {
    let cases = try await generateGameCases(seed: 11, maxPlies: 20)
    let engine = ChaosEngine(profile: .clean)
    var rng = SeededRNG(seed: 3)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        #expect(perturbation.appliedPatterns.isEmpty)
        // Same squares/lifts/pieces as the clean sequence; only pacing added.
        let stripped = perturbation.events.map { ChaosMoveEvent(square: $0.square, isLift: $0.isLift, piece: $0.piece) }
        let clean = corpusCase.context.cleanEvents.map { ChaosMoveEvent(square: $0.square, isLift: $0.isLift, piece: $0.piece) }
        #expect(stripped == clean)
        // Pacing must be drawn from the profile's inter-event range.
        for event in perturbation.events {
            #expect(ChaosProfile.clean.interEventDelayMs.contains(event.delayBeforeMs))
        }
    }
}

@Test func seededRNGStreamIsStable() {
    // Pin the first values of the SplitMix64 stream so an accidental
    // algorithm change (which would silently re-shuffle every corpus) fails
    // loudly. Reference values computed from the published SplitMix64
    // algorithm with seed 0.
    var rng = SeededRNG(seed: 0)
    #expect(rng.next() == 16294208416658607535)
    #expect(rng.next() == 7960286522194355700)
    // Same-seed copies fork the stream identically.
    var a = SeededRNG(seed: 99)
    var b = SeededRNG(seed: 99)
    for _ in 0..<64 {
        #expect(a.next() == b.next())
    }
}

@Test func hostileCorpusActuallyAppliesAdversarialPatterns() async throws {
    let perturbations = try await perturbCorpus(gameSeed: 5, chaosSeed: 5, profile: .hostile, plies: 60)
    let allPatterns = Set(perturbations.flatMap(\.appliedPatterns))
    #expect(allPatterns.contains(.knockedNeighbor) || allPatterns.contains(.slideThroughBlips),
            "hostile corpus never drew an adversarial pattern — probabilities or corpus too small")
}
