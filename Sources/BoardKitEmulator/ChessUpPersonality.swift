import Foundation
import ChessCore
import BoardKit
import ChessUpAdapter

/// Peripheral-side impersonation of a ChessUp (gen-1) board.
///
/// Occupancy-only: uses `ChessUpAdapter.encodeOccupancyFrame(occupied:)` for
/// 0xFD 0xFD push frames and builds 73-byte 0x67 board-state frames for
/// GET_STATE replies (host's `0x67` request). Piece codes are set to `0x01`
/// (white rook placeholder) for occupied squares — any non-0x40 value reads
/// as occupied by the host adapter.
///
/// ## Host→board commands handled
/// - `0x67`        → GET_STATE → `.notify(boardStateFrame())`
/// - `0x99 f t`    → show move → `.setLEDs([from, to])`
/// - `0x50`        → enable raw stream → `.log`
/// - `0xB9 …`      → game settings → `.log`
/// - Other         → `.log`
///
/// ## Transport identity
/// Nordic UART Service (NUS) — same as Square Off, Pegasus.
/// Discovery by name prefix `"ChessUp"` per `ChessUpGATT.isChessUp`.
public struct ChessUpPersonality: BoardPersonality {

    // MARK: - GATT constants

    public static let nusServiceUUID = ChessUpGATT.nusService
    public static let writeCharUUID  = ChessUpGATT.nusRX
    public static let notifyCharUUID = ChessUpGATT.nusTX

    // MARK: - State

    /// Occupancy mirror (file-major, a1=0…h8=63).
    private var occupancy: [Bool]

    /// Whether the first board-state frame has been sent in this session.
    private var isFirstFrame: Bool = true

    /// Fragment accumulator for multi-byte host commands.
    private var cmdBuffer: [UInt8] = []

    public let advertisedName: String

    public init(advertisedName: String = "ChessUp") {
        self.advertisedName = advertisedName
        var occ = [Bool](repeating: false, count: 64)
        for file in 0..<8 {
            for rank in [0, 1, 6, 7] { occ[file * 8 + rank] = true }
        }
        self.occupancy = occ
    }

    // MARK: - BoardPersonality

    public var gattLayout: GATTLayout {
        GATTLayout(
            services: [
                GATTServiceSpec(uuid: Self.nusServiceUUID, characteristics: [
                    GATTCharacteristicSpec(uuid: Self.writeCharUUID,  roles: [.write, .writeWithoutResponse]),
                    GATTCharacteristicSpec(uuid: Self.notifyCharUUID, roles: [.notify]),
                ]),
            ],
            advertisedServiceUUIDs: [Self.nusServiceUUID]
        )
    }

    public mutating func frames(for event: BoardEvent) -> [PersonalityFrame] {
        switch event {
        case .squareSensed(let square, let isLift, _):
            if let fm = Self.fileMajorIndex(square) { occupancy[fm] = !isLift }
            // Emit a 0x67 board-state frame so the host adapter can track state.
            // Each squareSensed updates the mirror and pushes a complete snapshot.
            return [boardStateFrame()]

        case .occupancySnapshot(let snapshot):
            if snapshot.count == 64 { occupancy = snapshot }
            return [boardStateFrame()]

        case .identitySnapshot(let identity):
            if identity.count == 64 { occupancy = identity.map { $0 != nil } }
            return [boardStateFrame()]

        case .ready, .battery, .connected, .disconnected, .raw:
            return []
        }
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        cmdBuffer.append(contentsOf: data)
        var actions: [PeripheralAction] = []
        while !cmdBuffer.isEmpty {
            let opcode = cmdBuffer[0]
            switch opcode {
            case 0x67:   // GET_STATE
                cmdBuffer.removeFirst()
                actions.append(.notify(boardStateFrame()))

            case 0x99:   // show move: [0x99, fromIdx, toIdx]
                guard cmdBuffer.count >= 3 else { return actions }
                let fromIdx = Int(cmdBuffer[1])
                let toIdx   = Int(cmdBuffer[2])
                cmdBuffer.removeFirst(3)
                let fromSq = Self.canonicalIdxToAlgebraic(fromIdx)
                let toSq   = Self.canonicalIdxToAlgebraic(toIdx)
                if let f = fromSq, let t = toSq {
                    actions.append(.setLEDs([f, t]))
                } else {
                    actions.append(.log("chessup: invalid 0x99 indices \(fromIdx),\(toIdx)"))
                }

            case 0x50:   // enable raw stream
                cmdBuffer.removeFirst()
                actions.append(.log("chessup: raw stream enabled"))

            case 0xB9:   // game settings (12 bytes total)
                guard cmdBuffer.count >= 12 else { return actions }
                cmdBuffer.removeFirst(12)
                actions.append(.log("chessup: game settings received"))

            case 0x66:   // load FEN — variable length; consume 1 byte and log
                // Full FEN frame is complex to parse; log and skip opcode.
                cmdBuffer.removeFirst()
                actions.append(.log("chessup: load FEN (partial)"))

            case 0x64:   // reset game (1 byte)
                cmdBuffer.removeFirst()
                actions.append(.startNewGame)

            default:
                cmdBuffer.removeFirst()
                actions.append(.log("chessup: unhandled host opcode 0x\(String(format: "%02X", opcode))"))
            }
        }
        return actions
    }

    // MARK: - Frame builders

    /// Build a 73-byte 0x67 board-state frame.
    ///
    /// Layout: `[0x67][64 piece codes in canonical order][8 FEN bytes]`.
    /// Canonical index = rank0indexed*8+file (a1=0, h1=7, a8=56, h8=63).
    /// Piece code: 0x40 = empty, 0x01 = occupied (white-rook placeholder).
    private mutating func boardStateFrame() -> PersonalityFrame {
        let wasFirst = isFirstFrame
        isFirstFrame = false
        var frame = [UInt8](repeating: 0, count: 73)
        frame[0] = 0x67
        for fm in 0..<64 {
            let file  = fm / 8
            let rank0 = fm % 8
            let canonIdx = rank0 * 8 + file
            frame[1 + canonIdx] = occupancy[fm] ? 0x01 : 0x40
        }
        // frame[65..72] = 0 (default FEN bytes: white to move, no castling/ep, 0 clocks)
        _ = wasFirst  // .ready fires on first 0x67 frame in the HOST adapter; no extra work here
        return PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                data: Data(frame))
    }

    // MARK: - Test mirror

    /// Expose occupancy mirror (file-major, a1=0…h8=63).
    public var occupancyMirror: [Bool] { occupancy }

    // MARK: - Helpers

    static func fileMajorIndex(_ square: String) -> Int? {
        guard let sq = Square(algebraic: square) else { return nil }
        return sq.file * 8 + sq.rank
    }

    /// Canonical index (rank0*8+file) → algebraic square string.
    static func canonicalIdxToAlgebraic(_ idx: Int) -> String? {
        guard (0..<64).contains(idx) else { return nil }
        let file  = idx % 8
        let rank0 = idx / 8
        let files = Array("abcdefgh")
        return "\(files[file])\(rank0 + 1)"
    }
}
