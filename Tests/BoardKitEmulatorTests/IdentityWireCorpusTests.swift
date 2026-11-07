// IDENTITY-BOARD WIRE CORPUS — the Chessnut Go failures behind 0.12.x.
//
// The kernel-survival corpus feeds chaos events straight into the kernels, so
// it cannot see what an identity board's adapter does with them. Here every
// seeded stream goes the whole way: chaos events → the board personality's
// frames (several events per frame when the sensor scan coalesces them) →
// 20-byte BLE notifications → the real adapter's `feed` → a session mimic that
// commits a live candidate only when `BoardIdentityCheck.confirms` it, as
// FianchettoKit's `EBoardSessionCore.tryApply` does.
//
// It must fail when either fix behind 0.12.x is undone (Fianchetto-b32.57):
// - 5771084 (identity deltas: a swap is a lift and a place, lifts first): a
//   coalesced capture then reads only the attacker's lift, and the move stalls.
// - 09db15d (`BoardIdentityCheck`): a ghost reading on a square the mover can
//   reach is then committed as the move.
// The mid-frame disconnect case adds BoardAdapter.resetFraming (b32.202).

import Testing
import Foundation
import ChessCore
import BoardKit
import ChessnutAdapter
import BoardKitTestSupport
import BoardKitEmulator

// MARK: - Wire profiles

/// An identity board as the host sees it: a personality on one side, the
/// adapter on the other, joined by 20-byte notifications.
private enum IdentityWire: String, CaseIterable, Sendable {
    case chessnutAir, chessnutMove

    func makeLink() -> any IdentityLink {
        switch self {
        case .chessnutAir: return Link(personality: ChessnutPersonality(), adapter: ChessnutAdapter()) { a, d in
            a.feed(bytes: d, from: .boardState)
        }
        case .chessnutMove: return Link(personality: ChessnutMovePersonality(), adapter: ChessnutMoveAdapter()) { a, d in
            a.feed(bytes: d, from: .boardState)
        }
        }
    }
}

private protocol IdentityLink {
    /// Encode one sensor scan (one or more events) and deliver it; returns the
    /// adapter's events. `cutAfterFirstChunk` delivers only the first 20 bytes.
    mutating func scan(_ events: [BoardEvent], cutAfterFirstChunk: Bool) -> [BoardEvent]
    /// Drop the link (reset through the protocol), reconnect, and deliver the
    /// board's answer to the realtime handshake.
    mutating func reconnect() -> [BoardEvent]
    var mirror: [Piece?] { get }
}

private struct Link<P: BoardPersonality, A: BoardAdapter>: IdentityLink {
    var personality: P
    var adapter: A
    let deliver: (inout A, Data) -> [BoardEvent]

    init(personality: P, adapter: A, deliver: @escaping (inout A, Data) -> [BoardEvent]) {
        self.personality = personality
        self.adapter = adapter
        self.deliver = deliver
    }

    var mirror: [Piece?] {
        if let move = personality as? ChessnutMovePersonality { return move.identityMirror }
        if let air = personality as? ChessnutPersonality { return air.identityMirror }
        return []
    }

    mutating func scan(_ events: [BoardEvent], cutAfterFirstChunk: Bool) -> [BoardEvent] {
        let frames = events.count == 1 ? personality.frames(for: events[0]) : personality.coalescedFrames(for: events)
        var out: [BoardEvent] = []
        for frame in frames where frame.characteristicUUID == ChessnutGATT.boardStateChar {
            for (index, chunk) in notifications(frame.data).enumerated() {
                if cutAfterFirstChunk && index > 0 { return out }
                out += deliver(&adapter, chunk)
            }
        }
        return out
    }

    mutating func reconnect() -> [BoardEvent] {
        dropLink(&adapter)
        var out: [BoardEvent] = []
        for action in personality.handleHostWrite(Data([0x21, 0x01, 0x00])) {
            if case .notify(let frame) = action, frame.characteristicUUID == ChessnutGATT.boardStateChar {
                for chunk in notifications(frame.data) { out += deliver(&adapter, chunk) }
            }
        }
        return out
    }
}

/// What a transport does on a link drop, through the protocol.
private func dropLink<A: BoardAdapter>(_ adapter: inout A) {
    adapter.resetFraming()
}

/// Split a frame into the 20-byte payloads of a default-MTU BLE link.
private func notifications(_ data: Data) -> [Data] {
    stride(from: 0, to: data.count, by: 20).map { data.subdata(in: $0..<min($0 + 20, data.count)) }
}

// MARK: - Session mimic

private enum LiveOutcome: Equatable {
    case committedIntended
    case committedOther(String)
    /// No candidate the board confirmed: the session would still be waiting.
    case stalled
}

/// The live half of `EBoardSessionCore` for an identity board: occupancy
/// inference proposes, the latest identity snapshot confirms, first confirmed
/// legal candidate wins. Promotions skip the identity check, as in the kit.
private final class IdentitySessionMimic {
    private let inference = OccupancyMoveInference()
    private let position: Position
    private let legal: [Move]
    private let intended: String
    private var identity: [Piece?]?
    private(set) var outcome: LiveOutcome = .stalled

    init(position: Position, intended: String) {
        self.position = position
        self.intended = intended
        self.legal = MoveGenerator.legalMoves(for: position)
        let legalSet = Set(legal.map(\.uci))
        inference.isCastlingStillLegal = { rookHome in
            switch rookHome {
            case "h1": return legalSet.contains("e1g1")
            case "a1": return legalSet.contains("e1c1")
            case "h8": return legalSet.contains("e8g8")
            case "a8": return legalSet.contains("e8c8")
            default: return false
            }
        }
    }

    func handle(_ events: [BoardEvent]) {
        for event in events {
            guard outcome == .stalled else { return }
            switch event {
            case .identitySnapshot(let snapshot):
                identity = snapshot
            case .squareSensed(let square, let isLift, _):
                if case .moveCandidates(let candidates) = inference.handle(square: square, isLift: isLift) {
                    commitFirstConfirmed(candidates)
                }
            default:
                break
            }
        }
    }

    /// The opponent's first lift of their next move. The inference defers a
    /// corner-rook move onto a castle square (a8c8 while O-O-O is legal) until
    /// the next lift arrives, and the kit re-feeds that lift after the commit;
    /// a stream that ends on such a move is flushed the same way.
    func flushWithNextLift(after corpusCase: CorpusCase) {
        guard outcome == .stalled else { return }
        var after = corpusCase.positionBefore
        MoveGenerator.applyMoveUnchecked(&after, corpusCase.move)
        let effect = corpusCase.context.effectSquares
        let opponent = after.activeColor
        let square = (0..<64).lazy
            .map { Square(file: $0 % 8, rank: $0 / 8) }
            .first { after[$0]?.color == opponent && !effect.contains($0.algebraic) }
        guard let square else { return }
        if case .moveCandidates(let candidates) = inference.handle(square: square.algebraic, isLift: true) {
            commitFirstConfirmed(candidates)
        }
    }

    private func commitFirstConfirmed(_ candidates: [String]) {
        for uci in candidates {
            guard let move = UCIParser.uciToMove(uci, in: legal) else { continue }
            if move.promotion == nil, let identity,
               !BoardIdentityCheck.confirms(move, in: position, sensed: identity) { continue }
            let samePromotionSquares = uci.count == 5 && intended.count == 5 && uci.prefix(4) == intended.prefix(4)
            outcome = (uci == intended || samePromotionSquares) ? .committedIntended : .committedOther(uci)
            return
        }
    }
}

// MARK: - Running one case

/// Group perturbed events into sensor scans.
private func scans(_ events: [ChaosMoveEvent]) -> [[BoardEvent]] {
    var groups: [[BoardEvent]] = []
    for event in events {
        let sensed = BoardEvent.squareSensed(square: event.square, isLift: event.isLift, piece: event.piece)
        if event.sameScanAsPrevious, !groups.isEmpty { groups[groups.count - 1].append(sensed) } else { groups.append([sensed]) }
    }
    return groups
}

private struct WireRun {
    let outcome: LiveOutcome
    /// After a mid-frame drop: whether the reconnect frame decoded to exactly
    /// the board's state and re-armed `.ready`.
    let reconnectDecodedCleanly: Bool?
}

private func runOverWire(_ wire: IdentityWire, corpusCase: CorpusCase, events: [ChaosMoveEvent],
                         dropDuringScan: Int? = nil) -> WireRun {
    var link = wire.makeLink()
    // Connect: the board streams its state before the move begins.
    _ = link.scan([.identitySnapshot(corpusCase.context.identityBefore)], cutAfterFirstChunk: false)
    let session = IdentitySessionMimic(position: corpusCase.positionBefore, intended: corpusCase.uci)
    var reconnectClean: Bool?
    for (index, scan) in scans(events).enumerated() {
        if index == dropDuringScan {
            // The link drops 20 bytes into this scan's frame; the board keeps
            // the physical state, and answers the reconnect with all of it.
            session.handle(link.scan(scan, cutAfterFirstChunk: true))
            let afterReconnect = link.reconnect()
            let snapshots = afterReconnect.compactMap { event -> [Piece?]? in
                if case .identitySnapshot(let identity) = event { return identity }
                return nil
            }
            reconnectClean = snapshots == [link.mirror]
                && afterReconnect.contains { if case .ready = $0 { return true }; return false }
            session.handle(afterReconnect)
        } else {
            session.handle(link.scan(scan, cutAfterFirstChunk: false))
        }
    }
    session.flushWithNextLift(after: corpusCase)
    return WireRun(outcome: session.outcome, reconnectDecodedCleanly: reconnectClean)
}

// MARK: - The corpus

private struct WireCorpusCase: Sendable, CustomTestStringConvertible {
    let wire: IdentityWire
    let gameSeed: UInt64
    var testDescription: String { "\(wire.rawValue) game \(gameSeed)" }
}

private let wireCorpus = IdentityWire.allCases.flatMap { wire in
    [UInt64(21), 22, 23].map { WireCorpusCase(wire: wire, gameSeed: $0) }
}

/// Gates: on an identity board read through its real adapter, a careful player
/// with a flaky sensor and fast captures has every move committed as played.
/// Breaks if: identity deltas stop reporting a piece swap as lift + place
/// (5771084), or live commits stop requiring the board to show the mover
/// where it lands (09db15d).
/// User loses: a fast capture freezes the game on a held confirmation, or a
/// flickering square commits a move they never made (Fianchetto-0yp, -s21).
@Test(arguments: wireCorpus)
private func identityNoiseStreamsCommitThePlayedMove(_ c: WireCorpusCase) async throws {
    let cases = try await generateGameCases(seed: c.gameSeed, maxPlies: 40)
    let engine = ChaosEngine(profile: .identityNoise)
    var rng = SeededRNG(seed: c.gameSeed &* 0xB32_57)
    var drawn: [ChaosPatternID: Int] = [:]
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        for pattern in perturbation.appliedPatterns { drawn[pattern, default: 0] += 1 }
        let run = runOverWire(c.wire, corpusCase: corpusCase, events: perturbation.events)
        #expect(run.outcome == .committedIntended,
                "\(corpusCase.uci) \(perturbation.appliedPatterns): \(run.outcome)")
    }
    // The corpus must actually exercise both failure shapes.
    #expect(drawn[.ghostNeighbor, default: 0] >= 3, "ghost neighbours drawn: \(drawn)")
    #expect(drawn[.coalescedCapture, default: 0] >= 1, "coalesced captures drawn: \(drawn)")
}

/// Gates: a link that drops in the middle of a frame, reset and reconnected,
/// delivers the board's state intact, and the game goes on.
/// Breaks if: the adapter keeps the old link's half frame (resetFraming is
/// missing or not reached through the protocol), splicing it onto the
/// reconnect frame.
/// User loses: after a Bluetooth blip the board's first state is garbled or
/// dropped, so the app shows phantom moves or never sees the board ready.
@Test(arguments: IdentityWire.allCases)
private func midFrameDisconnectDecodesTheReconnectCleanly(_ wire: IdentityWire) async throws {
    let cases = try await generateGameCases(seed: 31, maxPlies: 24)
    let engine = ChaosEngine(profile: .identityNoise)
    var rng = SeededRNG(seed: 0xD15C)
    for corpusCase in cases {
        let perturbation = engine.perturb(corpusCase.context, rng: &rng)
        let scanCount = scans(perturbation.events).count
        let run = runOverWire(wire, corpusCase: corpusCase, events: perturbation.events,
                              dropDuringScan: rng.int(in: 0...(scanCount - 1)))
        #expect(run.reconnectDecodedCleanly == true, "\(corpusCase.uci) \(perturbation.appliedPatterns)")
    }
}

// MARK: - Directed shapes

private func forcedCase(uci: String, fen: String, _ configure: (inout ChaosProfile) -> Void) async throws
    -> (CorpusCase, ChaosPerturbation) {
    let position = try #require(Position(fen: fen))
    let move = try #require(UCIParser.uciToMove(uci, in: MoveGenerator.legalMoves(for: position)))
    let sim = SimulatedBoard(position: position, capabilities: [.occupancySensing, .pieceIdentity])
    let context = ChaosMoveContext(move: move, positionBefore: position, cleanEvents: try await sim.executeMove(uci: uci))
    var profile = ChaosProfile.clean
    configure(&profile)
    var rng = SeededRNG(seed: 1)
    let perturbation = ChaosEngine(profile: profile).perturb(context, rng: &rng)
    return (CorpusCase(uci: uci, move: move, positionBefore: position, context: context), perturbation)
}

/// Gates: a ghost reading lands while the bishop is in hand, on a square it
/// could legally reach, so occupancy alone commits the wrong move and only
/// the identity check saves it (the owner's Bc1-g5 with d2 flickering).
/// Breaks if: the pattern drifts to a harmless shape (before the lift, or onto
/// a square the mover cannot reach), and the corpus stops testing anything.
/// User loses: nothing directly; the corpus would pass with the identity check
/// broken, and the next phantom capture would ship.
@Test func ghostNeighborReadsWhileTheMoverIsInHand() async throws {
    let (corpusCase, perturbation) = try await forcedCase(
        uci: "c1g5", fen: "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 2"
    ) { $0.ghostNeighborProbability = 1 }
    #expect(perturbation.appliedPatterns == [.ghostNeighbor])
    let squares = perturbation.events.map(\.square)
    #expect(squares.count == 4 && squares.first == "c1" && squares.last == "g5" && squares[1] == squares[2])
    #expect(perturbation.events.map(\.isLift) == [true, false, true, false])
    #expect(["d2", "e3", "f4", "h6"].contains(squares[1]))

    #expect(inferenceOutcome(events: perturbation.events, positionBefore: corpusCase.positionBefore,
                             intended: "c1g5") == .resolvedOther("c1" + squares[1]))
    for wire in IdentityWire.allCases {
        #expect(runOverWire(wire, corpusCase: corpusCase, events: perturbation.events).outcome == .committedIntended)
    }
}

/// Gates: a coalesced capture is one sensor scan, so the board reports the
/// destination going straight from the captured piece to the capturer.
/// Breaks if: the pattern stops marking its events as one scan, and the
/// corpus no longer reproduces the one-frame capture behind Fianchetto-0yp.
/// User loses: as above; the swap-delta fix could regress unseen.
@Test func coalescedCaptureIsOneScan() async throws {
    let (corpusCase, perturbation) = try await forcedCase(
        uci: "e4d5", fen: "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    ) { $0.coalescedCaptureProbability = 1 }
    #expect(perturbation.appliedPatterns == [.coalescedCapture])
    #expect(scans(perturbation.events).count == 1)
    for wire in IdentityWire.allCases {
        #expect(runOverWire(wire, corpusCase: corpusCase, events: perturbation.events).outcome == .committedIntended)
    }
}
