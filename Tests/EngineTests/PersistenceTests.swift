import Foundation
import Testing
@testable import Cards

struct PersistenceTests {
    private func temporaryStore() -> GameStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamestore-tests-\(UUID().uuidString)", isDirectory: true)
        return GameStore(directory: dir)
    }

    @Test func activeGameRoundTrips() async throws {
        let store = temporaryStore()
        var rng = SeededRNG(seed: 11)
        var state = RamiEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        state = try RamiEngine.apply(.deal(.p2111), by: 2, to: state, rng: &rng)
        await store.saveActiveGame(state)
        let loaded = await store.loadActiveGame()
        #expect(loaded == state)
        await store.clearActiveGame()
        #expect(await store.loadActiveGame() == nil)
    }

    @Test func historyAppendsAndDeduplicates() async throws {
        let store = temporaryStore()
        var rng = SeededRNG(seed: 12)
        let state = RamiEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 0, rng: &rng)
        let placements = (0..<4).map { FinalPlacement(seat: $0, place: $0 + 1, score: $0 * 100) }
        let record = MatchRecord(state: state, placements: placements, endedAt: Date())
        await store.appendToHistory(record)
        await store.appendToHistory(record)
        let history = await store.loadHistory()
        #expect(history.count == 1)
        #expect(history[0].id == state.matchID)
        #expect(history[0].placements == placements)
    }

    @Test func corruptedFilesAreTreatedAsAbsent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamestore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("active-game.json"))
        try Data("nope".utf8).write(to: dir.appendingPathComponent("history.json"))
        let store = GameStore(directory: dir)
        #expect(await store.loadActiveGame() == nil)
        #expect(await store.loadHistory().isEmpty)
    }
}
