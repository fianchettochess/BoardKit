// ChessnutGoCaptureGoldenTests.swift
// The owner's Chessnut Go capture is the only real-hardware Chessnut wire data
// any repo holds. It must decode exactly as it did in 0.17.1, before the
// framers learned to resync (Fianchetto-b32.158).

import Foundation
import Testing
import ChessCore
import BoardKit
import ChessnutAdapter

/// Owner's Chessnut Go capture, 2026-10-29 (copied from FianchettoKit
/// `EBoardCaptureSwapReplayTests.capture`): Black's Kxa1 after ...a1=Q Rxa1,
/// then White's f6. Each notification as received, with how many times in a
/// row the board sent it. 321 notifications in all.
private let goCapture: [(hex: String, count: Int)] = [
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 02 00 00 00 60 bd 09 00 00", 258),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 60 d7 09 00 00", 4),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 d8 09 00 00", 2),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 60 00 00 00 20 d8 09 00 00", 5),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 d9 09 00 00", 5),
    ("23 01 00", 1),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 d9 09 00 00", 11),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 da 09 00 00", 2),
    ("01 24 00 00 00 00 00 00 00 04 00 07 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 db 09 00 00", 2),
    ("01 24 00 00 00 00 00 00 00 04 00 07 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 db 09 00 00", 13),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 dc 09 00 00", 2),
    ("01 24 00 00 00 00 00 00 00 04 00 07 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 dc 09 00 00", 2),
    ("01 24 00 00 00 00 00 00 00 04 00 07 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 dd 09 00 00", 10),
    ("01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 de 09 00 00", 2),
    ("01 24 00 00 00 00 00 00 00 04 00 07 00 80 c0 00 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 de 09 00 00", 2),
]

private func goNotifications() -> [Data] {
    goCapture.flatMap { entry in
        let bytes = entry.hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        return Array(repeating: Data(bytes), count: entry.count)
    }
}

/// How the notifications reach the adapter. Every face feeds every subscribed
/// characteristic into one `feed(bytes:)` buffer, so both modes use it.
private enum GoCaptureDelivery: String, CaseIterable, Sendable {
    /// One `feed(bytes:)` per notification, as captured.
    case wholeNotification
    /// Each notification cut into 20-byte pieces (the default BLE MTU).
    case twentyByteChunks

    func chunks(_ notifications: [Data]) -> [Data] {
        switch self {
        case .wholeNotification: return notifications
        case .twentyByteChunks:
            return notifications.flatMap { data in
                stride(from: 0, to: data.count, by: 20).map {
                    data.subdata(in: $0..<min($0 + 20, data.count))
                }
            }
        }
    }
}

private enum GoCaptureProfile: String, CaseIterable, Sendable {
    case classic, move

    func decode(_ chunks: [Data]) -> [BoardEvent] {
        switch self {
        case .classic:
            var adapter = ChessnutAdapter()
            return chunks.flatMap { adapter.feed(bytes: $0) }
        case .move:
            var adapter = ChessnutMoveAdapter()
            return chunks.flatMap { adapter.feed(bytes: $0) }
        }
    }
}

private func fenLetter(_ piece: Piece) -> Character {
    let letter: Character
    switch piece.type {
    case .pawn: letter = "p"
    case .knight: letter = "n"
    case .bishop: letter = "b"
    case .rook: letter = "r"
    case .queen: letter = "q"
    case .king: letter = "k"
    }
    return piece.color == .white ? Character(letter.uppercased()) : letter
}

/// FEN piece placement of a file-major (a1 = 0 … h8 = 63) identity.
private func placement(_ identity: [Piece?]) -> String {
    (0..<8).reversed().map { rank in
        var row = ""
        var empty = 0
        for file in 0..<8 {
            if let piece = identity[file * 8 + rank] {
                if empty > 0 { row += "\(empty)"; empty = 0 }
                row.append(fenLetter(piece))
            } else {
                empty += 1
            }
        }
        if empty > 0 { row += "\(empty)" }
        return row
    }.joined(separator: "/")
}

private func line(_ event: BoardEvent) -> String {
    switch event {
    case .identitySnapshot(let identity): return "snapshot \(placement(identity))"
    case .squareSensed(let square, let isLift, let piece):
        return "\(isLift ? "lift" : "place") \(square) \(piece.map { String(fenLetter($0)) } ?? "-")"
    case .raw(let data): return "raw " + data.map { String(format: "%02x", $0) }.joined(separator: " ")
    case .ready: return "ready"
    default: return "other \(event)"
    }
}

/// The event log, one line per run of identical events (`x N` when N > 1).
private func goCaptureLog(_ events: [BoardEvent]) -> String {
    var runs: [(String, Int)] = []
    for event in events.map(line) {
        if let last = runs.last, last.0 == event {
            runs[runs.count - 1].1 += 1
        } else {
            runs.append((event, 1))
        }
    }
    return runs.map { $0.1 > 1 ? "\($0.0) x\($0.1)" : $0.0 }.joined(separator: "\n")
}

private struct GoCaptureCase: Sendable, CustomTestStringConvertible {
    let profile: GoCaptureProfile
    let delivery: GoCaptureDelivery
    var testDescription: String { "\(profile.rawValue), \(delivery.rawValue)" }
}

private let goCaptureCases = GoCaptureProfile.allCases.flatMap { profile in
    GoCaptureDelivery.allCases.map { GoCaptureCase(profile: profile, delivery: $0) }
}

/// The event log both Chessnut adapters produced from `goCapture` at 0.17.1,
/// in both delivery modes (recorded from the 0.17.1 tag, not from this code).
private let goCaptureLogAt0_17_1 = """
snapshot 8/1p6/r7/5PK1/8/8/1k4P1/R7
ready
snapshot 8/1p6/r7/5PK1/8/8/1k4P1/R7 x257
snapshot 8/1p6/r7/5PK1/8/8/6P1/R7
lift b2 k
snapshot 8/1p6/r7/5PK1/8/8/6P1/R7 x3
snapshot 8/1p6/r7/5PK1/8/8/6P1/k7
lift a1 R
place a1 k
snapshot 8/1p6/r7/5PK1/8/8/6P1/k7
snapshot 8/1p6/r7/5PK1/8/8/R5P1/k7
place a2 R
snapshot 8/1p6/r7/5PK1/8/8/R5P1/k7 x4
snapshot 8/1p6/r7/5PK1/8/8/6P1/k7
lift a2 R
snapshot 8/1p6/r7/5PK1/8/8/6P1/k7 x4
raw 23 01 00
snapshot 8/1p6/r7/5PK1/8/8/6P1/k7 x11
snapshot 8/1p6/r7/6K1/8/8/6P1/k7
lift f5 P
snapshot 8/1p6/r7/6K1/8/8/6P1/k7
snapshot 8/1p6/r4P2/6K1/8/8/6P1/k7
place f6 P
snapshot 8/1p6/r4P2/6K1/8/8/6P1/k7 x14
snapshot 8/1p6/r7/6K1/8/8/6P1/k7
lift f6 P
snapshot 8/1p6/r7/6K1/8/8/6P1/k7
snapshot 8/1p6/r4P2/6K1/8/8/6P1/k7
place f6 P
snapshot 8/1p6/r4P2/6K1/8/8/6P1/k7 x11
snapshot 8/1p6/r7/6K1/8/8/6P1/k7
lift f6 P
snapshot 8/1p6/r7/6K1/8/8/6P1/k7
snapshot 8/1p6/r4P2/6K1/8/8/6P1/k7
place f6 P
snapshot 8/1p6/r4P2/6K1/8/8/6P1/k7
"""

/// Gates: the only real Chessnut bytes on record decode exactly as they did
/// before the framer gained its per-opcode accept table.
/// Breaks if: an accept bound is tightened past what a real board sends (the
/// Go's `01 24` board frame or its `23 01 00` heartbeat), or framing changes
/// how a frame split across notifications is joined.
/// User loses: a Chessnut Go (or Air, which shares the framer) stops reporting
/// moves, or reports them late, after an update.
@Test(arguments: goCaptureCases)
private func goCaptureDecodesAsIn0_17_1(_ c: GoCaptureCase) {
    let events = c.profile.decode(c.delivery.chunks(goNotifications()))
    #expect(goCaptureLog(events) == goCaptureLogAt0_17_1)
}
