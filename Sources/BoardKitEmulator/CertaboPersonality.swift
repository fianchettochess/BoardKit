import Foundation
import ChessCore
import BoardKit
import CertaboAdapter

/// Peripheral-side impersonation of a Certabo RFID chess board.
///
/// Two operating modes, matching the adapter's dual-path capability:
///
/// - **Calibrated (RFID)**: emits 320-token ASCII frames (64 squares × 5 decimal bytes)
///   using a `CertaboCalibration` to map pieces to RFID tag IDs. The host adapter
///   decodes these with the same calibration and emits identity events.
///
/// - **Uncalibrated (Tabutronic-style)**: emits 8-token frames (one rank-bitmask per
///   rank, MSB = a-file). The host adapter decodes as occupancy events.
///
/// ## Transport identity
/// Certabo has no BLE GATT profile anywhere in open source (verified 2026-07):
/// the official app ([OFFICIAL], [BT]) is serial-only — `41c9ee4d-…-24710a` is a
/// classic-BT SPP SDP record (PyBluez `SERIAL_PORT_CLASS`), not a GATT service —
/// and Chesstimation, the only open firmware speaking Certabo wirelessly, does so
/// over classic BT serial only (its BLE modes are ChessLink/ISSC-UART and
/// Pegasus/NUS). Real-world Certabo BLE is either the closed Tabutronic ESP32-S3
/// module (ChessConnect-only, UUIDs unpublished; ChessConnect is also closed) or
/// [CER2NUT], which impersonates a Chessnut Air — those boards land on
/// `ChessnutAdapter` with no Certabo code involved. So this personality uses the
/// real SPP UUID as the advertised service with derived char UUIDs (…00/…01 in
/// place of the …0a base) and NUS-style roles; discovery is by name prefix
/// "Certabo". If the Tabutronic module is ever sniffed, expect NUS or ISSC
/// transparent UART (49535343-FE7D-…) — the two de-facto chess-board BLE bridges.
///
/// ## Host→board commands handled
/// - 8-byte classic LED frame  → `.setLEDs` (decode LSB-a-file rank bytes)
/// - 247-byte RGB LED frame    → `.setLEDs` (decode blue-channel corner LEDs)
/// - Other lengths             → `.log`
public struct CertaboPersonality: BoardPersonality {

    // MARK: - GATT constants (NUS-style over the SPP UUID as service)

    public static let serviceUUID    = CertaboBT.serviceUUID
    /// Write characteristic: host sends LED commands.
    public static let writeCharUUID  = "41c9ee4d-871e-4556-b521-84c89c247100"
    /// Notify characteristic: board streams RFID/occupancy frames.
    public static let notifyCharUUID = "41c9ee4d-871e-4556-b521-84c89c247101"

    // MARK: - State

    /// Identity mirror (file-major, a1=0…h8=63).
    private var identity: [Piece?]

    /// Occupancy mirror (file-major), used in uncalibrated mode.
    private var occupancy: [Bool]

    /// Calibration (nil = uncalibrated / Tabutronic mode).
    public let calibration: CertaboCalibration?

    public let advertisedName: String

    public init(advertisedName: String = "Certabo",
                calibration: CertaboCalibration? = nil) {
        self.advertisedName = advertisedName
        self.calibration = calibration
        let position = Position.initial()
        var fm = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 { fm[file * 8 + rank] = position.board[rank * 8 + file] }
        }
        self.identity = fm
        self.occupancy = fm.map { $0 != nil }
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
            // Certabo streams continuously; the host adapter debounces via a
            // 3-frame majority-vote history. To guarantee the vote converges:
            //   • 1st identical frame: [prev, prev, curr] → 2:1 majority=prev, no delta
            //   • 2nd identical frame: [prev, curr, curr] → 1:2 majority=curr, delta fires
            // Two frames always suffice regardless of prior history saturation.
            let frame = positionFrame()
            return [frame, frame]

        case .identitySnapshot(let snapshot):
            if snapshot.count == 64 {
                identity = snapshot
                occupancy = snapshot.map { $0 != nil }
            }
            let frame = positionFrame()
            return [frame, frame]

        case .occupancySnapshot(let snapshot):
            if snapshot.count == 64 {
                occupancy = snapshot
                // Cannot invent piece identity from occupancy.
                identity = [Piece?](repeating: nil, count: 64)
            }
            let frame = positionFrame()
            return [frame, frame]

        case .ready, .battery, .connected, .disconnected, .raw, .promotionPick, .storedGameImported:
            return []
        }
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        let bytes = [UInt8](data)
        switch bytes.count {
        case 8:
            return [.setLEDs(decodeClassicLED(bytes))]
        case 247:
            guard bytes[0] == 0xFF, bytes[1] == 0x55 else {
                return [.log("certabo: unexpected 247-byte frame header")]
            }
            return [.setLEDs(decodeRGBLED(bytes))]
        default:
            return [.log("certabo: unrecognised host write (\(bytes.count) bytes)")]
        }
    }

    // MARK: - Position frame builders

    private func positionFrame() -> PersonalityFrame {
        if let cal = calibration {
            return rfidFrame(calibration: cal)
        } else {
            return tabatronicFrame()
        }
    }

    /// Build a 320-token RFID frame (64 squares × 5 decimal bytes) + CRLF.
    private func rfidFrame(calibration: CertaboCalibration) -> PersonalityFrame {
        var tokens: [String] = []
        tokens.reserveCapacity(320)
        for streamIdx in 0..<64 {
            let fm = CertaboAdapter.streamIndexToFileMajor(streamIdx)
            let piece = identity[fm]
            let tag: CertaboTagID
            if let piece, let t = calibration.tagID(for: piece) {
                tag = t
            } else {
                tag = .zero
            }
            tokens += ["\(tag.b0)", "\(tag.b1)", "\(tag.b2)", "\(tag.b3)", "\(tag.b4)"]
        }
        let line = tokens.joined(separator: " ") + "\r\n"
        return PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                data: Data(line.utf8))
    }

    /// Build an 8-token Tabutronic occupancy frame (rank-8 first) + CRLF.
    ///
    /// Format: 8 decimal numbers, k=0 covers rank-8 (rank0idx=7), k=7 covers rank-1
    /// (rank0idx=0). Bit `(7 − file)` of bitmask k = occupied at (file, rank8−k).
    private func tabatronicFrame() -> PersonalityFrame {
        var masks = [UInt8](repeating: 0, count: 8)
        for k in 0..<8 {
            let rank0 = 7 - k
            for file in 0..<8 where occupancy[file * 8 + rank0] {
                masks[k] |= UInt8(1 << (7 - file))
            }
        }
        let line = masks.map { "\($0)" }.joined(separator: " ") + "\r\n"
        return PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                data: Data(line.utf8))
    }

    // MARK: - LED decode

    /// Decode a classic 8-byte LED frame: `byte[7−rank] |= 1 << file` (LSB=a-file).
    private func decodeClassicLED(_ bytes: [UInt8]) -> [String] {
        let files = Array("abcdefgh")
        var squares: [String] = []
        for i in 0..<8 {
            let rank0 = 7 - i   // byte i → rank0-indexed = 7-i
            for file in 0..<8 where bytes[i] & (1 << file) != 0 {
                squares.append("\(files[file])\(rank0 + 1)")
            }
        }
        return squares
    }

    /// Decode a 247-byte RGB LED frame: 0xFF 0x55 + 243-byte payload + 0x0D 0x0A.
    ///
    /// ## Corner-sharing / spillover
    ///
    /// The 9×9 corner grid means adjacent squares share corner LEDs. When two
    /// non-adjacent squares are lit (e.g. e2 + e4), the intermediate square (e3)
    /// also has all 4 corners nonzero — a pure artefact of shared corners.
    ///
    /// Fix (mirrors MillenniumPersonality.decodeLEDFrame): a square belongs to the
    /// INTENDED set iff at least one of its 4 blue-channel corner indices appears in
    /// no other candidate square (cornerCount == 1 → unique corner). Spillover
    /// squares have every corner shared with at least one other candidate.
    private func decodeRGBLED(_ bytes: [UInt8]) -> [String] {
        let payload = Array(bytes[2..<245])   // 243 bytes = 81 LEDs × 3
        let files = Array("abcdefgh")

        // Step 1: collect candidate squares (all 4 blue-channel corners nonzero).
        var litEntries: [(sq: String, corners: [Int])] = []
        for file in 0..<8 {
            for rank in 0..<8 {
                let streamIdx = (7 - rank) * 8 + file
                let row = 7 - streamIdx / 8
                let col = 7 - streamIdx % 8
                let base = (row * 9 + col) * 3
                let corners = [base + 2, base + 5, base + 29, base + 32]
                if corners.allSatisfy({ $0 < payload.count && payload[$0] != 0 }) {
                    litEntries.append((sq: "\(files[file])\(rank + 1)", corners: corners))
                }
            }
        }

        // Step 2: corner-index → count across all candidate squares.
        var cornerCount: [Int: Int] = [:]
        for entry in litEntries {
            for c in entry.corners { cornerCount[c, default: 0] += 1 }
        }

        // Step 3: keep only squares with ≥1 corner unique to that square.
        // Spillover squares (all corners shared, count ≥ 2) are excluded.
        return litEntries.filter { entry in
            entry.corners.contains { cornerCount[$0] == 1 }
        }.map(\.sq)
    }

    // MARK: - Test mirrors

    /// Expose identity mirror (file-major, a1=0…h8=63). `nil` when uncalibrated.
    public var identityMirror: [Piece?] { identity }

    /// Expose occupancy mirror (file-major, a1=0…h8=63).
    public var occupancyMirror: [Bool] { occupancy }

    // MARK: - Mirror

    private mutating func applySquareSensed(square: String, isLift: Bool, piece: Piece?) {
        guard let sq = Square(algebraic: square) else { return }
        let fm = sq.file * 8 + sq.rank
        identity[fm]  = isLift ? nil : piece
        occupancy[fm] = !isLift
    }
}
