import Testing
import BoardKit

/// Covers `ChessBoardGeometry` — the pure square-geometry helpers shared
/// between physical board sessions.
struct ChessBoardGeometryTests {

    // MARK: - flippedSquare

    @Test func testFlippedSquareSwapsCorners() {
        #expect(ChessBoardGeometry.flippedSquare("a1") == "h8")
        #expect(ChessBoardGeometry.flippedSquare("h8") == "a1")
        #expect(ChessBoardGeometry.flippedSquare("a8") == "h1")
        #expect(ChessBoardGeometry.flippedSquare("h1") == "a8")
    }

    @Test func testFlippedSquareReflectsCenter() {
        // The center 2x2 swaps as e4↔d5, e5↔d4, etc.
        #expect(ChessBoardGeometry.flippedSquare("e4") == "d5")
        #expect(ChessBoardGeometry.flippedSquare("d5") == "e4")
        #expect(ChessBoardGeometry.flippedSquare("e5") == "d4")
        #expect(ChessBoardGeometry.flippedSquare("d4") == "e5")
    }

    @Test func testFlippedSquareIsItsOwnInverse() throws {
        // Property check: applying flip twice returns the original.
        for file in 0..<8 {
            for rank in 0..<8 {
                let f = Character(UnicodeScalar(Int(Character("a").asciiValue!) + file)!)
                let r = Character(UnicodeScalar(Int(Character("1").asciiValue!) + rank)!)
                let original = "\(f)\(r)"
                let flipped = try #require(ChessBoardGeometry.flippedSquare(original),
                                            "flippedSquare returned nil for \(original)")
                let back = try #require(ChessBoardGeometry.flippedSquare(flipped),
                                         "flippedSquare returned nil for \(flipped)")
                #expect(back == original, "flip(flip(\(original))) should equal \(original)")
            }
        }
    }

    @Test func testFlippedSquareReturnsNilForMalformedInput() {
        #expect(ChessBoardGeometry.flippedSquare("") == nil)
        #expect(ChessBoardGeometry.flippedSquare("a") == nil)
        #expect(ChessBoardGeometry.flippedSquare("a9") == nil)
        #expect(ChessBoardGeometry.flippedSquare("i1") == nil)
        #expect(ChessBoardGeometry.flippedSquare("e44") == nil)
    }
}
