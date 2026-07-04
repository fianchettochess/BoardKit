import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter

/// Peripheral-side impersonation of a Chessnut Air board.
///
/// Reuses the `ChessnutAdapter` target's codec:
/// - **Board→host** board-state frames are produced by
///   `ChessnutAdapter.encodeFrame(identity:)` — the same 36-byte
///   `[0x01, 0x22, 32 nibble-packed squares, 2 zero]` layout (and therefore
///   the same piece-code table and h8-first square indexing) the host
///   adapter decodes.
/// - **Host→board** writes use the same `[opcode, payloadLength, payload…]`
///   framing the host parses; the personality accumulates fragments across
///   writes exactly like `ChessnutAdapter.feed(bytes:)`.
///
/// ## Protocol behaviour modelled
///
/// - Realtime-mode command `0x21 0x01 0x00` → an immediate fresh board-state
///   frame on the board-state characteristic (matches the host adapter's
///   documented `.requestState` mapping: "re-entering realtime mode causes
///   an immediate fresh frame").
/// - Battery request `0x29 0x01 0x00` → `0x2A 0x02 <level> 0x00` on the
///   command-response characteristic, where `<level>` is
///   `percent | 0x80` when charging (the flag the host masks off).
/// - LED command `0x0A 0x08 R8…R1` → decoded to algebraic squares
///   (bit 7 = a-file … bit 0 = h-file, bytes rank 8→1 — the doubly
///   source-confirmed G7 bit order).
/// - Beep `0x0B …` → logged.
///
/// ## Identity mirror
///
/// A real Chessnut board knows what every piece is. The emulator's chaos
/// streams sometimes lose identity on chaos-inserted events, so the mirror
/// keeps an "airborne" ledger keyed by origin square: a lift remembers the
/// piece it removed, and a nil-piece place falls back to (1) the piece that
/// was lifted from that very square (j'adoube / put-back), then (2) the only
/// airborne piece, then (3) the airborne piece that did NOT originate on the
/// placed square (capture landings).
public struct ChessnutPersonality: BoardPersonality {

    // MARK: - State

    /// File-major (a1=0…h8=63) identity mirror. Seeded to the initial
    /// position.
    private var identity: [Piece?]

    /// Pieces currently lifted, keyed by the square they were lifted from.
    private var airborne: [String: Piece] = [:]

    /// Framing accumulator for fragmented host writes.
    private var buffer: [UInt8] = []

    public let advertisedName: String

    /// Battery level reported by `0x29` requests (0–100).
    public var batteryPercent: Int

    /// When true, battery responses carry the 0x80 charging flag.
    public var isCharging: Bool

    public init(advertisedName: String = "Chessnut Air",
                batteryPercent: Int = 88,
                isCharging: Bool = false) {
        self.advertisedName = advertisedName
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging

        // Initial-position identity via ChessCore (rank-major → file-major).
        let position = Position.initial()
        var fileMajor = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                fileMajor[file * 8 + rank] = position.board[rank * 8 + file]
            }
        }
        self.identity = fileMajor
    }

    // MARK: - BoardPersonality

    public var gattLayout: GATTLayout {
        GATTLayout(
            services: [
                GATTServiceSpec(uuid: ChessnutGATT.boardStateService, characteristics: [
                    GATTCharacteristicSpec(uuid: ChessnutGATT.boardStateChar, roles: [.notify]),
                ]),
                GATTServiceSpec(uuid: ChessnutGATT.commandService, characteristics: [
                    GATTCharacteristicSpec(uuid: ChessnutGATT.commandWriteChar, roles: [.write, .writeWithoutResponse]),
                    GATTCharacteristicSpec(uuid: ChessnutGATT.commandResponseChar, roles: [.notify]),
                ]),
                GATTServiceSpec(uuid: ChessnutGATT.fileService, characteristics: [
                    GATTCharacteristicSpec(uuid: ChessnutGATT.fileChar, roles: [.notify]),
                ]),
            ],
            // Real Air-family boards are discovered by name; advertising the
            // board-state service UUID as well is an assumption recorded in
            // the README-level docs (harmless for name-filtering hosts).
            advertisedServiceUUIDs: [ChessnutGATT.boardStateService]
        )
    }

    public mutating func frames(for event: BoardEvent) -> [PersonalityFrame] {
        switch event {
        case .squareSensed(let square, let isLift, let piece):
            applySensed(square: square, isLift: isLift, piece: piece)
            return [boardStateFrame()]

        case .identitySnapshot(let snapshot):
            if snapshot.count == 64 {
                identity = snapshot
                airborne.removeAll()
            }
            return [boardStateFrame()]

        case .occupancySnapshot:
            // Identity board — an occupancy-only snapshot cannot be encoded
            // without inventing pieces. Callers feed identity snapshots.
            return []

        case .battery(let percent):
            return [batteryFrame(percent: percent, charging: isCharging)]

        case .ready, .connected, .disconnected, .raw:
            // Chessnut readiness is implicit in the first streamed frame.
            return []
        }
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        buffer.append(contentsOf: data)
        var actions: [PeripheralAction] = []
        while buffer.count >= 2 {
            let payloadLength = Int(buffer[1])
            let frameLength = payloadLength + 2
            guard buffer.count >= frameLength else { break }
            let frame = Array(buffer.prefix(frameLength))
            buffer.removeFirst(frameLength)
            actions += handleHostFrame(frame)
        }
        return actions
    }

    // MARK: - Host frame dispatch

    private mutating func handleHostFrame(_ frame: [UInt8]) -> [PeripheralAction] {
        guard let opcode = frame.first else { return [] }
        switch opcode {
        case 0x21:
            // Mode switch. 0x21 0x01 0x00 = realtime: stream board state.
            // A real board pushes a fresh frame immediately — do the same.
            let mode = frame.count > 2 ? frame[2] : 0xFF
            var actions: [PeripheralAction] = [.log("chessnut: mode switch 0x\(String(mode, radix: 16))")]
            if mode == 0x00 {
                actions.append(.notify(boardStateFrame()))
            }
            return actions

        case 0x29:
            // Battery request → battery response on the command-response
            // characteristic.
            return [.notify(batteryFrame(percent: batteryPercent, charging: isCharging))]

        case 0x0A:
            // LED command: 0A 08 R8…R1.
            guard frame.count >= 10 else {
                return [.log("chessnut: short LED frame (\(frame.count) bytes)")]
            }
            return [.setLEDs(Self.squaresFromLEDFrame(frame))]

        case 0x0B:
            return [.log("chessnut: beep \(frame.map { String(format: "%02X", $0) }.joined(separator: " "))")]

        default:
            return [.log("chessnut: unhandled host opcode 0x\(String(format: "%02X", opcode))")]
        }
    }

    // MARK: - Mirror maintenance

    private mutating func applySensed(square: String, isLift: Bool, piece: Piece?) {
        guard let index = Self.fileMajorIndex(square) else { return }
        if isLift {
            if let lifted = identity[index] {
                airborne[square] = lifted
            }
            identity[index] = nil
        } else {
            let landing: Piece?
            if let piece {
                landing = piece
            } else if let returned = airborne[square] {
                landing = returned                          // put-back on origin
            } else if airborne.count == 1 {
                landing = airborne.first?.value              // only piece in hand
            } else {
                landing = airborne.first(where: { $0.key != square })?.value
            }
            identity[index] = landing
            // Retire the ledger entry for whichever piece landed.
            if let landing, let origin = airborne.first(where: { $0.value == landing })?.key {
                airborne.removeValue(forKey: origin)
            }
        }
    }

    // MARK: - Frame builders

    private func boardStateFrame() -> PersonalityFrame {
        PersonalityFrame(characteristicUUID: ChessnutGATT.boardStateChar,
                         data: ChessnutAdapter.encodeFrame(identity: identity))
    }

    private func batteryFrame(percent: Int, charging: Bool) -> PersonalityFrame {
        let clamped = UInt8(max(0, min(100, percent)))
        let level = charging ? (clamped | 0x80) : clamped
        return PersonalityFrame(characteristicUUID: ChessnutGATT.commandResponseChar,
                                data: Data([0x2A, 0x02, level, 0x00]))
    }

    // MARK: - Helpers

    /// Decode a 10-byte LED frame into algebraic squares.
    /// bytes[2] = rank 8 … bytes[9] = rank 1; bit 7 = a-file … bit 0 = h-file.
    static func squaresFromLEDFrame(_ frame: [UInt8]) -> [String] {
        let files = Array("abcdefgh")
        var squares: [String] = []
        for byteIndex in 2...9 {
            let rank = 9 - byteIndex + 1     // rank number 8…1
            let byte = frame[byteIndex]
            for file in 0..<8 where byte & (0x80 >> UInt8(file)) != 0 {
                squares.append("\(files[file])\(rank)")
            }
        }
        return squares
    }

    /// File-major index for an algebraic square, nil when malformed.
    static func fileMajorIndex(_ square: String) -> Int? {
        guard let sq = Square(algebraic: square) else { return nil }
        return sq.file * 8 + sq.rank
    }

    /// Test hook: current identity mirror (file-major).
    public var identityMirror: [Piece?] { identity }
}
