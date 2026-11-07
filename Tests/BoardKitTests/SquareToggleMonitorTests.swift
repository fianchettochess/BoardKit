// SquareToggleMonitorTests.swift
// The flicker kernel tells a flickering square from a move, on a clock the
// caller supplies. (Fianchetto-1ml)

import Foundation
import Testing
import BoardKit

private struct ToggleCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// (square, time) toggles in order.
    let toggles: [(String, TimeInterval)]
    let queryTime: TimeInterval
    let flickering: [String]
    var testDescription: String { name }
}

private let toggleCases: [ToggleCase] = [
    // e2e4 with a j'adoube: no square toggles four times.
    ToggleCase(name: "a move with a j'adoube",
               toggles: [("e2", 0.0), ("e2", 0.3), ("e2", 0.6), ("e4", 1.0)],
               queryTime: 1.0, flickering: []),
    // d2 reads occupied/empty twice within 0.6 s while the bishop is in hand.
    ToggleCase(name: "a flickering neighbour",
               toggles: [("c1", 0.0), ("d2", 0.2), ("d2", 0.35), ("d2", 0.5), ("d2", 0.8), ("g5", 1.1)],
               queryTime: 1.1, flickering: ["d2"]),
    // Four toggles, but spread over more than the window.
    ToggleCase(name: "slow toggles",
               toggles: [("d2", 0.0), ("d2", 0.4), ("d2", 0.8), ("d2", 1.2)],
               queryTime: 1.2, flickering: []),
    // A burst ages out once the window has passed.
    ToggleCase(name: "an old burst",
               toggles: [("d2", 0.0), ("d2", 0.1), ("d2", 0.2), ("d2", 0.3)],
               queryTime: 1.5, flickering: []),
]

/// Gates: a square is flagged only when it toggles `flickerToggles` times
/// inside `window`, so normal handling is never mistaken for noise.
/// Breaks if: the window or the threshold comparison drifts (old toggles
/// counted, or one toggle short of the threshold flagged).
/// User loses: either a real move is held back as "sensor noise", or the
/// flickering square keeps completing moves the player never made.
@Test(arguments: toggleCases)
private func flickerIsToggleRateInsideTheWindow(_ c: ToggleCase) {
    var monitor = SquareToggleMonitor()
    for (square, time) in c.toggles { monitor.recordToggle(of: square, at: time) }
    #expect(monitor.flickeringSquares(at: c.queryTime) == c.flickering)
}

/// Gates: a destination counts as settled only after it has been quiet for
/// the asked span, and only lift/place events count as toggles.
/// Breaks if: the settle comparison is inverted or off by the boundary, or
/// snapshots start counting as toggles.
/// User loses: a move committed onto a square still flickering, or one held
/// forever on a square that has gone quiet.
@Test func settledMeansQuietForTheSpan() {
    var monitor = SquareToggleMonitor()
    monitor.record(.squareSensed(square: "e4", isLift: false, piece: nil), at: 2.0)
    monitor.record(.occupancySnapshot([Bool](repeating: false, count: 64)), at: 2.3)
    #expect(!monitor.isSettled("e4", for: 0.5, at: 2.4))
    #expect(monitor.isSettled("e4", for: 0.5, at: 2.5))
    #expect(monitor.totalToggles == ["e4": 1])
}
