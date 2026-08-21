import Foundation
import Testing
@testable import Cards

/// The opponent model reads only public information: takes, declines, table
/// melds, throw stacks — filtered through level-scaled human memory.
struct OpponentModelTests {

    /// Seat 1 acts; seat 2 is the next player being modeled.
    private func makeState(hand: [Card]) -> RummyState {
        let filler = Card.fullDeck().filter { !$0.isJoker }.suffix(20)
        return StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [Array(filler.prefix(5)), hand,
                    Array(filler.dropFirst(5).prefix(5)), Array(filler.dropFirst(10).prefix(5))],
            turnsCompleted: 8)
    }

    private func model(_ state: RummyState, level: BotLevel, archetype: BotArchetype = .blocker) -> OpponentModel {
        let view = PublicGameView(state: state, seat: 1)
        return OpponentModel(
            view: view,
            weights: .resolve(level: level, archetype: archetype, frustration: 0.3))
    }

    @Test func beginnerBarelyModelsTheNextPlayer() {
        var s = makeState(hand: [TestCards.card(.eight, .hearts)])
        s.players[2].takenThrows = [TestCards.card(.seven, .hearts)]
        let m = model(s, level: .beginner)
        #expect(m.danger(of: TestCards.card(.eight, .hearts)) == 0)
    }

    @Test func recentTakeIsSharperThanOldTake() {
        let noise = [TestCards.card(.two, .clubs), TestCards.card(.three, .clubs, copy: 1),
                     TestCards.card(.queen, .diamonds), TestCards.card(.five, .clubs)]
        var recent = makeState(hand: [TestCards.card(.eight, .hearts)])
        recent.players[2].takenThrows = noise + [TestCards.card(.seven, .hearts)]
        var old = makeState(hand: [TestCards.card(.eight, .hearts)])
        old.players[2].takenThrows = [TestCards.card(.seven, .hearts)] + noise
        let dangerRecent = model(recent, level: .intermediate).danger(of: TestCards.card(.eight, .hearts))
        let dangerOld = model(old, level: .intermediate).danger(of: TestCards.card(.eight, .hearts))
        #expect(dangerRecent > dangerOld, "memory decays — a fresh take burns hotter")
        #expect(dangerOld > 0, "still remembered inside the window")
    }

    @Test func adjacencyShapesDanger() {
        var s = makeState(hand: [TestCards.card(.eight, .hearts)])
        s.players[2].takenThrows = [TestCards.card(.seven, .hearts)]
        let m = model(s, level: .expert)
        let nextDoor = m.danger(of: TestCards.card(.eight, .hearts))     // suit distance 1
        let twoAway = m.danger(of: TestCards.card(.five, .hearts))       // suit distance 2
        let sameRankOtherSuit = m.danger(of: TestCards.card(.seven, .clubs))
        let unrelated = m.danger(of: TestCards.card(.queen, .spades))
        #expect(nextDoor > twoAway)
        #expect(sameRankOtherSuit > twoAway)
        #expect(unrelated == 0)
    }

    @Test func declinedZonesReadSafeAtExpert() {
        var withDecline = makeState(hand: [TestCards.card(.eight, .hearts)])
        withDecline.players[2].takenThrows = [TestCards.card(.seven, .hearts)]
        // Seat 2 already passed over an 8♥ sitting in my stack.
        withDecline.players[1].throwStack = [TestCards.card(.eight, .hearts, copy: 1)]
        var without = makeState(hand: [TestCards.card(.eight, .hearts)])
        without.players[2].takenThrows = [TestCards.card(.seven, .hearts)]
        let declined = model(withDecline, level: .expert).danger(of: TestCards.card(.eight, .hearts))
        let fresh = model(without, level: .expert).danger(of: TestCards.card(.eight, .hearts))
        #expect(declined < fresh)
    }

    @Test func intermediateIgnoresDeclines() {
        var withDecline = makeState(hand: [TestCards.card(.eight, .hearts)])
        withDecline.players[2].takenThrows = [TestCards.card(.seven, .hearts)]
        withDecline.players[1].throwStack = [TestCards.card(.eight, .hearts, copy: 1)]
        var without = makeState(hand: [TestCards.card(.eight, .hearts)])
        without.players[2].takenThrows = [TestCards.card(.seven, .hearts)]
        let a = model(withDecline, level: .intermediate).danger(of: TestCards.card(.eight, .hearts))
        let b = model(without, level: .intermediate).danger(of: TestCards.card(.eight, .hearts))
        #expect(a == b)
    }

    @Test func appendableCardIsHotOnceNextPlayerLaidDown() {
        var s = makeState(hand: [TestCards.card(.eight, .spades), TestCards.card(.queen, .hearts)])
        s.players[2].hasLaidDown = true
        s.tableMelds = [TableMeld(id: UUID(), ownerSeat: 2,
                                  meld: TestCards.run(.spades, .five, .six, .seven))]
        let m = model(s, level: .expert)
        #expect(m.danger(of: TestCards.card(.eight, .spades)) >= 0.9)
        #expect(m.danger(of: TestCards.card(.queen, .hearts)) < 0.5)
    }

    @Test func cardFreeingATableJokerIsHotAfterLaydown() {
        var s = makeState(hand: [TestCards.card(.six, .spades)])
        s.players[2].hasLaidDown = true
        // 5♠-JOKER(as 6♠)-7♠ on the table: throwing the real 6♠ hands the
        // next player a swap + free joker.
        let meld = Meld(entries: [
            TestCards.entry(.five, .spades),
            TestCards.jokerEntry(as: .six, .spades),
            TestCards.entry(.seven, .spades),
        ])
        s.tableMelds = [TableMeld(id: UUID(), ownerSeat: 3, meld: meld)]
        let m = model(s, level: .expert)
        #expect(m.danger(of: TestCards.card(.six, .spades)) >= 0.8)
    }

    @Test func deadPairBookkeeping() {
        var s = makeState(hand: [TestCards.card(.nine, .diamonds)])
        s.players[0].throwStack = [TestCards.card(.nine, .diamonds, copy: 1)]
        let m = model(s, level: .expert)
        // One copy in my own hand + one visible: the OTHER copy is gone, so
        // visible count for the exact card is 1, not a dead pair yet.
        #expect(!m.isDeadPair(rank: .nine, suit: .clubs))
        #expect(m.visibleCount(rank: .nine, suit: .diamonds) == 1)
        s.players[3].throwStack = [TestCards.card(.nine, .clubs), TestCards.card(.nine, .clubs, copy: 1)]
        let m2 = model(s, level: .expert)
        #expect(m2.isDeadPair(rank: .nine, suit: .clubs))
    }

    @Test func beginnerForgetsOldThrowsInTheDeadBook() {
        var s = makeState(hand: [TestCards.card(.nine, .diamonds)])
        // Both 9♣ copies thrown long ago in a deep stack.
        s.players[0].throwStack = [TestCards.card(.nine, .clubs), TestCards.card(.nine, .clubs, copy: 1)]
            + (10...16).map { TestCards.card(Rank(rawValue: $0 - 8)!, .hearts) }
        #expect(model(s, level: .beginner).visibleCount(rank: .nine, suit: .clubs) == 0)
        #expect(model(s, level: .expert).visibleCount(rank: .nine, suit: .clubs) == 2)
    }

    @Test func livelinessDropsWhenNeighborsAreDead() {
        var s = makeState(hand: [TestCards.card(.eight, .diamonds)])
        let fresh = model(s, level: .expert).liveliness(of: TestCards.card(.eight, .diamonds))
        s.players[0].throwStack = [
            TestCards.card(.seven, .diamonds), TestCards.card(.seven, .diamonds, copy: 1),
            TestCards.card(.nine, .diamonds), TestCards.card(.nine, .diamonds, copy: 1),
            TestCards.card(.eight, .hearts), TestCards.card(.eight, .clubs),
        ]
        let starved = model(s, level: .expert).liveliness(of: TestCards.card(.eight, .diamonds))
        #expect(starved < fresh)
    }
}
