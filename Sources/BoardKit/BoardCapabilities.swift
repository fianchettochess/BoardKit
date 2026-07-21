/// Feature flags describing a physical chess board's hardware capabilities.
///
/// Each concrete `BoardAdapter` exposes a `capabilities: BoardCapabilities`
/// value. The session layer uses it to select the appropriate kernel path
/// (occupancy-only vs. identity-aware) and re-reads it after the handshake for
/// adapters whose capabilities depend on board detection or calibration.
///
/// A declared flag means the adapter implements that capability; it does not
/// imply that the capability has been exercised on every target board. See the
/// repository README for the canonical hardware-status and capability tables.
/// Millennium, for example, declares `.moveIndication` for its 9×9 corner-LED
/// grid but not `.perSquareLEDs`.
public struct BoardCapabilities: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Per-square lift/place occupancy sensing. All boards in scope.
    public static let occupancySensing = BoardCapabilities(rawValue: 1 << 0)

    /// Piece type + color per square (Chessnut, Certabo, Millennium,
    /// DGT Classic boards). When set, `BoardEvent.squareSensed` carries a
    /// non-nil `piece` field and the adapter emits `identitySnapshot`
    /// instead of (or in addition to) `occupancySnapshot`.
    public static let pieceIdentity    = BoardCapabilities(rawValue: 1 << 1)

    /// Individually addressable per-square LEDs (Square Off, Chessnut,
    /// Certabo, most modern boards). `BoardCommand.indicateSquares` is
    /// fully honored; every listed square can be lit independently.
    public static let perSquareLEDs    = BoardCapabilities(rawValue: 1 << 2)

    /// Any move-indication capability: set whenever the board can highlight
    /// squares in some way, even if it uses corner LEDs rather than
    /// per-square ones. Callers check this before sending
    /// `BoardCommand.indicateSquares`; callers that need per-square
    /// control also check `.perSquareLEDs`.
    public static let moveIndication   = BoardCapabilities(rawValue: 1 << 3)

    /// Motorized auto-move (currently declared by Chessnut Move). When set,
    /// the board can physically move pieces to execute engine replies without
    /// human intervention. Square Off GKS hardware is motorized, but its
    /// adapter does not declare this flag while the command remains
    /// quarantined pending wire-format verification.
    public static let motorised        = BoardCapabilities(rawValue: 1 << 4)

    /// Reports battery level via `BoardEvent.battery(percent:)`.
    public static let batteryReporting = BoardCapabilities(rawValue: 1 << 5)

    /// True per-piece unique identity (Chessnut Move's 34 micro-robot
    /// pieces). Implies `.pieceIdentity`. The board supports per-piece
    /// status polling via opcode 0x0B; the adapter surfaces those
    /// responses as `.raw` pending a dedicated `BoardEvent` case.
    /// `identitySnapshot` carries type+color per square (same as
    /// `.pieceIdentity`), not per-robot object identity.  Session code
    /// should use `BoardAdapter.pieceStatusRequestData()` and parse
    /// `.raw` payloads directly rather than expecting `identitySnapshot`
    /// to carry per-robot tracking data.
    public static let perPieceTracking = BoardCapabilities(rawValue: 1 << 6)

    /// The board records completed games to internal flash and can replay
    /// them to the host. When set, `BoardCommand.requestStoredGames` is
    /// honored and the adapter emits `BoardEvent.storedGameImported` per
    /// game. Chessnut Air family (Air, Air+, Pro, Go) set this; occupancy-only
    /// and stateless boards do not.
    public static let gameArchive      = BoardCapabilities(rawValue: 1 << 7)

    // MARK: - Convenience presets

    /// Capabilities common to the Chessnut Air family (Air, Air+, Pro, Go).
    ///
    /// Note: Air+ supports multicolor LEDs via the standard LED command;
    /// that is a wire-level style extension, not a distinct capability bit.
    public static let chessnutAirFamily: BoardCapabilities = [
        .occupancySensing, .pieceIdentity, .perSquareLEDs,
        .moveIndication, .batteryReporting, .gameArchive
    ]

    /// Capabilities currently exposed by the Square Off adapter. The GKS
    /// motor command remains quarantined, so `.motorised` is not declared.
    public static let squareOff: BoardCapabilities = [
        .occupancySensing, .perSquareLEDs, .moveIndication
    ]
}
