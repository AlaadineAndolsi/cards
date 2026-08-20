import Foundation

/// Decides one action at a time from public information only. All three levels
/// receive identical cards and identical views — difficulty changes strategy,
/// never information or luck.
struct RamiBot: Sendable {
    let level: BotLevel

    func decide(_ view: PublicGameView, rng: inout some RandomNumberGenerator) -> RamiAction {
        switch view.phase {
        case .dealing(let shuffles):
            // Shuffle a random number of times, then pick a random pattern.
            let target = Int.random(in: 1...4, using: &rng)
            if shuffles < target { return .shuffle }
            return .deal(DealPattern.allCases.randomElement(using: &rng)!)

        case .vote:
            return .declareIntent(play: wantsToPlay(view))

        case .turn(_, .awaitingDraw):
            return drawDecision(view)

        case .turn(_, .awaitingThrow(_, let pendingJoker)):
            return meldOrThrowDecision(view, pendingJoker: pendingJoker, rng: &rng)

        case .roundEnded:
            return .startNextRound

        case .matchEnded:
            return .startNextRound  // never reached; engine rejects
        }
    }

    // MARK: - Vote

    /// Hand quality heuristic: melded value plus loose synergy.
    private func wantsToPlay(_ view: PublicGameView) -> Bool {
        let partition = HandAnalysis.bestPartition(hand: view.hand)
        var synergy = 0
        for i in view.hand.indices {
            for j in view.hand.indices where j > i {
                synergy += pairSynergy(view.hand[i], view.hand[j])
            }
        }
        let quality = partition.value + synergy * 2
        return quality >= view.config.minimumLayDown * 2 / 5
    }

    private func pairSynergy(_ a: Card, _ b: Card) -> Int {
        if a.isJoker || b.isJoker { return 2 }
        guard let ra = a.rank, let rb = b.rank else { return 0 }
        if ra == rb && a.suit != b.suit { return 2 }
        if a.suit == b.suit {
            let distance = abs(ra.rawValue - rb.rawValue)
            if distance == 1 { return 2 }
            if distance == 2 { return 1 }
        }
        return 0
    }

    // MARK: - Draw step

    private func drawDecision(_ view: PublicGameView) -> RamiAction {
        guard view.throwTakeUnlocked, let takeable = view.takeableCard else { return .drawFromPile }

        if view.hasLaidDown {
            // Worth taking when it appends to a table meld or completes a meld in hand.
            if appendEntry(for: takeable, in: view.tableMelds) != nil { return .takeThrow }
            let withCard = view.hand + [takeable]
            let index = withCard.count - 1
            let completes = HandAnalysis.candidates(hand: withCard)
                .contains { $0.mask & (1 << index) != 0 }
            if completes { return .takeThrow }
            return .drawFromPile
        }

        // Before the first lay-down, taking requires laying down right now.
        let withCard = view.hand + [takeable]
        var partition = HandAnalysis.bestPartition(hand: withCard)
        if partition.coveredCount == withCard.count {
            partition = droppingSmallestMeld(partition)
        }
        if partition.value >= view.requiredLayDown, !partition.melds.isEmpty,
           partition.coveredCount < withCard.count {
            return .takeThrowAndLayDown(melds: partition.melds)
        }
        return .drawFromPile
    }

    private func droppingSmallestMeld(_ partition: HandAnalysis.Partition) -> HandAnalysis.Partition {
        var result = partition
        guard let index = result.melds.indices.min(by: { a, b in
            ((try? result.melds[a].validatedThresholdValue()) ?? 0)
                < ((try? result.melds[b].validatedThresholdValue()) ?? 0)
        }) else { return result }
        let removed = result.melds.remove(at: index)
        result.value -= (try? removed.validatedThresholdValue()) ?? 0
        result.coveredCount -= removed.entries.count
        return result
    }

    // MARK: - Meld / throw step

    private func meldOrThrowDecision(
        _ view: PublicGameView, pendingJoker: Card?, rng: inout some RandomNumberGenerator
    ) -> RamiAction {
        // A joker swapped off the table must be replayed before anything else.
        if let joker = pendingJoker {
            return placeJoker(joker, view: view)
        }

        if !view.hasLaidDown {
            // Close outright if the whole hand melds at threshold value.
            if let closing = HandAnalysis.closingMelds(hand: view.hand) {
                let total = closing.reduce(0) { $0 + ((try? $1.validatedThresholdValue()) ?? 0) }
                if total >= view.requiredLayDown { return .layDown(melds: closing) }
            }
            var partition = HandAnalysis.bestPartition(hand: view.hand)
            if partition.coveredCount == view.hand.count {
                partition = droppingSmallestMeld(partition)
            }
            if partition.value >= view.requiredLayDown, !partition.melds.isEmpty,
               partition.coveredCount < view.hand.count {
                return .layDown(melds: partition.melds)
            }
            return .throwCard(chooseDiscard(view, rng: &rng))
        }

        // Already laid down: shed cards aggressively.
        if let closing = HandAnalysis.closingMelds(hand: view.hand) {
            return .layDown(melds: closing)
        }
        var partition = HandAnalysis.bestPartition(hand: view.hand, maximizeCoverage: true)
        if partition.coveredCount == view.hand.count {
            partition = droppingSmallestMeld(partition)
        }
        if !partition.melds.isEmpty, partition.coveredCount < view.hand.count {
            return .layDown(melds: partition.melds)
        }
        if level != .beginner, let swap = jokerSwapOpportunity(view) {
            return swap
        }
        if view.hand.count >= 2, let append = appendOpportunity(view) {
            return append
        }
        return .throwCard(chooseDiscard(view, rng: &rng))
    }

    /// Lay the pending joker into a new meld, or append it to a table meld.
    private func placeJoker(_ joker: Card, view: PublicGameView) -> RamiAction {
        if view.hand.count >= 2 {
            guard let jokerIndex = view.hand.firstIndex(of: joker) else {
                return .throwCard(view.hand[0])  // unreachable; engine would reject anyway
            }
            let usable = HandAnalysis.candidates(hand: view.hand)
                .filter { $0.mask & (1 << jokerIndex) != 0 && $0.cardCount < view.hand.count }
                .max(by: { $0.value < $1.value })
            if let usable { return .layDown(melds: [usable.meld]) }
            for tableMeld in view.tableMelds {
                if let entry = jokerAppendEntry(joker: joker, meld: tableMeld.meld) {
                    return .appendCard(entry, meldID: tableMeld.id)
                }
            }
        }
        // Last resort: also unreachable given the swap precondition.
        return .throwCard(view.hand.first(where: { $0 != joker }) ?? joker)
    }

    /// Swap a table joker for its real card when the freed joker is immediately
    /// reusable in a meld from hand.
    private func jokerSwapOpportunity(_ view: PublicGameView) -> RamiAction? {
        guard view.hand.count >= 4 else { return nil }
        for tableMeld in view.tableMelds {
            for entry in tableMeld.meld.entries where entry.card.isJoker {
                guard let realIndex = view.hand.firstIndex(where: {
                    $0.rank == entry.asRank && $0.suit == entry.asSuit
                }) else { continue }
                let real = view.hand[realIndex]
                var afterSwap = view.hand
                afterSwap.remove(at: realIndex)
                afterSwap.append(entry.card)
                let jokerIndex = afterSwap.count - 1
                let reusable = HandAnalysis.candidates(hand: afterSwap).contains {
                    $0.mask & (1 << jokerIndex) != 0 && $0.cardCount < afterSwap.count
                }
                let appendable = view.tableMelds.contains {
                    jokerAppendEntry(joker: entry.card, meld: $0.meld) != nil
                }
                if reusable || appendable {
                    return .swapJoker(meldID: tableMeld.id, realCard: real)
                }
            }
        }
        return nil
    }

    /// First deadwood card that legally extends any table meld.
    private func appendOpportunity(_ view: PublicGameView) -> RamiAction? {
        let partition = HandAnalysis.bestPartition(hand: view.hand)
        for index in view.hand.indices where partition.mask & (1 << index) == 0 {
            let card = view.hand[index]
            for tableMeld in view.tableMelds {
                if let entry = appendEntry(for: card, in: [tableMeld]) {
                    return .appendCard(entry, meldID: tableMeld.id)
                }
            }
        }
        return nil
    }

    private func appendEntry(for card: Card, in melds: [TableMeld]) -> MeldEntry? {
        for tableMeld in melds {
            if card.isJoker {
                if let entry = jokerAppendEntry(joker: card, meld: tableMeld.meld) { return entry }
                continue
            }
            guard let rank = card.rank, let suit = card.suit else { continue }
            let entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
            if tableMeld.meld.inserting(entry) != nil { return entry }
        }
        return nil
    }

    /// A face the joker could adopt to legally extend this meld.
    private func jokerAppendEntry(joker: Card, meld: Meld) -> MeldEntry? {
        meld.jokerEntryToExtend(joker: joker)
    }

    // MARK: - Discard choice (where the levels really differ)

    private func chooseDiscard(_ view: PublicGameView, rng: inout some RandomNumberGenerator) -> Card {
        let hand = view.hand
        let partition = HandAnalysis.bestPartition(hand: hand)
        var deadwood = hand.indices.filter { partition.mask & (1 << $0) == 0 }
        if deadwood.isEmpty { deadwood = Array(hand.indices) }

        var bestIndex = deadwood[0]
        var bestScore = -Double.infinity
        for index in deadwood {
            let score = discardScore(hand[index], view: view)
                + Double.random(in: 0..<0.01, using: &rng)  // tie-break only
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return hand[bestIndex]
    }

    /// Higher = better to throw.
    private func discardScore(_ card: Card, view: PublicGameView) -> Double {
        var score = 1.0
        if card.isJoker { return -100 }  // never throw a joker

        // Keep cards that still work toward melds in hand.
        for other in view.hand where other != card {
            score -= Double(pairSynergy(card, other)) * 0.2 * liveliness(card, view: view)
        }

        switch level {
        case .beginner:
            // Greedy: slight preference for shedding expensive cards.
            score += Double(card.handValue) * 0.03

        case .intermediate:
            score += Double(card.handValue) * 0.03
            score += danger(card, takenBy: view.players[view.nextAliveSeat].takenThrows,
                            recentOnly: true, view: view)

        case .expert:
            let next = view.players[view.nextAliveSeat]
            score += danger(card, takenBy: next.takenThrows, recentOnly: false, view: view)
            // Cards the next player declined (left in our stack) mark safe zones.
            let declined = view.players[view.seat].throwStack
            for safe in declined {
                if let sr = safe.rank, let cr = card.rank {
                    if sr == cr { score += 0.25 }
                    if safe.suit == card.suit, abs(sr.rawValue - cr.rawValue) <= 2 { score += 0.2 }
                }
            }
            // Early round: give away small cards so the next player cannot
            // cheaply reach the threshold; later, dump expensive deadwood.
            let early = view.turnsCompletedThisRound < view.aliveCount * 2
                && !view.players.contains(where: \.hasLaidDown)
            score += early
                ? Double(11 - card.handValue) * 0.06
                : Double(card.handValue) * 0.06
        }
        return score
    }

    /// 0…1: how completable this card's melds still are, from dead-card counting.
    /// Beginner ignores it; intermediate sees a recent window; expert sees all.
    private func liveliness(_ card: Card, view: PublicGameView) -> Double {
        guard level != .beginner, let rank = card.rank, let suit = card.suit else { return 1 }
        let visible: [Card]
        switch level {
        case .beginner: return 1
        case .intermediate:
            visible = view.players.flatMap { $0.throwStack.suffix(2) }
        case .expert:
            visible = view.visibleCards
        }
        var deadCount = 0
        var helperCount = 0
        for neighborOffset in [-2, -1, 1, 2] {
            guard let neighbor = Rank(rawValue: rank.rawValue + neighborOffset) else { continue }
            helperCount += 2
            deadCount += visible.filter { $0.rank == neighbor && $0.suit == suit }.count
        }
        for otherSuit in Suit.allCases where otherSuit != suit {
            helperCount += 2
            deadCount += visible.filter { $0.rank == rank && $0.suit == otherSuit }.count
        }
        guard helperCount > 0 else { return 1 }
        return max(0, 1 - Double(deadCount) / Double(helperCount) * 1.5)
    }

    /// Negative when throwing this card would likely feed the next player.
    private func danger(
        _ card: Card, takenBy taken: [Card], recentOnly: Bool, view: PublicGameView
    ) -> Double {
        guard let rank = card.rank else { return 0 }
        let considered = recentOnly ? Array(taken.suffix(3)) : taken
        var score = 0.0
        for takenCard in considered {
            guard let takenRank = takenCard.rank else { continue }
            if takenRank == rank && takenCard.suit != card.suit { score -= 0.9 }
            if takenCard.suit == card.suit {
                let distance = abs(takenRank.rawValue - rank.rawValue)
                if distance == 1 { score -= 0.8 }
                else if distance == 2 { score -= 0.4 }
            }
        }
        return score
    }
}
