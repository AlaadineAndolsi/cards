import Foundation
import Testing
@testable import Cards

enum GameDriver {
    static func actingSeat(_ s: RummyState) -> Int? {
        switch s.phase {
        case .dealing: s.dealerSeat
        case .vote(_, let current): current
        case .turn(let seat, _): seat
        case .roundEnded: s.players.firstIndex { !$0.isEliminated }
        case .matchEnded: nil
        }
    }

    /// Aggregate observations from full bot-vs-bot games, for the sanity
    /// metrics: skill ordering, glory-close frequency, elimination fear.
    struct GameStats {
        var actions = 0
        var finalScores: [Int] = []
        var places: [Int] = []            // per seat, 1…4
        var totalCloses = 0
        /// Closes where the closer slammed ≥ 12 cards in one lay having never
        /// laid before — the 14-card satisfaction close.
        var gloryCloses = 0
        /// First confirmed lay-down per (near-elimination?, turns into round).
        var firstLays: [(nearDeath: Bool, turn: Int)] = []
    }

    /// Plays one full match with one bot per seat (levels may differ).
    /// Records an issue on any illegal action or non-termination.
    @discardableResult
    static func playFullGame(
        bots: [RummyBot], config: RulesConfig = .default, seed: UInt64, actionCap: Int = 40_000
    ) -> GameStats {
        var rng = SeededRNG(seed: seed)
        var state = RummyEngine.newGame(
            config: config, names: ["A", "B", "C", "D"],
            dealerSeat: Int.random(in: 0..<4, using: &rng), rng: &rng)
        var stats = GameStats()
        var scoreAtRoundStart = [0, 0, 0, 0]
        var gloryPending = [false, false, false, false]

        while stats.actions < actionCap {
            guard let seat = actingSeat(state) else {
                if case .matchEnded(let placements) = state.phase {
                    stats.finalScores = state.players.map(\.totalScore)
                    stats.places = placements.sorted { $0.seat < $1.seat }.map(\.place)
                }
                return stats
            }
            let view = PublicGameView(state: state, seat: seat)
            let action = bots[seat].decide(view, rng: &rng)
            let before = state
            do {
                state = try RummyEngine.apply(action, by: seat, to: state, rng: &rng)
            } catch {
                Issue.record("Illegal bot action \(action) by seat \(seat) at step \(stats.actions) (seed \(seed)): \(error)")
                return stats
            }
            stats.actions += 1
            observe(action: action, by: seat, before: before, after: state,
                    stats: &stats, scoreAtRoundStart: &scoreAtRoundStart,
                    gloryPending: &gloryPending, config: config)
            if stats.actions % 200 == 0 { assertConservation(state, seed: seed) }
        }
        Issue.record("Game did not terminate in \(actionCap) actions (seed \(seed))")
        return stats
    }

    private static func observe(
        action: RummyAction, by seat: Int, before: RummyState, after: RummyState,
        stats: inout GameStats, scoreAtRoundStart: inout [Int],
        gloryPending: inout [Bool], config: RulesConfig
    ) {
        // A never-laid player dropping ≥ 12 cards at once is hunting glory.
        switch action {
        case .layDown(let melds), .takeThrowAndLayDown(let melds):
            if !before.players[seat].hasLaidDown,
               before.players[seat].pendingLayDownValue == nil,
               melds.reduce(0, { $0 + $1.entries.count }) >= 12 {
                gloryPending[seat] = true
            }
        default: break
        }

        // First confirmed lay-down of the round (flips at the throw).
        if !before.players[seat].hasLaidDown, after.players[seat].hasLaidDown {
            let nearDeath = scoreAtRoundStart[seat] >= config.eliminationScore - 120
            stats.firstLays.append((nearDeath, before.turnsCompletedThisRound))
        }

        if case .roundEnded(let result) = after.phase {
            if let closer = result.closerSeat {
                stats.totalCloses += 1
                if gloryPending[closer] { stats.gloryCloses += 1 }
            }
            gloryPending = [false, false, false, false]
        }
        if case .startNextRound = action {
            scoreAtRoundStart = after.players.map(\.totalScore)
            gloryPending = [false, false, false, false]
        }
    }

    static func assertConservation(_ s: RummyState, seed: UInt64) {
        let ids = s.drawPile.map(\.id)
            + s.players.flatMap { $0.hand.map(\.id) + $0.throwStack.map(\.id) }
            + s.tableMelds.flatMap { $0.meld.cards.map(\.id) }
        #expect(ids.count == 108, "card count broke (seed \(seed))")
        #expect(Set(ids).count == 108, "duplicate card ids (seed \(seed))")
    }
}

struct BotFuzzTests {
    /// Legality + termination fuzz, with the psychology metrics collected
    /// from the same games (§7): glory hunts happen but stay a minority, and
    /// bots near elimination lay down earlier than cushioned ones.
    @Test(arguments: BotLevel.allCases)
    func fullGamesAreLegalTerminateAndStaySane(level: BotLevel) {
        var config = RulesConfig.default
        config.botLevel = level
        let bots = (0..<4).map { _ in RummyBot(level: level) }
        var gloryCloses = 0, totalCloses = 0
        var nearDeathLayTurns: [Int] = []
        var cushionedLayTurns: [Int] = []
        for seed in 0..<350 {
            let stats = GameDriver.playFullGame(
                bots: bots, config: config,
                seed: UInt64(seed) &* 1000 &+ UInt64(level.rawValue))
            gloryCloses += stats.gloryCloses
            totalCloses += stats.totalCloses
            for lay in stats.firstLays {
                if lay.nearDeath { nearDeathLayTurns.append(lay.turn) }
                else { cushionedLayTurns.append(lay.turn) }
            }
        }
        #expect(totalCloses > 0, "rounds must end by closing sometimes")
        // Glory hunts occur but remain a minority of closes.
        #expect(gloryCloses < max(1, totalCloses * 35 / 100),
                "glory closes \(gloryCloses)/\(totalCloses) should be a minority at \(level)")
        if level == .expert {
            #expect(gloryCloses >= 1, "the satisfaction close must exist at expert")
        }
        // Elimination fear: threatened bots bank their lay-down earlier.
        if nearDeathLayTurns.count >= 30, cushionedLayTurns.count >= 30, level != .beginner {
            let nearMean = Double(nearDeathLayTurns.reduce(0, +)) / Double(nearDeathLayTurns.count)
            let calmMean = Double(cushionedLayTurns.reduce(0, +)) / Double(cushionedLayTurns.count)
            #expect(nearMean < calmMean,
                    "near-elimination bots should lay earlier (\(nearMean) vs \(calmMean)) at \(level)")
        }
    }

    /// Same cards, different skill: two experts vs two beginners at the same
    /// table. Over many games the experts must take fewer points.
    @Test func expertsOutperformBeginnersAtTheSameTable() {
        let bots = [RummyBot(level: .expert), RummyBot(level: .beginner),
                    RummyBot(level: .expert), RummyBot(level: .beginner)]
        var expertPoints = 0, beginnerPoints = 0
        var expertPlaces = 0, beginnerPlaces = 0
        var finished = 0
        for seed in 0..<150 {
            let stats = GameDriver.playFullGame(bots: bots, seed: 777_000 &+ UInt64(seed))
            guard stats.finalScores.count == 4, stats.places.count == 4 else { continue }
            finished += 1
            expertPoints += stats.finalScores[0] + stats.finalScores[2]
            beginnerPoints += stats.finalScores[1] + stats.finalScores[3]
            expertPlaces += stats.places[0] + stats.places[2]
            beginnerPlaces += stats.places[1] + stats.places[3]
        }
        #expect(finished > 100)
        #expect(expertPoints < beginnerPoints,
                "experts \(expertPoints) must out-score beginners \(beginnerPoints)")
        #expect(expertPlaces < beginnerPlaces,
                "experts \(expertPlaces) must place better than beginners \(beginnerPlaces)")
    }

    @Test func handInvariantsHoldThroughoutAGame() {
        var rng = SeededRNG(seed: 424242)
        var config = RulesConfig.default
        config.botLevel = .expert
        var state = RummyEngine.newGame(config: config, names: ["A", "B", "C", "D"], dealerSeat: 0, rng: &rng)
        let bot = RummyBot(level: .expert)
        var steps = 0
        while let seat = GameDriver.actingSeat(state), steps < 40_000 {
            let view = PublicGameView(state: state, seat: seat)
            let action = bot.decide(view, rng: &rng)
            do {
                state = try RummyEngine.apply(action, by: seat, to: state, rng: &rng)
            } catch {
                Issue.record("Illegal action \(action) by seat \(seat) at step \(steps): \(error)")
                return
            }
            steps += 1
            if case .turn(let turnSeat, .awaitingDraw) = state.phase {
                for i in state.players.indices where !state.players[i].isEliminated {
                    let count = state.players[i].hand.count
                    if i == turnSeat {
                        // Before drawing: never empty (the round would have
                        // ended) and never above 14 (laydowns only shrink it).
                        #expect(count >= 1 && count <= 14)
                    } else {
                        // Off-turn cap is 14 — except a dealer who has not yet
                        // played their first turn of the round (15).
                        #expect(count <= 14 || (count == 15 && i == state.dealerSeat))
                        #expect(count >= 1)
                    }
                }
            }
        }
        #expect(GameDriver.actingSeat(state) == nil, "game should have ended")
    }
}
