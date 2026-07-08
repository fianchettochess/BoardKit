import Foundation
import ChessCore
import BoardKit
import ChessUpAdapter

/// Peripheral-side impersonation of a ChessUp (gen-1) board.
///
/// ## Session-mode gating (hardware-verified 2026-07-07)
///
/// The real ChessUp 2 only streams `0xA3` move frames after the host writes a
/// `0xB9` game-settings frame with **mode byte = 5** (phoneOTB).  In standalone
/// modes (6 builtInAI / 7 noPhoneOTB) NO `0xA3` is emitted; the personality
/// enforces the same gate.  `sessionMode` is captured from `0xB9` byte[1].
///
/// ## Move assembly
///
/// `frames(for:)` receives individual `squareSensed` events (lift / place), not
/// complete moves.  The personality assembles them into moves:
/// - **First lift** in a move sequence → records the "from" square
///   (`pendingMoveFrom`).
/// - **Subsequent lifts** (captured-piece removal in captures; rook in castling)
///   → the first from-square is kept; subsequent lifts are ignored.
/// - **Place event** with a stored from-square → emits a 6-byte `0xA3` move
///   frame and clears `pendingMoveFrom`.
///
/// ## Retransmit model — deterministic simplification
///
/// Real hardware retransmits `0xA3` on a timer until the host writes `0x21`.
/// This personality has no timer, so it models retransmission **deterministically**:
/// `pendingUnackedMove` holds the last emitted `0xA3` frame and is prepended to
/// every subsequent `frames(for:)` output call that would otherwise produce at
/// least one frame, until the host writes `0x21` via `handleHostWrite`.  This
/// produces exactly one retransmit per board notification instead of a
/// time-paced flood, but is sufficient to exercise the host adapter's dedup +
/// ack protocol correctly in tests.
///
/// ## Ack handling (host → personality)
///
/// `handleHostWrite` now recognises three new opcodes the host writes back to
/// the board:
/// - `0x21` → move ack: clears `pendingUnackedMove`.
/// - `0x23` → promotion ack: clears `pendingUnackedPromotion`.
/// - `0xB9 …` → game settings: records `sessionMode` from byte[1] + logs.
///
/// ## Board-state snapshots (always emitted)
///
/// Every `squareSensed`, `occupancySnapshot`, and `identitySnapshot` event also
/// emits a `0x67` board-state frame regardless of session mode.  This keeps
/// host adapters that track occupancy via `0x67` working in all modes
/// (including nil / standalone modes where `0xA3` is suppressed), and preserves
/// all existing occupancy-loop-back tests green without any changes.
///
/// ## Host→board commands handled
/// - `0x67`        → GET_STATE → `.notify(boardStateFrame())`
/// - `0x99 f t`    → show move → `.setLEDs([from, to])`
/// - `0x50`        → enable raw stream → `.log`
/// - `0x21`        → move ack → clear pending retransmit + `.log`
/// - `0x23`        → promotion ack → clear pending promotion retransmit + `.log`
/// - `0xB9 …`      → game settings (12 B) → record mode + `.log`
/// - `0x66`        → load FEN → `.log`
/// - `0x64`        → reset game → `.startNewGame`
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

    /// Active game mode from the last received `0xB9` game-settings frame.
    ///
    /// `nil` before any `0xB9` is received.
    /// `5` = phoneOTB → `0xA3` move-frame gate is OPEN.
    /// `6` = builtInAI, `7` = noPhoneOTB → `0xA3` gate CLOSED (no move frames).
    private var sessionMode: UInt8? = nil

    /// From-square of the move currently being assembled for `0xA3` emission.
    ///
    /// Set on the first lift in a move sequence; cleared when the corresponding
    /// place event arrives and the `0xA3` frame is emitted.
    private var pendingMoveFrom: String? = nil

    /// Bytes of the last emitted `0xA3` move frame, held until the host sends `0x21`.
    ///
    /// Prepended to every subsequent `frames(for:)` output so the host receives
    /// at least one retransmit per board notification (deterministic
    /// simplification — see class-level doc for the real timed-flood contrast).
    private var pendingUnackedMove: [UInt8]? = nil

    /// Bytes of the last emitted `0x97` promotion frame, held until the host sends `0x23`.
    private var pendingUnackedPromotion: [UInt8]? = nil

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
            return squareSensedFrames(square: square, isLift: isLift)

        case .occupancySnapshot(let snapshot):
            if snapshot.count == 64 { occupancy = snapshot }
            return pendingRetransmitFrames() + [boardStateFrame()]

        case .identitySnapshot(let identity):
            if identity.count == 64 { occupancy = identity.map { $0 != nil } }
            return pendingRetransmitFrames() + [boardStateFrame()]

        case .ready, .battery, .connected, .disconnected, .raw:
            return []
        }
    }

    /// Handle a single `squareSensed` event: assemble `0xA3` in phoneOTB mode,
    /// prepend any pending retransmit, and always append the `0x67` board-state frame.
    private mutating func squareSensedFrames(square: String, isLift: Bool) -> [PersonalityFrame] {
        // ── Phase 1: 0xA3 move assembly (mode 5 only) ────────────────────────
        var newA3: PersonalityFrame? = nil
        if sessionMode == 5 {
            if isLift {
                // First lift in the move → record as the "from" square.
                // Subsequent lifts (captured piece, castling rook) are ignored so
                // the original from-square is preserved.
                if pendingMoveFrom == nil { pendingMoveFrom = square }
            } else {
                // Place event → the move is complete; emit the 0xA3 frame.
                if let fromSquare = pendingMoveFrom {
                    if let a3Bytes = Self.encodeA3Frame(from: fromSquare, to: square) {
                        pendingUnackedMove = a3Bytes
                        newA3 = PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                                 data: Data(a3Bytes))
                    }
                    pendingMoveFrom = nil
                }
            }
        }

        // ── Phase 2: build output ─────────────────────────────────────────────
        var output: [PersonalityFrame] = []

        // Prepend retransmit(s) of pending unacked frames UNLESS this call just
        // emitted a fresh 0xA3 (newA3 != nil).  On the first emission the fresh
        // A3 is already in `output`; retransmit fires on the NEXT call and every
        // subsequent call until `0x21` arrives.
        if newA3 == nil {
            output.append(contentsOf: pendingRetransmitFrames())
        }

        // Fresh 0xA3 frame (if assembled above).
        if let a3 = newA3 { output.append(a3) }

        // 0x67 board-state snapshot — always emitted so occupancy-only adapters
        // remain in sync regardless of session mode.
        output.append(boardStateFrame())
        return output
    }

    /// Returns notification frames for all pending unacked board messages
    /// (move and promotion retransmits), to be prepended before new output.
    private func pendingRetransmitFrames() -> [PersonalityFrame] {
        var frames: [PersonalityFrame] = []
        if let pending = pendingUnackedMove {
            frames.append(PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                           data: Data(pending)))
        }
        if let pending = pendingUnackedPromotion {
            frames.append(PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                           data: Data(pending)))
        }
        return frames
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

            case 0x21:   // move ack — board retransmits 0xA3 until this arrives
                cmdBuffer.removeFirst()
                pendingUnackedMove = nil
                actions.append(.log("chessup: move acked (0x21)"))

            case 0x23:   // promotion ack — board retransmits 0x97 until this arrives
                cmdBuffer.removeFirst()
                pendingUnackedPromotion = nil
                actions.append(.log("chessup: promotion acked (0x23)"))

            case 0x50:   // enable raw stream
                cmdBuffer.removeFirst()
                actions.append(.log("chessup: raw stream enabled"))

            case 0xB9:   // game settings (12 bytes total: [0xB9, mode, …])
                guard cmdBuffer.count >= 12 else { return actions }
                let mode = cmdBuffer[1]
                sessionMode = mode
                cmdBuffer.removeFirst(12)
                actions.append(.log("chessup: game settings received (mode \(mode))"))

            case 0x66:   // load FEN — variable length; consume opcode byte and log
                // Full FEN frame is complex to parse; log and skip the opcode.
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

    /// Build a 73-byte `0x67` board-state frame.
    ///
    /// Layout: `[0x67][64 piece codes in canonical order][8 FEN bytes]`.
    /// Canonical index = rank0indexed*8+file (a1=0, h1=7, a8=56, h8=63).
    /// Piece code: `0x40` = empty, `0x01` = occupied (white-rook placeholder).
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
        // frame[65..72] = 0 (FEN tail: white to move, no castling/ep, 0 clocks)
        _ = wasFirst  // .ready fires on first 0x67 frame in the HOST adapter
        return PersonalityFrame(characteristicUUID: Self.notifyCharUUID,
                                data: Data(frame))
    }

    /// Encode a 6-byte `0xA3` move frame.
    ///
    /// Format: `[A3, 0x35, fromCol, fromRow, toCol, toRow]`
    /// - `0x35`: hardware-observed sub byte (semantics unknown — constant on CU2).
    /// - col = file index (a=0…h=7).
    /// - row = rank 0-indexed (rank1=0, rank8=7).
    ///
    /// Verified against hardware-observed 1.d4 = `A3 35 03 01 03 03`:
    /// d2 → col=3, row=1; d4 → col=3, row=3. ✓
    ///
    /// - Returns: `nil` if either algebraic string is invalid.
    private static func encodeA3Frame(from: String, to: String) -> [UInt8]? {
        guard let fromSq = Square(algebraic: from),
              let toSq   = Square(algebraic: to) else { return nil }
        return [
            0xA3, 0x35,
            UInt8(fromSq.file), UInt8(fromSq.rank),   // fromCol, fromRow
            UInt8(toSq.file),   UInt8(toSq.rank),     // toCol,   toRow
        ]
    }

    // MARK: - Test mirrors

    /// Expose occupancy mirror (file-major, a1=0…h8=63).
    public var occupancyMirror: [Bool] { occupancy }

    /// Expose the active session mode for test assertions.
    ///
    /// `nil` before any `0xB9` is received; `5` = phoneOTB (0xA3 gate open).
    public var sessionModeForTesting: UInt8? { sessionMode }

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
