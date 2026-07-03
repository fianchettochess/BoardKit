import Foundation
import ChessCore

/// Pure square-geometry helpers for physical chess board integration.
///
/// Board reports occupancy in FILE-MAJOR order (a1=0, a2=1, …, a8=7, b1=8, …,
/// h8=63) while the app's `Position.board` is rank-major — these helpers own that
/// mapping plus the 180° orientation flip so sessions sharing this type can't drift.
/// Renamed from SquareOffGeometry on 2026-07-03.
public enum ChessBoardGeometry {

    /// Apply a 180° board rotation to a square name. a1 ↔ h8, e4 ↔ d5, etc.
    /// Used by the `orientationFlipped` path so events arriving in the
    /// physical board's frame can be translated into the app's frame.
    /// Returns nil for malformed input (the caller falls back to the
    /// original string so we never silently substitute a wrong square).
    public nonisolated static func flippedSquare(_ square: String) -> String? {
        let chars = Array(square)
        guard chars.count == 2,
              let fileScalar = chars[0].asciiValue,
              let rankScalar = chars[1].asciiValue,
              let aScalar = Character("a").asciiValue,
              let oneScalar = Character("1").asciiValue else { return nil }
        let file = Int(fileScalar) - Int(aScalar)
        let rank = Int(rankScalar) - Int(oneScalar)
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        let flippedFile = Character(UnicodeScalar(UInt8(Int(aScalar) + 7 - file)))
        let flippedRank = Character(UnicodeScalar(UInt8(Int(oneScalar) + 7 - rank)))
        return "\(flippedFile)\(flippedRank)"
    }

    /// Convert a square like "e4" to the board's file-major occupancy index
    /// (a1=0, a2=1, …, a8=7, b1=8, … h8=63). Nil for malformed input.
    public nonisolated static func boardOccupancyIndex(for square: String) -> Int? {
        let chars = Array(square)
        guard chars.count == 2,
              let fileScalar = chars[0].asciiValue,
              let rankScalar = chars[1].asciiValue,
              let aScalar = Character("a").asciiValue,
              let oneScalar = Character("1").asciiValue else { return nil }
        let file = Int(fileScalar - aScalar)
        let rank = Int(rankScalar - oneScalar)
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        return file * 8 + rank
    }

    /// Square names (a1..h8) whose occupancy disagrees between the app's
    /// expected `position` and the board's reported file-major `boardOccupancy`.
    /// Empty for a malformed snapshot.
    public nonisolated static func mismatchedSquares(position: Position, boardOccupancy: [Bool]) -> [String] {
        guard boardOccupancy.count == 64 else { return [] }
        let files = Array("abcdefgh")
        var out: [String] = []
        for file in 0..<8 {
            for rank in 0..<8 {
                // App stores [Piece?] in rank-major order: index = rank * 8 + file.
                let appHasPiece = (position.board[rank * 8 + file] != nil)
                // Board reports occupancy in file-major order: index = file * 8 + rank.
                let boardHasPiece = boardOccupancy[file * 8 + rank]
                if appHasPiece != boardHasPiece {
                    out.append("\(files[file])\(rank + 1)")
                }
            }
        }
        return out
    }
}
