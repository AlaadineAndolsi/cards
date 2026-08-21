import Foundation
import Testing
@testable import Cards

/// The human objective ladder: close > lay-and-bleed > never eat the 100 —
/// with the glory hunt on top and elimination fear underneath.
struct BotStrategyTests {
    private let expert = RummyBot(level: .expert)

    /// 15-card hand at the throw step: four clean runs (92 points), a low pair
    /// and one stray — one card short of the glorious 14-card close.
    private var nearlyCompleteHand: [Card] {
        [TestCards.card(.three, .spades), TestCards.card(.four, .spades), TestCards.card(.five, .spades),
         TestCards.card(.six, .hearts), TestCards.card(.seven, .hearts), TestCards.card(.eight, .hearts),
         TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
         TestCards.card(.queen, .diamonds), TestCards.card(.king, .diamonds), TestCards.card(.ace, .diamonds),
         TestCards.card(.two, .hearts), TestCards.card(.two, .diamonds), TestCards.card(.seven, .diamonds)]
    }

    private func fillerHands(excluding used: [Card]) -> [[Card]] {
        let usedIDs = Set(used.map(\.id))
        let pool = Card.fullDeck().filter { !$0.isJoker && !usedIDs.contains($0.id) }
        return [Array(pool.prefix(10)), Array(pool.dropFirst(10).prefix(10)),
                Array(pool.dropFirst(20).prefix(10))]
    }

    private func throwTurnState(
        hand: [Card], archetype: BotArchetype, frustration: Double = 0.2,
        myScore: Int = 0, nextHandSize: Int = 10, pile: Int? = nil,
        lastInitialLayDown: Int? = nil, turnsCompleted: Int = 8
    ) -> RummyState {
        let filler = fillerHands(excluding: hand)
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [filler[0], hand, Array(filler[1].prefix(nextHandSize)), filler[2]],
            turnsCompleted: turnsCompleted,
            lastInitialLayDown: lastInitialLayDown)
        s.players[1].totalScore = myScore
        s.botMinds = [.neutral,
                      BotMind(archetype: archetype, frustration: frustration),
                      .neutral, .neutral]
        if let pile { s.drawPile = Array(s.drawPile.prefix(pile)) }
        return s
    }

    // MARK: - The glory hunt (§2)

    @Test func cushionedGloryHunterHoldsInsteadOfLaying() {
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .gloryHunter)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.objective(view) == .huntGloryClose)
        var rng = SeededRNG(seed: 1)
        let action = expert.decide(view, rng: &rng)
        guard case .throwCard = action else {
            Issue.record("hunter should keep the hand hidden, got \(action)")
            return
        }
    }

    @Test func cautiousAccountantSecuresTheSameHand() {
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .accountant)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.objective(view) != .huntGloryClose)
        var rng = SeededRNG(seed: 1)
        let action = expert.decide(view, rng: &rng)
        guard case .layDown = action else {
            Issue.record("accountant should bank the lay-down, got \(action)")
            return
        }
    }

    @Test func hunterBailsOutWhenAnOpponentRunsLow() {
        // Same hand, but the next player is down to 2 cards: heat spikes.
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .gloryHunter, nextHandSize: 2)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.objective(view) != .huntGloryClose)
        var rng = SeededRNG(seed: 1)
        let action = expert.decide(view, rng: &rng)
        guard case .layDown = action else {
            Issue.record("the hunt should be abandoned under pressure, got \(action)")
            return
        }
    }

    @Test func hunterBailsOutWhenThePileShrinks() {
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .gloryHunter, pile: 8)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.objective(view) != .huntGloryClose)
    }

    @Test func beginnerCommitsToGloryMoreRecklesslyThanExpertJudgesHeat() {
        // Moderate heat: an opponent at 4 cards. Expert bails, beginner stays.
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .gloryHunter, nextHandSize: 4)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.objective(view) != .huntGloryClose)
        #expect(RummyBot(level: .beginner).objective(view) == .huntGloryClose)
    }

    // MARK: - Elimination fear (§1)

    @Test func nearEliminationOverridesTheHunt() {
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .gloryHunter, myScore: 700)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.nearElimination(view))
        #expect(expert.objective(view) == .secureLayDown || expert.objective(view) == .panicLayDown)
        var rng = SeededRNG(seed: 1)
        let action = expert.decide(view, rng: &rng)
        guard case .layDown = action else {
            Issue.record("a bot at 700/800 must bank points now, got \(action)")
            return
        }
    }

    @Test func comfortableScoreIsNotNearElimination() {
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .accountant, myScore: 300)
        #expect(!expert.nearElimination(PublicGameView(state: s, seat: 1)))
    }

    // MARK: - Round heat / panic (§1.3)

    @Test func escalatedThresholdAndOldRoundPanic() {
        // Weak hand, threshold escalated to 76, deep round, thin pile.
        let weakHand = [TestCards.card(.two, .spades), TestCards.card(.five, .hearts),
                        TestCards.card(.nine, .diamonds), TestCards.card(.queen, .clubs),
                        TestCards.card(.three, .diamonds), TestCards.card(.jack, .hearts),
                        TestCards.card(.six, .clubs), TestCards.card(.ten, .spades)]
        let s = throwTurnState(hand: weakHand, archetype: .accountant, pile: 10,
                               lastInitialLayDown: 75, turnsCompleted: 60)
        let view = PublicGameView(state: s, seat: 1)
        #expect(expert.roundHeat(view) > 0.7)
        #expect(expert.objective(view) == .panicLayDown)
    }

    @Test func quietEarlyRoundIsCool() {
        let s = throwTurnState(hand: nearlyCompleteHand, archetype: .accountant)
        #expect(expert.roundHeat(PublicGameView(state: s, seat: 1)) < 0.4)
    }

    // MARK: - Closing beats everything (§1.1)

    @Test func fullCloseIsNeverPassedUp() {
        // 15 cards, exactly 14 meldable (three runs + a five-run), one throw.
        let hand = [
            TestCards.card(.three, .spades), TestCards.card(.four, .spades), TestCards.card(.five, .spades),
            TestCards.card(.six, .hearts), TestCards.card(.seven, .hearts), TestCards.card(.eight, .hearts),
            TestCards.card(.nine, .clubs), TestCards.card(.ten, .clubs), TestCards.card(.jack, .clubs),
            TestCards.card(.three, .diamonds), TestCards.card(.four, .diamonds), TestCards.card(.five, .diamonds),
            TestCards.card(.six, .diamonds), TestCards.card(.seven, .diamonds),
            TestCards.card(.queen, .spades),
        ]
        let s = throwTurnState(hand: hand, archetype: .gloryHunter)
        let view = PublicGameView(state: s, seat: 1)
        var rng = SeededRNG(seed: 1)
        let action = expert.decide(view, rng: &rng)
        guard case .layDown(let melds) = action else {
            Issue.record("expected the closing lay, got \(action)")
            return
        }
        #expect(melds.reduce(0) { $0 + $1.entries.count } == 14)
    }

    @Test func hunterTakesTheThrowThatCompletesTheSlam() {
        // 14 in hand, previous player just threw the King that closes it all.
        let hand = [TestCards.card(.three, .diamonds), TestCards.card(.four, .diamonds),
                    TestCards.card(.five, .diamonds), TestCards.card(.six, .diamonds),
                    TestCards.card(.seven, .diamonds),
                    TestCards.card(.six, .spades), TestCards.card(.seven, .spades), TestCards.card(.eight, .spades),
                    TestCards.card(.nine, .hearts), TestCards.card(.ten, .hearts), TestCards.card(.jack, .hearts),
                    TestCards.card(.king, .spades), TestCards.card(.king, .hearts),
                    TestCards.card(.nine, .clubs)]
        let filler = fillerHands(excluding: hand + [TestCards.card(.king, .diamonds)])
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingDraw,
            hands: [filler[0], hand, filler[1], filler[2]],
            throwStacks: [[TestCards.card(.king, .diamonds)], [], [], []],
            turnsCompleted: 8)
        s.botMinds = [.neutral, BotMind(archetype: .gloryHunter, frustration: 0.2), .neutral, .neutral]
        let view = PublicGameView(state: s, seat: 1)
        var rng = SeededRNG(seed: 1)
        let action = expert.decide(view, rng: &rng)
        guard case .takeThrowAndLayDown(let melds) = action else {
            Issue.record("expected take + full lay, got \(action)")
            return
        }
        #expect(melds.reduce(0) { $0 + $1.entries.count } == 14)
    }
}
