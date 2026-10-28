import Testing
import Foundation
import ChessCore
import BoardKit
import OpenChessAdapter

/// Open Chess speaks newline-delimited JSON. The load-bearing details are the
/// occupancy bit order (rank-major on the wire, file-major in BoardKit), line
/// framing across BLE notifications, and the exact command bytes.
@Suite("Open Chess adapter")
struct OpenChessAdapterTests {

    private func feed(_ text: String, into adapter: inout OpenChessAdapter) -> [BoardEvent] {
        adapter.feed(bytes: Data(text.utf8))
    }

    private func fileMajor(_ square: String) -> Int {
        let s = Square(algebraic: square)!
        return s.file * 8 + s.rank
    }

    private func rawLines(_ events: [BoardEvent]) -> [String] {
        events.compactMap { if case .raw(let data) = $0 { String(decoding: data, as: UTF8.self) } else { nil } }
    }

    // MARK: - Occupancy bit order

    /// THE TRANSPOSITION. Bit k on the wire is rank × 8 + file (a1 = bit 0,
    /// b1 = bit 1, a2 = bit 8), the order the board's own web controller
    /// reads. BoardKit is file-major (a1 = 0, a2 = 1, b1 = 8). The start
    /// position is symmetric under that transposition, so single squares
    /// pin it instead.
    @Test(arguments: [
        ("0000000000000001", "a1"),
        ("0000000000000002", "b1"),
        ("0000000000000080", "h1"),
        ("0000000000000100", "a2"),
        ("0000000000100000", "e3"),
        ("8000000000000000", "h8"),
    ])
    func oneOccupiedSquare(hex: String, square: String) throws {
        let squares = try #require(OpenChessCodec.occupancy(hex: hex))
        #expect(squares.indices.filter { squares[$0] } == [fileMajor(square)])
        #expect(OpenChessCodec.occupancyHex(squares) == hex)
    }

    @Test func startPositionAndMalformedHex() throws {
        let start = try #require(OpenChessCodec.occupancy(hex: "FFFF00000000FFFF"))
        for square in ["a1", "h1", "d2", "e7", "a8", "h8"] { #expect(start[fileMajor(square)]) }
        for square in ["a3", "e4", "h6"] { #expect(!start[fileMajor(square)]) }
        #expect(OpenChessCodec.occupancy(hex: "ffff00000000fff") == nil)
        #expect(OpenChessCodec.occupancy(hex: "ffff00000000fffg") == nil)
        #expect(OpenChessCodec.occupancy(hex: "+fff00000000ffff") == nil)
    }

    @Test func occupancyLineBecomesASnapshot() throws {
        var adapter = OpenChessAdapter()
        let events = feed(#"{"t":"occupancy","squares":"0000000000100000"}"# + "\n", into: &adapter)
        guard case .occupancySnapshot(let squares) = try #require(events.first), events.count == 1 else {
            Issue.record("expected one occupancy snapshot, got \(events)"); return
        }
        #expect(squares.indices.filter { squares[$0] } == [fileMajor("e3")])
    }

    // MARK: - Framing

    @Test func linesSplitAcrossNotificationsAndCRLF() {
        var adapter = OpenChessAdapter()
        #expect(feed(#"{"t":"li"#, into: &adapter).isEmpty)
        let lifted = feed(#"ft","sq":"e2"}"# + "\r\n\n" + #"{"t":"place","#, into: &adapter)
        guard lifted.count == 1, case .squareSensed("e2", true, nil) = lifted[0] else {
            Issue.record("expected e2 lift, got \(lifted)"); return
        }
        let placed = feed(#""sq":"e4"}"# + "\n", into: &adapter)
        guard placed.count == 1, case .squareSensed("e4", false, nil) = placed[0] else {
            Issue.record("expected e4 place, got \(placed)"); return
        }
    }

    /// Bytes are split before decoding, so a character divided between two
    /// notifications survives.
    @Test func multiByteCharacterAcrossNotifications() {
        var adapter = OpenChessAdapter()
        let line = Data(#"{"t":"status","phase":"playing","msg":"Échec"}"#.utf8) + Data([0x0A])
        let cut = line.firstIndex(of: 0xC3)! + 1
        #expect(adapter.feed(bytes: line[..<cut]).isEmpty)
        #expect(rawLines(adapter.feed(bytes: line[cut...])) == [#"{"t":"status","phase":"playing","msg":"Échec"}"#])
    }

    @Test func runawayLineIsBounded() {
        var adapter = OpenChessAdapter()
        #expect(adapter.feed(bytes: Data(repeating: 0x61, count: 70_000)).isEmpty)
        // The tail of the runaway line comes out as text; the next line is clean.
        let events = feed("\n" + #"{"t":"lift","sq":"a1"}"# + "\n", into: &adapter)
        #expect(rawLines(events).first?.utf8.count == 8_000)
        guard case .squareSensed("a1", true, nil) = events.last else {
            Issue.record("expected a1 lift after the runaway line"); return
        }
    }

    // MARK: - Messages

    @Test func helloIsReadyAndKeepsItsLine() throws {
        let line = #"{"t":"hello","board":"open-chess","fw":"1.2.0","game":"classic-chess","name":"Classic Chess","volume":200}"#
        var adapter = OpenChessAdapter()
        let events = feed(line + "\n", into: &adapter)
        guard events.count == 2, case .ready = events[0] else { Issue.record("\(events)"); return }
        #expect(rawLines(events) == [line])
        #expect(OpenChessMessage.parse(line: line) == .hello(.init(
            board: "open-chess", firmware: "1.2.0", core: nil, game: "classic-chess",
            name: "Classic Chess", volume: 200)))
        // Older firmware names the installed game "mode".
        guard case .hello(let old) = OpenChessMessage.parse(line: #"{"t":"hello","board":"open-chess","mode":"atomic"}"#)
        else { Issue.record("expected hello"); return }
        #expect(old.game == "atomic")
    }

    @Test func batteryIsClampedAndTyped() {
        var adapter = OpenChessAdapter()
        let events = feed(#"{"t":"battery","percent":104,"charging":true,"usb":true,"volts":4.18}"# + "\n", into: &adapter)
        guard events.count == 1, case .battery(100) = events[0] else { Issue.record("\(events)"); return }
        #expect(OpenChessMessage.parse(line: #"{"t":"battery","percent":84}"#)
                == .battery(percent: 84, charging: false, usb: false, volts: nil))
        // A boolean is not a percentage.
        #expect(OpenChessMessage.parse(line: #"{"t":"battery","percent":true}"#)
                == .unknown(line: #"{"t":"battery","percent":true}"#))
    }

    /// The installed game's own reports pass through untouched; the session
    /// infers moves from occupancy.
    @Test func gameReportsAndNoiseAreRaw() {
        let lines = [
            #"{"t":"move","uci":"e7e8q"}"#,
            #"{"t":"state","fen":"rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1","turn":"b"}"#,
            #"{"t":"result","result":"checkmate","winner":"w"}"#,
            #"{"t":"button","id":"a","pressed":true}"#,
            #"{"t":"ack"}"#,
            #"{"t":"error","msg":"bad command"}"#,
            #"{"t":"sparkle","n":3}"#,
            #"{"t":"lift","sq":"i9"}"#,
            #"{"t":"occupancy","squares":"xyz"}"#,
            "booting sensor matrix...",
        ]
        var adapter = OpenChessAdapter()
        let events = feed(lines.joined(separator: "\n") + "\n", into: &adapter)
        #expect(rawLines(events) == lines)
        #expect(OpenChessMessage.parse(line: lines[0]) == .move(uci: "e7e8q"))
        #expect(OpenChessMessage.parse(line: lines[3]) == .button(id: "a", pressed: true))
        #expect(OpenChessMessage.parse(line: lines[7]) == .unknown(line: lines[7]))
        #expect(OpenChessMessage.parse(line: lines[9]) == .text(line: lines[9]))
    }

    @Test func ledFrameIsTransposed() throws {
        // Wire square 1 (b1) green, wire square 8 (a2) white, the rest off.
        var bytes = [String](repeating: "00000000", count: 64)
        bytes[1] = "00ff0000"
        bytes[8] = "000000ff"
        let frame = try #require(OpenChessCodec.ledFrame(hex: bytes.joined()))
        #expect(frame[fileMajor("b1")] == OpenChessColor(red: 0, green: 255, blue: 0))
        #expect(frame[fileMajor("a2")] == OpenChessColor(red: 0, green: 0, blue: 0, white: 255))
        #expect(frame.filter { $0 != OpenChessColor(red: 0, green: 0, blue: 0) }.count == 2)
        #expect(OpenChessCodec.ledFrame(hex: String(repeating: "0", count: 511)) == nil)
    }

    // MARK: - Commands

    @Test func commandBytes() {
        let adapter = OpenChessAdapter()
        func text(_ command: BoardCommand) -> String? {
            adapter.encode(command).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(text(.startSession) == #"{"t":"identify"}"# + "\n")
        #expect(text(.requestState) == #"{"t":"identify"}"# + "\n")
        #expect(text(.indicateSquares([], style: .highlight)) == #"{"t":"leds","clear":true}"# + "\n")
        #expect(text(.indicateSquares(["e2", "e4", "z9"], style: .moveTo))
                == #"{"t":"leds","clear":true}"# + "\n" + #"{"t":"hint","squares":["e2","e4"],"color":[255,160,0,0]}"# + "\n")
        #expect(text(.indicateSquares(["d7"], style: .danger))?.hasSuffix(#""color":[255,0,0,0]}"# + "\n") == true)
        #expect(adapter.encode(.executeMove(uci: "e2e4")) == nil)
        #expect(adapter.encode(.requestStoredGames) == nil)
        #expect(adapter.encode(.custom(Data([1, 2]))) == Data([1, 2]))
        #expect(String(decoding: OpenChessCodec.led("c3", color: .init(red: 1, green: 2, blue: 3, white: 4))!, as: UTF8.self)
                == #"{"t":"led","sq":"c3","color":[1,2,3,4]}"# + "\n")
        #expect(OpenChessCodec.led("c9", color: .init(red: 0, green: 0, blue: 0)) == nil)
        #expect(String(decoding: OpenChessCodec.brightness(120), as: UTF8.self) == #"{"t":"brightness","value":120}"# + "\n")
    }

    /// Every command is one JSON object per line, so the board's parser sees
    /// whole objects however the transport chunks the write.
    @Test func everyCommandLineIsJSON() throws {
        let adapter = OpenChessAdapter()
        let commands: [BoardCommand] = [
            .startSession, .indicateSquares([], style: .highlight),
            .indicateSquares(["a1", "h8"], style: .custom(9)),
        ]
        for command in commands {
            let data = try #require(adapter.encode(command))
            for line in data.split(separator: 0x0A) {
                let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                #expect(object?["t"] is String)
            }
        }
    }

    @Test func handshakeIsIdentifyOnly() {
        let adapter = OpenChessAdapter()
        for reconnect in [false, true] {
            let steps = adapter.handshakeCommands(isReconnect: reconnect)
            #expect(steps.count == 1)
            guard case .startSession = steps[0].command else { Issue.record("\(steps)"); continue }
            #expect(steps[0].delayBefore == 0.25)
        }
    }

    @Test func capabilitiesAndDiscovery() {
        let capabilities = OpenChessAdapter().capabilities
        #expect(capabilities.contains([.occupancySensing, .perSquareLEDs, .moveIndication, .batteryReporting]))
        #expect(!capabilities.contains(.pieceIdentity))
        #expect(!capabilities.contains(.motorised))
        #expect(OpenChessGATT.isOpenChess(name: "Open Chess 4F2A"))
        #expect(!OpenChessGATT.isOpenChess(name: "Chessnut Air"))
        #expect(OpenChessSerial.baudRate == 115_200)
    }
}
