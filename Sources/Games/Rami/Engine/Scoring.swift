import Foundation

enum Scoring {

    /// Applies round-end scoring after `closerSeat` threw their last card:
    /// closer 0; players who never laid down +100 flat; everyone else the sum
    /// of cards left in hand (2–10 face value; J/Q/K/A/joker = 10). Then
    /// eliminates players at or above the configured score and either
    /// continues to the next round or ends the match.
    static func settleRound(_ s: inout RamiState, closerSeat: Int) {
        var deltas = [Int](repeating: 0, count: s.players.count)
        for seat in s.players.indices {
            guard !s.players[seat].isEliminated else {
                s.players[seat].roundScores.append(nil)
                continue
            }
            let delta: Int
            if seat == closerSeat {
                delta = 0
            } else if s.players[seat].hasLaidDown {
                delta = s.players[seat].hand.reduce(0) { $0 + $1.handValue }
            } else {
                delta = 100
            }
            deltas[seat] = delta
            s.players[seat].roundScores.append(delta)
            s.players[seat].totalScore += delta
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
    static func finalPlacements(_ s: RamiState) -> [FinalPlacement] {
        let survivors = s.players.indices
            .filter { !s.players[$0].isEliminated }
            .sorted { s.players[$0].totalScore < s.players[$1].totalScore }
        let ranked = survivors + s.eliminationOrder.reversed()
        return ranked.enumerated().map { index, seat in
            FinalPlacement(seat: seat, place: index + 1, score: s.players[seat].totalScore)
        }
    }
}
