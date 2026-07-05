import Foundation
import ChessCore
import BoardKit
import BoardKitTestSupport

/// Plays a game on the emulated board: either a supplied PGN main line or a
/// seeded legal-random game, perturbed by the `ChaosEngine`, with app-dictated
/// moves (LED commands from the host) executed "physically" after a
/// configurable human delay.
///
/// Platform-free — the BLE `PeripheralServer` (macOS-only) plugs into
/// `onFrames` / `hostWrote(_:)`; tests drive the same surface directly.
///
/// ## Turn ownership (adaptive)
///
/// The driver initially assumes it plays BOTH sides from its script (PGN or
/// seeded random). The first time the host dictates a move for a colour via
/// an LED from/to pair, that colour is marked host-owned and the think-timer
/// stops auto-playing it — matching the Fianchetto OTB flow where the app's
/// engine replies arrive as LED indications that the human then executes.
public actor GameDriver {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// PGN main-line UCIs to play; empty = seeded legal-random game.
        public var scriptedUCIs: [String]
        public var chaosProfile: ChaosProfile
        public var seed: UInt64
        /// Pause before the driver plays its own next scripted move.
        public var thinkMs: Int
        /// Pause between an LED move indication arriving and the "human"
        /// starting to execute it on the board.
        public var humanMs: Int
        /// When non-nil, emit an UNSOLICITED board-state snapshot frame after
        /// every n-th successfully executed move.
        ///
        /// This is a **divergence-detection test knob**: it lets the host's
        /// occupancy-mismatch machinery notice app/board drift without a manual
        /// sync request. Left `nil` (OFF) by default because real boards do not
        /// push unsolicited state — enabling it changes the protocol in a way
        /// the host adapter does not expect from hardware.
        public var pushStateEvery: Int?

        /// When true the driver never auto-plays: it only executes moves it is
        /// explicitly told to (host-dictated engine moves, or `play`/`takeback`
        /// stdin commands). Used to drive precise validation scenarios.
        public var manual: Bool

        public init(scriptedUCIs: [String] = [],
                    chaosProfile: ChaosProfile = .casual,
                    seed: UInt64 = 0,
                    thinkMs: Int = 2_000,
                    humanMs: Int = 1_200,
                    pushStateEvery: Int? = nil,
                    manual: Bool = false) {
            self.scriptedUCIs = scriptedUCIs
            self.chaosProfile = chaosProfile
            self.seed = seed
            self.thinkMs = thinkMs
            self.humanMs = humanMs
            self.pushStateEvery = pushStateEvery
            self.manual = manual
        }
    }

    // MARK: - State

    private var personality: any BoardPersonality
    private let board: SimulatedBoard
    private let chaos: ChaosEngine
    private var rng: SeededRNG
    private let configuration: Configuration

    private var remainingScript: [String]
    private var scriptDiverged = false
    private var hostSides: Set<PieceColor> = []
    private var pendingHostMove: (uci: String, isMotorised: Bool)?
    private var running = false
    private var loopTask: Task<Void, Never>?
    /// Number of moves successfully executed (host-dictated or scripted).
    /// Drives the `pushStateEvery` unsolicited-snapshot feature.
    private var executedMoveCount = 0

    /// Per-move undo stack: the position BEFORE each executed move and the clean
    /// physical events it produced. Drives `takeBackLastMove`.
    private var moveHistory: [(positionBefore: Position, cleanEvents: [BoardEvent])] = []

    private var onFrames: (@Sendable ([PersonalityFrame]) -> Void)?
    private var onLog: (@Sendable (String) -> Void)?

    // MARK: - Init

    public init(personality: any BoardPersonality, configuration: Configuration) {
        self.personality = personality
        self.configuration = configuration
        self.remainingScript = configuration.scriptedUCIs
        self.chaos = ChaosEngine(profile: configuration.chaosProfile)
        self.rng = SeededRNG(seed: configuration.seed)
        self.board = SimulatedBoard(capabilities: [.occupancySensing, .pieceIdentity])
    }

    // MARK: - Wiring

    public func setOnFrames(_ handler: @escaping @Sendable ([PersonalityFrame]) -> Void) {
        onFrames = handler
    }

    public func setOnLog(_ handler: @escaping @Sendable (String) -> Void) {
        onLog = handler
    }

    // MARK: - Lifecycle

    /// Begin the play loop. Also pushes an initial board snapshot so a host
    /// that connects mid-session sees a coherent state.
    public func start() async {
        guard !running else { return }
        running = true
        await emitSnapshot()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Host input

    /// Route one raw host write through the personality and process the
    /// resulting actions.
    public func hostWrote(_ data: Data) async {
        let actions = personality.handleHostWrite(data)
        await process(actions)
    }

    // MARK: - Manual control (validation hooks, driven from stdin)

    /// Play a specific board-originated move immediately (the emulator acting as
    /// the physical player making this move). Ignores the think-timer / script.
    public func playMoveNow(uci: String) async {
        await execute(uci: uci, dictatedByHost: false, paced: true)
    }

    /// Emit a full board-state snapshot on demand.
    public func snapshotNow() async {
        await emitSnapshot()
    }

    /// Take back the last executed move: reset the simulated board to the position
    /// before it and emit the REVERSE physical events — the forward events reversed
    /// with lift/place flipped, which is the correct retraction for simple moves,
    /// captures, castling, en passant, and promotion. Models a player physically
    /// picking their move back up (the club-play blunder undo).
    public func takeBackLastMove() async {
        guard let last = moveHistory.popLast() else {
            log("take-back: no move to undo")
            return
        }
        await board.reset(to: last.positionBefore)
        executedMoveCount = max(0, executedMoveCount - 1)
        log("take-back → \(last.positionBefore.fen)")
        let reverse: [BoardEvent] = last.cleanEvents.reversed().map { event in
            if case let .squareSensed(square, isLift, piece) = event {
                return .squareSensed(square: square, isLift: !isLift, piece: piece)
            }
            return event
        }
        for event in reverse {
            let frames = personality.frames(for: event)
            if !frames.isEmpty { onFrames?(frames) }
            try? await Task.sleep(for: .milliseconds(max(1, configuration.humanMs / 2)))
        }
    }

    private func process(_ actions: [PeripheralAction]) async {
        for action in actions {
            switch action {
            case .notify(let frame):
                onFrames?([frame])

            case .setLEDs(let squares):
                await handleLEDs(squares)

            case .startNewGame:
                await handleNewGame()

            case .executeMove(let uci):
                log("host requested motorised move \(uci)")
                pendingHostMove = (uci, isMotorised: true)

            case .log(let message):
                log(message)
            }
        }
    }

    private func handleLEDs(_ squares: [String]) async {
        guard !squares.isEmpty else { return }   // LED clear
        let position = await board.position
        guard let uci = Self.moveForLEDSquares(squares, position: position) else {
            log("LEDs \(squares.joined(separator: ",")) do not indicate a unique legal move")
            return
        }
        log("host LEDs dictate \(uci)")
        pendingHostMove = (uci, isMotorised: false)
    }

    private func handleNewGame() async {
        log("host started a new game — resetting board")
        await board.reset()
        remainingScript = configuration.scriptedUCIs
        scriptDiverged = false
        hostSides = []
        moveHistory.removeAll()
        pendingHostMove = nil
        executedMoveCount = 0
        await emitSnapshot()
    }

    // MARK: - Play loop

    private func runLoop() async {
        let tickMs = 100
        var thinkAccumulatedMs = 0
        while running, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(tickMs))

            if let pending = pendingHostMove {
                pendingHostMove = nil
                if !pending.isMotorised {
                    // The human walks over and physically executes the
                    // indicated move.
                    try? await Task.sleep(for: .milliseconds(configuration.humanMs))
                }
                await execute(uci: pending.uci, dictatedByHost: true)
                thinkAccumulatedMs = 0
                continue
            }

            // Manual mode: never auto-play — only host-dictated / stdin-driven moves.
            guard !configuration.manual else { continue }

            thinkAccumulatedMs += tickMs
            guard thinkAccumulatedMs >= configuration.thinkMs else { continue }
            thinkAccumulatedMs = 0

            let position = await board.position
            guard !hostSides.contains(position.activeColor) else { continue }
            guard let uci = nextScriptedMove(for: position) else { continue }
            await execute(uci: uci, dictatedByHost: false)
        }
    }

    /// Play the next scripted move immediately (dry-run and test hook —
    /// bypasses the think-timer). Returns the UCI played, or nil when the
    /// script/game is over.
    @discardableResult
    public func playNextScriptedMoveNow() async -> String? {
        let position = await board.position
        guard let uci = nextScriptedMove(for: position) else { return nil }
        await execute(uci: uci, dictatedByHost: false, paced: false)
        return uci
    }

    // MARK: - Move selection

    private func nextScriptedMove(for position: Position) -> String? {
        let legal = MoveGenerator.legalMoves(for: position)
        guard !legal.isEmpty else { return nil }   // game over

        if !remainingScript.isEmpty, !scriptDiverged {
            let next = remainingScript[0]
            if UCIParser.uciToMove(next, in: legal) != nil {
                remainingScript.removeFirst()
                return next
            }
            log("scripted move \(next) is not legal here — falling back to random play")
            scriptDiverged = true
        }

        if configuration.scriptedUCIs.isEmpty || scriptDiverged {
            // Seeded legal-random game.
            let index = Int(rng.next() % UInt64(legal.count))
            return legal[index].uci
        }
        return nil   // PGN exhausted: sit idle (host may keep dictating)
    }

    // MARK: - Physical execution

    private func execute(uci: String, dictatedByHost: Bool, paced: Bool = true) async {
        let position = await board.position
        let legal = MoveGenerator.legalMoves(for: position)
        guard let move = UCIParser.uciToMove(uci, in: legal) else {
            log("cannot execute \(uci): not legal in \(position.fen)")
            return
        }

        if dictatedByHost {
            let color = position.activeColor
            if hostSides.insert(color).inserted {
                log("host now owns \(color == .white ? "white" : "black")")
            }
            // Keep the PGN cursor in sync when the host plays the scripted move.
            if remainingScript.first == uci {
                remainingScript.removeFirst()
            } else if !remainingScript.isEmpty, !scriptDiverged {
                log("host move \(uci) diverges from script (\(remainingScript[0])) — random play from here")
                scriptDiverged = true
            }
        }

        guard let cleanEvents = try? await board.executeMove(uci: uci) else {
            log("SimulatedBoard rejected \(uci)")
            return
        }
        moveHistory.append((positionBefore: position, cleanEvents: cleanEvents))

        let context = ChaosMoveContext(move: move, positionBefore: position, cleanEvents: cleanEvents)
        let perturbation = chaos.perturb(context, rng: &rng)
        let patterns = perturbation.appliedPatterns.map(\.rawValue).joined(separator: "+")
        log("playing \(uci)\(patterns.isEmpty ? "" : " [chaos: \(patterns)]")")

        for event in perturbation.events {
            if paced, event.delayBeforeMs > 0 {
                try? await Task.sleep(for: event.delayBefore)
            }
            let frames = personality.frames(
                for: .squareSensed(square: event.square, isLift: event.isLift, piece: event.piece)
            )
            if !frames.isEmpty { onFrames?(frames) }
        }

        if MoveGenerator.legalMoves(for: await board.position).isEmpty {
            log("game over: \(await board.position.fen)")
        }

        executedMoveCount += 1
        if let n = configuration.pushStateEvery, n > 0, executedMoveCount % n == 0 {
            log("push-state-every \(n): emitting unsolicited board-state (after move \(executedMoveCount))")
            await emitSnapshot()
        }
    }

    private func emitSnapshot() async {
        let snapshot = await board.boardSnapshot()
        let frames = personality.frames(for: snapshot)
        if !frames.isEmpty { onFrames?(frames) }
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    // MARK: - LED decoding (pure, test-covered)

    /// Decode a lit square set into the unique legal move it indicates.
    ///
    /// - Exactly two lit squares are required (from + to, either order).
    /// - When several legal moves share the pair (the four promotion
    ///   variants), the queen promotion is chosen — the emulator's stand-in
    ///   for the human picking a piece.
    /// - Castling: the host lights the king's from/to (e.g. e1+g1), which
    ///   matches only the castle move.
    public static func moveForLEDSquares(_ squares: [String], position: Position) -> String? {
        guard squares.count == 2 else { return nil }
        let pair = Set(squares.map { $0.lowercased() })
        let matches = MoveGenerator.legalMoves(for: position).filter {
            Set([$0.from.algebraic, $0.to.algebraic]) == pair
        }
        guard !matches.isEmpty else { return nil }
        if matches.count == 1 { return matches[0].uci }
        // Promotion family: prefer the queen.
        if let queen = matches.first(where: { $0.promotion == .queen }) {
            return queen.uci
        }
        return matches[0].uci
    }
}
