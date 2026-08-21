import Foundation
import Testing
@testable import Cards

/// Defensive throwing (§3) and human imperfection (§4): jailing, small cards
/// first, softmax noise — all through the public throw stacks only.
struct BotDiscardTests {
    private let expert = RummyBot(level: .expert)

    private func fillerHands(excluding used: [Card]) -> [[Card]] {
        let usedIDs = Set(used.map(\.id))
        let pool = Card.fullDeck().filter { !$0.isJoker && !usedIDs.contains($0.id) }
        return [Array(pool.prefix(10)), Array(pool.dropFirst(10).prefix(10)),
                Array(pool.dropFirst(20).prefix(10))]
    }

    private func state(
        hand: [Card], archetype: BotArchetype = .blocker, frustration: Double = 0.2,
        nextTakes: [Card] = [], turnsCompleted: Int = 8, myScore: Int = 0
    ) -> RummyState {
        let filler = fillerHands(excluding: hand + nextTakes)
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [filler[0], hand, filler[1], filler[2]],
            turnsCompleted: turnsCompleted)
        s.players[2].takenThrows = nextTakes
        s.players[1].totalScore = myScore
        s.botMinds = [.neutral, BotMind(archetype: archetype, frustration: frustration), .neutral, .neutral]
        return s
    }

    private func discard(_ s: RummyState, bot: RummyBot, seed: UInt64 = 5) -> Card {
        var rng = SeededRNG(seed: seed)
        let action = bot.decide(PublicGameView(state: s, seat: 1), rng: &rng)
        guard case .throwCard(let card) = action else {
            Issue.record("expected a throw, got \(action)")
            return TestCards.card(.two, .clubs)
        }
        return card
    }

    // MARK: - Card jailing

    @Test func dangerousCardStaysJailed() {
        // Deadwood: 2♦ (safe, cheap) and 8♥ (next player just took 7♥ and
        // 9♥). Pure value says dump the 8; a human jails it and eats the
        // worse keep to starve the neighbor.
        let hand = [
            TestCards.card(.three, .spades), TestCards.card(.four, .spades), TestCards.card(.five, .spades),
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.eight, .hearts), TestCards.card(.two, .diamonds),
        ]
        let takes = [TestCards.card(.seven, .hearts), TestCards.card(.nine, .hearts)]
        let s = state(hand: hand, nextTakes: takes)
        for seed in UInt64(0)..<20 {
            #expect(discard(s, bot: expert, seed: seed).rank != .eight, "8♥ must stay in jail")
        }
    }

    @Test func beginnerDoesNotJail() {
        let hand = [
            TestCards.card(.three, .spades), TestCards.card(.four, .spades), TestCards.card(.five, .spades),
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.eight, .hearts), TestCards.card(.two, .diamonds),
        ]
        let takes = [TestCards.card(.seven, .hearts), TestCards.card(.nine, .hearts)]
        let s = state(hand: hand, nextTakes: takes)
        var threwTheHotCard = false
        for seed in UInt64(0)..<40 where discard(s, bot: RummyBot(level: .beginner), seed: seed).rank == .eight {
            threwTheHotCard = true
        }
        #expect(threwTheHotCard, "a beginner shouldn't reliably starve the next player")
    }

    @Test func jailOpensWhenEveryOptionIsHot() {
        // Both deadwood cards sit in the next player's hot zone: the bot still
        // has to throw something legal.
        let hand = [
            TestCards.card(.three, .spades), TestCards.card(.four, .spades), TestCards.card(.five, .spades),
            TestCards.card(.eight, .hearts), TestCards.card(.six, .hearts),
        ]
        let takes = [TestCards.card(.seven, .hearts), TestCards.card(.seven, .clubs), TestCards.card(.seven, .spades)]
        let s = state(hand: hand, nextTakes: takes)
        let thrown = discard(s, bot: expert)
        #expect(hand.contains(thrown))
    }

    // MARK: - Small cards first (§3)

    @Test func earlyRoundThrowsSmallFirst() {
        // Both loose cards are safe; early round → deny cheap progress: the
        // expert gives away the 3, not the King.
        let hand = [
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.six, .diamonds), TestCards.card(.seven, .diamonds), TestCards.card(.eight, .diamonds),
            TestCards.card(.king, .hearts), TestCards.card(.three, .spades),
        ]
        let s = state(hand: hand, turnsCompleted: 5)
        for seed in UInt64(0)..<10 {
            #expect(discard(s, bot: expert, seed: seed).rank == .three)
        }
    }

    @Test func lateRoundDumpsExpensiveDeadwood() {
        let hand = [
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.six, .diamonds), TestCards.card(.seven, .diamonds), TestCards.card(.eight, .diamonds),
            TestCards.card(.king, .hearts), TestCards.card(.three, .spades),
        ]
        var s = state(hand: hand, turnsCompleted: 40)
        s.players[3].hasLaidDown = true   // someone banked: points now real
        for seed in UInt64(0)..<10 {
            #expect(discard(s, bot: expert, seed: seed).rank == .king)
        }
    }

    @Test func nearEliminationDumpsHighCardsEvenEarly() {
        let hand = [
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.six, .diamonds), TestCards.card(.seven, .diamonds), TestCards.card(.eight, .diamonds),
            TestCards.card(.king, .hearts), TestCards.card(.three, .spades),
        ]
        let s = state(hand: hand, turnsCompleted: 5, myScore: 720)
        for seed in UInt64(0)..<10 {
            #expect(discard(s, bot: expert, seed: seed).rank == .king)
        }
    }

    // MARK: - Softmax imperfection (§4)

    @Test func expertIsNearGreedyBeginnerWanders() {
        let hand = [
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.two, .spades), TestCards.card(.five, .hearts), TestCards.card(.seven, .diamonds),
            TestCards.card(.queen, .hearts), TestCards.card(.four, .diamonds),
        ]
        let s = state(hand: hand, turnsCompleted: 20)
        func spread(_ bot: RummyBot) -> Int {
            var seen = Set<Int>()
            for seed in UInt64(0)..<60 { seen.insert(discard(s, bot: bot, seed: seed).id) }
            return seen.count
        }
        let expertSpread = spread(expert)
        let beginnerSpread = spread(RummyBot(level: .beginner))
        #expect(expertSpread <= 2, "expert throws are consistent")
        #expect(beginnerSpread > expertSpread, "beginners visibly wobble")
    }

    @Test func jokerIsNeverThrown() {
        let hand = [TestCards.joker(0), TestCards.card(.two, .spades), TestCards.card(.nine, .diamonds)]
        let s = state(hand: hand, turnsCompleted: 8)
        for seed in UInt64(0)..<20 {
            #expect(!discard(s, bot: RummyBot(level: .beginner), seed: seed).isJoker)
        }
    }

    @Test func penalizedThrowStillAvoided() {
        // 8♠ extends the table run — throwing it costs +10, so it never goes
        // while a legal card exists.
        let hand = [TestCards.card(.eight, .spades), TestCards.card(.two, .hearts)]
        var s = state(hand: hand, turnsCompleted: 8)
        s.players[3].hasLaidDown = true
        s.tableMelds = [TableMeld(id: UUID(), ownerSeat: 3,
                                  meld: TestCards.run(.spades, .five, .six, .seven))]
        for seed in UInt64(0)..<20 {
            let bot = RummyBot(level: .beginner)
            var rng = SeededRNG(seed: seed)
            let action = bot.decide(PublicGameView(state: s, seat: 1), rng: &rng)
            if case .throwCard(let card) = action {
                #expect(card.rank != .eight)
            }
        }
    }
}
