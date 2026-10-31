/// Progress of one Chessnut archive download since the adapter's last reset.
/// File boundaries count even when a corrupt or empty file yields no game.
public struct ChessnutStoredGameImportProgress: Equatable, Sendable {
    /// Nil until the board answers the catalog query; zero means an empty archive.
    public let expectedFileCount: Int?
    public let completedFileCount: Int
    public let isReceivingFile: Bool
    /// Advertised files the adapter will never request, because a runaway
    /// transfer ended the import. Non-zero means the archive was only partly read.
    public let abandonedFileCount: Int

    /// Completion requires a catalog reply and an end for every advertised file,
    /// whether its end flag arrived or the adapter abandoned it.
    /// No elapsed-time heuristic or number of recovered games is involved.
    public var isFinished: Bool {
        guard let expectedFileCount else { return false }
        return completedFileCount + abandonedFileCount == expectedFileCount && !isReceivingFile
    }
}
