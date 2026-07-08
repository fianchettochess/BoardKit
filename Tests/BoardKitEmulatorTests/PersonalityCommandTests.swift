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
    var adapter = CertaboAdapter()
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
