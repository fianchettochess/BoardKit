// ChessnutFramingResyncTests.swift
// Both Chessnut framers trust a header only when the opcode and length fit,
// and resync one byte at a time otherwise. (Fianchetto-b32.158)

import Foundation
import Testing
import ChessCore
import BoardKit
import BoardKitTestSupport
@testable import ChessnutAdapter

private enum Profile: String, CaseIterable, Sendable {
    case classic, move

    func feed(_ chunks: [Data]) -> [BoardEvent] {
        switch self {
        case .classic:
            var adapter = ChessnutAdapter()
            return chunks.flatMap { adapter.feed(bytes: $0) }
        case .move:
            var adapter = ChessnutMoveAdapter()
            return chunks.flatMap { adapter.feed(bytes: $0) }
        }
    }

    func frame(_ identity: [Piece?]) -> Data {
        switch self {
        case .classic: return ChessnutAdapter.encodeFrame(identity: identity)
        case .move: return ChessnutMoveAdapter.encodeFrame(identity: identity)
        }
    }
}

/// File-major (a1 = 0 … h8 = 63) identity of the start position.
private func startIdentity() -> [Piece?] {
    let board = Position.initial().board
    return (0..<64).map { board[($0 % 8) * 8 + $0 / 8] }
}

/// The corruptions a noisy link produces in front of a good frame.
private enum Corruption: String, CaseIterable, Sendable {
    /// One byte that is no Chessnut opcode.
    case junkByte
    /// A real opcode whose length byte is impossible for it (battery `2A`
    /// claiming 0x55 payload bytes would swallow the board frame).
    case knownOpcodeBadLength
    /// A board-state opcode whose length would swallow the next frame.
    case boardStateBadLength
    /// A header claiming the longest length any byte can carry.
    case maximalLength

    var bytes: Data {
        switch self {
        case .junkByte: return Data([0x99])
        case .knownOpcodeBadLength: return Data([0x2A, 0x55])
        case .boardStateBadLength: return Data([0x01, 0xC8])
        case .maximalLength: return Data([0xFF, 0xFF])
        }
    }
}

private struct ResyncCase: Sendable, CustomTestStringConvertible {
    let profile: Profile
    let corruption: Corruption
    var testDescription: String { "\(profile.rawValue) after \(corruption.rawValue)" }
}

private let resyncCases = Profile.allCases.flatMap { profile in
    Corruption.allCases.map { ResyncCase(profile: profile, corruption: $0) }
}

/// Gates: corrupt bytes in front of a board frame cost nothing beyond
/// themselves; the very next good frame decodes.
/// Breaks if: the framer goes back to trusting `buf[1]` for any opcode, or a
/// length check is widened until it accepts the corrupt header.
/// User loses: the board goes silent (every later frame misaligned) until they
/// reconnect, mid-game.
@Test(arguments: resyncCases)
private func corruptHeaderRecoversWithinOneFrame(_ c: ResyncCase) {
    let identity = startIdentity()
    let events = c.profile.feed([c.corruption.bytes + c.profile.frame(identity)])

    let snapshots = events.compactMap { event -> [Piece?]? in
        if case .identitySnapshot(let id) = event { return id }
        return nil
    }
    #expect(snapshots == [identity])
    #expect(events.contains { if case .ready = $0 { return true }; return false })
    // The skipped bytes are still visible for logging, as one raw run.
    guard case .raw(let skipped) = events.first else {
        Issue.record("expected the skipped bytes first, as .raw")
        return
    }
    #expect(skipped == c.corruption.bytes)
}

/// Gates: the framing buffer stays bounded by the longest real frame, whatever
/// arrives, while a split valid frame still waits for its tail.
/// Breaks if: an opcode's accepted length range is widened past what the boards
/// send, or unknown opcodes are trusted again (a `FF FF` header then parks 257
/// bytes, swallowing the board frames behind it).
/// User loses: a burst of radio noise holds back the next board frames, so
/// moves arrive late or merge.
@Test func framingBufferStaysBelowLongestFrame() {
    var rng = SeededRNG(seed: 0xB32_158)
    var buffer: [UInt8] = []
    var largest = 0
    for _ in 0..<2_000 {
        let count = rng.int(in: 1...40)
        let chunk = Data((0..<count).map { _ in UInt8(truncatingIfNeeded: rng.int(in: 0...255)) })
        _ = chessnutExtractFrames(appending: chunk, to: &buffer)
        largest = max(largest, buffer.count)
    }
    #expect(largest < chessnutMaxFrameLength)
}

// MARK: - Live frames behind a resync

/// `startIdentity()` with each listed move made, so every board frame in a
/// stream is distinct and a lost one shows.
private func identity(after moves: [(String, String)]) -> [Piece?] {
    var identity = startIdentity()
    for (from, to) in moves {
        let source = Square(algebraic: from)!, target = Square(algebraic: to)!
        identity[target.file * 8 + target.rank] = identity[source.file * 8 + source.rank]
        identity[source.file * 8 + source.rank] = nil
    }
    return identity
}

private let liveIdentities: [[Piece?]] = [
    identity(after: []),
    identity(after: [("e2", "e4")]),
    identity(after: [("e2", "e4"), ("e7", "e5")]),
    identity(after: [("e2", "e4"), ("e7", "e5"), ("g1", "f3")]),
]

/// Bytes the framer must skip without latching onto the live frames behind
/// them. All arrive on the one `feed(bytes:)` buffer every face uses.
private enum StrayFrame: String, CaseIterable, Sendable {
    /// An opcode no table lists, whose payload reads as `41 22`: a `0x41`
    /// header claiming 34 bytes, exactly one classic board frame.
    case unrecognisedOpcode
    /// Version text longer than the `0x27` bound, containing `Ai` (`41 69`),
    /// that a resync walks through byte by byte.
    case longVersionText
    /// A board-state frame longer than the accepted 42 bytes (payload 0x2A).
    case longBoardFrame

    func bytes(_ profile: Profile) -> Data {
        switch self {
        case .unrecognisedOpcode:
            return Data([0x2B, 0x02, 0x41, 0x22])
        case .longVersionText:
            let text = Array("Chessnut Air BLE V1.3 MCU Ai Go/Pro mk0X".utf8)
            precondition(text.count == 40)
            return Data([0x27, UInt8(text.count)] + text)
        case .longBoardFrame:
            let frame = profile.frame(liveIdentities[0])
            return Data([0x01, 0x2A]) + frame.dropFirst(2).prefix(32) + Data(repeating: 0, count: 10)
        }
    }
}

private enum Delivery: String, CaseIterable, Sendable {
    /// One `feed(bytes:)` per frame.
    case wholeFrame
    /// Every frame cut into 20-byte notifications.
    case twentyByteChunks

    func chunks(_ frames: [Data]) -> [Data] {
        switch self {
        case .wholeFrame: return frames
        case .twentyByteChunks:
            return frames.flatMap { data in
                stride(from: 0, to: data.count, by: 20).map {
                    data.subdata(in: (data.startIndex + $0)..<(data.startIndex + min($0 + 20, data.count)))
                }
            }
        }
    }
}

private struct StrayCase: Sendable, CustomTestStringConvertible {
    let profile: Profile
    let stray: StrayFrame
    let delivery: Delivery
    var testDescription: String { "\(profile.rawValue), \(stray.rawValue), \(delivery.rawValue)" }
}

private let strayCases = Profile.allCases.flatMap { profile in
    StrayFrame.allCases.flatMap { stray in
        Delivery.allCases.map { StrayCase(profile: profile, stray: stray, delivery: $0) }
    }
}

/// Gates: a frame the framer cannot use costs only itself; every live board
/// frame before and after it decodes, in order.
/// Breaks if: the `0x41` header accepts a length or sub-opcode the Move never
/// sends (a resync then latches onto `41 22` or the `A` in version text and
/// swallows up to 139 bytes of live frames), or a header with no sub-opcode
/// yet waits for a length that cannot be a `0x41` reply. The long board frame
/// pins the deliberate 42-byte bound: widening it is a decision for a
/// capture, and this case changes with it.
/// User loses: moves made right after a stray notification never reach the
/// app, or a board model with a longer frame silently stalls.
@Test(arguments: strayCases)
private func strayFrameCostsOnlyItself(_ c: StrayCase) {
    let frames = [c.profile.frame(liveIdentities[0]), c.stray.bytes(c.profile)]
        + liveIdentities.dropFirst().map(c.profile.frame)
    let events = c.profile.feed(c.delivery.chunks(frames))
    let snapshots = events.compactMap { event -> [Piece?]? in
        if case .identitySnapshot(let id) = event { return id }
        return nil
    }
    #expect(snapshots == liveIdentities)
}

/// Gates: a `0x41` header whose sub-opcode has not arrived waits only for the
/// two lengths the Move sends, and a split battery reply still frames whole.
/// Breaks if: the framer rejects a valid `41 03` header before its
/// sub-opcode arrives, or holds a `41` header of any other length.
/// User loses: a Move's battery reply split across notifications is dropped,
/// or stray bytes are held back until more arrive.
@Test func extendedHeaderWaitsOnlyForMoveShapes() {
    var buffer: [UInt8] = []
    #expect(chessnutExtractFrames(appending: Data([0x41, 0x03]), to: &buffer).isEmpty)
    #expect(chessnutExtractFrames(appending: Data([0x0C, 0x00, 0x55]), to: &buffer)
        == [.frame([0x41, 0x03, 0x0C, 0x00, 0x55])])
    #expect(buffer.isEmpty)

    #expect(chessnutExtractFrames(appending: Data([0x41, 0x89]), to: &buffer).isEmpty)
    #expect(buffer == [0x41, 0x89])
    buffer = []

    #expect(chessnutExtractFrames(appending: Data([0x41, 0x22]), to: &buffer) == [.discarded([0x41, 0x22])])
    #expect(buffer.isEmpty)

    // A sub-opcode that has arrived must match its length.
    #expect(chessnutExtractFrames(appending: Data([0x41, 0x03, 0x0B]), to: &buffer)
        == [.discarded([0x41, 0x03, 0x0B])])
    #expect(chessnutExtractFrames(appending: Data([0x41, 0x89, 0x0C]), to: &buffer)
        == [.discarded([0x41, 0x89, 0x0C])])
    #expect(buffer.isEmpty)
}
