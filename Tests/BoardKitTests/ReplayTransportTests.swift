// ReplayTransport determinism tests.
//
// Verifies that:
//   (a) runSync() is deterministic — identical scripts produce identical results.
//   (b) runByStep() preserves per-step granularity.
//   (c) Delay steps are recorded but not executed during synchronous replay.
//   (d) Lifecycle events bypass the adapter parser and appear in output order.
//   (e) Multiple frames in a single .bytes step are all processed.

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport

// MARK: - Helpers

private let g1Bytes = Data([
    0x01, 0x22,
    0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x77, 0x77, 0x77, 0x77,
    0xA6, 0xC9, 0x9B, 0x6A,
    0x00, 0x00,
])

private let g2Bytes = Data([
    0x01, 0x22,
    0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x77, 0x07, 0x77, 0x77,
    0xA6, 0xC9, 0x9B, 0x6A,
    0x00, 0x00,
])

// MARK: - Determinism

@Test func replayTransportIsDeterministic() {
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [
        .bytes(g1Bytes),
        .bytes(g2Bytes),
    ]
    let replay1 = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    let replay2 = ReplayTransport(adapter: ChessnutAdapter(), script: script)

    let events1 = replay1.runSync()
    let events2 = replay2.runSync()

    // Same script + same adapter state → same event count.
    #expect(events1.count == events2.count)

    // All identitySnapshot events should carry identical arrays.
    let snaps1 = events1.compactMap { (e: BoardEvent) -> [Piece?]? in
        if case .identitySnapshot(let id) = e { return id }; return nil
    }
    let snaps2 = events2.compactMap { (e: BoardEvent) -> [Piece?]? in
        if case .identitySnapshot(let id) = e { return id }; return nil
    }
    #expect(snaps1.count == snaps2.count)
    for (a, b) in zip(snaps1, snaps2) {
        #expect(a == b)
    }
}

// MARK: - Per-step granularity

@Test func runByStepPreservesGranularity() {
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [
        .bytes(g1Bytes),
        .delay(.seconds(1)),
        .bytes(g2Bytes),
    ]
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    let perStep = replay.runByStep()

    #expect(perStep.count == 3)
    // Step 0: G1 frame → identitySnapshot + ready (first frame).
    #expect(!perStep[0].isEmpty)
    // Step 1: delay → empty (not executed).
    #expect(perStep[1].isEmpty)
    // Step 2: G2 frame → identitySnapshot + squareSensed deltas.
    #expect(!perStep[2].isEmpty)
}

// MARK: - Delay steps not executed

@Test func delayStepsAreNotExecuted() {
    var delayCount = 0
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [
        .delay(.seconds(5)),
        .delay(.seconds(10)),
    ]
    // If delays were executed we'd block for 15 s; they must be skipped.
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    let events = replay.runSync()
    // No bytes → no events.
    #expect(events.isEmpty)
    // Verify the delays are recorded.
    for step in replay.recordedSteps {
        if case .delay = step { delayCount += 1 }
    }
    #expect(delayCount == 2)
}

// MARK: - Lifecycle events bypass parser

@Test func lifecycleEventsBypassParser() {
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [
        .lifecycle(.connected),
        .bytes(g1Bytes),
        .lifecycle(.disconnected(error: nil)),
    ]
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    let events = replay.runSync()

    // events[0] must be .connected.
    guard case .connected = events.first else {
        Issue.record("First event must be .connected")
        return
    }
    // Last event must be .disconnected.
    guard case .disconnected = events.last else {
        Issue.record("Last event must be .disconnected")
        return
    }
    // Middle events from the G1 frame.
    let midEvents = events.dropFirst().dropLast()
    #expect(midEvents.contains { if case .identitySnapshot = $0 { return true }; return false })
}

// MARK: - Multiple frames in one bytes step

@Test func multipleFramesInOneBytesStep() {
    // Concatenate G1 + G2 bytes in a single delivery; adapter must
    // produce events for both frames in one feed call.
    let combined = g1Bytes + g2Bytes
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [.bytes(combined)]
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    let events = replay.runSync()

    let snapshots = events.filter { if case .identitySnapshot = $0 { return true }; return false }
    #expect(snapshots.count == 2)
}

// MARK: - Script recording

@Test func scriptIsRecorded() {
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [
        .bytes(g1Bytes),
        .delay(.milliseconds(200)),
        .lifecycle(.connected),
    ]
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    #expect(replay.recordedSteps.count == 3)
}

// MARK: - Empty script

@Test func emptyScriptProducesNoEvents() {
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: [])
    let events = replay.runSync()
    #expect(events.isEmpty)
}

// MARK: - ReplayScript parser (finding 7)

@Test func replayScriptParsesRxLine() throws {
    let text = "rx 01 22 00 00"
    let steps = try ReplayScript.parse(text: text)
    #expect(steps.count == 1)
    guard case .bytes(let data) = steps[0] else {
        Issue.record("Expected .bytes step")
        return
    }
    #expect(data == Data([0x01, 0x22, 0x00, 0x00]))
}

@Test func replayScriptParsesHexCaseInsensitive() throws {
    let lower = try ReplayScript.parse(text: "rx ff ab cd")
    let upper = try ReplayScript.parse(text: "rx FF AB CD")
    guard case .bytes(let lo) = lower[0], case .bytes(let hi) = upper[0] else {
        Issue.record("Expected .bytes steps")
        return
    }
    #expect(lo == hi)
}

@Test func replayScriptParsesDelayLine() throws {
    let steps = try ReplayScript.parse(text: "delay 200")
    #expect(steps.count == 1)
    guard case .delay(let d) = steps[0] else {
        Issue.record("Expected .delay step")
        return
    }
    #expect(d == .milliseconds(200))
}

@Test func replayScriptParsesEventConnected() throws {
    let steps = try ReplayScript.parse(text: "event connected")
    #expect(steps.count == 1)
    guard case .lifecycle(let event) = steps[0] else {
        Issue.record("Expected .lifecycle step")
        return
    }
    guard case .connected = event else {
        Issue.record("Expected .connected lifecycle event")
        return
    }
}

@Test func replayScriptParsesEventDisconnected() throws {
    let steps = try ReplayScript.parse(text: "event disconnected")
    #expect(steps.count == 1)
    guard case .lifecycle(let event) = steps[0] else {
        Issue.record("Expected .lifecycle step")
        return
    }
    guard case .disconnected(let err) = event else {
        Issue.record("Expected .disconnected lifecycle event")
        return
    }
    #expect(err == nil)
}

@Test func replayScriptSkipsComments() throws {
    let text = """
    # This is a comment
    rx 01 22 00 00
    # another comment
    delay 50
    """
    let steps = try ReplayScript.parse(text: text)
    #expect(steps.count == 2)
    if case .bytes(let d) = steps[0] {
        #expect(d == Data([0x01, 0x22, 0x00, 0x00]))
    } else {
        Issue.record("Expected .bytes as first non-comment step")
    }
    if case .delay(let dur) = steps[1] {
        #expect(dur == .milliseconds(50))
    } else {
        Issue.record("Expected .delay as second non-comment step")
    }
}

@Test func replayScriptSkipsBlankLines() throws {
    let text = "\n\nrx 01 22\n\n"
    let steps = try ReplayScript.parse(text: text)
    #expect(steps.count == 1)
}

@Test func replayScriptThrowsOnUnknownDirective() {
    #expect(throws: ReplayScript.ParseError.self) {
        _ = try ReplayScript.parse(text: "unknown 01 02")
    }
}

@Test func replayScriptThrowsOnBadHexOctet() {
    // "ZZ" is not a valid hex byte.
    #expect(throws: ReplayScript.ParseError.self) {
        _ = try ReplayScript.parse(text: "rx ZZ 01")
    }
}

@Test func replayScriptThrowsOnOddLengthHex() {
    // "1" is only one digit — two required per octet.
    #expect(throws: ReplayScript.ParseError.self) {
        _ = try ReplayScript.parse(text: "rx 1 22")
    }
}

@Test func replayScriptThrowsOnEmptyRxLine() {
    #expect(throws: ReplayScript.ParseError.self) {
        _ = try ReplayScript.parse(text: "rx")
    }
}

@Test func replayScriptThrowsOnUnknownEventName() {
    #expect(throws: ReplayScript.ParseError.self) {
        _ = try ReplayScript.parse(text: "event scanning")
    }
}

/// Integration test: parse a multi-line script, build a ReplayTransport
/// from it, and verify the decoded events match the G1 → G2 sequence.
@Test func replayScriptIntegrationG1ThenG2() throws {
    // G1 bytes and G2 bytes as hex lines.
    let scriptText = """
    # G1: initial position
    event connected
    rx 01 22 58 23 31 85 44 44 44 44 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 77 77 77 77 A6 C9 9B 6A 00 00
    delay 100
    # G2: after 1.e4
    rx 01 22 58 23 31 85 44 44 44 44 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 77 07 77 77 A6 C9 9B 6A 00 00
    """
    let steps = try ReplayScript.parse(text: scriptText)
    // connected + rx(G1) + delay + rx(G2) = 4 steps.
    #expect(steps.count == 4)

    let replay = ReplayTransport(adapter: ChessnutAdapter(), parsedScript: steps)
    let events = replay.runSync()

    // Must have two identitySnapshot events (one per board-state frame).
    let snapshots = events.filter { if case .identitySnapshot = $0 { return true }; return false }
    #expect(snapshots.count == 2)

    // First board-state frame must emit .ready.
    #expect(events.contains { if case .ready = $0 { return true }; return false })

    // Second frame must produce squareSensed deltas (e2 lift, e4 place).
    let sensed = events.compactMap { (event: BoardEvent) -> (String, Bool)? in
        if case .squareSensed(let sq, let lift, _) = event { return (sq, lift) }
        return nil
    }
    #expect(sensed.count == 2)
    #expect(sensed.contains { $0 == ("e2", true) })
    #expect(sensed.contains { $0 == ("e4", false) })
}

// MARK: - Partial frame across steps

@Test func partialFrameAcrossSteps() {
    // Split G1 across two .bytes steps; the frame must be buffered and
    // emitted only when complete.
    let part1 = g1Bytes.prefix(10)
    let part2 = g1Bytes.dropFirst(10)
    let script: [ReplayTransport<ChessnutAdapter>.Step] = [
        .bytes(part1),
        .bytes(part2),
    ]
    let replay = ReplayTransport(adapter: ChessnutAdapter(), script: script)
    let perStep = replay.runByStep()

    // Step 0: partial frame → no events.
    #expect(perStep[0].isEmpty)
    // Step 1: frame completes → identitySnapshot emitted.
    #expect(!perStep[1].isEmpty)
    #expect(perStep[1].contains { if case .identitySnapshot = $0 { return true }; return false })
}
