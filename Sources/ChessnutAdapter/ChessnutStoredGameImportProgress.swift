/// Progress of one Chessnut archive download since the adapter's last reset.
/// File boundaries count even when a corrupt or empty file yields no game.
public struct ChessnutStoredGameImportProgress: Equatable, Sendable {
    /// Nil until the board answers the catalog query; zero means an empty archive.
    public let expectedFileCount: Int?
    public let completedFileCount: Int
    public let isReceivingFile: Bool

    /// Completion requires a catalog reply and every advertised file end.
    /// No elapsed-time heuristic or number of recovered games is involved.
    public var isFinished: Bool {
        guard let expectedFileCount else { return false }
        return completedFileCount == expectedFileCount && !isReceivingFile
    }
}
