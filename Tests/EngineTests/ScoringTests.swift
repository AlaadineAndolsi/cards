import Foundation
import Testing
@testable import Cards

struct ClosingAndScoringTests {
    /// Seat 0 about to close: 1 card in hand. Seat 1 laid down, holds K+9 (19).
    /// Seat 2 never laid down (100 flat). Seat 3 laid down, holds a joker + 5 = 15.
    private func closingState() -> RamiState {
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
        s = try RamiEngine.apply(.deal(.p1111), by: s.dealerSeat, to: s, rng: &rng)
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
        var s = RamiEngine.newGame(config: .default, names: ["A", "B", "C", "D"], dealerSeat: 0, rng: &rng)
        s = try RamiEngine.apply(.shuffle, by: 0, to: s, rng: &rng)
        s = try RamiEngine.apply(.deal(.p3222), by: 0, to: s, rng: &rng)
        s = try RamiEngine.apply(.declareIntent(play: true), by: 1, to: s, rng: &rng)
        s = try RamiEngine.apply(.drawFromPile, by: 1, to: s, rng: &rng)
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(RamiState.self, from: data)
        #expect(decoded == s)
    }

    @Test func savedGameKeepsItsOwnRuleValues() throws {
        var config = RulesConfig.default
        config.minimumLayDown = 75
        config.eliminationScore = 500
        var rng = SeededRNG(seed: 3)
        let s = RamiEngine.newGame(config: config, names: ["A", "B", "C", "D"], dealerSeat: 1, rng: &rng)
        let decoded = try JSONDecoder().decode(RamiState.self, from: JSONEncoder().encode(s))
        #expect(decoded.config.minimumLayDown == 75)
        #expect(decoded.config.eliminationScore == 500)
    }
}
