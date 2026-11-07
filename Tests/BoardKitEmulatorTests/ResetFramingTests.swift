// ResetFramingTests.swift
// Every adapter's resetFraming, called the way a transport calls it (through
// the BoardAdapter protocol), leaves it decoding like a fresh adapter.
// (Fianchetto-b32.202)

import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter
import ChessnutAdapter
import PegasusAdapter
import MillenniumAdapter
import CertaboAdapter
import ChessUpAdapter
import BoardKitTestSupport
import BoardKitEmulator

private enum ResetBoard: String, CaseIterable, Sendable {
    case squareOff, chessnut, chessnutMove, pegasus, millennium, certabo, chessUp

    /// Whether the first state frame on the new link emits `.ready`. Square
    /// Off's `.ready` answers `startSession`, which its reconnect handshake
    /// does not send.
    var reArmsReady: Bool { self != .squareOff }
}

/// What a transport does on a link drop: reset through the protocol, never
/// through the concrete type, so a reset the protocol cannot see is a no-op.
private func dropLink<A: BoardAdapter>(_ adapter: inout A) {
    adapter.resetFraming()
}

/// Feed the board's state frames, then half of the first one (the link drops
/// mid-frame), reset, then all of them again. Returns the events after the
/// reset and the events a fresh adapter produces from the same frames.
private func afterMidFrameDrop<A: BoardAdapter>(_ make: () -> A, frames: [Data]) -> (reset: String, fresh: String) {
    let wire = frames.reduce(Data(), +)
    var adapter = make()
    _ = adapter.feed(bytes: wire)
    _ = adapter.feed(bytes: frames[0].prefix(frames[0].count / 2))
    dropLink(&adapter)
    let reset = adapter.feed(bytes: wire)
    var fresh = make()
    return ("\(reset)", "\(fresh.feed(bytes: wire))")
}

/// The board after 1.e4, as each board's own wire encoding.
private func stateWire<P: BoardPersonality>(_ personality: P, identity: [Piece?]) -> [Data] {
    var personality = personality
    return personality.frames(for: .identitySnapshot(identity)).map(\.data)
}

private func identityAfterE4() async throws -> [Piece?] {
    let sim = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
    _ = try await sim.executeMove(uci: "e2e4")
    guard case .identitySnapshot(let identity) = await sim.boardSnapshot() else {
        Issue.record("identity board produced no identity snapshot")
        return []
    }
    return identity
}

/// What a Square Off sends back to its reconnect handshake, run through the
/// board's own personality with the board after 1.e4.
private func squareOffReconnectWire(identity: [Piece?]) -> [Data] {
    var personality = SquareOffPersonality()
    _ = personality.frames(for: .identitySnapshot(identity))
    let adapter = SquareOffAdapter()
    return adapter.handshakeCommands(isReconnect: true).flatMap { step -> [Data] in
        guard let write = adapter.encode(step.command) else { return [] }
        return personality.handleHostWrite(write).compactMap { action in
            if case .notify(let frame) = action { return frame.data }
            return nil
        }
    }
}

/// Gates: after a link drop mid-frame and `resetFraming()`, every adapter
/// decodes the next frame exactly as a fresh adapter would, `.ready` where the
/// board re-announces it.
/// Breaks if: an adapter keeps part of its framing or history across the reset,
/// or `resetFraming` stops being a protocol requirement (a generic transport
/// then reaches the default no-op).
/// User loses: after a reconnect the first board state is lost or garbled
/// (phantom lifts and places) and the app never sees the board become ready.
@Test(arguments: ResetBoard.allCases)
private func resetFramingDecodesLikeAFreshAdapter(_ board: ResetBoard) async throws {
    let identity = try await identityAfterE4()
    let result: (reset: String, fresh: String)
    switch board {
    case .squareOff:
        // The reconnect handshake asks for state only; no "14#GO*" follows.
        result = afterMidFrameDrop({ SquareOffAdapter() }, frames: squareOffReconnectWire(identity: identity))
    case .chessnut:
        result = afterMidFrameDrop({ ChessnutAdapter() }, frames: stateWire(ChessnutPersonality(), identity: identity))
    case .chessnutMove:
        result = afterMidFrameDrop({ ChessnutMoveAdapter() }, frames: [ChessnutMoveAdapter.encodeFrame(identity: identity)])
    case .pegasus:
        result = afterMidFrameDrop({ PegasusAdapter() }, frames: stateWire(PegasusPersonality(), identity: identity))
    case .millennium:
        result = afterMidFrameDrop({ MillenniumAdapter() }, frames: stateWire(MillenniumPersonality(), identity: identity))
    case .certabo:
        result = afterMidFrameDrop({ CertaboAdapter() }, frames: stateWire(CertaboPersonality(), identity: identity))
    case .chessUp:
        result = afterMidFrameDrop({ ChessUpAdapter() }, frames: stateWire(ChessUpPersonality(), identity: identity))
    }
    #expect(result.reset == result.fresh)
    #expect(result.reset.contains("ready") == board.reArmsReady)
    if board == .squareOff {
        #expect(result.reset.contains("occupancySnapshot"), "the reconnect must still deliver the board state")
    }
}
