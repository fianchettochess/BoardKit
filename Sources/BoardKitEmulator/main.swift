// boardkit-emulator — Tier-0 physical-board emulator CLI.
//
// Advertises over real BLE as a Square Off Pro or Chessnut Air and plays
// games (PGN or seeded legal-random) with a deterministic chaos layer
// modelling fallible-human piece handling, so the Fianchetto apps on a real
// phone can connect to it as if it were hardware.
//
// LIVE-RUN NOTE (honest limits): real advertising requires the macOS
// Bluetooth TCC permission prompt to be accepted and a real central to
// connect — the first live run is a human-driven session. CI covers
// everything below the radio via BoardKitEmulatorTests.

import Foundation
import ChessCore
import BoardKitTestSupport

// MARK: - Shared setup

func loadScriptedUCIs(pgnPath: String?) -> [String] {
    guard let pgnPath else { return [] }
    guard let text = try? String(contentsOfFile: pgnPath, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read PGN file: \(pgnPath)\n".utf8))
        exit(2)
    }
    guard let game = PGNParser.loadGame(from: text) else {
        FileHandle.standardError.write(Data("cannot parse PGN file: \(pgnPath)\n".utf8))
        exit(2)
    }
    return game.mainLine.map { $0.move.uci }
}

func makeDriver(options: EmulatorOptions) -> GameDriver {
    let configuration = GameDriver.Configuration(
        scriptedUCIs: loadScriptedUCIs(pgnPath: options.pgnPath),
        chaosProfile: options.chaosProfile,
        seed: options.seed,
        thinkMs: options.thinkMs,
        humanMs: options.humanMs,
        pushStateEvery: options.pushStateEvery
    )
    return GameDriver(personality: options.makePersonality(), configuration: configuration)
}

func log(_ message: String) {
    print("[emulator] \(message)")
}

// MARK: - Entry

let parsed = EmulatorOptions.parse(Array(CommandLine.arguments.dropFirst()))
let options: EmulatorOptions
switch parsed {
case .success(let value):
    options = value
case .failure(let usageError):
    FileHandle.standardError.write(Data((usageError.message + "\n").utf8))
    exit(64)   // EX_USAGE
}

if options.dryRun {
    // ── Dry run: everything below the radio, frames printed as hex ────────
    let driver = makeDriver(options: options)
    let plies = options.dryRunPlies
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await driver.setOnLog { message in log(message) }
        await driver.setOnFrames { frames in
            for frame in frames {
                let hex = frame.data.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("notify \(frame.characteristicUUID): \(hex)")
            }
        }
        for _ in 0..<plies {
            if await driver.playNextScriptedMoveNow() == nil { break }
        }
        done.signal()
    }
    done.wait()
    log("dry run complete (\(options.boardKind.rawValue), chaos \(options.chaosProfile.name), seed \(options.seed))")
    exit(0)
}

#if os(macOS) && canImport(CoreBluetooth)

let personality = options.makePersonality()
let driver = makeDriver(options: options)

let captureURL = options.capturePath.map { URL(fileURLWithPath: $0) }
let header = """
boardkit-emulator capture
board: \(options.boardKind.rawValue)  chaos: \(options.chaosProfile.name)  seed: \(options.seed)
rx = board→host notification (replayable via ReplayTransport); tx = host→board write
"""
let server = PeripheralServer(
    advertisedName: personality.advertisedName,
    layout: personality.gattLayout,
    notifyGapMs: options.notifyGapMs,
    captureURL: captureURL,
    captureHeader: header
)

server.onLog = { message in log(message) }
server.onHostWrite = { data in
    Task { await driver.hostWrote(data) }
}
server.onCentralPresence = { present in
    Task {
        if present {
            log("central subscribed — starting game driver")
            await driver.start()
        } else {
            log("central gone — pausing game driver")
            await driver.stop()
        }
    }
}

Task {
    await driver.setOnLog { message in log(message) }
    await driver.setOnFrames { frames in
        server.enqueue(frames)
    }
}

log("starting \(options.boardKind.rawValue) emulator (chaos \(options.chaosProfile.name), seed \(options.seed))")
if let captureURL {
    log("capturing traffic to \(captureURL.path)")
}
server.start()
dispatchMain()

#else

FileHandle.standardError.write(Data("""
boardkit-emulator: live BLE advertising requires macOS with CoreBluetooth.
Use --dry-run on this platform to exercise the personality + chaos layers.

""".utf8))
exit(70)   // EX_SOFTWARE

#endif
