import Foundation
import Testing
@testable import Cards

enum GameDriver {
    static func actingSeat(_ s: RamiState) -> Int? {
        switch s.phase {
        case .dealing: s.dealerSeat
        case .vote(_, let current): current
        case .turn(let seat, _): seat
        case .roundEnded: s.players.firstIndex { !$0.isEliminated }
        case .matchEnded: nil
        }
    }

    /// Plays one full bot-vs-bot match. Returns the number of actions, or
    /// records an issue if any bot action is illegal or the game fails to end.
    @discardableResult
    static func playFullGame(level: BotLevel, seed: UInt64, actionCap: Int = 40_000) -> Int {
        var rng = SeededRNG(seed: seed)
        var config = RulesConfig.default
        config.botLevel = level
        var state = RamiEngine.newGame(
            config: config, names: ["A", "B", "C", "D"],
            dealerSeat: Int.random(in: 0..<4, using: &rng), rng: &rng)
        let bot = RamiBot(level: level)
        var actions = 0
        while actions < actionCap {
            guard let seat = actingSeat(state) else { return actions }  // match ended
            let view = PublicGameView(state: state, seat: seat)
            let action = bot.decide(view, rng: &rng)
            do {
                state = try RamiEngine.apply(action, by: seat, to: state, rng: &rng)
            } catch {
                Issue.record("Illegal bot action \(action) by seat \(seat) at step \(actions) (seed \(seed), level \(level)): \(error)")
                return actions
            }
            actions += 1
            if actions % 100 == 0 { assertConservation(state, seed: seed) }
        }
        Issue.record("Game did not terminate in \(actionCap) actions (seed \(seed), level \(level))")
        return actions
    }

    static func assertConservation(_ s: RamiState, seed: UInt64) {
        let ids = s.drawPile.map(\.id)
            + s.players.flatMap { $0.hand.map(\.id) + $0.throwStack.map(\.id) }
            + s.tableMelds.flatMap { $0.meld.cards.map(\.id) }
        #expect(ids.count == 108, "card count broke (seed \(seed))")
        #expect(Set(ids).count == 108, "duplicate card ids (seed \(seed))")
    }
}

struct BotFuzzTests {
    @Test(arguments: BotLevel.allCases)
    func fullGamesAreLegalAndTerminate(level: BotLevel) {
        for seed in 0..<350 {
            GameDriver.playFullGame(level: level, seed: UInt64(seed) &* 1000 &+ UInt64(level.rawValue))
        }
    }

    @Test func handInvariantsHoldThroughoutAGame() {
        var rng = SeededRNG(seed: 424242)
        var config = RulesConfig.default
        config.botLevel = .expert
        var state = RamiEngine.newGame(config: config, names: ["A", "B", "C", "D"], dealerSeat: 0, rng: &rng)
        let bot = RamiBot(level: .expert)
        var steps = 0
        while let seat = GameDriver.actingSeat(state), steps < 40_000 {
            let view = PublicGameView(state: state, seat: seat)
            let action = bot.decide(view, rng: &rng)
            do {
                state = try RamiEngine.apply(action, by: seat, to: state, rng: &rng)
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
