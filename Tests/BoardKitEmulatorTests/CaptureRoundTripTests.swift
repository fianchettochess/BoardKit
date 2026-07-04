// Capture output round-trips through ReplayScript.parse — every emulator
// session doubles as a host-side replay fixture.

import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter
import BoardKitTestSupport
import BoardKitEmulator

@Test func captureTextParsesAsReplayScript() throws {
    var recorder = CaptureRecorder(header: "unit-test capture\nsecond header line")
    recorder.recordLifecycle(connected: true)
    recorder.recordNotification(Data("0#e2u*".utf8))
    recorder.recordHostWrite(Data("25#e2e4*".utf8), elapsedMs: 42)      // below threshold
    recorder.recordNotification(Data("0#e4d*".utf8), elapsedMs: 350)    // above threshold
    recorder.recordComment("move e2e4 complete")
    recorder.recordLifecycle(connected: false)

    let steps = try ReplayScript.parse(text: recorder.text)

    // Header lines, tx lines, and comments vanish; rx/delay/lifecycle stay.
    #expect(steps.count == 5)
    guard case .lifecycle(.connected) = steps[0] else {
        Issue.record("step 0: expected connected, got \(steps[0])"); return
    }
    guard case .bytes(let first) = steps[1] else {
        Issue.record("step 1: expected bytes, got \(steps[1])"); return
    }
    #expect(first == Data("0#e2u*".utf8))
    guard case .delay(let pause) = steps[2] else {
        Issue.record("step 2: expected delay, got \(steps[2])"); return
    }
    #expect(pause == .milliseconds(350))
    guard case .bytes(let second) = steps[3] else {
        Issue.record("step 3: expected bytes, got \(steps[3])"); return
    }
    #expect(second == Data("0#e4d*".utf8))
    guard case .lifecycle(.disconnected(let error)) = steps[4] else {
        Issue.record("step 4: expected disconnected, got \(steps[4])"); return
    }
    #expect(error == nil)
}

@Test func emulatorSessionCaptureReplaysThroughHostAdapter() async throws {
    // Full pipeline: SimulatedBoard → SquareOffPersonality frames →
    // CaptureRecorder → ReplayScript.parse → ReplayTransport(SquareOffAdapter)
    // → the host sees the original ground truth.
    var personality = SquareOffPersonality()
    var recorder = CaptureRecorder()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    var truth: [(square: String, isLift: Bool, piece: Piece?)] = []
    for uci in ["e2e4", "e7e5", "g1f3"] {
        let events = try await sim.executeMove(uci: uci)
        truth += sensedTuples(events)
        for event in events {
            for frame in personality.frames(for: event) {
                recorder.recordNotification(frame.data, elapsedMs: 500)
            }
        }
    }

    let steps = try ReplayScript.parse(text: recorder.text)
    let replay = ReplayTransport(adapter: SquareOffAdapter(), parsedScript: steps)
    let replayed = sensedTuples(replay.runSync())

    #expect(replayed.count == truth.count)
    for (replayedEvent, truthEvent) in zip(replayed, truth) {
        #expect(replayedEvent.square == truthEvent.square)
        #expect(replayedEvent.isLift == truthEvent.isLift)
    }
}

@Test func captureHexIsCanonical() {
    var recorder = CaptureRecorder()
    recorder.recordNotification(Data([0x01, 0x22, 0xAB, 0x00, 0xFF]))
    #expect(recorder.text == "rx 01 22 AB 00 FF\n")
}
