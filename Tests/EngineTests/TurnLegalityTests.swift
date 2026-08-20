import Foundation
import Testing
@testable import TunisianCards

private func distinctCards(_ count: Int, excluding: Set<Int> = []) -> [Card] {
    Array(Card.fullDeck().filter { !excluding.contains($0.id) }.prefix(count))
}

struct DealFlowTests {
    @Test func shuffleAndDealProducesVotePhaseWithCorrectHands() throws {
        var rng = SeededRNG(seed: 1)
        var s = RamiEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        s = try RamiEngine.apply(.shuffle, by: 2, to: s, rng: &rng)
        s = try RamiEngine.apply(.shuffle, by: 2, to: s, rng: &rng)
        #expect(s.phase == .dealing(shuffles: 2))
        s = try RamiEngine.apply(.deal(.p2222), by: 2, to: s, rng: &rng)
        #expect(s.players[2].hand.count == 15)
        for seat in [0, 1, 3] { #expect(s.players[seat].hand.count == 14) }
        #expect(s.drawPile.count == 108 - 57)
        #expect(s.phase == .vote(proposerSeat: 3, currentSeat: 3))
    }

    @Test func onlyDealerMayShuffleOrDeal() throws {
        var rng = SeededRNG(seed: 1)
        let s = RamiEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        #expect(throws: RamiError.notYourTurn) { try StateBuilder.apply(.shuffle, by: 0, to: s) }
        #expect(throws: RamiError.notYourTurn) { try StateBuilder.apply(.deal(.p1111), by: 1, to: s) }
    }
}

struct VoteTests {
    private func dealtState() throws -> RamiState {
        var rng = SeededRNG(seed: 5)
        var s = RamiEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        s = try RamiEngine.apply(.deal(.p1111), by: 2, to: s, rng: &rng)
        return s
    }

    @Test func firstActorPlayingStartsTheirTurn() throws {
        var s = try dealtState()
        s = try StateBuilder.apply(.declareIntent(play: true), by: 3, to: s)
        #expect(s.phase == .turn(seat: 3, .awaitingDraw))
    }

    @Test func anyDeclineStartsPlayWithFirstActor() throws {
        var s = try dealtState()
        s = try StateBuilder.apply(.declareIntent(play: false), by: 3, to: s)
        #expect(s.phase == .vote(proposerSeat: 3, currentSeat: 0))
        s = try StateBuilder.apply(.declareIntent(play: false), by: 0, to: s)
        s = try StateBuilder.apply(.declareIntent(play: true), by: 1, to: s)
        #expect(s.phase == .turn(seat: 3, .awaitingDraw))
    }

    @Test func unanimousPassAbandonsRoundAndRotatesDealer() throws {
        var s = try dealtState()
        for seat in [3, 0, 1, 2] {
            s = try StateBuilder.apply(.declareIntent(play: false), by: seat, to: s)
        }
        #expect(s.phase == .dealing(shuffles: 0))
        #expect(s.dealerSeat == 3)
        #expect(s.roundNumber == 2)
        #expect(s.players.allSatisfy { $0.hand.isEmpty && $0.roundScores == [nil] })
        #expect(s.drawPile.count == 108)
    }

    @Test func voteRespectsTurnOrder() throws {
        let s = try dealtState()
        #expect(throws: RamiError.notYourTurn) { try StateBuilder.apply(.declareIntent(play: true), by: 1, to: s) }
    }
}

struct TurnStructureTests {
    @Test func drawFromPileMovesOneCardToHand() throws {
        let hand = distinctCards(14)
        var s = StateBuilder.turn(seat: 0, stage: .awaitingDraw, hands: [hand, [], [], []])
        let top = s.drawPile.last!
        s = try StateBuilder.apply(.drawFromPile, by: 0, to: s)
        #expect(s.players[0].hand.count == 15)
        #expect(s.players[0].hand.last == top)
        #expect(s.phase == .turn(seat: 0, .awaitingThrow(drew: .pile, pendingJoker: nil)))
    }

    @Test func cannotThrowBeforeDrawingAndCannotDrawTwice() throws {
        let hand = distinctCards(14)
        let s = StateBuilder.turn(seat: 0, stage: .awaitingDraw, hands: [hand, [], [], []])
        #expect(throws: RamiError.illegalPhase) { try StateBuilder.apply(.throwCard(hand[0]), by: 0, to: s) }
        let drawn = try StateBuilder.apply(.drawFromPile, by: 0, to: s)
        #expect(throws: RamiError.illegalPhase) { try StateBuilder.apply(.drawFromPile, by: 0, to: drawn) }
    }

    @Test func throwEndsTurnAndPassesToNextSeat() throws {
        let hand = distinctCards(15)
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [distinctCards(14, excluding: Set(hand.map(\.id))), hand, [], []])
        s = try StateBuilder.apply(.throwCard(hand[3]), by: 1, to: s)
        #expect(s.players[1].hand.count == 14)
        #expect(s.players[1].throwStack == [hand[3]])
        #expect(s.turnsCompletedThisRound == 1)
        #expect(s.phase == .turn(seat: 2, .awaitingDraw))
    }

    @Test func dealerFirstTurnSkipsTheDraw() throws {
        // Seat 2 threw; seat 3 (next) holds 15 cards (dealer) → goes straight to awaitingThrow(.dealt).
        let dealerHand = distinctCards(15)
        let thrower = distinctCards(15, excluding: Set(dealerHand.map(\.id)))
        var s = StateBuilder.turn(
            seat: 2, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[], [], thrower, dealerHand])
        s = try StateBuilder.apply(.throwCard(thrower[0]), by: 2, to: s)
        #expect(s.phase == .turn(seat: 3, .awaitingThrow(drew: .dealt, pendingJoker: nil)))
    }

    @Test func actingOutOfTurnThrows() {
        let s = StateBuilder.turn(seat: 0, stage: .awaitingDraw, hands: [distinctCards(14), [], [], []])
        #expect(throws: RamiError.notYourTurn) { try StateBuilder.apply(.drawFromPile, by: 2, to: s) }
    }
}

struct ThrowTakeTests {
    private func takeSetup(turnsCompleted: Int, laidDown: Bool, seat: Int = 1) -> (RamiState, Card) {
        let hand = distinctCards(14)
        let prevThrown = distinctCards(2, excluding: Set(hand.map(\.id)))
        let s = StateBuilder.turn(
            seat: seat, stage: .awaitingDraw,
            hands: [distinctCards(14, excluding: Set((hand + prevThrown).map(\.id))), hand, [], []],
            throwStacks: [prevThrown, [], [], []],
            laidDown: [false, laidDown, false, false],
            turnsCompleted: turnsCompleted)
        return (s, prevThrown.last!)
    }

    @Test func takeThrowLockedUntilEveryoneHasPlayedOnce() {
        let (s, _) = takeSetup(turnsCompleted: 3, laidDown: true)
        #expect(throws: RamiError.throwTakeLocked) { try StateBuilder.apply(.takeThrow, by: 1, to: s) }
    }

    @Test func takeThrowAfterLayDownTakesPreviousPlayersTopThrow() throws {
        let (s, top) = takeSetup(turnsCompleted: 4, laidDown: true)
        let after = try StateBuilder.apply(.takeThrow, by: 1, to: s)
        #expect(after.players[1].hand.contains(top))
        #expect(after.players[1].takenThrows == [top])
        #expect(after.players[0].throwStack.count == 1)
        #expect(after.phase == .turn(seat: 1, .awaitingThrow(drew: .takenThrow, pendingJoker: nil)))
    }

    @Test func plainTakeThrowRequiresPriorLayDown() {
        let (s, _) = takeSetup(turnsCompleted: 4, laidDown: false)
        #expect(throws: RamiError.mustLayDownWithTake) { try StateBuilder.apply(.takeThrow, by: 1, to: s) }
    }

    @Test func takeThrowAndLayDownMustMeetThreshold() {
        // Hand engineered so a valid but too-small meld exists.
        let meldCards = [TestCards.card(.two, .hearts), TestCards.card(.three, .hearts), TestCards.card(.four, .hearts)]
        let filler = distinctCards(11, excluding: Set(meldCards.map(\.id)))
        let prevThrown = [TestCards.card(.nine, .spades, copy: 1)]
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingDraw,
            hands: [[], meldCards + filler, [], []],
            throwStacks: [prevThrown, [], [], []],
            turnsCompleted: 4)
        s.players[0].hand = distinctCards(14, excluding: Set((meldCards + filler + prevThrown).map(\.id)))
        let meld = Meld(entries: meldCards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) })
        #expect(throws: RamiError.thresholdNotMet(required: 61, got: 9)) {
            try StateBuilder.apply(.takeThrowAndLayDown(melds: [meld]), by: 1, to: s)
        }
    }

    @Test func takeThrowAndLayDownSucceedsWhenThresholdMet() throws {
        // Three kings (30) + three queens (30) + taken card is not required in melds; total 60 < 61,
        // so add a run Q-K-A (30) instead: use kings set (30) + QKA run (30) = 60... make it
        // kings set (30) + aces set (30) + taken irrelevant = 60 → still short; use K,K,K + A,A,A + 10,J,Q run (30) = 90.
        let kings = [TestCards.card(.king, .hearts), TestCards.card(.king, .spades), TestCards.card(.king, .clubs)]
        let aces = [TestCards.card(.ace, .hearts), TestCards.card(.ace, .spades), TestCards.card(.ace, .clubs)]
        let run = [TestCards.card(.ten, .diamonds), TestCards.card(.jack, .diamonds), TestCards.card(.queen, .diamonds)]
        let meldCards = kings + aces + run
        let filler = distinctCards(5, excluding: Set(meldCards.map(\.id)))
        let prevThrown = [TestCards.card(.nine, .spades, copy: 1)]
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingDraw,
            hands: [[], meldCards + filler, [], []],
            throwStacks: [prevThrown, [], [], []],
            turnsCompleted: 4)
        s.players[0].hand = distinctCards(14, excluding: Set((meldCards + filler + prevThrown).map(\.id)))
        let melds = [kings, aces, run].map { cards in
            Meld(entries: cards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) })
        }
        let after = try StateBuilder.apply(.takeThrowAndLayDown(melds: melds), by: 1, to: s)
        #expect(after.players[1].hasLaidDown)
        #expect(after.lastInitialLayDownTotal == 90)
        #expect(after.tableMelds.count == 3)
        #expect(after.players[1].hand.count == 5 + 1)  // filler + taken card
        #expect(after.players[1].takenThrows == prevThrown)
    }
}
