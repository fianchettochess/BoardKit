import Foundation
import ChessCore
import BoardKit

/// A virtual chess board that applies ChessCore moves to a position and
/// emits the corresponding physical sensor events.
///
/// Bypasses byte decoding — tests session logic directly. Pair with
/// `ReplayTransport` only when the byte-decode path also needs coverage.
///
/// ## Event semantics
///
/// When `capabilities` contains `.pieceIdentity`, every `squareSensed`
/// event carries the `piece` field populated from the position's board
/// array. Otherwise `piece: nil` (occupancy-only path).
///
/// ### Move type → event sequence
///
/// | Move type           | Events emitted (in order)                               |
/// |---------------------|---------------------------------------------------------|
/// | Simple (e2e4)       | lift(e2, piece), place(e4, piece)                       |
/// | Normal capture      | lift(from, mover), lift(to, captured), place(to, mover) |
/// | En-passant (e5d6)   | lift(e5, pawn), lift(d5, captured), place(d6, pawn)     |
/// | Castling (e1g1)     | lift(e1, K), lift(h1, R), place(f1, R), place(g1, K)    |
/// | Promotion (e7e8q)   | lift(e7, pawn), place(e8, queen)                        |
///
/// Castling emits rook-place before king-place (matches how a human
/// typically moves the rook first on a physical board in a king-first
/// castle; both orders are legal and the OccupancyMoveInference handles
/// both via its shape-#1 deferral path).
///
/// ## Usage
///
/// ```swift
/// let sim = SimulatedBoard()
/// let events = try await sim.executeMove(uci: "e2e4")
/// // events: [squareSensed("e2", isLift: true, piece: Piece(.pawn,.white)),
/// //          squareSensed("e4", isLift: false, piece: Piece(.pawn,.white))]
/// let snap = await sim.boardSnapshot()
/// // snap: .identitySnapshot([...])
/// ```
public actor SimulatedBoard {

    // MARK: - State

    private var _position: Position
    private let _capabilities: BoardCapabilities

    // MARK: - Init

    /// Create a simulated board.
    ///
    /// - Parameters:
    ///   - position: Starting position. Defaults to the initial chess position.
    ///   - capabilities: Controls whether `squareSensed` events carry
    ///     piece identity. Defaults to occupancy-only (`.occupancySensing`).
    public init(
        position: Position = .initial(),
        capabilities: BoardCapabilities = [.occupancySensing]
    ) {
        _position = position
        _capabilities = capabilities
    }

    // MARK: - Public interface

    /// The current position.
    public var position: Position { _position }

    /// The capabilities this board was created with.
    public var capabilities: BoardCapabilities { _capabilities }

    /// Apply `uci` to the current position and return the lift/place event
    /// sequence a physical board would emit.
    ///
    /// The position is advanced after computing the events so that
    /// subsequent calls start from the new position.
    ///
    /// - Throws: `SimulatedBoardError.illegalMove` if `uci` has no legal
    ///   match in the current position.
    public func executeMove(uci: String) throws -> [BoardEvent] {
        let legal = MoveGenerator.legalMoves(for: _position)
        guard let move = UCIParser.uciToMove(uci, in: legal) else {
            throw SimulatedBoardError.illegalMove(uci: uci, fen: _position.fen)
        }
        let events = physicalEvents(for: move, in: _position)
        MoveGenerator.applyMoveUnchecked(&_position, move)
        return events
    }

    /// Emit the current board as a snapshot event appropriate for the
    /// board's capabilities.
    ///
    /// - `.pieceIdentity` capability → `.identitySnapshot([Piece?])`
    /// - otherwise → `.occupancySnapshot([Bool])`
    ///
    /// Both arrays are file-major (a1=0…h8=63).
    public func boardSnapshot() -> BoardEvent {
        let fileMajor = fileMajorArray(from: _position)
        if _capabilities.contains(.pieceIdentity) {
            return .identitySnapshot(fileMajor)
        }
        return .occupancySnapshot(fileMajor.map { $0 != nil })
    }

    /// Reset to a new position without emitting events.
    public func reset(to position: Position = .initial()) {
        _position = position
    }

    // MARK: - Private helpers

    private func physicalEvents(for move: Move, in position: Position) -> [BoardEvent] {
        let withPiece = _capabilities.contains(.pieceIdentity)
        var events: [BoardEvent] = []

        let fromSq  = move.from.algebraic
        let toSq    = move.to.algebraic
        let moverPiece: Piece? = withPiece ? position[move.from] : nil

        if move.isCastling {
            // Castling: king-first lift, rook lift, rook place, king place.
            // The rook squares are inferred from the king's destination file.
            let rank = move.from.rank
            let (rookFromFile, rookToFile): (Int, Int) = move.to.file == 6
                ? (7, 5)   // kingside:  h-file → f-file
                : (0, 3)   // queenside: a-file → d-file
            let rookFromSq = Square(file: rookFromFile, rank: rank).algebraic
            let rookToSq   = Square(file: rookToFile,   rank: rank).algebraic
            let rookPiece: Piece? = withPiece ? position[Square(file: rookFromFile, rank: rank)] : nil

            events.append(.squareSensed(square: fromSq,    isLift: true,  piece: moverPiece))
            events.append(.squareSensed(square: rookFromSq, isLift: true, piece: rookPiece))
            events.append(.squareSensed(square: rookToSq,   isLift: false, piece: rookPiece))
            events.append(.squareSensed(square: toSq,       isLift: false, piece: moverPiece))
            return events
        }

        if move.isEnPassant {
            // En passant: capturing pawn lifts, captured pawn (same rank as
            // mover's from, same file as mover's to) lifts, mover places.
            let capturedSq = Square(file: move.to.file, rank: move.from.rank).algebraic
            let capturedPiece: Piece? = withPiece
                ? position[Square(file: move.to.file, rank: move.from.rank)]
                : nil
            events.append(.squareSensed(square: fromSq,     isLift: true,  piece: moverPiece))
            events.append(.squareSensed(square: capturedSq,  isLift: true,  piece: capturedPiece))
            events.append(.squareSensed(square: toSq,        isLift: false, piece: moverPiece))
            return events
        }

        // Normal capture: attacker lifts, captured piece lifts, attacker places.
        if move.capturedPiece != nil {
            let capturedPiece: Piece? = withPiece ? position[move.to] : nil
            events.append(.squareSensed(square: fromSq, isLift: true,  piece: moverPiece))
            events.append(.squareSensed(square: toSq,   isLift: true,  piece: capturedPiece))
            events.append(.squareSensed(square: toSq,   isLift: false, piece: moverPiece))
            return events
        }

        // Simple move (including promotion — the piece swap happens out-of-band
        // and is not modelled here; the physical lift/place is the same).
        // When this is a promotion, the placed piece is the promoted type in
        // the mover's colour.
        let placePiece: Piece?
        if withPiece, let promo = move.promotion, let color = moverPiece?.color {
            placePiece = Piece(type: promo, color: color)
        } else {
            placePiece = moverPiece
        }
        events.append(.squareSensed(square: fromSq, isLift: true,  piece: moverPiece))
        events.append(.squareSensed(square: toSq,   isLift: false, piece: placePiece))
        return events
    }

    /// Convert a Position to a file-major `[Piece?]` array (a1=0…h8=63).
    private func fileMajorArray(from position: Position) -> [Piece?] {
        // Position.board is rank-major (index = rank * 8 + file).
        // File-major index = file * 8 + rank.
        var out = [Piece?](repeating: nil, count: 64)
        for file in 0..<8 {
            for rank in 0..<8 {
                let rankMajor = rank * 8 + file     // Position.board index
                let fileMajor = file * 8 + rank     // BoardEvent array index
                out[fileMajor] = position.board[rankMajor]
            }
        }
        return out
    }
}

/// Errors thrown by `SimulatedBoard`.
public enum SimulatedBoardError: Error, Sendable {
    /// The UCI string has no legal match in the current position.
    case illegalMove(uci: String, fen: String)
}
