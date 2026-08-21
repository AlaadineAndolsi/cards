import Foundation

/// JSON persistence in Application Support: one file for the active game
/// snapshot (autosaved after every action) and one for match history.
actor GameStore {
    private let directory: URL
    private var activeURL: URL { directory.appendingPathComponent("active-game.json") }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("TunisianCards", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: Active game

    func saveActiveGame(_ state: RummyState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: activeURL, options: .atomic)
    }

    func loadActiveGame() -> RummyState? {
        guard let data = try? Data(contentsOf: activeURL) else { return nil }
        return try? JSONDecoder().decode(RummyState.self, from: data)
    }

    func clearActiveGame() {
        try? FileManager.default.removeItem(at: activeURL)
    }

    // MARK: History

    func loadHistory() -> [MatchRecord] {
        guard let data = try? Data(contentsOf: historyURL),
              let records = try? JSONDecoder().decode([MatchRecord].self, from: data)
        else { return [] }
        return records.sorted { $0.endedAt > $1.endedAt }
    }

    func appendToHistory(_ record: MatchRecord) {
        var records = loadHistory()
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}
