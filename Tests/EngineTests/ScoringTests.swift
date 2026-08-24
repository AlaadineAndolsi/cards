import Foundation
import Testing
@testable import Cards

/// A same-rank set that fills to four bursts off the table: its cards
/// (jokers included) leave play invisibly and only return when the
/// exhausted draw pile is rebuilt from the throws.
struct SetDestructionTests {
    @Test func fourthCardDestroysTheSet() throws {
        let kings = TestCards.set(.king, .spades, .hearts, .clubs)
        let kd = TestCards.card(.king, .diamonds)
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[kd, TestCards.card(.two, .clubs)], [], [], []],
            laidDown: [true, true, true, true],
            tableMelds: [TableMeld(id: UUID(), ownerSeat: 1, meld: kings)])
        let meldID = s.tableMelds[0].id
        s = try StateBuilder.apply(
            .appendCard(TestCards.entry(.king, .diamonds), meldID: meldID), by: 0, to: s)
        #expect(s.tableMelds.isEmpty, "the completed set leaves the table")
        #expect(s.destroyedCards?.count == 4)
        #expect(s.destroyedCards?.contains(kd) == true)
        #expect(!s.players[0].hand.contains(kd))
    }

    @Test func jokerCompletingASetIsDestroyedWithIt() throws {
        let queens = TestCards.set(.queen, .spades, .hearts, .diamonds)
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[TestCards.joker(0), TestCards.card(.two, .clubs)], [], [], []],
            laidDown: [true, true, true, true],
            tableMelds: [TableMeld(id: UUID(), ownerSeat: 2, meld: queens)])
        let meldID = s.tableMelds[0].id
        s = try StateBuilder.apply(
            .appendCard(TestCards.jokerEntry(as: .queen, .clubs), meldID: meldID), by: 0, to: s)
        #expect(s.tableMelds.isEmpty)
        #expect(s.destroyedCards?.contains(TestCards.joker(0)) == true)
    }

    @Test func destroyedCardsReturnOnPileReshuffle() throws {
        let kd = TestCards.card(.king, .diamonds)
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingDraw,
            hands: [[TestCards.card(.two, .clubs)], [], [], []],
            throwStacks: [[], [TestCards.card(.nine, .hearts)], [], []],
            laidDown: [true, true, true, true],
            drawPile: [])
        s.destroyedCards = [kd, TestCards.joker(0)]
        s = try StateBuilder.apply(.drawFromPile, by: 0, to: s)
        #expect(s.destroyedCards?.isEmpty == true)
        // 3 cards were collected (1 throw + 2 destroyed); one was drawn.
        let inPlay = s.drawPile + s.players[0].hand
        #expect(inPlay.contains(kd), "destroyed cards rejoin via the reshuffle")
        #expect(inPlay.contains(TestCards.joker(0)))
    }
}

struct ClosingAndScoringTests {
    /// Seat 0 about to close: 1 card in hand. Seat 1 laid down, holds K+9 (19).
    /// Seat 2 never laid down (100 flat). Seat 3 laid down, holds a joker + 5 = 15.
    private func closingState() -> RummyState {
        let last = TestCards.card(.two, .clubs)
        let s1 = [TestCards.card(.king, .diamonds), TestCards.card(.nine, .hearts)]
        let s2 = [TestCards.card(.three, .spades)]
        let s3 = [TestCards.joker(2), TestCards.card(.five, .diamonds)]
        return StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[last], s1, s2, s3],
            laidDown: [true, true, false, true])
    }

    @Test func closerScoresZeroOthersScoreHandsOrHundred() throws {
        var s = closingState()
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        guard case .roundEnded(let result) = s.phase else {
            Issue.record("expected roundEnded, got \(s.phase)")
            return
        }
        #expect(result.closerSeat == 0)
        #expect(result.deltas == [0, 19, 100, 15])
        #expect(s.players.map(\.totalScore) == [0, 19, 100, 15])
        #expect(s.players.map(\.roundScores) == [[0], [19], [100], [15]])
    }

    /// Throwing with only jokers left behind closes the round: the jokers
    /// auto-append to table melds (a joker places anywhere), sparing the
    /// player the busywork of parking them before the final discard.
    @Test func throwWithOnlyJokersLeftAutoClosesTheRound() throws {
        let run = TestCards.run(.hearts, .seven, .eight, .nine)
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [
                [TestCards.card(.two, .clubs), TestCards.joker(0), TestCards.joker(1)],
                [TestCards.card(.king, .diamonds)], [], [],
            ],
            laidDown: [true, true, true, true],
            tableMelds: [TableMeld(id: UUID(), ownerSeat: 1, meld: run)])
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        guard case .roundEnded(let result) = s.phase else {
            Issue.record("expected roundEnded, got \(s.phase)")
            return
        }
        #expect(result.closerSeat == 0)
        #expect(s.players[0].hand.isEmpty)
        // Both jokers grew the table run (9-8-7 → 5 entries).
        #expect(s.tableMelds[0].meld.entries.count == 5)
        #expect(s.tableMelds[0].meld.entries.filter(\.card.isJoker).count == 2)
    }

    /// With no room on the table for the jokers, the throw does NOT close —
    /// the turn passes and the jokers stay in hand.
    @Test func throwWithJokersButNoTableRoomDoesNotClose() throws {
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [
                [TestCards.card(.two, .clubs), TestCards.joker(0)],
                [TestCards.card(.king, .diamonds)], [], [],
            ],
            laidDown: [true, true, true, true])
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        guard case .turn(let seat, _) = s.phase else {
            Issue.record("expected the turn to pass, got \(s.phase)")
            return
        }
        #expect(seat == 1)
        #expect(s.players[0].hand.count == 1)
    }

    @Test func eliminationAtConfiguredScore() throws {
        var s = closingState()
        s.players[2].totalScore = 700  // + 100 → 800 = default elimination
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        guard case .roundEnded(let result) = s.phase else {
            Issue.record("expected roundEnded, got \(s.phase)")
            return
        }
        #expect(result.newlyEliminated == [2])
        #expect(s.players[2].isEliminated)
        #expect(s.eliminationOrder == [2])
        #expect(s.aliveCount == 3)
    }

    @Test func customEliminationScoreIsRespected() throws {
        var s = closingState()
        s.config.eliminationScore = 300
        s.players[1].totalScore = 290  // + 19 → 309 ≥ 300
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        #expect(s.players[1].isEliminated)
    }

    @Test func secondDeathEndsMatchWithRanking() throws {
        var s = closingState()
        s.players[3].isEliminated = true          // died in an earlier round
        s.players[3].hand = []
        s.eliminationOrder = [3]
        s.players[1].totalScore = 500
        s.players[2].totalScore = 750             // + 100 → 850 dies now
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        guard case .matchEnded(let placements) = s.phase else {
            Issue.record("expected matchEnded, got \(s.phase)")
            return
        }
        // Survivors 0 (0 pts) and 1 (519 pts); eliminated: 3 first, then 2.
        #expect(placements.map(\.seat) == [0, 1, 2, 3])
        #expect(placements.map(\.place) == [1, 2, 3, 4])
    }

    @Test func threePlayerContinuationSkipsDeadSeatAndAdjustsUnlock() throws {
        var s = closingState()
        s.players[2].totalScore = 700
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        s = try StateBuilder.apply(.startNextRound, by: 0, to: s)
        #expect(s.aliveCount == 3)
        // Dealer rotation from seat 3 skips nobody here; deal skips seat 2.
        var rng = SeededRNG(seed: 9)
        s = try RummyEngine.apply(.deal(.p1111), by: s.dealerSeat, to: s, rng: &rng)
        #expect(s.players[2].hand.isEmpty)
        #expect(s.players[s.dealerSeat].hand.count == 15)
        // Unlock now needs only 3 completed turns.
        s.turnsCompletedThisRound = 3
        #expect(s.throwTakeUnlocked)
        s.turnsCompletedThisRound = 2
        #expect(!s.throwTakeUnlocked)
    }

    @Test func dealerRotationSkipsEliminatedPlayers() throws {
        var s = closingState()
        s.dealerSeat = 1
        s.players[2].totalScore = 700  // seat 2 dies this round
        s = try StateBuilder.apply(.throwCard(s.players[0].hand[0]), by: 0, to: s)
        s = try StateBuilder.apply(.startNextRound, by: 0, to: s)
        #expect(s.dealerSeat == 3)  // 1 → 2 is dead → 3
    }
}

struct ReshuffleTests {
    @Test func drawFromEmptyPileReshufflesThrowStacks() throws {
        let hand = Array(Card.fullDeck().prefix(14))
        let stacks: [[Card]] = [
            Array(Card.fullDeck()[20..<25]),
            Array(Card.fullDeck()[30..<34]),
            Array(Card.fullDeck()[40..<43]),
            Array(Card.fullDeck()[50..<52]),
        ]
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingDraw,
            hands: [hand, [], [], []],
            throwStacks: stacks,
            drawPile: [])
        let totalThrown = stacks.map(\.count).reduce(0, +)
        s = try StateBuilder.apply(.drawFromPile, by: 0, to: s)
        #expect(s.players[0].hand.count == 15)
        #expect(s.drawPile.count == totalThrown - 1)
        #expect(s.players.allSatisfy { $0.throwStack.isEmpty })
    }
}

struct SerializationTests {
    @Test func midGameStateRoundTripsIdentically() throws {
        var rng = SeededRNG(seed: 77)
        var s = RummyEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 0, rng: &rng)
        s = try RummyEngine.apply(.shuffle, by: 0, to: s, rng: &rng)
        s = try RummyEngine.apply(.deal(.p3222), by: 0, to: s, rng: &rng)
        s = try RummyEngine.apply(.declareIntent(play: true), by: 1, to: s, rng: &rng)
        // The dealer (seat 0) opens with their throw-only turn.
        s = try RummyEngine.apply(
            .throwCard(s.players[0].hand.first { !$0.isJoker }!), by: 0, to: s, rng: &rng)
        s = try RummyEngine.apply(.drawFromPile, by: 1, to: s, rng: &rng)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(RummyState.self, from: data)
        #expect(decoded == s)
    }

    @Test func savedGameKeepsItsOwnRuleValues() throws {
        var config = RulesConfig.default
        config.minimumLayDown = 75
        config.eliminationScore = 500
        var rng = SeededRNG(seed: 3)
        let s = RummyEngine.newGame(config: config, names: ["A", "B", "C", "D"], dealerSeat: 1, rng: &rng)
        let decoded = try JSONDecoder().decode(RummyState.self, from: JSONEncoder().encode(s))
        #expect(decoded.config.minimumLayDown == 75)
        #expect(decoded.config.eliminationScore == 500)
    }
}
