// Capture output round-trips through ReplayScript.parse — every emulator
// session doubles as a host-side replay fixture.

import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter
import PegasusAdapter
import MillenniumAdapter
import CertaboAdapter
import ChessUpAdapter
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
    #expect(pause == 0.35)
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

// MARK: - Pegasus capture round-trip

@Test func pegasusSessionCaptureReplaysThroughHostAdapter() async throws {
    // Pegasus emits field-update frames; the host adapter decodes them as
    // squareSensed events. Requires an initial board-dump frame to seed
    // previousOccupancy in the adapter.
    var personality = PegasusPersonality()
    var recorder = CaptureRecorder()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // Record initial board dump (seeds previousOccupancy in host adapter).
    let initial = await sim.boardSnapshot()
    for frame in personality.frames(for: initial) {
        recorder.recordNotification(frame.data)
    }

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
    let replay = ReplayTransport(adapter: PegasusAdapter(), parsedScript: steps)
    let replayed = sensedTuples(replay.runSync())

    #expect(replayed.count == truth.count, "Pegasus round-trip event count mismatch")
    for (replayedEvent, truthEvent) in zip(replayed, truth) {
        #expect(replayedEvent.square == truthEvent.square)
        #expect(replayedEvent.isLift == truthEvent.isLift)
    }
}

// MARK: - Millennium capture round-trip

@Test func millenniumSessionCaptureReplaysThroughHostAdapter() async throws {
    // Millennium emits s-frames (full board state) per event; the adapter
    // diffs them against previousIdentity and emits squareSensed deltas.
    // Requires an initial s-frame to seed previousIdentity.
    var personality = MillenniumPersonality()
    var recorder = CaptureRecorder()
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Record initial s-frame (seeds previousIdentity + .ready in host adapter).
    let initial = await sim.boardSnapshot()
    for frame in personality.frames(for: initial) {
        recorder.recordNotification(frame.data)
    }

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
    let replay = ReplayTransport(adapter: MillenniumAdapter(), parsedScript: steps)
    let replayed = sensedTuples(replay.runSync())

    #expect(replayed.count == truth.count, "Millennium round-trip event count mismatch")
    for (replayedEvent, truthEvent) in zip(replayed, truth) {
        #expect(replayedEvent.square == truthEvent.square)
        #expect(replayedEvent.isLift == truthEvent.isLift)
        #expect(replayedEvent.piece == truthEvent.piece, "piece identity diverged @ \(truthEvent.square)")
    }
}

// MARK: - Certabo capture round-trip

@Test func certaboSessionCaptureReplaysThroughHostAdapter() async throws {
    // Certabo emits 2 identical RFID frames per event (adapter uses a 3-frame
    // majority vote to suppress transient noise). Requires an initial RFID
    // frame pair to prime the vote history.
    let cal = makeTestCalibration()
    var personality = CertaboPersonality(calibration: cal)
    var recorder = CaptureRecorder()
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])

    // Record initial RFID frame pair (primes vote history + seeds .ready).
    let initial = await sim.boardSnapshot()
    for frame in personality.frames(for: initial) {
        recorder.recordNotification(frame.data)
    }

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
    let replay = ReplayTransport(adapter: CertaboAdapter(calibration: cal), parsedScript: steps)
    let replayed = sensedTuples(replay.runSync())

    #expect(replayed.count == truth.count, "Certabo round-trip event count mismatch")
    for (replayedEvent, truthEvent) in zip(replayed, truth) {
        #expect(replayedEvent.square == truthEvent.square)
        #expect(replayedEvent.isLift == truthEvent.isLift)
    }
}

// MARK: - ChessUp capture round-trip

@Test func chessUpSessionCaptureReplaysThroughHostAdapter() async throws {
    // ChessUp emits 0x67 board-state frames that the adapter decodes as
    // occupancySnapshot events. The round-trip is verified by comparing the
    // final occupancy snapshot to the expected position after all moves.
    var personality = ChessUpPersonality()
    var recorder = CaptureRecorder()
    let sim = SimulatedBoard(capabilities: [.occupancySensing])

    // Seed the personality's initial board-state frame via a GET_STATE probe,
    // so the adapter sees the first 0x67 frame and emits .ready.
    let primeActions = personality.handleHostWrite(Data([0x67]))
    if case .notify(let frame) = primeActions.first {
        recorder.recordNotification(frame.data)
    }

    var finalExpected: [Bool] = BoardDiffResolver.occupancyArray(for: Position.initial())
    for uci in ["e2e4", "e7e5", "g1f3"] {
        let events = try await sim.executeMove(uci: uci)
        for event in events {
            for frame in personality.frames(for: event) {
                recorder.recordNotification(frame.data, elapsedMs: 500)
            }
        }
        finalExpected = BoardDiffResolver.occupancyArray(for: await sim.position)
    }

    let steps = try ReplayScript.parse(text: recorder.text)
    let replay = ReplayTransport(adapter: ChessUpAdapter(), parsedScript: steps)
    let replayed = replay.runSync()

    // Extract the last occupancySnapshot emitted by the adapter.
    var lastOccupancy: [Bool]? = nil
    for event in replayed {
        if case .occupancySnapshot(let occ) = event { lastOccupancy = occ }
    }
    if let occ = lastOccupancy {
        #expect(occ == finalExpected, "ChessUp round-trip: final occupancy mismatch")
    } else {
        Issue.record("ChessUp round-trip: no occupancySnapshot decoded from replay")
    }
}
