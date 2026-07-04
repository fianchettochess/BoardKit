/// Deterministic, seedable random number generator (SplitMix64).
///
/// Determinism is the contract of the chaos layer: the same seed MUST
/// produce the same perturbation stream on every run, so a failing
/// kernel-survival case can be reproduced from its seed alone, and so the
/// BLE emulator replays identical "human" behaviour session after session.
///
/// - No `Date`, no `SystemRandomNumberGenerator`, no global state.
/// - Value type: copying an instance forks the stream (both copies produce
///   the same continuation) — pass `inout` to advance a single stream.
///
/// SplitMix64 reference: Steele, Lea & Flood, "Fast Splittable Pseudorandom
/// Number Generators" (public-domain reference implementation; reimplemented
/// here from the published algorithm, no third-party code copied).
public struct SeededRNG: RandomNumberGenerator, Sendable, Equatable {

    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // MARK: - Convenience draws
    //
    // Thin wrappers so chaos code reads declaratively. All are pure
    // functions of the generator state.

    /// Bernoulli draw. `probability` is clamped to 0...1.
    public mutating func chance(_ probability: Double) -> Bool {
        if probability <= 0 { return false }
        if probability >= 1 { return true }
        return Double.random(in: 0..<1, using: &self) < probability
    }

    /// Uniform integer draw from a closed range.
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// Uniform element draw. Returns nil for an empty collection.
    public mutating func pick<C: Collection>(_ collection: C) -> C.Element? {
        guard !collection.isEmpty else { return nil }
        let offset = Int(next() % UInt64(collection.count))
        return collection[collection.index(collection.startIndex, offsetBy: offset)]
    }
}
