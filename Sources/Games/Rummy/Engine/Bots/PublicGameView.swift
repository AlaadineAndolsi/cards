import Foundation

/// Everything a bot is allowed to know: its own hand plus information that is
/// public at the table. Built by copying — other hands and the pile order are
/// physically absent, so bots cannot peek by construction.
struct PublicGameView: Sendable {
    struct Player: Sendable {
        let name: String
        let handCount: Int
        let throwStack: [Card]
        let takenThrows: [Card]
        let hasLaidDown: Bool
        let isEliminated: Bool
        let totalScore: Int
    }

    let seat: Int
    let hand: [Card]
    let config: RulesConfig
    let phase: Phase
    let dealerSeat: Int
    let drawPileCount: Int
    let tableMelds: [TableMeld]
    let players: [Player]
    let requiredLayDown: Int
    let throwTakeUnlocked: Bool
    let takeableCard: Card?
    let turnsCompletedThisRound: Int
    let aliveCount: Int
    let hasLaidDown: Bool
    /// Own unconfirmed lay-down total this turn (threshold checks at the throw).
    let pendingLayDownValue: Int?
    /// Own temperament + tilt (falls back to a neutral mind for old saves).
    let mind: BotMind

    init(state: RummyState, seat: Int) {
        self.seat = seat
        self.hand = state.players[seat].hand
        self.config = state.config
        self.phase = state.phase
        self.dealerSeat = state.dealerSeat
        self.drawPileCount = state.drawPile.count
        self.tableMelds = state.tableMelds
        self.players = state.players.map {
            Player(
                name: $0.name, handCount: $0.hand.count, throwStack: $0.throwStack,
                takenThrows: $0.takenThrows, hasLaidDown: $0.hasLaidDown,
                isEliminated: $0.isEliminated, totalScore: $0.totalScore)
        }
        self.requiredLayDown = state.requiredLayDown
        self.throwTakeUnlocked = state.throwTakeUnlocked
        self.takeableCard = state.takeableThrow(for: seat)
        self.turnsCompletedThisRound = state.turnsCompletedThisRound
        self.aliveCount = state.aliveCount
        self.hasLaidDown = state.players[seat].hasLaidDown
        self.pendingLayDownValue = state.players[seat].pendingLayDownValue
        if let minds = state.botMinds, minds.indices.contains(seat) {
            self.mind = minds[seat]
        } else {
            self.mind = .neutral
        }
    }

    var nextAliveSeat: Int {
        var next = seat
        repeat { next = (next + 1) % players.count } while players[next].isEliminated
        return next
    }

    /// Every card currently visible to everyone (throw stacks + table melds).
    var visibleCards: [Card] {
        players.flatMap(\.throwStack) + tableMelds.flatMap { $0.meld.cards }
    }
}
