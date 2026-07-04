// GameDriver pure logic: LED-pair → move decoding, CLI option parsing, and
// an end-to-end scripted-move drive through a personality.

import Testing
import Foundation
import ChessCore
import BoardKit
import BoardKitTestSupport
import BoardKitEmulator

// MARK: - LED move decoding

@Test func ledPairDecodesUniqueLegalMove() {
    let initial = Position.initial()
    #expect(GameDriver.moveForLEDSquares(["e2", "e4"], position: initial) == "e2e4")
    // Order-independent.
    #expect(GameDriver.moveForLEDSquares(["e4", "e2"], position: initial) == "e2e4")
    // Not a legal move.
    #expect(GameDriver.moveForLEDSquares(["a3", "h8"], position: initial) == nil)
    // Wrong count.
    #expect(GameDriver.moveForLEDSquares(["e2"], position: initial) == nil)
    #expect(GameDriver.moveForLEDSquares(["e2", "e3", "e4"], position: initial) == nil)
}

@Test func ledPairDecodesCastleAndPromotion() {
    let castleReady = Position(fen: "r1bqk1nr/pppp1ppp/2n5/2b1p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4")!
    #expect(GameDriver.moveForLEDSquares(["e1", "g1"], position: castleReady) == "e1g1")

    let promo = Position(fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1")!
    // Four promotion variants share the pair — the queen wins.
    #expect(GameDriver.moveForLEDSquares(["e7", "e8"], position: promo) == "e7e8q")
}

// MARK: - CLI options

@Test func optionParsingHappyPath() throws {
    let result = EmulatorOptions.parse([
        "chessnut", "--seed", "99", "--chaos", "hostile", "--think-ms", "500",
        "--human-ms", "250", "--capture", "/tmp/x.replay", "--battery", "42",
    ])
    let options = try result.get()
    #expect(options.boardKind == .chessnut)
    #expect(options.seed == 99)
    #expect(options.chaosProfile == .hostile)
    #expect(options.thinkMs == 500)
    #expect(options.humanMs == 250)
    #expect(options.capturePath == "/tmp/x.replay")
    #expect(options.batteryPercent == 42)
    #expect(!options.dryRun)
}

@Test func optionParsingRejectsBadInput() {
    if case .success = EmulatorOptions.parse([]) { Issue.record("empty argv must fail") }
    if case .success = EmulatorOptions.parse(["dgt"]) { Issue.record("unknown board must fail") }
    if case .success = EmulatorOptions.parse(["squareoff", "--chaos", "medium"]) {
        Issue.record("unknown chaos profile must fail")
    }
    if case .success = EmulatorOptions.parse(["squareoff", "--seed"]) {
        Issue.record("missing value must fail")
    }
    if case .success = EmulatorOptions.parse(["squareoff", "--frobnicate"]) {
        Issue.record("unknown flag must fail")
    }
}

@Test func optionParsingDryRunPlies() throws {
    var options = try EmulatorOptions.parse(["squareoff", "--dry-run"]).get()
    #expect(options.dryRun && options.dryRunPlies == 12)
    options = try EmulatorOptions.parse(["squareoff", "--dry-run", "3"]).get()
    #expect(options.dryRun && options.dryRunPlies == 3)
}

// MARK: - Scripted drive end-to-end (no BLE)

/// Thread-safe frame sink for driver callbacks.
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

@Test func scriptedMovesFlowThroughSquareOffPersonality() async throws {
    let driver = GameDriver(
        personality: SquareOffPersonality(),
        configuration: .init(scriptedUCIs: ["e2e4", "e7e5"], chaosProfile: .clean, seed: 1)
    )
    let sink = FrameSink()
    await driver.setOnFrames { sink.append($0) }

    #expect(await driver.playNextScriptedMoveNow() == "e2e4")
    #expect(await driver.playNextScriptedMoveNow() == "e7e5")
    #expect(await driver.playNextScriptedMoveNow() == nil)   // script exhausted, PGN mode

    // Clean profile, two simple moves → four field-update frames.
    let bodies = sink.frames.map { String(decoding: $0.data, as: UTF8.self) }
    #expect(bodies == ["0#e2u*", "0#e4d*", "0#e7u*", "0#e5d*"])
}

@Test func seededRandomDriveIsDeterministic() async throws {
    func run() async -> [String] {
        let driver = GameDriver(
            personality: SquareOffPersonality(),
            configuration: .init(scriptedUCIs: [], chaosProfile: .casual, seed: 777)
        )
        var moves: [String] = []
        for _ in 0..<10 {
            guard let uci = await driver.playNextScriptedMoveNow() else { break }
            moves.append(uci)
        }
        return moves
    }
    let first = await run()
    let second = await run()
    #expect(first.count == 10)
    #expect(first == second, "seeded random games must be reproducible")
}
