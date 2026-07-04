import Foundation
import ChessCore
import BoardKit
import PegasusAdapter

/// Peripheral-side impersonation of a DGT Pegasus board.
///
/// Occupancy-only: reuses `PegasusAdapter.encodeBoardDump(occupancy:)` for
/// board-dump replies and builds 5-byte field-update frames inline (the
/// inverse of `processFieldUpdate` in `PegasusAdapter`).
///
/// ## Transport identity
/// Nordic UART Service (NUS) only — same UUID family as Square Off and ChessUp.
/// Discovery by service UUID per the adapter's pinned discovery rule.
public struct PegasusPersonality: BoardPersonality {

    // MARK: - GATT constants

    public static let nusServiceUUID = PegasusGATT.nordicUART
    public static let writeCharUUID  = PegasusGATT.writeChar
    public static let notifyCharUUID = PegasusGATT.notifyChar

    // MARK: - State

    /// Occupancy mirror (file-major a1=0…h8=63). Seeded to the initial position.
    private var occupancy: [Bool]

    /// Fragment accumulator for multi-byte host commands (LED 0x60, devkey 0x63).
    private var cmdBuffer: [UInt8] = []

    public let advertisedName: String

    public init(advertisedName: String = PegasusGATT.factoryNamePrefix) {
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
            if let idx = Self.protocolIndex(square) {
                if let fm = Self.fileMajorIndex(square) { occupancy[fm] = !isLift }
                return [fieldUpdateFrame(index: idx, isLift: isLift)]
            }
            return []

        case .occupancySnapshot(let snapshot):
            if snapshot.count == 64 { occupancy = snapshot }
            return [boardDumpFrame()]

        case .identitySnapshot(let identity):
            if identity.count == 64 { occupancy = identity.map { $0 != nil } }
            return [boardDumpFrame()]

        case .battery(let percent):
            // 0xA0 [0x00, 0x0C, percent, 0,0,0,0,0,0,0,0,0] — 12 bytes total length
            // Keep simple: emit a minimal valid battery reply.
            let totalLen: UInt8 = 12
            let frame = Data([0xA0, 0x00, totalLen, UInt8(max(0, min(100, percent))),
                              0, 0, 0, 0, 0, 0, 0, 0])
            return [PersonalityFrame(characteristicUUID: Self.notifyCharUUID, data: frame)]

        case .ready, .connected, .disconnected, .raw:
            return []
        }
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        cmdBuffer.append(contentsOf: data)
        var actions: [PeripheralAction] = []
        while !cmdBuffer.isEmpty {
            let byte = cmdBuffer[0]
            switch byte {
            case 0x44:  // fieldUpdateMode → streaming start
                cmdBuffer.removeFirst()
                actions.append(.startNewGame)
            case 0x42:  // board dump request
                cmdBuffer.removeFirst()
                actions.append(.notify(boardDumpFrame()))
            case 0x40:  // reset
                cmdBuffer.removeFirst()
                actions.append(.log("pegasus: reset 0x40"))
            case 0x45, 0x47, 0x4D, 0x4C:  // serial/trademark/version/battery info
                cmdBuffer.removeFirst()
                actions.append(.log("pegasus: info request 0x\(String(format: "%02X", byte))"))
            case 0x60:  // LED command (multi-byte, self-length-prefixed)
                guard cmdBuffer.count >= 2 else { return actions }  // wait for len byte
                let totalLen = Int(cmdBuffer[1]) + 2
                guard cmdBuffer.count >= totalLen else { return actions }
                let frame = Array(cmdBuffer.prefix(totalLen))
                cmdBuffer.removeFirst(totalLen)
                actions.append(contentsOf: decodeLEDFrame(frame))
            case 0x63:  // devkey (multi-byte)
                guard cmdBuffer.count >= 2 else { return actions }
                let totalLen = Int(cmdBuffer[1]) + 2
                guard cmdBuffer.count >= totalLen else { return actions }
                cmdBuffer.removeFirst(totalLen)
                actions.append(.log("pegasus: devkey registered"))
            default:
                cmdBuffer.removeFirst()
                actions.append(.log("pegasus: unhandled host byte 0x\(String(format: "%02X", byte))"))
            }
        }
        return actions
    }

    // MARK: - Frame builders

    private func boardDumpFrame() -> PersonalityFrame {
        PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                         data: PegasusAdapter.encodeBoardDump(occupancy: occupancy))
    }

    /// Field-update frame: `[0x8E, 0x00, 0x05, protocolIndex, code]`.
    /// code=0x00 for lift (empty), 0x01 for place (occupied).
    private func fieldUpdateFrame(index: Int, isLift: Bool) -> PersonalityFrame {
        let frame = Data([0x8E, 0x00, 0x05, UInt8(index), isLift ? 0x00 : 0x01])
        return PersonalityFrame(characteristicUUID: Self.notifyCharUUID, data: frame)
    }

    // MARK: - LED decode

    /// Decode a Pegasus 0x60 LED frame into algebraic squares.
    private func decodeLEDFrame(_ frame: [UInt8]) -> [PeripheralAction] {
        guard frame.count >= 2, frame[0] == 0x60 else {
            return [.log("pegasus: malformed LED frame")]
        }
        // All-off: `60 02 00 00`
        if frame.count >= 4, frame[2] == 0x00 { return [.setLEDs([])] }
        // Subcommand-0x05 list form: `60 len 05 speed repeat brightness sq0…sqN 00`
        guard frame.count >= 4, frame[2] == 0x05, frame.count >= 7 else {
            return [.log("pegasus: short LED frame")]
        }
        let squareBytes = frame.dropFirst(6).dropLast()  // strip 00 terminator
        let files = Array("abcdefgh")
        var squares: [String] = []
        for sq in squareBytes {
            let (file, rankIdx) = PegasusAdapter.squareComponents(protocolIndex: Int(sq))
            if file < 8 && rankIdx < 8 {
                squares.append("\(files[file])\(rankIdx + 1)")
            }
        }
        return [.setLEDs(squares)]
    }

    // MARK: - Test mirror

    /// Expose occupancy mirror (file-major, a1=0…h8=63).
    public var occupancyMirror: [Bool] { occupancy }

    // MARK: - Index helpers

    /// Pegasus protocol index for a square: (7 - rank0indexed) * 8 + file (0=a8…63=h1).
    static func protocolIndex(_ square: String) -> Int? {
        guard let sq = Square(algebraic: square) else { return nil }
        return (7 - sq.rank) * 8 + sq.file
    }

    static func fileMajorIndex(_ square: String) -> Int? {
        guard let sq = Square(algebraic: square) else { return nil }
        return sq.file * 8 + sq.rank
    }
}
