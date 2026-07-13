// Personality command handling — LED writes, handshakes, battery requests
// produce protocol-correct responses. Golden bytes are reused from the
// existing adapter test suites (G4/G6/G7 fixtures) as inputs.

import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter
import ChessnutAdapter
import PegasusAdapter
import MillenniumAdapter
import CertaboAdapter
import ChessUpAdapter
import BoardKitEmulator
import BoardKitTestSupport

// MARK: - Square Off host commands

@Test func squareOffStartNewGameRespondsGO() {
    var personality = SquareOffPersonality()
    // The exact bytes the host adapter sends for .startSession.
    let write = SquareOffAdapter().encode(.startSession)!
    #expect(write == Data("14#1*".utf8))

    let actions = personality.handleHostWrite(write)
    #expect(actions.contains(.startNewGame))
    #expect(actions.contains(.notify(PersonalityFrame(
        characteristicUUID: SquareOffPersonality.txCharUUID,
        data: Data("14#GO*".utf8)
    ))))
}

@Test func squareOffBoardStateRequestReturnsInitialOccupancy() {
    var personality = SquareOffPersonality()
    let write = SquareOffAdapter().encode(.requestState)!
    #expect(write == Data("30#R*".utf8))

    let actions = personality.handleHostWrite(write)
    #expect(actions.count == 1)
    guard case .notify(let frame) = actions[0] else {
        Issue.record("expected notify, got \(actions[0])")
        return
    }
    // Initial position: every file reads ranks 1,2 occupied + 7,8 occupied.
    let expectedBody = String(repeating: "11000011", count: 8)
    #expect(frame.data == Data(("30#" + expectedBody + "*").utf8))

    // Loop the response back through the host adapter.
    var host = SquareOffAdapter()
    let events = host.feed(bytes: frame.data)
    guard case .occupancySnapshot(let occupancy) = events.first else {
        Issue.record("host could not decode the board-state response")
        return
    }
    #expect(occupancy.filter { $0 }.count == 32)
}

@Test func squareOffLEDWriteDecodesSquares() {
    var personality = SquareOffPersonality()
    // Host-side encode for .indicateSquares — reuse the committed codec.
    let write = SquareOffAdapter().encode(.indicateSquares(["e2", "e4"], style: .highlight))!
    #expect(write == Data("25#e2e4*".utf8))
    let actions = personality.handleHostWrite(write)
    #expect(actions == [.setLEDs(["e2", "e4"])])

    // Clear-all form.
    let clear = personality.handleHostWrite(Data("25#*".utf8))
    #expect(clear == [.setLEDs([])])
}

@Test func squareOffLEDWriteSurvivesFragmentation() {
    var personality = SquareOffPersonality()
    let first = personality.handleHostWrite(Data("25#e2".utf8))
    #expect(first.isEmpty, "half a frame must not produce actions")
    let second = personality.handleHostWrite(Data("e4*30#R*".utf8))
    // Completing the LED frame plus a whole state request in one write.
    #expect(second.count == 2)
    #expect(second[0] == .setLEDs(["e2", "e4"]))
    guard case .notify = second[1] else {
        Issue.record("expected board-state notify, got \(second[1])")
        return
    }
}

@Test func squareOffMotorisedMoveCommands() {
    var personality = SquareOffPersonality()
    #expect(personality.handleHostWrite(Data("0#e2e4*".utf8)) == [.executeMove(uci: "e2e4")])
    #expect(personality.handleHostWrite(Data("24#e2,e4*".utf8)) == [.executeMove(uci: "e2e4")])
}

@Test func squareOffUnknownCommandIsLoggedNotFatal() {
    var personality = SquareOffPersonality()
    let actions = personality.handleHostWrite(Data("99#zzz*".utf8))
    #expect(actions.count == 1)
    guard case .log = actions[0] else {
        Issue.record("expected log action, got \(actions[0])")
        return
    }
}

// MARK: - Chessnut host commands

@Test func chessnutRealtimeHandshakeStreamsAFreshFrame() {
    var personality = ChessnutPersonality()
    // The exact bytes the host adapter sends for .startSession (G5 fixture).
    let write = ChessnutAdapter().encode(.startSession)!
    #expect(write == Data([0x21, 0x01, 0x00]))

    let actions = personality.handleHostWrite(write)
    let frames = actions.compactMap { action -> PersonalityFrame? in
        if case .notify(let frame) = action { return frame }
        return nil
    }
    #expect(frames.count == 1)
    #expect(frames[0].characteristicUUID == ChessnutGATT.boardStateChar)
    #expect(frames[0].data.count == 36)

    // The fresh frame must decode to the initial position on the host side
    // — byte-identical to the G1 golden fixture.
    let g1Bytes = Data([
        0x01, 0x22,
        0x58, 0x23, 0x31, 0x85, 0x44, 0x44, 0x44, 0x44,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x77, 0x77, 0x77, 0x77,
        0xA6, 0xC9, 0x9B, 0x6A,
        0x00, 0x00,
    ])
    #expect(frames[0].data == g1Bytes)
}

@Test func chessnutBatteryRequestGoldenResponses() {
    // Not charging, 67 % — must equal the G6 golden frame.
    var personality = ChessnutPersonality(batteryPercent: 67, isCharging: false)
    let request = ChessnutAdapter.batteryRequestData()   // 0x29 0x01 0x00
    var actions = personality.handleHostWrite(request)
    #expect(actions == [.notify(PersonalityFrame(
        characteristicUUID: ChessnutGATT.commandResponseChar,
        data: Data([0x2A, 0x02, 0x43, 0x00])
    ))])

    // Charging, 67 % — the 0x80 flag variant of the G6 fixture.
    personality = ChessnutPersonality(batteryPercent: 67, isCharging: true)
    actions = personality.handleHostWrite(request)
    guard case .notify(let frame) = actions[0] else {
        Issue.record("expected notify")
        return
    }
    #expect(frame.data == Data([0x2A, 0x02, 0xC3, 0x00]))

    // Host adapter decodes the charging response to 67 %.
    var host = ChessnutAdapter()
    let events = host.feed(bytes: frame.data)
    guard case .battery(let percent) = events.first else {
        Issue.record("host could not decode battery response")
        return
    }
    #expect(percent == 67)
}

@Test func chessnutLEDWriteDecodesG7AndG4Fixtures() {
    var personality = ChessnutPersonality()

    // G7 orientation canary: c4 only.
    let g7 = Data([0x0A, 0x08, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00])
    #expect(personality.handleHostWrite(g7) == [.setLEDs(["c4"])])

    // G4: e2 + e4.
    let g4 = Data([0x0A, 0x08, 0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x08, 0x00])
    let actions = personality.handleHostWrite(g4)
    guard case .setLEDs(let squares) = actions[0] else {
        Issue.record("expected setLEDs")
        return
    }
    #expect(Set(squares) == Set(["e2", "e4"]))

    // Round-trip: host encode → personality decode for a batch.
    let hostEncoded = ChessnutAdapter().encode(.indicateSquares(["a1", "h8", "d4"], style: .highlight))!
    let decoded = personality.handleHostWrite(hostEncoded)
    guard case .setLEDs(let batch) = decoded[0] else {
        Issue.record("expected setLEDs")
        return
    }
    #expect(Set(batch) == Set(["a1", "h8", "d4"]))
}

@Test func chessnutWriteSurvivesFragmentation() {
    var personality = ChessnutPersonality()
    let g7 = Data([0x0A, 0x08, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00])
    let first = personality.handleHostWrite(g7.prefix(4))
    #expect(first.isEmpty)
    let second = personality.handleHostWrite(g7.dropFirst(4))
    #expect(second == [.setLEDs(["c4"])])
}

@Test func chessnutBeepAndUnknownOpcodesAreLogged() {
    var personality = ChessnutPersonality()
    // G8 beep fixture bytes.
    let beep = ChessnutAdapter.beepData(frequency: 1000, duration: 200)
    let beepActions = personality.handleHostWrite(beep)
    #expect(beepActions.count == 1)
    guard case .log = beepActions[0] else {
        Issue.record("expected log for beep")
        return
    }
    let unknown = personality.handleHostWrite(Data([0x77, 0x01, 0x00]))
    #expect(unknown.count == 1)
    guard case .log = unknown[0] else {
        Issue.record("expected log for unknown opcode")
        return
    }
}

// MARK: - GATT layouts + advertising identity

@Test func squareOffGATTMatchesHostTransportConstants() {
    let personality = SquareOffPersonality()
    let layout = personality.gattLayout
    // Host scans for the marker service and the NUS.
    #expect(layout.advertisedServiceUUIDs == [
        "D804B643-6CE7-4E81-9F8A-CE0F699085EB",
        "6e400001-b5a3-f393-e0a9-e50e24dcca9e",
    ])
    // Data channel: NUS with RX (host write) + TX (board notify).
    #expect(layout.services.count == 1)
    #expect(layout.services[0].uuid == "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    #expect(layout.writableCharacteristicUUIDs == ["6e400002-b5a3-f393-e0a9-e50e24dcca9e"])
    // Host filter: name contains "square" case-insensitively.
    #expect(personality.advertisedName.lowercased().contains("square"))
}

@Test func chessnutGATTMatchesAdapterConstantsAndNameFilter() {
    let personality = ChessnutPersonality()
    let layout = personality.gattLayout
    let serviceUUIDs = Set(layout.services.map(\.uuid))
    #expect(serviceUUIDs.contains(ChessnutGATT.boardStateService))
    #expect(serviceUUIDs.contains(ChessnutGATT.commandService))
    #expect(layout.writableCharacteristicUUIDs == [ChessnutGATT.commandWriteChar])
    // The advertised name must pass the host's classic-profile filter.
    #expect(ChessnutGATT.isClassicProfile(name: personality.advertisedName))
}

// MARK: - Pegasus host commands

@Test func pegasusFieldUpdateModeIsStartNewGame() {
    var personality = PegasusPersonality()
    let write = PegasusAdapter().encode(.startSession)!  // 0x44
    #expect(write == Data([0x44]))
    let actions = personality.handleHostWrite(write)
    #expect(actions.contains(.startNewGame))
}

@Test func pegasusBoardDumpRequestReturnsBoardDump() {
    var personality = PegasusPersonality()
    let write = PegasusAdapter().encode(.requestState)!  // 0x42
    #expect(write == Data([0x42]))
    let actions = personality.handleHostWrite(write)
    #expect(actions.count == 1)
    guard case .notify(let frame) = actions[0] else {
        Issue.record("expected notify, got \(actions[0])"); return
    }
    #expect(frame.data.count == 67)
    #expect(frame.data[0] == 0x86)
    // Start position: ranks 1,2,7,8 occupied → 32 occupied squares.
    let occupancyBytes = [UInt8](frame.data[3...])
    #expect(occupancyBytes.filter { $0 != 0 }.count == 32)
    // Round-trip through host adapter.
    var host = PegasusAdapter()
    let events = host.feed(bytes: frame.data)
    guard case .occupancySnapshot(let occ) = events.first else {
        Issue.record("host could not decode board dump"); return
    }
    #expect(occ.filter { $0 }.count == 32)
}

@Test func pegasusLEDCommandDecodesSquares() {
    var personality = PegasusPersonality()
    let adapter = PegasusAdapter()
    // LED: e2 + e4.
    let write = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))!
    let actions = personality.handleHostWrite(write)
    guard case .setLEDs(let squares) = actions.first else {
        Issue.record("expected setLEDs, got \(actions)"); return
    }
    #expect(Set(squares) == Set(["e2", "e4"]))
}

@Test func pegasusLEDAllOffCommand() {
    var personality = PegasusPersonality()
    let write = PegasusAdapter().encode(.indicateSquares([], style: .highlight))!
    let actions = personality.handleHostWrite(write)
    #expect(actions == [.setLEDs([])])
}

@Test func pegasusUnknownCommandIsLogged() {
    var personality = PegasusPersonality()
    let actions = personality.handleHostWrite(Data([0x4D]))  // version request
    #expect(actions.count == 1)
    guard case .log = actions[0] else {
        Issue.record("expected log, got \(actions[0])"); return
    }
}

@Test func pegasusGATTMatchesAdapterConstants() {
    let personality = PegasusPersonality()
    let layout = personality.gattLayout
    #expect(layout.services.count == 1)
    #expect(layout.services[0].uuid == PegasusGATT.nordicUART)
    #expect(layout.writableCharacteristicUUIDs == [PegasusGATT.writeChar])
    #expect(layout.advertisedServiceUUIDs.contains(PegasusGATT.nordicUART))
}

// MARK: - Millennium host commands

@Test func millenniumStateRequestReturnsSFrame() {
    var personality = MillenniumPersonality()
    let write = MillenniumAdapter.encodeStateRequest()  // "S" parity-encoded
    let actions = personality.handleHostWrite(write)
    guard case .notify(let frame) = actions.first else {
        Issue.record("expected notify, got \(actions)"); return
    }
    #expect(frame.characteristicUUID == MillenniumPersonality.notifyCharUUID)
    #expect(frame.data.count == 67)
    // Round-trip: the s-frame must decode to .identitySnapshot + .ready on first feed.
    var host = MillenniumAdapter()
    let events = host.feed(bytes: frame.data)
    let hasIdentity = events.contains { if case .identitySnapshot = $0 { return true }; return false }
    #expect(hasIdentity, "host did not decode the s-frame to identitySnapshot")
}

@Test func millenniumLEDCommandDecodesSquares() {
    var personality = MillenniumPersonality()
    // Encode via the adapter (internal `millenniumLEDFrame` path).
    let write = MillenniumAdapter().encode(.indicateSquares(["e2", "e4"], style: .highlight))!
    #expect(write.count == 167)
    let actions = personality.handleHostWrite(write)
    guard case .setLEDs(let squares) = actions.first else {
        Issue.record("expected setLEDs, got \(actions)"); return
    }
    #expect(Set(squares) == Set(["e2", "e4"]))
}

@Test func millenniumExtinguishCommandClearsLEDs() {
    var personality = MillenniumPersonality()
    let write = MillenniumAdapter.encodeLEDOff()  // "X" parity-encoded
    let actions = personality.handleHostWrite(write)
    #expect(actions.contains(.setLEDs([])))
}

@Test func millenniumResetIsStartNewGame() {
    var personality = MillenniumPersonality()
    let write = MillenniumAdapter.encodeReset()  // "T" parity-encoded
    let actions = personality.handleHostWrite(write)
    #expect(actions.contains(.startNewGame))
}

@Test func millenniumVersionRequestIsLogged() {
    var personality = MillenniumPersonality()
    let write = MillenniumAdapter.encodeVersionRequest()
    let actions = personality.handleHostWrite(write)
    #expect(actions.count == 1)
    guard case .log = actions[0] else {
        Issue.record("expected log, got \(actions[0])"); return
    }
}

@Test func millenniumGATTMatchesAdapterConstants() {
    let personality = MillenniumPersonality()
    let layout = personality.gattLayout
    #expect(layout.services.count == 1)
    #expect(layout.services[0].uuid == MillenniumGATT.serviceUUID)
    #expect(layout.writableCharacteristicUUIDs == [MillenniumGATT.writeCharUUID])
    #expect(personality.advertisedName == MillenniumGATT.advertisedName)
    #expect(MillenniumGATT.isMillennium(name: personality.advertisedName))
}

// MARK: - Certabo host commands

@Test func certaboClassicLEDDecodes() {
    var personality = CertaboPersonality()
    // 8-byte frame: e2 + e4 lit. [OFFICIAL]: byte[7-rank] |= 1 << file.
    // e2: file=4, rank0=1 → byte[6] |= 1<<4 = 0x10
    // e4: file=4, rank0=3 → byte[4] |= 1<<4 = 0x10
    var ledBytes = [UInt8](repeating: 0, count: 8)
    ledBytes[6] = 0x10   // e2
    ledBytes[4] = 0x10   // e4
    let write = Data(ledBytes)
    let actions = personality.handleHostWrite(write)
    guard case .setLEDs(let squares) = actions.first else {
        Issue.record("expected setLEDs, got \(actions)"); return
    }
    #expect(Set(squares) == Set(["e2", "e4"]))
}

@Test func certaboAllOffLEDDecodes() {
    var personality = CertaboPersonality()
    let write = Data(repeating: 0, count: 8)
    let actions = personality.handleHostWrite(write)
    #expect(actions == [.setLEDs([])])
}

@Test func certaboRoundTripLEDViaAdapter() {
    var personality = CertaboPersonality()
    let adapter = CertaboAdapter()
    let encoded = adapter.encode(.indicateSquares(["a1", "h8"], style: .highlight))!
    #expect(encoded.count == 8)
    let actions = personality.handleHostWrite(encoded)
    guard case .setLEDs(let squares) = actions.first else {
        Issue.record("expected setLEDs"); return
    }
    #expect(Set(squares) == Set(["a1", "h8"]))
}

@Test func certaboUnknownWriteIsLogged() {
    var personality = CertaboPersonality()
    let actions = personality.handleHostWrite(Data([0x01, 0x02, 0x03]))
    #expect(actions.count == 1)
    guard case .log = actions[0] else {
        Issue.record("expected log, got \(actions[0])"); return
    }
}

@Test func certaboGATTHasServiceAndWriteChar() {
    let personality = CertaboPersonality()
    let layout = personality.gattLayout
    #expect(layout.services.count == 1)
    #expect(layout.services[0].uuid == CertaboBT.serviceUUID)
    #expect(layout.writableCharacteristicUUIDs == [CertaboPersonality.writeCharUUID])
}

// MARK: - ChessUp host commands

@Test func chessUpGetStateReturns73ByteFrame() {
    var personality = ChessUpPersonality()
    // GET_STATE is .requestState (0x67); .startSession now opens the phoneOTB
    // recording session (0xB9) rather than probing state.
    let write = ChessUpAdapter().encode(.requestState)!  // Data([0x67])
    #expect(write == Data([0x67]))
    let actions = personality.handleHostWrite(write)
    guard case .notify(let frame) = actions.first else {
        Issue.record("expected notify, got \(actions)"); return
    }
    #expect(frame.data.count == 73)
    #expect(frame.data[0] == 0x67)
    // Round-trip: host adapter must decode as occupancySnapshot + .ready.
    var host = ChessUpAdapter()
    let events = host.feed(bytes: frame.data)
    #expect(events.contains { if case .ready = $0 { return true }; return false })
    guard let first = events.first, case .occupancySnapshot(let occ) = first else {
        Issue.record("host did not decode 0x67 as occupancySnapshot"); return
    }
    #expect(occ.filter { $0 }.count == 32, "start position must have 32 occupied squares")
}

@Test func chessUpShowMoveDecodesSquares() {
    var personality = ChessUpPersonality()
    // Host encodes: .indicateSquares(["e2","e4"], style:) → [0x99, fromIdx, toIdx]
    let write = ChessUpAdapter().encode(.indicateSquares(["e2", "e4"], style: .highlight))!
    #expect(write == Data([0x99, 0x0C, 0x1C]))  // e2=12, e4=28
    let actions = personality.handleHostWrite(write)
    guard case .setLEDs(let squares) = actions.first else {
        Issue.record("expected setLEDs, got \(actions)"); return
    }
    #expect(squares.count == 2)
    #expect(Set(squares) == Set(["e2", "e4"]))
}

@Test func chessUpEnableStreamIsLogged() {
    var personality = ChessUpPersonality()
    let actions = personality.handleHostWrite(ChessUpAdapter.enableRawStreamData)
    #expect(actions.count == 1)
    guard case .log = actions[0] else {
        Issue.record("expected log, got \(actions[0])"); return
    }
}

@Test func chessUpGameSettingsIsLogged() {
    var personality = ChessUpPersonality()
    let settings = ChessUpAdapter.gameSettingsData(
        mode: 5, whiteType: 0, whiteLevel: 1, whiteLock: 0,
        blackType: 0, blackLevel: 1, blackLock: 0,
        hintLimit: 0, whiteRemote: 0, blackRemote: 0, deviceUser: 0)
    let actions = personality.handleHostWrite(settings)
    #expect(actions.count == 1)
    guard case .log = actions[0] else {
        Issue.record("expected log for game settings"); return
    }
}

@Test func chessUpGATTMatchesAdapterConstants() {
    let personality = ChessUpPersonality()
    let layout = personality.gattLayout
    #expect(layout.services.count == 1)
    #expect(layout.services[0].uuid == ChessUpGATT.nusService)
    #expect(layout.writableCharacteristicUUIDs == [ChessUpGATT.nusRX])
    #expect(ChessUpGATT.isChessUp(name: personality.advertisedName))
}

// MARK: - ChessUp 0xA3 move-frame gating + retransmit (hardware-verified 2026-07-07)

/// Before any 0xB9 (or in builtInAI/noPhoneOTB modes) no 0xA3 must be emitted.
@Test func chessUpNoMoveA3WithoutPhoneOTBMode() {
    // ── nil mode (no 0xB9 ever sent) ──────────────────────────────────────────
    var pNil = ChessUpPersonality()
    #expect(pNil.sessionModeForTesting == nil)
    let liftNil  = pNil.frames(for: .squareSensed(square: "e2", isLift: true,  piece: nil))
    let placeNil = pNil.frames(for: .squareSensed(square: "e4", isLift: false, piece: nil))
    #expect(!(liftNil + placeNil).contains { $0.data.first == 0xA3 },
            "No 0xA3 before any 0xB9 (nil mode)")

    // ── builtInAI mode 6 ──────────────────────────────────────────────────────
    var p6 = ChessUpPersonality()
    let b9mode6 = ChessUpAdapter.gameSettingsData(
        mode: 6, whiteType: 0, whiteLevel: 1, whiteLock: 0,
        blackType: 0, blackLevel: 1, blackLock: 0,
        hintLimit: 0, whiteRemote: 0, blackRemote: 0, deviceUser: 0)
    _ = p6.handleHostWrite(b9mode6)
    #expect(p6.sessionModeForTesting == 6)
    let lift6  = p6.frames(for: .squareSensed(square: "d2", isLift: true,  piece: nil))
    let place6 = p6.frames(for: .squareSensed(square: "d4", isLift: false, piece: nil))
    #expect(!(lift6 + place6).contains { $0.data.first == 0xA3 },
            "No 0xA3 in builtInAI mode (6)")

    // ── noPhoneOTB mode 7 ─────────────────────────────────────────────────────
    var p7 = ChessUpPersonality()
    let b9mode7 = ChessUpAdapter.gameSettingsData(
        mode: 7, whiteType: 0, whiteLevel: 1, whiteLock: 0,
        blackType: 0, blackLevel: 1, blackLock: 0,
        hintLimit: 0, whiteRemote: 0, blackRemote: 0, deviceUser: 0)
    _ = p7.handleHostWrite(b9mode7)
    let lift7  = p7.frames(for: .squareSensed(square: "c2", isLift: true,  piece: nil))
    let place7 = p7.frames(for: .squareSensed(square: "c4", isLift: false, piece: nil))
    #expect(!(lift7 + place7).contains { $0.data.first == 0xA3 },
            "No 0xA3 in noPhoneOTB mode (7)")
}

/// After 0xB9 mode 5 (phoneOTB) a completed move emits a 6-byte 0xA3 frame
/// with hardware-observed sub byte 0x35, correct col/row encoding, that the
/// host ChessUpAdapter decodes into the right squareSensed pair AND queues
/// exactly one 0x21 ack in takePendingResponses().
@Test func chessUpPhoneOTBMovesEmitA3WithCorrectEncoding() {
    var personality = ChessUpPersonality()

    // Open the phoneOTB recording session.
    let b9 = ChessUpAdapter.collectionSessionData()   // 0xB9 mode 5
    _ = personality.handleHostWrite(b9)
    #expect(personality.sessionModeForTesting == 5)

    // Drive e2→e4: lift, then place.
    let liftFrames  = personality.frames(for: .squareSensed(square: "e2", isLift: true,  piece: nil))
    let placeFrames = personality.frames(for: .squareSensed(square: "e4", isLift: false, piece: nil))

    // No 0xA3 on the lift alone (move is incomplete).
    #expect(!liftFrames.contains { $0.data.first == 0xA3 },
            "No 0xA3 on lift alone — move not yet complete")

    // Exactly one 0xA3 on the place event (move complete).
    let a3Frames = placeFrames.filter { $0.data.first == 0xA3 && $0.data.count == 6 }
    #expect(a3Frames.count == 1, "Exactly one 0xA3 frame when move completes")

    let a3 = [UInt8](a3Frames[0].data)
    // Byte layout: [A3, 0x35, fromCol, fromRow, toCol, toRow]
    #expect(a3[0] == 0xA3)
    #expect(a3[1] == 0x35, "Sub byte must be 0x35 (hardware-observed constant)")
    // e2: file e=4, rank0idx=1  →  col=4, row=1
    #expect(a3[2] == 4 && a3[3] == 1,
            "From square e2: col \(a3[2]) row \(a3[3]) (expected 4, 1)")
    // e4: file e=4, rank0idx=3  →  col=4, row=3
    #expect(a3[4] == 4 && a3[5] == 3,
            "To square e4: col \(a3[4]) row \(a3[5]) (expected 4, 3)")

    // ── Round-trip: host ChessUpAdapter must decode the A3 correctly ──────────
    var hostAdapter = ChessUpAdapter()
    let events = hostAdapter.feed(bytes: a3Frames[0].data)
    let sensed = events.compactMap { e -> (String, Bool)? in
        if case .squareSensed(let sq, let lift, _) = e { return (sq, lift) }
        return nil
    }
    #expect(sensed.count == 2, "0xA3 must decode to exactly 2 squareSensed events on host")
    #expect(sensed[0] == ("e2", true),  "First host event: lift from e2")
    #expect(sensed[1] == ("e4", false), "Second host event: place on e4")

    // Host adapter queues exactly one 0x21 ack per 0xA3 frame.
    let acks = hostAdapter.takePendingResponses()
    #expect(acks == [ChessUpAdapter.ackMoveData()],
            "Host must queue exactly one 0x21 ack for the 0xA3")
}

/// Retransmit model: an unacked 0xA3 is re-emitted alongside subsequent
/// notifications; the host adapter deduplicates the retransmit in its event
/// stream but still queues an ack for EVERY raw frame; personality clears
/// the pending retransmit when it receives 0x21.
@Test func chessUpA3RetransmitClearedByAck() {
    var personality = ChessUpPersonality()
    _ = personality.handleHostWrite(ChessUpAdapter.collectionSessionData())  // mode 5

    // Complete a move (e2→e4).
    _ = personality.frames(for: .squareSensed(square: "e2", isLift: true,  piece: nil))
    _ = personality.frames(for: .squareSensed(square: "e4", isLift: false, piece: nil))

    // Subsequent event BEFORE 0x21: the pending A3 must be retransmitted.
    let nextFrames = personality.frames(for: .squareSensed(square: "e7", isLift: true, piece: nil))
    let retransmits = nextFrames.filter { $0.data.first == 0xA3 && $0.data.count == 6 }
    #expect(retransmits.count == 1,
            "A3 must be retransmitted on the next board notification before 0x21")

    // ── Host-side dedup + ack-every-raw contract ──────────────────────────────
    // Simulate the host adapter receiving the original A3, then the retransmit.
    var hostAdapter = ChessUpAdapter()
    // Prime: original A3 (e2→e4 in col/row)
    let originalA3 = Data([0xA3, 0x35, 4, 1, 4, 3])
    let firstEvents  = hostAdapter.feed(bytes: originalA3)
    _ = hostAdapter.takePendingResponses()   // drain the first ack
    let firstSensed = firstEvents.compactMap { e -> (String, Bool)? in
        if case .squareSensed(let sq, let lift, _) = e { return (sq, lift) }
        return nil
    }
    #expect(firstSensed.count == 2, "Original A3: 2 squareSensed events")

    // Feed the retransmit (byte-identical A3).
    let retransmitEvents = hostAdapter.feed(bytes: retransmits[0].data)
    let retransmitSensed = retransmitEvents.compactMap { e -> (String, Bool)? in
        if case .squareSensed(let sq, let lift, _) = e { return (sq, lift) }
        return nil
    }
    #expect(retransmitSensed.isEmpty,
            "Host deduplicates the retransmitted A3 — no squareSensed events in event stream")
    let acksForRetransmit = hostAdapter.takePendingResponses()
    #expect(acksForRetransmit == [ChessUpAdapter.ackMoveData()],
            "Host acks every raw A3 even when deduped from event stream")

    // ── Personality clears pending move on 0x21 ───────────────────────────────
    let ackActions = personality.handleHostWrite(Data([0x21]))
    let hasLog = ackActions.contains { if case .log = $0 { return true }; return false }
    #expect(hasLog, "0x21 must produce at least one .log action")

    // After 0x21, the next event must NOT carry an A3 retransmit.
    // Use occupancySnapshot to avoid triggering new A3 assembly.
    let afterAckFrames = personality.frames(for: .occupancySnapshot([Bool](repeating: false, count: 64)))
    #expect(!afterAckFrames.contains { $0.data.first == 0xA3 },
            "No A3 retransmit after 0x21 ack — pendingUnackedMove must be cleared")
}

// MARK: - ChessUp board-side promotion (0x97) emission and round-trip

/// In phoneOTB mode (mode 5) a promotion move must emit 0xA3 followed
/// immediately by a 0x97 promotion-pick frame.  The host adapter decodes
/// the 0x97 as `.promotionPick(piece:)`.  The personality holds the 0x97
/// in `pendingUnackedPromotion` and retransmits it until the host sends 0x23.
@Test func chessUpPromotionMoveEmitsA3ThenPromo97() {
    var personality = ChessUpPersonality()
    _ = personality.handleHostWrite(ChessUpAdapter.collectionSessionData())  // mode 5

    // Play a pawn promotion: lift from b2, place on a1 as a bishop.
    // The piece parameter carries the promotion result (bishop).
    _ = personality.frames(for: .squareSensed(square: "b2", isLift: true,  piece: nil))
    let placeFrames = personality.frames(for: .squareSensed(
        square: "a1", isLift: false,
        piece: Piece(type: .bishop, color: .white)
    ))

    // Both 0xA3 (move) and 0x97 (promotion pick) must be in the output.
    let a3s = placeFrames.filter { $0.data.first == 0xA3 && $0.data.count == 6 }
    let promos = placeFrames.filter { $0.data.first == 0x97 && $0.data.count == 2 }
    #expect(a3s.count == 1,   "Exactly one 0xA3 frame for the promotion move")
    #expect(promos.count == 1, "Exactly one 0x97 promotion frame alongside 0xA3")

    // 0xA3 must appear before 0x97 in the output.
    if let a3Idx  = placeFrames.firstIndex(where: { $0.data.first == 0xA3 }),
       let promIdx = placeFrames.firstIndex(where: { $0.data.first == 0x97 }) {
        #expect(a3Idx < promIdx, "0xA3 must precede 0x97 in the frame output")
    }

    // 0x97 piece byte must be 3 (bishop wire code).
    let promoBytes = [UInt8](promos[0].data)
    #expect(promoBytes[1] == 3, "Bishop promotion must carry wire byte 3")

    // ── Round-trip: host ChessUpAdapter decodes 0x97 as .promotionPick(.bishop) ──
    var hostAdapter = ChessUpAdapter()
    // Feed the A3 first (deduplication guard needs the move frame first).
    _ = hostAdapter.feed(bytes: a3s[0].data)
    _ = hostAdapter.takePendingResponses()   // drain A3 ack
    // Feed the 0x97.
    let promoEvents = hostAdapter.feed(bytes: promos[0].data)
    guard case .promotionPick(let decodedPiece) = promoEvents.first else {
        Issue.record("Host must decode 0x97 byte=3 as .promotionPick(.bishop)")
        return
    }
    #expect(decodedPiece == .bishop, "Host decoded piece must be .bishop")
    // Host queues 0x23 ack.
    let promoAcks = hostAdapter.takePendingResponses()
    #expect(promoAcks == [ChessUpAdapter.ackBoardPromotionData()],
            "Host must queue 0x23 after receiving 0x97")
}

/// The 0x97 promotion frame is retransmitted alongside subsequent notifications
/// until the host sends 0x23.
@Test func chessUpPromo97RetransmitClearedBy0x23() {
    var personality = ChessUpPersonality()
    _ = personality.handleHostWrite(ChessUpAdapter.collectionSessionData())  // mode 5

    // Play a promotion move (queen).
    _ = personality.frames(for: .squareSensed(square: "e7", isLift: true, piece: nil))
    _ = personality.frames(for: .squareSensed(
        square: "e8", isLift: false,
        piece: Piece(type: .queen, color: .white)
    ))

    // Next event before 0x21/0x23: both A3 and promo retransmits must fire.
    let nextFrames = personality.frames(for: .squareSensed(square: "a2", isLift: true, piece: nil))
    let a3Retransmits    = nextFrames.filter { $0.data.first == 0xA3 }
    let promoRetransmits = nextFrames.filter { $0.data.first == 0x97 }
    #expect(a3Retransmits.count == 1,    "A3 retransmit before ack")
    #expect(promoRetransmits.count == 1, "0x97 retransmit before 0x23")
    // Queen promotion wire byte is 4.
    if let promoBytes = promoRetransmits.first.map({ [UInt8]($0.data) }) {
        #expect(promoBytes[1] == 4, "Queen promotion must carry wire byte 4")
    }

    // Ack 0x21 (move ack) — clears A3 retransmit only.
    _ = personality.handleHostWrite(Data([0x21]))
    let afterA3Ack = personality.frames(for: .occupancySnapshot([Bool](repeating: false, count: 64)))
    #expect(!afterA3Ack.contains { $0.data.first == 0xA3 }, "No A3 after 0x21 ack")
    // 0x97 retransmit must still fire (0x23 not yet sent).
    #expect(afterA3Ack.contains { $0.data.first == 0x97 }, "0x97 still retransmits before 0x23")

    // Ack 0x23 (promotion ack) — clears promotion retransmit.
    let ackActions = personality.handleHostWrite(Data([0x23]))
    let hasLog = ackActions.contains { if case .log = $0 { return true }; return false }
    #expect(hasLog, "0x23 must produce at least one .log action")

    let afterPromoAck = personality.frames(for: .occupancySnapshot([Bool](repeating: false, count: 64)))
    #expect(!afterPromoAck.contains { $0.data.first == 0x97 },
            "No 0x97 retransmit after 0x23 ack — pendingUnackedPromotion must be cleared")
}

/// Non-promotion moves (normal pawn push, piece moves) must NOT emit 0x97.
@Test func chessUpNonPromotionMoveDoesNotEmit97() {
    var personality = ChessUpPersonality()
    _ = personality.handleHostWrite(ChessUpAdapter.collectionSessionData())  // mode 5

    // Normal pawn push e2→e4 (piece is nil — occupancy-only path).
    _ = personality.frames(for: .squareSensed(square: "e2", isLift: true,  piece: nil))
    let placeFrames = personality.frames(for: .squareSensed(square: "e4", isLift: false, piece: nil))
    #expect(!placeFrames.contains { $0.data.first == 0x97 },
            "Normal move must not emit 0x97 promotion frame")

    // Pawn move with piece=pawn (not a promotion — still on rank 3).
    let pawnPiece = Piece(type: .pawn, color: .white)
    _ = personality.frames(for: .squareSensed(square: "d2", isLift: true,  piece: nil))
    let pawnPlaceFrames = personality.frames(for: .squareSensed(square: "d4", isLift: false, piece: pawnPiece))
    #expect(!pawnPlaceFrames.contains { $0.data.first == 0x97 },
            "Pawn piece (not promoted) must not emit 0x97")
}

// MARK: - Driver-path promotion tests (SimulatedBoard.executeMove → personality)
//
// These tests exercise the REAL driver path and close the modeling gap proven
// by the live end-to-end test: b2a1b produced only 0xA3+0x21, no 0x97.
//
// Root causes:
// (a) SimulatedBoard.physicalEvents: capture branch placed moverPiece=pawn
//     instead of promoted piece, and never emitted .promotionPick.
// (b) ChessUpPersonality.frames(for:): .promotionPick was a no-op.
// (c) GameDriver.execute: .promotionPick was never forwarded to the personality.

/// Plain (non-capture) promotion through the DRIVER path:
/// SimulatedBoard on an occupancy-only board must emit .promotionPick which
/// the personality converts to 0x97 in phoneOTB mode.
@Test func driverPathPlainPromotionEmits0x97() async throws {
    let sim = SimulatedBoard(
        position: Position(fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1")!,
        capabilities: [.occupancySensing]  // ChessUp has no .pieceIdentity
    )
    var personality = ChessUpPersonality()
    _ = personality.handleHostWrite(ChessUpAdapter.collectionSessionData())  // mode 5

    let events = try await sim.executeMove(uci: "e7e8q")
    // events: [squareSensed(e7,lift,nil), squareSensed(e8,place,nil), promotionPick(.queen)]

    var allFrames: [PersonalityFrame] = []
    for event in events {
        allFrames += personality.frames(for: event)
    }

    let a3Frames  = allFrames.filter { $0.data.first == 0xA3 && $0.data.count == 6 }
    let x97Frames = allFrames.filter { $0.data.first == 0x97 && $0.data.count == 2 }
    #expect(a3Frames.count == 1,  "Driver path: plain promotion must emit exactly one 0xA3")
    #expect(x97Frames.count == 1, "Driver path: plain promotion must emit exactly one 0x97")

    // Queen = wire code 4.
    let promoBytes = [UInt8](x97Frames[0].data)
    #expect(promoBytes[1] == 4, "Queen promotion driver path: wire code must be 4")

    // 0xA3 must appear before 0x97.
    if let a3Idx  = allFrames.firstIndex(where: { $0.data.first == 0xA3 }),
       let promIdx = allFrames.firstIndex(where: { $0.data.first == 0x97 }) {
        #expect(a3Idx < promIdx, "0xA3 must precede 0x97 in the frame output")
    }
}

/// CAPTURE-promotion through the DRIVER path — this was the exact failing
/// scenario: playing a capture-promotion produced only 0xA3+0x21, no 0x97
/// (fallback picker appeared).
///
/// Fixes verified: SimulatedBoard capture branch now handles promotion (places
/// promoted piece for identity boards + emits .promotionPick); personality
/// handles .promotionPick; GameDriver forwards knowledge events.
@Test func driverPathCapturePromotionEmits0x97() async throws {
    // White pawn b7 captures black rook a8 and promotes to bishop (b7a8b).
    // (White pawns promote on rank 8, not rank 1.)
    let sim = SimulatedBoard(
        position: Position(fen: "r7/1P6/8/8/8/8/8/4K2k w - - 0 1")!,
        capabilities: [.occupancySensing]
    )
    var personality = ChessUpPersonality()
    _ = personality.handleHostWrite(ChessUpAdapter.collectionSessionData())  // mode 5

    let events = try await sim.executeMove(uci: "b7a8b")
    // events: [squareSensed(b7,lift,nil), squareSensed(a8,lift,nil),
    //          squareSensed(a8,place,nil), promotionPick(.bishop)]

    var allFrames: [PersonalityFrame] = []
    for event in events {
        allFrames += personality.frames(for: event)
    }

    let a3Frames  = allFrames.filter { $0.data.first == 0xA3 && $0.data.count == 6 }
    let x97Frames = allFrames.filter { $0.data.first == 0x97 && $0.data.count == 2 }
    #expect(a3Frames.count == 1,
            "Capture-promotion driver path: must emit 0xA3 (the proven-missing frame)")
    #expect(x97Frames.count == 1,
            "Capture-promotion driver path: must emit 0x97 (was the verified bug)")

    // Bishop = wire code 3.
    let promoBytes = [UInt8](x97Frames[0].data)
    #expect(promoBytes[1] == 3,
            "b7a8b bishop promotion: wire code must be 3")

    // ── Adapter round-trip: 0x97 → .promotionPick(.bishop) + queues 0x23 ──────
    var hostAdapter = ChessUpAdapter()
    _ = hostAdapter.feed(bytes: a3Frames[0].data)
    _ = hostAdapter.takePendingResponses()  // drain 0x21 ack
    let promoEvents = hostAdapter.feed(bytes: x97Frames[0].data)
    guard case .promotionPick(let piece) = promoEvents.first else {
        Issue.record("Host adapter must decode 0x97 byte=3 as .promotionPick(.bishop)")
        return
    }
    #expect(piece == .bishop, "Round-trip: decoded piece must be .bishop")
    #expect(hostAdapter.takePendingResponses() == [ChessUpAdapter.ackBoardPromotionData()],
            "Host adapter must queue 0x23 ack for the 0x97")
}

/// .promotionPick must be suppressed (no 0x97) in non-phoneOTB modes.
@Test func driverPathPromotionInNonPhoneOTBModeNoPromo97() async throws {
    // nil mode: no 0xB9 received.
    let simNil = SimulatedBoard(
        position: Position(fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1")!,
        capabilities: [.occupancySensing]
    )
    var pNil = ChessUpPersonality()
    var framesNil: [PersonalityFrame] = []
    for event in try await simNil.executeMove(uci: "e7e8q") {
        framesNil += pNil.frames(for: event)
    }
    #expect(!framesNil.contains { $0.data.first == 0x97 },
            "No 0x97 without a 0xB9 (nil session mode)")

    // builtInAI mode 6.
    let sim6 = SimulatedBoard(
        position: Position(fen: "8/4P3/8/8/8/8/8/4K2k w - - 0 1")!,
        capabilities: [.occupancySensing]
    )
    var p6 = ChessUpPersonality()
    _ = p6.handleHostWrite(ChessUpAdapter.gameSettingsData(
        mode: 6, whiteType: 0, whiteLevel: 1, whiteLock: 0,
        blackType: 0, blackLevel: 1, blackLock: 0,
        hintLimit: 0, whiteRemote: 0, blackRemote: 0, deviceUser: 0))
    var framesP6: [PersonalityFrame] = []
    for event in try await sim6.executeMove(uci: "e7e8q") {
        framesP6 += p6.frames(for: event)
    }
    #expect(!framesP6.contains { $0.data.first == 0x97 },
            "No 0x97 in builtInAI mode 6")
}

/// initialSessionMode: 5 in EmulatorOptions.makePersonality() means the dry-run
/// emulator has the 0xA3/0x97 gate open without a real host handshake.
@Test func chessUpInitialSessionModePreset() {
    // Default init: nil (gate closed until real 0xB9 arrives).
    let defaultPersonality = ChessUpPersonality()
    #expect(defaultPersonality.sessionModeForTesting == nil,
            "Default init must have nil session mode")

    // Emulator init: mode 5 (gate open for dry-run / live emulation).
    let emulatorPersonality = ChessUpPersonality(initialSessionMode: 5)
    #expect(emulatorPersonality.sessionModeForTesting == 5,
            "initialSessionMode:5 must pre-set phoneOTB mode")

    // A host 0xB9 can still override the initial mode.
    var overridable = ChessUpPersonality(initialSessionMode: 5)
    _ = overridable.handleHostWrite(ChessUpAdapter.gameSettingsData(
        mode: 6, whiteType: 0, whiteLevel: 1, whiteLock: 0,
        blackType: 0, blackLevel: 1, blackLock: 0,
        hintLimit: 0, whiteRemote: 0, blackRemote: 0, deviceUser: 0))
    #expect(overridable.sessionModeForTesting == 6,
            "Host 0xB9 mode 6 must override the initial mode 5")
}
