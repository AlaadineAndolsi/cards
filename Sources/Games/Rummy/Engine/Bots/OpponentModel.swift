import Foundation

/// A human-style read of the table, built from public information only: what
/// the next player took and declined, what everyone threw, what sits in melds.
/// Memory is imperfect by design — recent events are sharp, old ones fade at
/// the level's decay rate, and low levels barely model opponents at all.
struct OpponentModel {
    private let weights: BotWeights
    private let nextHasLaidDown: Bool
    private let tableMelds: [TableMeld]
    /// Next player's takes, most recent last, paired with a decayed weight.
    private let weightedTakes: [(card: Card, weight: Double)]
    /// Cards in my own stack the next player looked at and left.
    private let declined: [Card]
    /// Throw-stack cards inside the memory window (melds are always in view).
    private let rememberedThrows: [Card]

    init(view: PublicGameView, weights: BotWeights) {
        self.weights = weights
        self.tableMelds = view.tableMelds
        let next = view.players[view.nextAliveSeat]
        self.nextHasLaidDown = next.hasLaidDown

        let takes = next.takenThrows.suffix(weights.memoryWindow == .max ? next.takenThrows.count : weights.memoryWindow)
        self.weightedTakes = takes.enumerated().map { offset, card in
            (card, pow(weights.memoryDecay, Double(takes.count - 1 - offset)))
        }
        // Everything still in my stack was available to the next player and
        // passed over at least once.
        self.declined = weights.opponentModelDepth >= 2 ? view.players[view.seat].throwStack : []
        self.rememberedThrows = view.players.flatMap { player in
            player.throwStack.suffix(weights.memoryWindow == .max ? player.throwStack.count : weights.memoryWindow)
        }
    }

    // MARK: - Danger: would this throw feed the next player?

    /// 0…1 likelihood-ish score that the next player wants this card.
    func danger(of card: Card) -> Double {
        guard weights.opponentModelDepth > 0 else { return 0 }
        if card.isJoker { return 1 }

        if nextHasLaidDown {
            // After their lay-down the threat is the table itself: anything
            // they can append, or a real card that frees a table joker.
            return postLayDownDanger(of: card)
        }

        guard let rank = card.rank else { return 0 }
        var score = 0.0
        for (taken, weight) in weightedTakes {
            guard let takenRank = taken.rank else { continue }
            if takenRank == rank && taken.suit != card.suit { score += 0.9 * weight }
            if taken.suit == card.suit {
                switch abs(takenRank.rawValue - rank.rawValue) {
                case 1: score += 0.8 * weight
                case 2: score += 0.4 * weight
                default: break
                }
            }
        }
        if weights.opponentModelDepth >= 2 {
            for safe in declined {
                guard let safeRank = safe.rank else { continue }
                if safeRank == rank { score -= 0.35 }
                if safe.suit == card.suit, abs(safeRank.rawValue - rank.rawValue) <= 2 { score -= 0.25 }
            }
        }
        return min(1, max(0, score))
    }

    private func postLayDownDanger(of card: Card) -> Double {
        guard let rank = card.rank, let suit = card.suit else { return 0 }
        let entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
        for tableMeld in tableMelds {
            if tableMeld.meld.inserting(entry) != nil { return 1 }
            // The real card behind a played joker: throwing it offers a free
            // swap and a loose joker.
            if tableMeld.meld.entries.contains(where: {
                $0.card.isJoker && $0.asRank == rank && $0.asSuit == suit
            }) {
                return 0.9
            }
        }
        return 0
    }

    // MARK: - Dead-card book

    /// Copies of this exact card currently visible *and remembered*.
    func visibleCount(rank: Rank, suit: Suit) -> Int {
        let inMelds = tableMelds.flatMap { $0.meld.cards }
            .filter { $0.rank == rank && $0.suit == suit }.count
        let inThrows = rememberedThrows
            .filter { $0.rank == rank && $0.suit == suit }.count
        return inMelds + inThrows
    }

    /// Both copies gone: no meld through this exact card can ever complete.
    func isDeadPair(rank: Rank, suit: Suit) -> Bool {
        visibleCount(rank: rank, suit: suit) >= 2
    }

    /// 0…1 how completable this card's melds remain given remembered deaths.
    func liveliness(of card: Card) -> Double {
        guard weights.opponentModelDepth > 0, let rank = card.rank, let suit = card.suit else { return 1 }
        var deadCount = 0
        var helperCount = 0
        for neighborOffset in [-2, -1, 1, 2] {
            guard let neighbor = Rank(rawValue: rank.rawValue + neighborOffset) else { continue }
            helperCount += 2
            deadCount += visibleCount(rank: neighbor, suit: suit)
        }
        for otherSuit in Suit.allCases where otherSuit != suit {
            helperCount += 2
            deadCount += visibleCount(rank: rank, suit: otherSuit)
        }
        guard helperCount > 0 else { return 1 }
        return max(0, 1 - Double(deadCount) / Double(helperCount) * 1.5)
    }
}
