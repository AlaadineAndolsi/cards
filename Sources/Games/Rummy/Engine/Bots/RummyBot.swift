import Foundation

/// Decides one action at a time from public information only. All three levels
/// receive identical cards and identical views — difficulty changes strategy,
/// never information or luck.
struct RummyBot: Sendable {
    let level: BotLevel

    func decide(_ view: PublicGameView, rng: inout some RandomNumberGenerator) -> RummyAction {
        switch view.phase {
        case .dealing(let shuffles):
            // Shuffle a random number of times, then pick a random pattern.
            let target = Int.random(in: 1...4, using: &rng)
            if shuffles < target { return .shuffle }
            return .deal(DealPattern.allCases.randomElement(using: &rng)!)

        case .vote:
            // A hand dead in doubles forces the redeal outright.
            if RummyEngine.canForcePass(hand: view.hand) { return .forcePass }
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

    // MARK: - Objective ladder (§1): close > lay-and-bleed > never eat 100

    enum Objective: Equatable {
        /// Hold a nearly-complete hand and hunt the 14-card satisfaction close.
        case huntGloryClose
        /// Already laid: keep bleeding cards onto melds toward zero.
        case bleed
        /// Bank a qualifying lay-down the normal way.
        case secureLayDown
        /// Danger is high and nothing is banked: lock in *any* lay-down now.
        case panicLayDown
    }

    func weights(for view: PublicGameView) -> BotWeights {
        .resolve(level: level, archetype: view.mind.archetype, frustration: view.mind.frustration)
    }

    /// Close to the kill score, a bot stops gambling entirely. Awareness of
    /// this shrinks with level — beginners barely feel the cliff coming.
    func nearElimination(_ view: PublicGameView) -> Bool {
        let margin = Int(120 * weights(for: view).eliminationAwareness)
        return view.players[view.seat].totalScore >= view.config.eliminationScore - margin
    }

    /// 0…1 urgency: the pile draining, an opponent about to close, the
    /// threshold escaping upward, the round dragging on.
    func roundHeat(_ view: PublicGameView) -> Double {
        var heat = 0.0
        let pile = Double(view.drawPileCount)
        if pile < 25 { heat += (25 - pile) / 25 * 0.6 }
        let threat = view.players.indices
            .filter { $0 != view.seat && !view.players[$0].isEliminated }
            .map { view.players[$0].handCount }
            .min() ?? 14
        if threat <= 2 { heat += 0.6 } else if threat <= 4 { heat += 0.45 } else if threat <= 6 { heat += 0.2 }
        if view.players.enumerated().contains(where: { $0.offset != view.seat && $0.element.hasLaidDown }) {
            heat += 0.2
        }
        if view.requiredLayDown > view.config.minimumLayDown { heat += 0.15 }
        let age = Double(view.turnsCompletedThisRound) / Double(max(1, view.aliveCount))
        heat += min(0.25, max(0, (age - 8) * 0.03))
        return min(1, heat)
    }

    /// Comfortable enough to gamble: at or below the table's median score and
    /// far from elimination.
    func scoreCushion(_ view: PublicGameView) -> Bool {
        let alive = view.players.filter { !$0.isEliminated }.map(\.totalScore).sorted()
        guard !alive.isEmpty else { return false }
        let my = view.players[view.seat].totalScore
        return my <= alive[alive.count / 2] && view.config.eliminationScore - my >= 250
    }

    /// 0…1 plausibility of melding the full hand: current meld coverage plus
    /// how alive the leftover cards still are given remembered dead cards.
    func closePotential(_ view: PublicGameView) -> Double {
        closePotential(view, partition: HandAnalysis.bestPartition(hand: view.hand, maximizeCoverage: true))
    }

    private func closePotential(_ view: PublicGameView, partition: HandAnalysis.Partition) -> Double {
        let hand = view.hand
        guard hand.count > 1 else { return 0 }
        let target = Double(hand.count - 1)
        let coverage = Double(min(partition.coveredCount, hand.count - 1)) / target
        let loose = hand.indices.filter { partition.mask & (1 << $0) == 0 }.map { hand[$0] }
        let model = OpponentModel(view: view, weights: weights(for: view))
        let liveliness = loose.isEmpty
            ? 1
            : loose.reduce(0.0) { $0 + ($1.isJoker ? 1 : model.liveliness(of: $1)) } / Double(loose.count)
        return coverage * 0.7 + liveliness * 0.3
    }

    /// Which tier of the outcome hierarchy this bot is realistically playing
    /// for right now — re-estimated every decision, personality-weighted.
    func objective(_ view: PublicGameView) -> Objective {
        if view.hasLaidDown { return .bleed }
        let w = weights(for: view)
        let heat = roundHeat(view)
        if nearElimination(view) { return heat > 0.5 ? .panicLayDown : .secureLayDown }
        if heat > 0.7 { return .panicLayDown }
        // The glory hunt: only with appetite, a score cushion, and a cool
        // room. Experts read heat sharply; beginners barely notice it. A hand
        // already one-or-two cards from complete stays committed (hysteresis).
        let heatCap = 0.4 + 0.4 * (1 - w.eliminationAwareness)
        if w.gloryAppetite > 0.3, scoreCushion(view), heat < heatCap {
            let partition = HandAnalysis.bestPartition(hand: view.hand, maximizeCoverage: true)
            let bar = partition.coveredCount >= view.hand.count - 2 ? w.gloryBail : w.gloryCommit
            if closePotential(view, partition: partition) >= bar { return .huntGloryClose }
        }
        return .secureLayDown
    }

    // MARK: - Draw step

    private func drawDecision(_ view: PublicGameView) -> RummyAction {
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

        let withCard = view.hand + [takeable]
        // The glorious take: everything melds at once and one card remains to
        // throw — closing needs no threshold, so this is always safe.
        if let closing = HandAnalysis.closingMelds(hand: withCard) {
            return .takeThrowAndLayDown(melds: closing)
        }
        // A hunter refuses the partial take+lay that would blow the cover.
        if objective(view) == .huntGloryClose { return .drawFromPile }

        // Before the first lay-down, taking requires laying down right now.
        let partition = initialPartition(hand: withCard, required: view.requiredLayDown)
        if partition.value >= view.requiredLayDown, !partition.melds.isEmpty,
           partition.coveredCount < withCard.count {
            return .takeThrowAndLayDown(melds: partition.melds)
        }
        return .drawFromPile
    }

    /// Best qualifying initial lay-down, preferring to keep a closable hand
    /// (≥ 4 cards left) when dropping a meld still meets the threshold.
    private func initialPartition(hand: [Card], required: Int) -> HandAnalysis.Partition {
        var partition = HandAnalysis.bestPartition(hand: hand)
        while !partition.melds.isEmpty,
              hand.count - partition.coveredCount < 4 {
            let smaller = droppingSmallestMeld(partition)
            guard smaller.value >= required, !smaller.melds.isEmpty else { break }
            partition = smaller
        }
        // Never lay the entire hand — a throw must remain.
        while partition.coveredCount == hand.count, !partition.melds.isEmpty {
            partition = droppingSmallestMeld(partition)
        }
        return partition
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
    ) -> RummyAction {
        // A joker swapped off the table must be replayed before anything else.
        if let joker = pendingJoker {
            return placeJoker(joker, view: view)
        }

        // Already laid this turn (pending until the throw): finish the turn —
        // the laid total qualifies by construction.
        if view.pendingLayDownValue != nil {
            return .throwCard(chooseDiscard(view, rng: &rng))
        }

        // First cycle: draw and throw only, no lay-downs yet.
        guard view.turnsCompletedThisRound >= view.aliveCount else {
            return .throwCard(chooseDiscard(view, rng: &rng))
        }

        if !view.hasLaidDown {
            // Close outright when the whole hand melds — going out never
            // needs the threshold, and even a hunter slams this down.
            if let closing = HandAnalysis.closingMelds(hand: view.hand) {
                return .layDown(melds: closing)
            }
            let objective = objective(view)
            switch objective {
            case .huntGloryClose:
                // Hold everything: the hand stays hidden until the full slam.
                return .throwCard(chooseDiscard(view, rng: &rng))
            case .panicLayDown, .secureLayDown, .bleed:
                // Panic (or elimination fear) banks the biggest qualifying
                // partition immediately; the calm path trims to keep the
                // leftover hand closable.
                let partition: HandAnalysis.Partition
                if objective == .panicLayDown || nearElimination(view) {
                    var full = HandAnalysis.bestPartition(hand: view.hand)
                    while full.coveredCount == view.hand.count, !full.melds.isEmpty {
                        full = droppingSmallestMeld(full)
                    }
                    partition = full
                } else {
                    partition = initialPartition(hand: view.hand, required: view.requiredLayDown)
                }
                if partition.value >= view.requiredLayDown, !partition.melds.isEmpty,
                   partition.coveredCount < view.hand.count {
                    return .layDown(melds: partition.melds)
                }
            }
            return .throwCard(chooseDiscard(view, rng: &rng))
        }

        // Already laid down: shed cards, but never strand the hand below a
        // closable size (a 1–2 card off-turn hand can only close via appends).
        if let closing = HandAnalysis.closingMelds(hand: view.hand) {
            return .layDown(melds: closing)
        }
        var partition = HandAnalysis.bestPartition(hand: view.hand, maximizeCoverage: true)
        while !partition.melds.isEmpty, view.hand.count - partition.coveredCount < 4 {
            partition = droppingSmallestMeld(partition)
        }
        if !partition.melds.isEmpty {
            return .layDown(melds: partition.melds)
        }
        if level != .beginner, let swap = jokerSwapOpportunity(view) {
            return swap
        }
        if view.hand.count >= 5, let append = appendOpportunity(view) {
            return append
        }
        if view.hand.count >= 2, view.hand.count <= 4,
           let append = closingAppendOpportunity(view) {
            return append
        }
        return .throwCard(chooseDiscard(view, rng: &rng))
    }

    /// For a small hand: append only when every card except one throwable can
    /// be placed on the table right now — i.e. the appends chain to a close.
    private func closingAppendOpportunity(_ view: PublicGameView) -> RummyAction? {
        let hand = view.hand
        for excluded in hand.indices where !hand[excluded].isJoker || hand.count == 1 {
            var melds = view.tableMelds
            var firstAction: RummyAction?
            var allPlaced = true
            for index in hand.indices where index != excluded {
                let card = hand[index]
                var placed = false
                for meldIndex in melds.indices {
                    let entry: MeldEntry?
                    if card.isJoker {
                        entry = melds[meldIndex].meld.jokerEntryToExtend(joker: card)
                    } else if let rank = card.rank, let suit = card.suit {
                        entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
                    } else {
                        entry = nil
                    }
                    if let entry, let grown = melds[meldIndex].meld.inserting(entry) {
                        melds[meldIndex].meld = grown
                        if firstAction == nil {
                            firstAction = .appendCard(entry, meldID: melds[meldIndex].id)
                        }
                        placed = true
                        break
                    }
                }
                if !placed {
                    allPlaced = false
                    break
                }
            }
            if allPlaced, let firstAction { return firstAction }
        }
        return nil
    }

    /// Lay the pending joker into a new meld, or append it to a table meld.
    private func placeJoker(_ joker: Card, view: PublicGameView) -> RummyAction {
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
    private func jokerSwapOpportunity(_ view: PublicGameView) -> RummyAction? {
        guard view.hand.count >= 7 else { return nil }  // keep a closable hand after replaying it
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
    private func appendOpportunity(_ view: PublicGameView) -> RummyAction? {
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

    // MARK: - Discard choice: the heart of human play (§3, §4)

    private func chooseDiscard(_ view: PublicGameView, rng: inout some RandomNumberGenerator) -> Card {
        let hand = view.hand
        let w = weights(for: view)
        let model = OpponentModel(view: view, weights: w)
        let partition = HandAnalysis.bestPartition(hand: hand)
        var deadwood = hand.indices.filter { partition.mask & (1 << $0) == 0 }
        if deadwood.isEmpty { deadwood = Array(hand.indices) }

        // Never choose a penalized throw (joker / meld-fitting card) while a
        // legal one exists — the engine would bounce it back with +10.
        let legalDeadwood = deadwood.filter {
            !RummyEngine.throwPenalized(hand[$0], tableMelds: view.tableMelds)
        }
        if !legalDeadwood.isEmpty {
            deadwood = legalDeadwood
        } else {
            let legalAnywhere = hand.indices.filter {
                !RummyEngine.throwPenalized(hand[$0], tableMelds: view.tableMelds)
            }
            if !legalAnywhere.isEmpty { deadwood = legalAnywhere }
        }

        // Stalemate breaker: if the round drags on far beyond normal length,
        // churn the hand with a random legal discard instead of hoarding.
        let stalemate = view.turnsCompletedThisRound > 30 * view.aliveCount
        if stalemate {
            let nonJokers = deadwood.filter { !hand[$0].isJoker }
            let pool = nonJokers.isEmpty ? deadwood : nonJokers
            return hand[pool.randomElement(using: &rng)!]
        }

        // Card jailing (§3): a card the next player wants stays stuck in hand
        // — playing slightly worse for myself to starve them — until it turns
        // safe or keeping it hurts too much. Everyone-is-hot releases the jail.
        let nearDeath = nearElimination(view)
        let dangers = Dictionary(uniqueKeysWithValues: deadwood.map {
            ($0, model.danger(of: hand[$0]))
        })
        let free = deadwood.filter { index in
            let keepCost = Double(hand[index].handValue) * 0.1 * (nearDeath ? 2 : 1)
            return dangers[index]! <= w.jailThreshold || keepCost > w.jailCostCap
        }
        if !free.isEmpty { deadwood = free }

        // Score every remaining candidate: higher = better to throw.
        let early = view.turnsCompletedThisRound < view.aliveCount * 2
            && !view.players.contains(where: \.hasLaidDown)
        let scores = deadwood.map { index -> Double in
            let card = hand[index]
            if card.isJoker { return -100 }
            var score = 0.0
            // Value pressure: early on, give away small cards to deny the next
            // player cheap threshold progress; later (or near elimination),
            // shed the expensive deadwood that would score against me.
            if early && !nearDeath {
                score += Double(11 - card.handValue) * 0.12 * w.smallCardsDiscipline
                score += Double(card.handValue) * 0.12 * (1 - w.smallCardsDiscipline)
            } else {
                score += Double(card.handValue) * (nearDeath ? 0.18 : 0.12)
            }
            // Keep cards that still work toward live melds in hand.
            let synergy = hand.reduce(0) { $0 + (($1 == card) ? 0 : pairSynergy(card, $1)) }
            score -= Double(synergy) * 0.25 * model.liveliness(of: card)
            // Soft defensive pressure below the jail bar.
            score -= dangers[index]! * 0.6
            return score
        }

        // Human inconsistency (§4): softmax over the scores instead of argmax.
        // Experts are near-greedy; beginners visibly pick second-best moves.
        let temperature = max(0.02, w.noiseTemperature)
        let peak = scores.max() ?? 0
        let softWeights = scores.map { exp(($0 - peak) / temperature) }
        let total = softWeights.reduce(0, +)
        var roll = Double.random(in: 0..<max(total, .leastNonzeroMagnitude), using: &rng)
        for (offset, weight) in softWeights.enumerated() {
            roll -= weight
            if roll <= 0 { return hand[deadwood[offset]] }
        }
        return hand[deadwood.last!]
    }
}
