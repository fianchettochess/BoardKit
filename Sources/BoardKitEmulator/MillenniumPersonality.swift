import Foundation
import ChessCore
import BoardKit
import MillenniumAdapter

/// Peripheral-side impersonation of a Millennium ChessLink board.
///
/// Identity board (Hall sensors): reuses `MillenniumAdapter.encodeFrame(identity:)`
/// for s-frames in both the board→host direction and as the response to the host's
/// S-command. All bytes on the wire are odd-parity encoded (as the host adapter
/// expects); the personality mirrors the host adapter's framing exactly.
///
/// ## Host→board commands handled
/// - `S` (state request)   → emit an s-frame on the notify characteristic
/// - `V` (version request) → logged (no version reply emitted)
/// - `X` (LED off)         → `.setLEDs([])`
/// - `L` (LED pattern)     → decode corner-LED patterns → `.setLEDs`
/// - `T` (reset/start)     → `.startNewGame`
/// - `W`/`R` (E2ROM)       → logged
public struct MillenniumPersonality: BoardPersonality {

    // MARK: - GATT constants

    public static let serviceUUID    = MillenniumGATT.serviceUUID
    public static let notifyCharUUID = MillenniumGATT.notifyCharUUID
    public static let writeCharUUID  = MillenniumGATT.writeCharUUID

    // MARK: - Host→board frame lengths (chars, after parity strip)

    private enum HostFrameLen {
        static let threeChar: Int = 3   // V, S, X, T commands (1 cmd + 2 chk)
        static let ledFrame: Int  = 167  // L cmd: 1 + 2 slottime + 81×2 patterns + 2 chk
        static let writeReg: Int  = 7   // W cmd: 1 + 4 addr/data + 2 chk
        static let readReg:  Int  = 5   // R cmd: 1 + 2 addr + 2 chk
    }

    // MARK: - State

    /// Identity mirror (file-major, a1=0…h8=63).
    private var identity: [Piece?]

    /// Raw byte accumulator (parity already stripped on append).
    private var rawBuffer: [UInt8] = []

    public let advertisedName: String

    public init(advertisedName: String = MillenniumGATT.advertisedName) {
        self.advertisedName = advertisedName
        let position = Position.initial()
        var fm = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 { fm[file * 8 + rank] = position.board[rank * 8 + file] }
        }
        self.identity = fm
    }

    // MARK: - BoardPersonality

    public var gattLayout: GATTLayout {
        GATTLayout(
            services: [
                GATTServiceSpec(uuid: Self.serviceUUID, characteristics: [
                    GATTCharacteristicSpec(uuid: Self.writeCharUUID,  roles: [.write, .writeWithoutResponse]),
                    GATTCharacteristicSpec(uuid: Self.notifyCharUUID, roles: [.notify]),
                ]),
            ],
            advertisedServiceUUIDs: [Self.serviceUUID]
        )
    }

    public mutating func frames(for event: BoardEvent) -> [PersonalityFrame] {
        switch event {
        case .squareSensed(let square, let isLift, let piece):
            applySquareSensed(square: square, isLift: isLift, piece: piece)
            return [sFrame()]
        case .identitySnapshot(let snapshot):
            if snapshot.count == 64 { identity = snapshot }
            return [sFrame()]
        case .occupancySnapshot:
            // Cannot invent pieces for an identity board.
            return []
        case .ready, .battery, .connected, .disconnected, .raw, .promotionPick:
            return []
        }
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        // Strip parity (& 0x7F) on every incoming byte, as the host adapter does.
        for byte in data { rawBuffer.append(byte & 0x7F) }
        var actions: [PeripheralAction] = []
        while !rawBuffer.isEmpty {
            guard let typeChar = rawBuffer.first else { break }
            let needed = hostFrameLength(typeChar: typeChar)
            guard rawBuffer.count >= needed else { break }
            let frame = Array(rawBuffer.prefix(needed))
            rawBuffer.removeFirst(needed)
            actions += dispatchHostFrame(frame)
        }
        return actions
    }

    // MARK: - Host frame dispatch

    private mutating func dispatchHostFrame(_ frame: [UInt8]) -> [PeripheralAction] {
        guard let t = frame.first else { return [] }
        switch t {
        case UInt8(ascii: "S"):  // state request → push current board state
            return [.notify(sFrame())]
        case UInt8(ascii: "V"):  // version request → log only
            return [.log("millennium: version request")]
        case UInt8(ascii: "X"):  // extinguish LEDs
            return [.setLEDs([])]
        case UInt8(ascii: "T"):  // reset / start new game
            return [.startNewGame]
        case UInt8(ascii: "L"):  // LED pattern frame
            return decodeLEDFrame(frame)
        case UInt8(ascii: "W"), UInt8(ascii: "R"):
            return [.log("millennium: E2ROM op '\(String(UnicodeScalar(t)))'")]
        default:
            return [.log("millennium: unhandled host cmd '\(String(UnicodeScalar(t)))'")]
        }
    }

    // MARK: - LED decode

    /// Decode a 167-char L-frame into `.setLEDs`.
    ///
    /// L-frame (after parity strip): `L <HH> <81 × HH patterns> <HH chk>`
    /// where each `HH` is 2 uppercase hex ASCII chars. A non-zero pattern at
    /// index i (0-based) means corner LED `i+1` is lit.
    ///
    /// ## Corner-sharing / spillover
    ///
    /// The 9×9 corner grid means adjacent squares share corner LEDs.
    /// When two non-adjacent squares are lit (e.g. e2 + e4), the intermediate
    /// square (e3) also has all 4 corners lit — a pure artefact of shared corners.
    ///
    /// Fix: a square is in the INTENDED set iff at least one of its corners is
    /// covered by exactly one lit-square (i.e. unique to that square in the set
    /// of all lit squares). Spillover squares have every corner shared with at
    /// least one other lit square and therefore have no unique corner.
    private func decodeLEDFrame(_ frame: [UInt8]) -> [PeripheralAction] {
        guard frame.count == HostFrameLen.ledFrame, frame[0] == UInt8(ascii: "L") else {
            return [.log("millennium: malformed L-frame")]
        }
        // Parse 81 patterns (2 hex chars each, starting at offset 3).
        var patterns = [UInt8](repeating: 0, count: 81)
        for i in 0..<81 {
            let hi = frame[3 + i * 2]
            let lo = frame[3 + i * 2 + 1]
            guard let value = UInt8(String([Character(UnicodeScalar(hi)),
                                           Character(UnicodeScalar(lo))]), radix: 16) else { continue }
            patterns[i] = value
        }
        let files = Array("abcdefgh")

        // Step 1: collect all squares whose 4 corners are all non-zero.
        var litEntries: [(sq: String, corners: [Int])] = []
        for f in 0..<8 {
            for r in 1...8 {
                let corners = millenniumSquareToCornerLEDs(file: f, rank: r)
                if corners.allSatisfy({ $0 >= 1 && $0 <= 81 && patterns[$0 - 1] != 0 }) {
                    litEntries.append((sq: "\(files[f])\(r)", corners: corners))
                }
            }
        }

        // Step 2: build a corner → occupancy-count map across all lit squares.
        var cornerCount: [Int: Int] = [:]
        for entry in litEntries {
            for c in entry.corners { cornerCount[c, default: 0] += 1 }
        }

        // Step 3: keep only squares with at least one corner that belongs to
        // no other lit square (count == 1 → that corner is unique / intended).
        // Spillover squares have every corner count ≥ 2.
        let intended = litEntries.filter { entry in
            entry.corners.contains { cornerCount[$0] == 1 }
        }
        return [.setLEDs(intended.map(\.sq))]
    }

    // MARK: - Frame builder

    private func sFrame() -> PersonalityFrame {
        PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                         data: MillenniumAdapter.encodeFrame(identity: identity))
    }

    // MARK: - Mirror

    private mutating func applySquareSensed(square: String, isLift: Bool, piece: Piece?) {
        guard let sq = Square(algebraic: square) else { return }
        let fm = sq.file * 8 + sq.rank
        identity[fm] = isLift ? nil : piece
    }

    // MARK: - Frame length table (host→board)

    private func hostFrameLength(typeChar: UInt8) -> Int {
        switch typeChar {
        case UInt8(ascii: "V"), UInt8(ascii: "S"), UInt8(ascii: "X"), UInt8(ascii: "T"):
            return HostFrameLen.threeChar
        case UInt8(ascii: "L"):
            return HostFrameLen.ledFrame
        case UInt8(ascii: "W"):
            return HostFrameLen.writeReg
        case UInt8(ascii: "R"):
            return HostFrameLen.readReg
        default:
            return 1   // resync: skip unknown byte
        }
    }

    /// Test hook: expose identity mirror.
    public var identityMirror: [Piece?] { identity }
}
