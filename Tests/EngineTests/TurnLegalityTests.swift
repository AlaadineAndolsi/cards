import Foundation
import Testing
@testable import Cards

private func distinctCards(_ count: Int, excluding: Set<Int> = []) -> [Card] {
    Array(Card.fullDeck().filter { !excluding.contains($0.id) }.prefix(count))
}

struct DealFlowTests {
    @Test func shuffleAndDealProducesVotePhaseWithCorrectHands() throws {
        var rng = SeededRNG(seed: 1)
        var s = RummyEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        s = try RummyEngine.apply(.shuffle, by: 2, to: s, rng: &rng)
        s = try RummyEngine.apply(.shuffle, by: 2, to: s, rng: &rng)
        #expect(s.phase == .dealing(shuffles: 2))
        s = try RummyEngine.apply(.deal(.p2222), by: 2, to: s, rng: &rng)
        #expect(s.players[2].hand.count == 15)
        for seat in [0, 1, 3] { #expect(s.players[seat].hand.count == 14) }
        #expect(s.drawPile.count == 108 - 57)
        #expect(s.phase == .vote(proposerSeat: 3, currentSeat: 3))
    }

    @Test func onlyDealerMayShuffleOrDeal() throws {
        var rng = SeededRNG(seed: 1)
        let s = RummyEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        #expect(throws: RummyError.notYourTurn) { try StateBuilder.apply(.shuffle, by: 0, to: s) }
        #expect(throws: RummyError.notYourTurn) { try StateBuilder.apply(.deal(.p1111), by: 1, to: s) }
    }
}

struct VoteTests {
    private func dealtState() throws -> RummyState {
        var rng = SeededRNG(seed: 5)
        var s = RummyEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 2, rng: &rng)
        s = try RummyEngine.apply(.deal(.p1111), by: 2, to: s, rng: &rng)
        return s
    }

    @Test func playStartsWithTheDealerThrowingTheir15thCard() throws {
        var s = try dealtState()
        s = try StateBuilder.apply(.declareIntent(play: true), by: 3, to: s)
        // The dealer (seat 2, 15 cards) opens the round with a throw-only turn.
        #expect(s.phase == .turn(seat: 2, .awaitingThrow(drew: .dealt, pendingJoker: nil)))
    }

    @Test func anyDeclineStartsPlayWithTheDealer() throws {
        var s = try dealtState()
        s = try StateBuilder.apply(.declareIntent(play: false), by: 3, to: s)
        #expect(s.phase == .vote(proposerSeat: 3, currentSeat: 0))
        s = try StateBuilder.apply(.declareIntent(play: false), by: 0, to: s)
        s = try StateBuilder.apply(.declareIntent(play: true), by: 1, to: s)
        #expect(s.phase == .turn(seat: 2, .awaitingThrow(drew: .dealt, pendingJoker: nil)))
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
        #expect(throws: RummyError.notYourTurn) { try StateBuilder.apply(.declareIntent(play: true), by: 1, to: s) }
    }
}

struct ForcedPassTests {
    private func pair(_ rank: Rank, _ suit: Suit) -> [Card] {
        [TestCards.card(rank, suit, copy: 0), TestCards.card(rank, suit, copy: 1)]
    }

    private func filler(_ count: Int, excluding: [Card]) -> [Card] {
        let used = Set(excluding.map(\.id))
        return Array(Card.fullDeck().filter { !used.contains($0.id) && !$0.isJoker }
            .suffix(count))
    }

    @Test func qualificationRules() {
        let fourDoubles = pair(.two, .hearts) + pair(.five, .clubs)
            + pair(.nine, .spades) + pair(.king, .diamonds)
        #expect(RummyEngine.canForcePass(hand: fourDoubles + filler(6, excluding: fourDoubles)))

        let threeDoubles = pair(.two, .hearts) + pair(.five, .clubs) + pair(.nine, .spades)
        #expect(!RummyEngine.canForcePass(hand: threeDoubles + filler(8, excluding: threeDoubles)))
        #expect(RummyEngine.canForcePass(
            hand: threeDoubles + [TestCards.joker()] + filler(7, excluding: threeDoubles)))

        let twoDoubles = pair(.two, .hearts) + pair(.five, .clubs)
        #expect(!RummyEngine.canForcePass(
            hand: twoDoubles + [TestCards.joker()] + filler(9, excluding: twoDoubles)))
        #expect(RummyEngine.canForcePass(
            hand: twoDoubles + [TestCards.joker(0), TestCards.joker(1)]
                + filler(8, excluding: twoDoubles)))

        // Two copies of the same rank in different suits are not a double.
        let fakeDoubles = [
            TestCards.card(.two, .hearts), TestCards.card(.two, .spades),
            TestCards.card(.five, .clubs), TestCards.card(.five, .diamonds),
            TestCards.card(.nine, .spades), TestCards.card(.nine, .hearts),
            TestCards.card(.king, .diamonds), TestCards.card(.king, .clubs),
        ]
        #expect(!RummyEngine.canForcePass(hand: fakeDoubles + filler(6, excluding: fakeDoubles)))
    }

    @Test func forcePassAbandonsTheRoundImmediately() throws {
        var s = StateBuilder.base()
        let qualifying = pair(.two, .hearts) + pair(.five, .clubs)
            + pair(.nine, .spades) + pair(.king, .diamonds)
        s.players[0].hand = qualifying + filler(6, excluding: qualifying)
        for seat in 1..<4 { s.players[seat].hand = filler(14, excluding: []) }
        s.dealerSeat = 3
        s.phase = .vote(proposerSeat: 0, currentSeat: 0)
        let after = try StateBuilder.apply(.forcePass, by: 0, to: s)
        #expect(after.phase == .dealing(shuffles: 0))
        #expect(after.dealerSeat == 0)  // rotates right from seat 3
        #expect(after.players.allSatisfy { $0.roundScores == [nil] && $0.hand.isEmpty })
    }

    @Test func forcePassWithoutQualifyingHandIsRejected() throws {
        var s = StateBuilder.base()
        for seat in 0..<4 { s.players[seat].hand = filler(14, excluding: []) }
        s.phase = .vote(proposerSeat: 0, currentSeat: 0)
        #expect(throws: RummyError.cannotForcePass) {
            try StateBuilder.apply(.forcePass, by: 0, to: s)
        }
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
        #expect(throws: RummyError.illegalPhase) { try StateBuilder.apply(.throwCard(hand[0]), by: 0, to: s) }
        let drawn = try StateBuilder.apply(.drawFromPile, by: 0, to: s)
        #expect(throws: RummyError.illegalPhase) { try StateBuilder.apply(.drawFromPile, by: 0, to: drawn) }
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
        #expect(throws: RummyError.notYourTurn) { try StateBuilder.apply(.drawFromPile, by: 2, to: s) }
    }
}

struct ThrowTakeTests {
    private func takeSetup(turnsCompleted: Int, laidDown: Bool, seat: Int = 1) -> (RummyState, Card) {
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
        #expect(throws: RummyError.throwTakeLocked) { try StateBuilder.apply(.takeThrow, by: 1, to: s) }
    }

    /// The whole rule in one boundary: the round's opening-cycle throws
    /// (the first `aliveCount`) can never be taken, and from the very next
    /// throw on EVERY throw can — a player's first throw included.
    @Test func openingCycleThrowsLockedFifthThrowOnwardTakeable() throws {
        // Turn 5 (four throws completed): the takeable card would be the
        // round's 4th throw — still locked, even for the dealer.
        let (atFourth, _) = takeSetup(turnsCompleted: 4, laidDown: true)
        #expect(!atFourth.throwTakeUnlocked)
        #expect(throws: RummyError.throwTakeLocked) {
            try StateBuilder.apply(.takeThrow, by: 1, to: atFourth)
        }
        // One throw later the round's 5th throw is on offer — takeable,
        // even though it is that player's FIRST throw of the round.
        let thrown = TestCards.card(.nine, .hearts)
        let s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[thrown, TestCards.card(.king, .diamonds)],
                    [TestCards.card(.four, .clubs)], [], []],
            laidDown: [true, true, true, true],
            turnsCompleted: 4)
        let after = try StateBuilder.apply(.throwCard(thrown), by: 0, to: s)
        #expect(after.throwTakeUnlocked)
        #expect(after.takeableThrow(for: 1) == thrown)
        let taken = try StateBuilder.apply(.takeThrow, by: 1, to: after)
        #expect(taken.players[1].hand.contains(thrown))
    }

    @Test func takeThrowAfterLayDownTakesPreviousPlayersTopThrow() throws {
        let (s, top) = takeSetup(turnsCompleted: 5, laidDown: true)
        let after = try StateBuilder.apply(.takeThrow, by: 1, to: s)
        #expect(after.players[1].hand.contains(top))
        #expect(after.players[1].takenThrows == [top])
        #expect(after.players[0].throwStack.count == 1)
        #expect(after.phase == .turn(seat: 1, .awaitingThrow(drew: .takenThrow, pendingJoker: nil)))
    }

    @Test func preLayDownTakeIsNeverJudgedAtTheTake() throws {
        // Even a meldless junk hand takes freely: the count verdict only
        // ever lands when the turn ends with a throw — never at the take.
        let junk = [
            TestCards.card(.two, .hearts), TestCards.card(.six, .hearts), TestCards.card(.ten, .hearts),
            TestCards.card(.ace, .hearts),
            TestCards.card(.three, .diamonds), TestCards.card(.seven, .diamonds), TestCards.card(.jack, .diamonds),
            TestCards.card(.four, .clubs), TestCards.card(.eight, .clubs), TestCards.card(.queen, .clubs),
            TestCards.card(.five, .spades), TestCards.card(.nine, .spades), TestCards.card(.king, .spades),
            TestCards.card(.seven, .spades),
        ]
        let prevThrown = [TestCards.card(.nine, .spades, copy: 1)]
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingDraw,
            hands: [[], junk, [], []],
            throwStacks: [prevThrown, [], [], []],
            turnsCompleted: 5)
        s.players[0].hand = Array(Card.fullDeck().filter { card in
            !junk.contains(card) && !prevThrown.contains(card)
        }.prefix(14))
        let after = try StateBuilder.apply(.takeThrow, by: 1, to: s)
        #expect(after.phase == .turn(seat: 1, .awaitingThrow(drew: .takenThrow, pendingJoker: nil)))
        #expect(after.players[1].totalScore == 0, "no penalty at the take")
        // The commitment still stands: ending the turn without a single
        // laid series is refused — the throw is where the judgment lives.
        #expect(throws: RummyError.mustLayDownWithTake) {
            try StateBuilder.apply(.throwCard(junk[0]), by: 1, to: after)
        }
    }

    @Test func preLayDownTakeWithQualifyingHandLocksUntilLayDown() throws {
        // Kings + aces + Q-K-A run in hand: taking commits, throw is blocked
        // until the lay-down happens, then the turn completes normally.
        let kings = [TestCards.card(.king, .hearts), TestCards.card(.king, .spades), TestCards.card(.king, .clubs)]
        let aces = [TestCards.card(.ace, .hearts), TestCards.card(.ace, .spades), TestCards.card(.ace, .clubs)]
        let run = [TestCards.card(.ten, .diamonds), TestCards.card(.jack, .diamonds), TestCards.card(.queen, .diamonds)]
        let meldCards = kings + aces + run
        let filler = Array(Card.fullDeck().filter { card in
            !meldCards.contains(card) && !card.isJoker
        }.suffix(5))
        let prevThrown = [TestCards.card(.nine, .spades, copy: 1)]
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingDraw,
            hands: [[], meldCards + filler, [], []],
            throwStacks: [prevThrown, [], [], []],
            turnsCompleted: 5)
        s.players[0].hand = Array(Card.fullDeck().filter { card in
            !meldCards.contains(card) && !filler.contains(card) && !prevThrown.contains(card)
        }.prefix(14))
        var after = try StateBuilder.apply(.takeThrow, by: 1, to: s)
        #expect(after.phase == .turn(seat: 1, .awaitingThrow(drew: .takenThrow, pendingJoker: nil)))
        // Throwing before honoring the lay-down is illegal.
        #expect(throws: RummyError.mustLayDownWithTake) {
            try StateBuilder.apply(.throwCard(filler[0]), by: 1, to: after)
        }
        let melds = [kings, aces, run].map { cards in
            Meld(entries: cards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) })
        }
        after = try StateBuilder.apply(.layDown(melds: melds), by: 1, to: after)
        #expect(!after.players[1].hasLaidDown)  // pending until the throw
        #expect(after.players[1].pendingLayDownValue == 90)
        let safeThrow = after.players[1].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: after.tableMelds)
        }!
        after = try StateBuilder.apply(.throwCard(safeThrow), by: 1, to: after)
        #expect(after.players[1].hasLaidDown)
        #expect(after.lastInitialLayDownTotal == 90)
    }

    @Test func takeThrowAndLayDownShortOfThresholdPenalizesAtTheThrow() throws {
        // Hand engineered so a valid but too-small meld exists.
        let meldCards = [TestCards.card(.two, .hearts), TestCards.card(.three, .hearts), TestCards.card(.four, .hearts)]
        let filler = distinctCards(11, excluding: Set(meldCards.map(\.id)))
        let prevThrown = [TestCards.card(.nine, .spades, copy: 1)]
        var s = StateBuilder.turn(
            seat: 1, stage: .awaitingDraw,
            hands: [[], meldCards + filler, [], []],
            throwStacks: [prevThrown, [], [], []],
            turnsCompleted: 5)
        s.players[0].hand = distinctCards(14, excluding: Set((meldCards + filler + prevThrown).map(\.id)))
        let meld = Meld(entries: meldCards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) })
        // Laying short is allowed — the throw ends the round at +100.
        let laid = try StateBuilder.apply(.takeThrowAndLayDown(melds: [meld]), by: 1, to: s)
        #expect(laid.players[1].pendingLayDownValue == 9)
        let safeThrow = laid.players[1].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: laid.tableMelds)
        }!
        let thrown = try StateBuilder.apply(.throwCard(safeThrow), by: 1, to: laid)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected the round to stop, got \(thrown.phase)")
            return
        }
        #expect(result.closerSeat == nil)
        #expect(result.deltas[1] == 100)
        #expect(result.deltas[0] == 0)
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
            turnsCompleted: 5)
        s.players[0].hand = distinctCards(14, excluding: Set((meldCards + filler + prevThrown).map(\.id)))
        let melds = [kings, aces, run].map { cards in
            Meld(entries: cards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) })
        }
        var after = try StateBuilder.apply(.takeThrowAndLayDown(melds: melds), by: 1, to: s)
        #expect(!after.players[1].hasLaidDown)  // pending until the throw
        #expect(after.players[1].pendingLayDownValue == 90)
        #expect(after.lastInitialLayDownTotal == nil)
        #expect(after.tableMelds.count == 3)
        #expect(after.players[1].hand.count == 5 + 1)  // filler + taken card
        #expect(after.players[1].takenThrows == prevThrown)
        let safeThrow = after.players[1].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: after.tableMelds)
        }!
        after = try StateBuilder.apply(.throwCard(safeThrow), by: 1, to: after)
        #expect(after.players[1].hasLaidDown)
        #expect(after.lastInitialLayDownTotal == 90)
    }
}

/// The wasted-throw rule covers every card that can be placed into a table
/// meld — extensions AND the real card behind a played joker (swap).
struct WastedThrowTests {
    private func jokerFaceState() -> RummyState {
        // Table: 5♠-JOKER(as 6♠)-7♠. Seat 1 holds the real 6♠ plus a safe 2♥.
        let meld = Meld(entries: [
            TestCards.entry(.five, .spades),
            TestCards.jokerEntry(as: .six, .spades),
            TestCards.entry(.seven, .spades),
        ])
        let hand = [TestCards.card(.six, .spades), TestCards.card(.two, .hearts)]
        let used = Set((hand + meld.cards).map(\.id))
        return StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [distinctCards(5, excluding: used), hand, [], []],
            laidDown: [false, true, false, false],
            turnsCompleted: 8,
            tableMelds: [TableMeld(id: UUID(), ownerSeat: 3, meld: meld)])
    }

    @Test func cardMatchingATableJokerFaceIsPenalized() {
        let s = jokerFaceState()
        #expect(RummyEngine.throwPenalized(TestCards.card(.six, .spades), tableMelds: s.tableMelds))
        #expect(!RummyEngine.throwPenalized(TestCards.card(.two, .hearts), tableMelds: s.tableMelds))
    }

    @Test func throwingTheJokerFaceCardBouncesWithPenalty() throws {
        let s = jokerFaceState()
        let after = try StateBuilder.apply(.throwCard(TestCards.card(.six, .spades)), by: 1, to: s)
        #expect(after.players[1].hand.count == 2, "the card comes back")
        #expect(after.players[1].penaltiesThisRound == 10)
        #expect(after.phase == s.phase, "the turn is not over")
    }

    @Test func theSafeCardStillGoesThrough() throws {
        let s = jokerFaceState()
        let after = try StateBuilder.apply(.throwCard(TestCards.card(.two, .hearts)), by: 1, to: s)
        #expect(after.players[1].hand.count == 1)
        #expect(after.players[1].penaltiesThisRound == 0)
    }

    @Test func cardExtendingAFullFiveRunIsStillPenalized() throws {
        // The reported table: 7♦-8♦-9♦-🃏(10♦)-🃏(J♦), five cards. The 6♦
        // goes under the 7♦ — runs keep growing past five — so throwing it
        // is a wasted throw and bounces.
        let meld = Meld(entries: [
            TestCards.entry(.seven, .diamonds),
            TestCards.entry(.eight, .diamonds),
            TestCards.entry(.nine, .diamonds),
            TestCards.jokerEntry(as: .ten, .diamonds, index: 0),
            TestCards.jokerEntry(as: .jack, .diamonds, index: 1),
        ])
        let hand = [TestCards.card(.six, .diamonds), TestCards.card(.two, .hearts)]
        let used = Set((hand + meld.cards).map(\.id))
        let s = StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [distinctCards(5, excluding: used), hand, [], []],
            laidDown: [false, true, false, false],
            turnsCompleted: 8,
            tableMelds: [TableMeld(id: UUID(), ownerSeat: 3, meld: meld)])
        #expect(RummyEngine.throwPenalized(TestCards.card(.six, .diamonds), tableMelds: s.tableMelds))
        let after = try StateBuilder.apply(.throwCard(TestCards.card(.six, .diamonds)), by: 1, to: s)
        #expect(after.players[1].hand.count == 2, "the 6♦ comes back")
        #expect(after.players[1].penaltiesThisRound == 10)
        // And the 6♦ can actually be appended under the 7♦.
        let grown = try StateBuilder.apply(
            .appendCard(TestCards.entry(.six, .diamonds), meldID: s.tableMelds[0].id), by: 1, to: s)
        #expect(grown.tableMelds[0].meld.entries.count == 6)
    }

    @Test func layingASixCardRunIsStillRejected() {
        // Growth applies on the table only; a laid series stays capped at 5.
        let run = TestCards.run(.hearts, .four, .five, .six, .seven, .eight, .nine)
        let hand = run.cards + [TestCards.card(.two, .spades)]
        let s = StateBuilder.turn(
            seat: 1, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[], hand, [], []],
            turnsCompleted: 8)
        #expect(throws: RummyError.invalidMeld(.invalidSize)) {
            try StateBuilder.apply(.layDown(melds: [run]), by: 1, to: s)
        }
    }
}
