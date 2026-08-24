import Foundation

struct RulesConfig: Codable, Hashable, Sendable {
    var minimumLayDown: Int
    var eliminationScore: Int
    var botLevel: BotLevel

    static let `default` = RulesConfig(minimumLayDown: 61, eliminationScore: 800, botLevel: .expert)

    static let minimumLayDownRange = 41...101
    static let eliminationScoreRange = 300...2000
}

enum BotLevel: Int, Codable, CaseIterable, Hashable, Sendable {
    case beginner = 1, intermediate = 2, expert = 3
}

struct PlayerState: Codable, Hashable, Sendable {
    var name: String
    var isHuman: Bool
    var hand: [Card] = []
    var throwStack: [Card] = []
    var hasLaidDown = false
    /// Total of series laid this turn before the first lay-down is confirmed.
    /// Table touch rule: a laid series never comes back. The threshold is only
    /// checked when the turn ends with a throw: enough confirms the lay-down,
    /// short means +100 and the round stops.
    var pendingLayDownValue: Int?
    var isEliminated = false
    var totalScore = 0
    /// +10 per wasted throw (joker or meld-fitting card); settled at round end.
    var penaltiesThisRound = 0
    var roundScores: [Int?] = []   // nil = abandoned (fully passed) round
    /// Cards this player took from throws this round — public info for bots.
    var takenThrows: [Card] = []
    /// The very first card this player threw this round: it can NEVER be
    /// taken, even after the global take unlock, and even if takes drain
    /// the stack back down to it. Cleared when a pile reshuffle recycles
    /// the throws. Optional so older saves keep decoding.
    var firstThrowID: Int? = nil
}

struct TableMeld: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var ownerSeat: Int
    var meld: Meld
}

enum DrawSource: Codable, Hashable, Sendable {
    case pile          // purchased from the face-down pile
    case takenThrow    // took the previous player's last throw
    case dealt         // dealer's first turn: the 15th card replaces the draw
}

enum TurnStage: Codable, Hashable, Sendable {
    case awaitingDraw
    /// Player has 15 cards and may lay down / append / swap before throwing.
    /// `pendingJoker` is a joker swapped off the table that must be re-melded
    /// before the turn can end.
    case awaitingThrow(drew: DrawSource, pendingJoker: Card?)
}

struct RoundResult: Codable, Hashable, Sendable {
    var closerSeat: Int?
    var deltas: [Int]            // per seat, 0 for eliminated non-participants
    var newlyEliminated: [Int]
}

struct FinalPlacement: Codable, Hashable, Sendable {
    var seat: Int
    var place: Int   // 1...4
    var score: Int
}

enum Phase: Codable, Hashable, Sendable {
    /// Dealer may shuffle repeatedly, then deal with a chosen pattern.
    case dealing(shuffles: Int)
    /// Round-pass vote. `currentSeat` is who must speak next. Reached only
    /// while everyone so far has passed/proposed.
    case vote(proposerSeat: Int, currentSeat: Int)
    case turn(seat: Int, TurnStage)
    case roundEnded(RoundResult)
    case matchEnded([FinalPlacement])
}

struct RummyState: Codable, Hashable, Sendable {
    var config: RulesConfig
    var players: [PlayerState]      // 4 seats; seat 0 = human; turn order = ascending seat, wrapping
    var dealerSeat: Int
    var phase: Phase
    var drawPile: [Card]
    var tableMelds: [TableMeld] = []
    /// Cards from destroyed melds — a same-rank set that filled to four
    /// bursts off the table (jokers included). Invisible to everyone, but
    /// they rejoin the game when the exhausted draw pile is rebuilt from
    /// the throws. Optional so saves from before the rule keep decoding.
    var destroyedCards: [Card]? = nil
    var roundNumber = 1
    /// Escalation chain: most recent *initial* lay-down total this round.
    var lastInitialLayDownTotal: Int?
    var turnsCompletedThisRound = 0
    var eliminationOrder: [Int] = []
    /// Pattern used for the most recent deal (drives the deal animation).
    var lastDealPattern: DealPattern?
    /// One mind per seat (human's is an inert placeholder). Optional so saves
    /// from before the psychology layer keep decoding; engine seeds it lazily.
    var botMinds: [BotMind]? = nil
    var startedAt: Date
    var matchID: UUID

    var aliveCount: Int { players.filter { !$0.isEliminated }.count }

    func nextAliveSeat(after seat: Int) -> Int {
        var next = seat
        repeat { next = (next + 1) % players.count } while players[next].isEliminated
        return next
    }

    func previousAliveSeat(before seat: Int) -> Int {
        var prev = seat
        repeat { prev = (prev + players.count - 1) % players.count } while players[prev].isEliminated
        return prev
    }

    /// Total a player's *first* lay-down must reach right now.
    var requiredLayDown: Int {
        lastInitialLayDownTotal.map { $0 + 1 } ?? config.minimumLayDown
    }

    /// Throw-taking unlocks once every alive player has completed one turn.
    var throwTakeUnlocked: Bool { turnsCompletedThisRound >= aliveCount }

    /// The card a player could take right now (previous alive player's last
    /// throw) — nil when that card is the thrower's protected FIRST throw
    /// of the round: none of the four opening throws can ever be picked.
    func takeableThrow(for seat: Int) -> Card? {
        let previous = players[previousAliveSeat(before: seat)]
        guard let card = previous.throwStack.last,
              card.id != previous.firstThrowID else { return nil }
        return card
    }
}
