// IdentitySwapDeltaTests.swift
// A capture fast enough that one piece replaces another between two frames
// must still reach the session as a lift and a place. (Fianchetto-0yp)

import Foundation
import Testing
import ChessCore
import BoardKit
@testable import ChessnutAdapter
@testable import MillenniumAdapter

private let blackKing = Piece(type: .king, color: .black)
private let whiteRook = Piece(type: .rook, color: .white)

private func sensed(_ events: [BoardEvent]) -> [String] {
    events.compactMap {
        guard case .squareSensed(let square, let isLift, let piece) = $0 else { return nil }
        return "\(isLift ? "lift" : "place") \(square) \(piece.map { "\($0.color) \($0.type)" } ?? "-")"
    }
}

/// The owner's Chessnut Go frames, 2026-10-29: Black's king already in hand
/// from b2, then a1 reads the black king where the white rook stood, with no
/// empty frame between (...Kxa1).
@Test func chessnutGoKingCaptureInOneFrame() {
    let beforeHex = "01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 60 d7 09 00 00"
    let afterHex = "01 24 00 00 00 00 00 00 00 04 00 00 00 80 c0 07 00 00 00 00 00 00 00 00 00 00 70 00 00 00 00 00 00 20 d8 09 00 00"
    let bytes = { (hex: String) in Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! }) }
    var adapter = ChessnutAdapter()
    _ = adapter.feed(bytes: bytes(beforeHex))
    #expect(sensed(adapter.feed(bytes: bytes(afterHex))) == ["lift a1 white rook", "place a1 black king"])
}

@Test(arguments: [true, false])
func swapEmitsLiftThenPlace(chessnut: Bool) {
    var prev = [Piece?](repeating: nil, count: 64)
    var curr = prev
    prev[0] = whiteRook      // a1
    curr[0] = blackKing
    prev[9] = blackKing      // b2: unchanged king elsewhere is not an event
    curr[9] = blackKing
    let events = chessnut
        ? chessnutDeltaEvents(prev: prev, curr: curr)
        : millenniumDeltaEvents(prev: prev, curr: curr)
    #expect(sensed(events) == ["lift a1 white rook", "place a1 black king"])
}

@Test(arguments: [true, false])
func unchangedPieceIsSilent(chessnut: Bool) {
    var board = [Piece?](repeating: nil, count: 64)
    board[0] = whiteRook
    let events = chessnut
        ? chessnutDeltaEvents(prev: board, curr: board)
        : millenniumDeltaEvents(prev: board, curr: board)
    #expect(events.isEmpty)
}
