// PushStateEvery — tests for the --push-state-every <n> divergence-detection knob.
//
// Three coverage areas:
//   1. Flag parsing: --push-state-every sets pushStateEvery; absent → nil.
//   2. Frame emission cadence: snapshot frames appear at the right move indices
//      (dry-run path via playNextScriptedMoveNow).
//   3. Capture round-trip: snapshot frames are recorded by CaptureRecorder and
//      survive ReplayScript.parse.

import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter
import BoardKitTestSupport
import BoardKitEmulator

// MARK: - 1. Flag parsing

@Test func pushStateEveryFlagParsed() throws {
    // Explicit value.
    let options = try EmulatorOptions.parse(["squareoff", "--push-state-every", "3"]).get()
    #expect(options.pushStateEvery == 3)
}

@Test func pushStateEveryAbsentDefaultsToNil() throws {
    let options = try EmulatorOptions.parse(["squareoff"]).get()
    #expect(options.pushStateEvery == nil)
}

@Test func pushStateEveryRequiresAnIntegerValue() {
    // Flag with no argument.
    if case .success = EmulatorOptions.parse(["squareoff", "--push-state-every"]) {
        Issue.record("--push-state-every with no argument must fail")
    }
    // Flag with non-integer.
    if case .success = EmulatorOptions.parse(["squareoff", "--push-state-every", "foo"]) {
        Issue.record("--push-state-every with non-integer must fail")
    }
}

// MARK: - 2. Frame emission cadence (dry-run, no BLE)

/// Thread-safe frame accumulator (same pattern used in GameDriverTests).
private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [PersonalityFrame] = []
    func append(_ frames: [PersonalityFrame]) {
        lock.lock(); defer { lock.unlock() }
        _frames += frames
    }
    var frames: [PersonalityFrame] {
        lock.lock(); defer { lock.unlock() }
        return _frames
    }
}

/// Returns true when the frame payload is a SquareOff board-state message
/// (starts with "30#").
private func isSquareOffSnapshot(_ frame: PersonalityFrame) -> Bool {
    let body = String(decoding: frame.data, as: UTF8.self)
    return body.hasPrefix("30#")
}

@Test func pushStateEverySquareOffSnapshotCount() async {
    // 4 clean moves, push-state-every 2 → snapshots after moves 2 and 4.
    let driver = GameDriver(
        personality: SquareOffPersonality(),
        configuration: .init(
            scriptedUCIs: ["e2e4", "e7e5", "g1f3", "b8c6"],
            chaosProfile: .clean,
            seed: 1,
            pushStateEvery: 2
        )
    )
    let sink = FrameSink()
    await driver.setOnFrames { sink.append($0) }

    for _ in 0..<4 {
        await driver.playNextScriptedMoveNow()
    }

    // 4 clean moves × 2 squareSensed frames (lift + place) = 8 move frames.
    // 2 unsolicited snapshots = 2 more frames.  Total: 10.
    let snapshots = sink.frames.filter { isSquareOffSnapshot($0) }
    #expect(snapshots.count == 2)
    #expect(sink.frames.count == 10)
}

@Test func pushStateEveryInterleaving() async {
    // push-state-every 1: snapshot after EVERY move.
    let driver = GameDriver(
        personality: SquareOffPersonality(),
        configuration: .init(
            scriptedUCIs: ["e2e4", "e7e5"],
            chaosProfile: .clean,
            seed: 1,
            pushStateEvery: 1
        )
    )
    let sink = FrameSink()
    await driver.setOnFrames { sink.append($0) }

    for _ in 0..<2 {
        await driver.playNextScriptedMoveNow()
    }

    // 2 clean moves × 2 squareSensed = 4 move frames + 2 snapshots = 6 total.
    let snapshots = sink.frames.filter { isSquareOffSnapshot($0) }
    #expect(snapshots.count == 2)
    #expect(sink.frames.count == 6)

    // The frames must interleave correctly:
    // [lift, place, snapshot, lift, place, snapshot]
    let bodies = sink.frames.map { String(decoding: $0.data, as: UTF8.self) }
    #expect(bodies[2].hasPrefix("30#"))
    #expect(bodies[5].hasPrefix("30#"))
}

@Test func pushStateEveryOffProducesNoExtraFrames() async {
    // pushStateEvery nil (default) must not emit any snapshot frames beyond
    // the regular squareSensed stream.
    let driver = GameDriver(
        personality: SquareOffPersonality(),
        configuration: .init(
            scriptedUCIs: ["e2e4", "e7e5"],
            chaosProfile: .clean,
            seed: 1
            // pushStateEvery omitted → nil
        )
    )
    let sink = FrameSink()
    await driver.setOnFrames { sink.append($0) }

    for _ in 0..<2 {
        await driver.playNextScriptedMoveNow()
    }

    // Exactly 4 squareSensed frames, zero snapshots.
    let snapshots = sink.frames.filter { isSquareOffSnapshot($0) }
    #expect(snapshots.isEmpty)
    #expect(sink.frames.count == 4)
}

// MARK: - 3. Capture round-trip

@Test func pushStateEverySnapshotFramesSurviveCapture() async throws {
    // Full pipeline:  GameDriver (pushStateEvery: 2, SquareOff, clean, 4 moves)
    //   → frames accumulated in FrameSink (Sendable)
    //   → CaptureRecorder built on the main-actor side after playback
    //   → ReplayScript.parse → confirm rx lines include the two snapshot payloads.

    let driver = GameDriver(
        personality: SquareOffPersonality(),
        configuration: .init(
            scriptedUCIs: ["e2e4", "e7e5", "g1f3", "b8c6"],
            chaosProfile: .clean,
            seed: 1,
            pushStateEvery: 2
        )
    )
    let sink = FrameSink()
    await driver.setOnFrames { sink.append($0) }

    for _ in 0..<4 {
        await driver.playNextScriptedMoveNow()
    }

    // Build the capture from the accumulated frames.
    var recorder = CaptureRecorder()
    for frame in sink.frames {
        recorder.recordNotification(frame.data, elapsedMs: 500)
    }

    // Parse capture and verify snapshot rx lines are present.
    let steps = try ReplayScript.parse(text: recorder.text)

    // The two snapshot lines encode as 68-byte payloads ("30#" + 64 chars + "*").
    let snapshotPayloads = steps.compactMap { step -> Data? in
        guard case .bytes(let data) = step else { return nil }
        let body = String(decoding: data, as: UTF8.self)
        return body.hasPrefix("30#") ? data : nil
    }
    #expect(snapshotPayloads.count == 2)

    // Snapshot payloads must round-trip through the SquareOffAdapter: the
    // host receives an .occupancySnapshot event.
    for payload in snapshotPayloads {
        var adapter = SquareOffAdapter()
        let events = adapter.feed(bytes: payload)
        guard case .occupancySnapshot(let occ) = events.first else {
            Issue.record("snapshot payload did not decode to occupancySnapshot: \(payload as NSData)")
            continue
        }
        // After a few moves the board is not the initial position, but
        // squares are still occupied somewhere — sanity check.
        #expect(occ.filter { $0 }.count > 0)
    }
}
