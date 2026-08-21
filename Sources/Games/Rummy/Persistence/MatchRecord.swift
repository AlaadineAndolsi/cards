import Foundation

/// A finished match, as stored in the history file.
struct MatchRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let config: RulesConfig
    let playerNames: [String]
    let humanSeat: Int
    /// Per seat, one entry per round; nil = abandoned round or already eliminated.
    let roundScores: [[Int?]]
    let finalScores: [Int]
    let placements: [FinalPlacement]

    init(state: RummyState, placements: [FinalPlacement], endedAt: Date) {
        self.id = state.matchID
        self.startedAt = state.startedAt
        self.endedAt = endedAt
        self.config = state.config
        self.playerNames = state.players.map(\.name)
        self.humanSeat = state.players.firstIndex(where: \.isHuman) ?? 0
        self.roundScores = state.players.map(\.roundScores)
        self.finalScores = state.players.map(\.totalScore)
        self.placements = placements
    }
}
