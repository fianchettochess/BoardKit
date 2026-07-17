import Testing
import Foundation
import ChessCore
import BoardKit
import SquareOffAdapter

/// Direct coverage for the SquareOff codec. Previously SquareOff was the only
/// adapter without a dedicated test — its `"30#<64 bits>*"` occupancy byte-order
/// (file-major) is load-bearing for every occupancy-inferred move, and the
/// framer's split/coalesce/over-cap handling was only exercised indirectly via
/// emulator loopback. This locks both.
@Suite("SquareOff adapter")
struct SquareOffAdapterTests {

    /// A `"30#<64 bits>*"` board-state frame from file-major occupied indices.
    private func boardStateFrame(occupied: Set<Int>) -> Data {
        let bits = (0..<64).map { occupied.contains($0) ? "1" : "0" }.joined()
        return Data("30#\(bits)*".utf8)
    }

    private func occupancy(from events: [BoardEvent]) -> [Bool]? {
        for e in events { if case .occupancySnapshot(let occ) = e { return occ } }
        return nil
    }

    private func fileMajor(_ sq: String) -> Int {
        let s = Square(algebraic: sq)!
        return s.file * 8 + s.rank
    }

    @Test("Board-state occupancy is file-major (a1=0 … a8=7, b1=8 … h8=63)")
    func occupancyIsFileMajor() throws {
        var adapter = SquareOffAdapter()
        // a2 = file 0, rank 1 → index 1; e4 = file 4, rank 3 → index 35.
        let events = adapter.feed(bytes: boardStateFrame(occupied: [1, 35]))
        let occ = try #require(occupancy(from: events))
        #expect(occ.count == 64)
        #expect(occ[fileMajor("a2")])
        #expect(occ[fileMajor("e4")])
        #expect(occ.filter { $0 }.count == 2)
        #expect(!occ[fileMajor("a1")] && !occ[fileMajor("h8")] && !occ[fileMajor("b1")])
    }

    @Test("A short (<64) board-state body is not decoded as occupancy")
    func shortBoardStateIsNotOccupancy() {
        var adapter = SquareOffAdapter()
        let events = adapter.feed(bytes: Data("30#\(String(repeating: "1", count: 32))*".utf8))
        #expect(occupancy(from: events) == nil)   // parser rejects → adapter emits .raw
    }

    @Test("Field update decodes to a squareSensed lift/place")
    func fieldUpdate() {
        var adapter = SquareOffAdapter()
        let lift = adapter.feed(bytes: Data("0#e2u*".utf8))
        #expect(lift.contains { if case .squareSensed("e2", true, _) = $0 { return true }; return false })
        let place = adapter.feed(bytes: Data("0#e4d*".utf8))
        #expect(place.contains { if case .squareSensed("e4", false, _) = $0 { return true }; return false })
    }

    @Test("A frame split across two feeds reassembles into one snapshot")
    func splitFrameReassembles() throws {
        var adapter = SquareOffAdapter()
        let whole = boardStateFrame(occupied: [1])
        let cut = whole.count / 2
        #expect(adapter.feed(bytes: Data(whole[..<cut])).isEmpty)   // incomplete: no event yet
        let occ = try #require(occupancy(from: adapter.feed(bytes: Data(whole[cut...]))))
        #expect(occ[1] && occ.filter { $0 }.count == 1)
    }

    @Test("Two concatenated frames in one feed yield two events")
    func coalescedFrames() {
        var adapter = SquareOffAdapter()
        var blob = Data("0#e2u*".utf8); blob.append(Data("0#e4d*".utf8))
        #expect(adapter.feed(bytes: blob).count == 2)
    }

    @Test("An unterminated over-cap buffer is dropped without wedging the framer")
    func overCapBufferDropped() {
        var adapter = SquareOffAdapter()
        // > 64 KB with no '*' terminator: the framer caps + drops rather than grow.
        let junk = Data(String(repeating: "x", count: 70_000).utf8)
        #expect(adapter.feed(bytes: junk).isEmpty)
        // A subsequent valid frame still parses (the buffer was reset, not stuck).
        let ok = adapter.feed(bytes: Data("0#e2u*".utf8))
        #expect(ok.contains { if case .squareSensed("e2", true, _) = $0 { return true }; return false })
    }
}
