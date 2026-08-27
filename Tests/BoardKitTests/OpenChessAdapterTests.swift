import Testing
import Foundation
import ChessCore
import BoardKit
import OpenChessAdapter

/// Test suite for the Open Chess adapter.
///
/// Tests cover:
/// - Sensor event parsing (SE events)
/// - Occupancy snapshot parsing (OC events)
/// - Command encoding (LED, GETSTATE, NEWGAME)
/// - BLE constants and helper methods
/// - Frame reassembly across multiple feeds
@Suite("OpenChess adapter")
struct OpenChessAdapterTests {

    // MARK: - Helper Methods

    /// Create a sensor event string (e.g., "SE:e2L").
    private func sensorEvent(square: String, isLift: Bool) -> Data {
        let state = isLift ? "L" : "P"
        return Data("SE:\(square)\(state)\n".utf8)
    }

    /// Create an occupancy snapshot string (e.g., "OC:11111111...").
    private func occupancySnapshot(occupied: Set<Int>) -> Data {
        let bits = (0..<64).map { occupied.contains($0) ? "1" : "0" }.joined()
        return Data("OC:\(bits)\n".utf8)
    }

    /// Extract occupancy snapshot from events.
    private func occupancy(from events: [BoardEvent]) -> [Bool]? {
        for e in events { if case .occupancySnapshot(let occ) = e { return occ } }
        return nil
    }

    /// Convert algebraic square to file-major index.
    private func fileMajor(_ sq: String) -> Int {
        let s = Square(algebraic: sq)!
        return s.file * 8 + s.rank
    }

    // MARK: - Sensor Event Tests

    @Test("Sensor event decodes to squareSensed lift")
    func sensorEventLift() {
        var adapter = OpenChessAdapter()
        let events = adapter.feed(bytes: sensorEvent(square: "e2", isLift: true))
        #expect(events.contains { event in
            if case .squareSensed("e2", true, _) = event { return true }
            return false
        })
    }

    @Test("Sensor event decodes to squareSensed place")
    func sensorEventPlace() {
        var adapter = OpenChessAdapter()
        let events = adapter.feed(bytes: sensorEvent(square: "e4", isLift: false))
        #expect(events.contains { event in
            if case .squareSensed("e4", false, _) = event { return true }
            return false
        })
    }

    @Test("Sensor events for all corners work correctly")
    func sensorEventCorners() {
        var adapter = OpenChessAdapter()
        
        // Test a1 (bottom-left)
        let a1 = adapter.feed(bytes: sensorEvent(square: "a1", isLift: true))
        #expect(a1.contains { event in
            if case .squareSensed("a1", true, _) = event { return true }
            return false
        })
        
        // Test h8 (top-right)
        let h8 = adapter.feed(bytes: sensorEvent(square: "h8", isLift: false))
        #expect(h8.contains { event in
            if case .squareSensed("h8", false, _) = event { return true }
            return false
        })
    }

    // MARK: - Occupancy Snapshot Tests

    @Test("Occupancy snapshot is file-major (a1=0, h8=63)")
    func occupancyIsFileMajor() throws {
        var adapter = OpenChessAdapter()
        // a2 = file 0, rank 1 → index 1; e4 = file 4, rank 3 → index 35
        let events = adapter.feed(bytes: occupancySnapshot(occupied: [1, 35]))
        let occ = try #require(occupancy(from: events))
        #expect(occ.count == 64)
        #expect(occ[fileMajor("a2")])
        #expect(occ[fileMajor("e4")])
        #expect(occ.filter { $0 }.count == 2)
        #expect(!occ[fileMajor("a1")] && !occ[fileMajor("h8")] && !occ[fileMajor("b1")])
    }

    @Test("Empty occupancy snapshot has no occupied squares")
    func emptyOccupancy() throws {
        var adapter = OpenChessAdapter()
        let events = adapter.feed(bytes: occupancySnapshot(occupied: []))
        let occ = try #require(occupancy(from: events))
        #expect(occ.filter { $0 }.count == 0)
    }

    @Test("Full occupancy snapshot has all squares occupied")
    func fullOccupancy() throws {
        var adapter = OpenChessAdapter()
        let allSquares = Set(0..<64)
        let events = adapter.feed(bytes: occupancySnapshot(occupied: allSquares))
        let occ = try #require(occupancy(from: events))
        #expect(occ.filter { $0 }.count == 64)
    }

    // MARK: - Command Encoding Tests

    @Test("Start session encodes to NEWGAME command")
    func startSessionCommand() {
        let adapter = OpenChessAdapter()
        let data = adapter.encode(.startSession)
        let command = String(data: data!, encoding: .utf8)
        #expect(command?.contains("CMD:NEWGAME") == true)
    }

    @Test("Request state encodes to GETSTATE command")
    func requestStateCommand() {
        let adapter = OpenChessAdapter()
        let data = adapter.encode(.requestState)
        let command = String(data: data!, encoding: .utf8)
        #expect(command?.contains("CMD:GETSTATE") == true)
    }

    @Test("Indicate squares encodes LED command")
    func indicateSquaresCommand() {
        let adapter = OpenChessAdapter()
        let data = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
        let command = String(data: data!, encoding: .utf8)
        #expect(command?.contains("LED:e2,e4") == true)
    }

    @Test("Execute move encodes MOVE command")
    func executeMoveCommand() {
        let adapter = OpenChessAdapter()
        let data = adapter.encode(.executeMove(uci: "e2e4"))
        let command = String(data: data!, encoding: .utf8)
        #expect(command?.contains("MOVE:e2e4") == true)
    }

    @Test("Custom data is forwarded verbatim")
    func customDataCommand() {
        let adapter = OpenChessAdapter()
        let customData = Data("CUSTOM:test".utf8)
        let data = adapter.encode(.custom(customData))
        #expect(data == customData)
    }

    // MARK: - Handshake Tests

    @Test("Fresh handshake includes startSession and requestState")
    func freshHandshake() {
        let adapter = OpenChessAdapter()
        let commands = adapter.handshakeCommands(isReconnect: false)
        #expect(commands.count == 2)
        
        // Check first command is startSession
        if case .startSession = commands[0].command {
            // OK
        } else {
            Issue.record("Expected .startSession command")
        }
        
        // Check second command is requestState
        if case .requestState = commands[1].command {
            // OK
        } else {
            Issue.record("Expected .requestState command")
        }
        
        #expect(commands[0].delayBefore == 0.5)
        #expect(commands[1].delayBefore == 0.2)
    }

    @Test("Reconnect handshake only includes requestState")
    func reconnectHandshake() {
        let adapter = OpenChessAdapter()
        let commands = adapter.handshakeCommands(isReconnect: true)
        #expect(commands.count == 1)
        
        // Check command is requestState
        if case .requestState = commands[0].command {
            // OK
        } else {
            Issue.record("Expected .requestState command")
        }
        
        #expect(commands[0].delayBefore == 0.25)
    }

    // MARK: - Frame Reassembly Tests

    @Test("Split frame reassembles across two feeds")
    func splitFrameReassembles() throws {
        var adapter = OpenChessAdapter()
        let whole = occupancySnapshot(occupied: [1])
        let cut = whole.count / 2
        #expect(adapter.feed(bytes: Data(whole[..<cut])).isEmpty)
        let events = adapter.feed(bytes: Data(whole[cut...]))
        let occ = try #require(occupancy(from: events))
        #expect(occ[1] && occ.filter { $0 }.count == 1)
    }

    @Test("Two concatenated frames in one feed yield two events")
    func coalescedFrames() {
        var adapter = OpenChessAdapter()
        var blob = sensorEvent(square: "e2", isLift: true)
        blob.append(sensorEvent(square: "e4", isLift: false))
        #expect(adapter.feed(bytes: blob).count == 2)
    }

    // MARK: - BLE Constants Tests

    @Test("BLE service UUID matches firmware")
    func bleServiceUUID() {
        #expect(OpenChessBLE.serviceUUID == "19B10000-E8F2-537E-4F6C-D104768A1214")
    }

    @Test("BLE sensor characteristic UUID matches firmware")
    func bleSensorCharUUID() {
        #expect(OpenChessBLE.sensorCharUUID == "19B10001-E8F2-537E-4F6C-D104768A1214")
    }

    @Test("BLE command characteristic UUID matches firmware")
    func bleCommandCharUUID() {
        #expect(OpenChessBLE.commandCharUUID == "19B10002-E8F2-537E-4F6C-D104768A1214")
    }

    @Test("BLE device name is OpenChess")
    func bleDeviceName() {
        #expect(OpenChessBLE.deviceName == "OpenChess")
    }

    @Test("OpenChessBLE.isOpenChess matches device name")
    func isOpenChess() {
        #expect(OpenChessBLE.isOpenChess(name: "OpenChess"))
        #expect(OpenChessBLE.isOpenChess(name: "openchess"))
        #expect(!OpenChessBLE.isOpenChess(name: "OtherDevice"))
    }

    // MARK: - BLE Helper Method Tests

    @Test("BLE set LEDs helper creates correct command")
    func bleSetLEDsHelper() {
        let data = OpenChessAdapter.bleSetLEDs(squares: ["e2", "e4"])
        let command = String(data: data, encoding: .utf8)
        #expect(command == "SET:e2,e4")
    }

    @Test("BLE set LED color helper creates correct command")
    func bleSetLEDColorHelper() {
        let data = OpenChessAdapter.bleSetLEDColor(square: "e4", r: 255, g: 0, b: 0)
        let command = String(data: data, encoding: .utf8)
        #expect(command == "COLOR:e4R255G0B0")
    }

    @Test("BLE clear LEDs helper creates correct command")
    func bleClearLEDsHelper() {
        let data = OpenChessAdapter.bleClearLEDs()
        let command = String(data: data, encoding: .utf8)
        #expect(command == "CLEAR")
    }

    @Test("BLE request state helper creates correct command")
    func bleRequestStateHelper() {
        let data = OpenChessAdapter.bleRequestState()
        let command = String(data: data, encoding: .utf8)
        #expect(command == "GETSTATE")
    }

    @Test("BLE start new game helper creates correct command")
    func bleStartNewGameHelper() {
        let data = OpenChessAdapter.bleStartNewGame()
        let command = String(data: data, encoding: .utf8)
        #expect(command == "NEWGAME")
    }

    // MARK: - Capabilities Tests

    @Test("OpenChess adapter has correct capabilities")
    func capabilities() {
        let adapter = OpenChessAdapter()
        #expect(adapter.capabilities.contains(.occupancySensing))
        #expect(adapter.capabilities.contains(.perSquareLEDs))
        #expect(adapter.capabilities.contains(.moveIndication))
        #expect(!adapter.capabilities.contains(.pieceIdentity))
    }

    @Test("Minimum write interval is 200ms")
    func minimumWriteInterval() {
        let adapter = OpenChessAdapter()
        #expect(adapter.minimumWriteInterval == 0.2)
    }
}
