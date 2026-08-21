import Foundation

enum Scoring {

    /// Applies round-end scoring after `closerSeat` threw their last card:
    /// closer 0; players who never laid down +100 flat; everyone else the sum
    /// of cards left in hand (2–10 face value; J/Q/K/A/joker = 10). Then
    /// eliminates players at or above the configured score and either
    /// continues to the next round or ends the match.
    static func settleRound(_ s: inout RummyState, closerSeat: Int) {
        var deltas = [Int](repeating: 0, count: s.players.count)
        for seat in s.players.indices where !s.players[seat].isEliminated {
            if seat == closerSeat {
                deltas[seat] = 0
            } else if s.players[seat].hasLaidDown {
                deltas[seat] = s.players[seat].hand.reduce(0) { $0 + $1.handValue }
            } else {
                deltas[seat] = 100
            }
        }
        finish(&s, deltas: deltas, closerSeat: closerSeat)
    }

    /// A player took the throw without any qualifying lay-down possible:
    /// they take 100 flat, everyone else 0, and the round ends immediately.
    static func settleFailedTake(_ s: inout RummyState, penalized seat: Int) {
        var deltas = [Int](repeating: 0, count: s.players.count)
        deltas[seat] = 100
        finish(&s, deltas: deltas, closerSeat: nil)
    }

    private static func finish(_ s: inout RummyState, deltas: [Int], closerSeat: Int?) {
        var deltas = deltas
        for seat in s.players.indices {
            guard !s.players[seat].isEliminated else {
                s.players[seat].roundScores.append(nil)
                continue
            }
            deltas[seat] += s.players[seat].penaltiesThisRound
            s.players[seat].roundScores.append(deltas[seat])
            s.players[seat].totalScore += deltas[seat]
        }

        // Psychology settles with the points: bots tilt on bad rounds and calm
        // on good ones. Pure — the outcome above is untouched.
        if var minds = s.botMinds {
            for seat in s.players.indices
            where !s.players[seat].isHuman && !s.players[seat].isEliminated && minds.indices.contains(seat) {
                minds[seat].absorbRound(
                    myDelta: deltas[seat],
                    iClosed: seat == closerSeat,
                    someoneElseClosed: closerSeat != nil && closerSeat != seat,
                    level: s.config.botLevel)
            }
            s.botMinds = minds
        }

        // Among simultaneous deaths, the higher total dies "first" (worse place).
        let newlyDead = s.players.indices
            .filter { !s.players[$0].isEliminated && s.players[$0].totalScore >= s.config.eliminationScore }
            .sorted { s.players[$0].totalScore > s.players[$1].totalScore }
        for seat in newlyDead {
            s.players[seat].isEliminated = true
            s.eliminationOrder.append(seat)
        }

        let result = RoundResult(closerSeat: closerSeat, deltas: deltas, newlyEliminated: newlyDead)
        if s.aliveCount <= 2 && !newlyDead.isEmpty {
            s.phase = .matchEnded(finalPlacements(s))
        } else {
            s.phase = .roundEnded(result)
        }
    }

    /// Survivors ranked by fewest points, then eliminated players in reverse
    /// elimination order.
    static func finalPlacements(_ s: RummyState) -> [FinalPlacement] {
        let survivors = s.players.indices
            .filter { !s.players[$0].isEliminated }
            .sorted { s.players[$0].totalScore < s.players[$1].totalScore }
        let ranked = survivors + s.eliminationOrder.reversed()
        return ranked.enumerated().map { index, seat in
            FinalPlacement(seat: seat, place: index + 1, score: s.players[seat].totalScore)
        }
    }
}
