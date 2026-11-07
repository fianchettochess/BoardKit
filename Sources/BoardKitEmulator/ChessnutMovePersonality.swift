import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter

/// Peripheral-side impersonation of a Chessnut Move robotic board.
///
/// The Move shares every GATT UUID and the identity mirror of the Air family,
/// so this wraps `ChessnutPersonality` for the mirror and changes only what
/// the Move does differently on the wire, per the `ChessnutMoveAdapter` docs:
///
/// - **Board state** frames are the Move's 38-byte `[0x01, 0x24, …]` layout
///   from `ChessnutMoveAdapter.encodeFrame(identity:)`.
/// - **Battery** `41 01 0C` → `41 03 0C <charging> <level>` on the
///   command-response characteristic.
/// - **Piece status** `41 01 0B` → the 139-byte `41 89 0B` reply, one record
///   per piece on the board, sent in 20-byte notifications as a default-MTU
///   link would deliver it.
/// - **LEDs** `43 20 <32 nibble bytes>` → the lit squares.
/// - **Auto-move** `42 21 <target board> <force>` → the robot moves pieces
///   until the board matches the target, then streams the new state. The
///   emulator moves them at once. No FEN frames are documented during motion,
///   so none are sent between the command and the result.
/// - **Realtime** `21 01 00` → an immediate board frame, as on the Air.
///
/// Stored-game import is not wired for the Move (the adapter returns nil for
/// `.requestStoredGames`), so archive opcodes are only logged.
public struct ChessnutMovePersonality: BoardPersonality {

    /// Identity mirror and airborne ledger, shared with the Air personality.
    private var mirror: ChessnutPersonality

    /// Framing accumulator for fragmented host writes.
    private var buffer: [UInt8] = []

    public let advertisedName: String
    public var batteryPercent: Int
    public var isCharging: Bool

    public init(advertisedName: String = "Chessnut Move",
                batteryPercent: Int = 88,
                isCharging: Bool = false) {
        self.advertisedName = advertisedName
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.mirror = ChessnutPersonality(advertisedName: advertisedName)
    }

    public var gattLayout: GATTLayout { mirror.gattLayout }

    /// Current identity mirror (file-major), for tests.
    public var identityMirror: [Piece?] { mirror.identityMirror }

    public mutating func frames(for event: BoardEvent) -> [PersonalityFrame] {
        switch event {
        case .battery(let percent):
            return [batteryFrame(percent: percent)]
        default:
            let frames = mirror.frames(for: event)
            return moveFrames(frames)
        }
    }

    public mutating func coalescedFrames(for events: [BoardEvent]) -> [PersonalityFrame] {
        let frames = mirror.coalescedFrames(for: events)
        return moveFrames(frames)
    }

    public mutating func handleHostWrite(_ data: Data) -> [PeripheralAction] {
        buffer.append(contentsOf: data)
        var actions: [PeripheralAction] = []
        while buffer.count >= 2 {
            let frameLength = Int(buffer[1]) + 2
            guard buffer.count >= frameLength else { break }
            let frame = Array(buffer.prefix(frameLength))
            buffer.removeFirst(frameLength)
            actions += handleHostFrame(frame)
        }
        return actions
    }

    // MARK: - Host frames

    private mutating func handleHostFrame(_ frame: [UInt8]) -> [PeripheralAction] {
        switch frame[0] {
        case 0x21:
            let actions = mirror.handleHostWrite(Data(frame))
            return actions.map(moveAction)
        case 0x41 where frame.count >= 3 && frame[2] == 0x0C:
            return [.notify(batteryFrame(percent: batteryPercent))]
        case 0x41 where frame.count >= 3 && frame[2] == 0x0B:
            return Self.chunks(pieceStatusReply(), size: 20).map {
                .notify(PersonalityFrame(characteristicUUID: ChessnutGATT.commandResponseChar, data: $0))
            }
        case 0x42 where frame.count >= 35:
            guard let target = chessnutDecodeTarget(Array(frame[2..<34])) else {
                return [.log("chessnut move: unreadable auto-move target")]
            }
            let frames = mirror.frames(for: .identitySnapshot(target))
            return [.log("chessnut move: auto-move (force flag \(frame[34]))")]
                + moveFrames(frames).map { .notify($0) }
        case 0x43 where frame.count >= 34:
            return [.setLEDs(Self.squaresFromLEDFrame(frame))]
        default:
            return [.log("chessnut move: unhandled host opcode 0x\(String(format: "%02X", frame[0]))")]
        }
    }

    // MARK: - Frame builders

    /// Re-encode the Air personality's board frames in the Move's layout, from
    /// the mirror as it stands now. Callers must update the mirror into a local
    /// first: `moveFrames(mirror.frames(…))` would read `self` before the
    /// argument updates it.
    private func moveFrames(_ frames: [PersonalityFrame]) -> [PersonalityFrame] {
        frames.map { frame in
            guard frame.characteristicUUID == ChessnutGATT.boardStateChar else { return frame }
            return PersonalityFrame(characteristicUUID: ChessnutGATT.boardStateChar,
                                    data: ChessnutMoveAdapter.encodeFrame(identity: mirror.identityMirror))
        }
    }

    private func moveAction(_ action: PeripheralAction) -> PeripheralAction {
        guard case .notify(let frame) = action else { return action }
        return .notify(moveFrames([frame])[0])
    }

    private func batteryFrame(percent: Int) -> PersonalityFrame {
        PersonalityFrame(characteristicUUID: ChessnutGATT.commandResponseChar,
                         data: Data([0x41, 0x03, 0x0C, isCharging ? 1 : 0, UInt8(max(0, min(100, percent)))]))
    }

    /// `41 89 0B` + 34 four-byte records `[identity, x, y, battery]`, in the
    /// documented record order (white P×8 R×2 N×2 B×2 Q×2 K, then black).
    /// A piece not on the board reports identity 0. x/y are the square's file
    /// and rank scaled to 0…255 (axis orientation is undocumented).
    private func pieceStatusReply() -> Data {
        let order: [PieceType] = [.pawn, .pawn, .pawn, .pawn, .pawn, .pawn, .pawn, .pawn,
                                  .rook, .rook, .knight, .knight, .bishop, .bishop,
                                  .queen, .queen, .king]
        let codes: [PieceType: UInt8] = [.pawn: 1, .rook: 2, .knight: 3, .bishop: 4, .queen: 5, .king: 6]
        var remaining = Array(mirror.identityMirror.enumerated())
        var reply: [UInt8] = [0x41, 0x89, 0x0B]
        for color in [PieceColor.white, .black] {
            for type in order {
                let wanted = Piece(type: type, color: color)
                if let slot = remaining.firstIndex(where: { $0.element == wanted }) {
                    let square = remaining.remove(at: slot).offset
                    let code = codes[type]! + (color == .black ? 6 : 0)
                    reply += [code, UInt8(square / 8 * 36), UInt8(square % 8 * 36), UInt8(max(0, min(100, batteryPercent)))]
                } else {
                    reply += [0, 0, 0, 0]
                }
            }
        }
        return Data(reply)
    }

    static func chunks(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map {
            data.subdata(in: $0..<min($0 + size, data.count))
        }
    }

    /// Lit squares of a `43 20` LED frame: any non-zero nibble. Square order and
    /// nibble packing are the board frames' (h8 first, low nibble first).
    static func squaresFromLEDFrame(_ frame: [UInt8]) -> [String] {
        var squares: [String] = []
        for s in 0..<64 {
            let byte = frame[2 + s / 2]
            let nibble = s % 2 == 0 ? byte & 0x0F : byte >> 4
            guard nibble != 0 else { continue }
            let row = s / 8, pc = s % 8
            squares.append(Square(file: 7 - pc, rank: 7 - row).algebraic)
        }
        return squares.sorted()
    }
}

/// Decode a 32-byte Move board payload (the auto-move target) into a
/// file-major identity, through the host adapter's own frame decoder.
private func chessnutDecodeTarget(_ board: [UInt8]) -> [Piece?]? {
    var adapter = ChessnutMoveAdapter()
    for event in adapter.feed(bytes: Data([0x01, 0x24] + board + [0, 0, 0, 0])) {
        if case .identitySnapshot(let identity) = event { return identity }
    }
    return nil
}
