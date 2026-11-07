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
