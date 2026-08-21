import Foundation

/// Pure, deterministic Rummy state machine. Every action either produces a new
/// validated state or throws a `RummyError`. No hidden information ever leaks:
/// the RNG is injected and bots only ever receive a `PublicGameView`.
enum RummyEngine {

    static func newGame(
        config: RulesConfig,
        names: [String],
        humanSeat: Int = 0,
        dealerSeat: Int,
        rng: inout some RandomNumberGenerator
    ) -> RummyState {
        precondition(names.count == 4)
        var pile = Card.fullDeck()
        // Base fairness shuffle; the dealer's explicit shuffles come on top.
        pile.fisherYatesShuffle(using: &rng)
        // Three distinct temperaments dealt across the three bot seats,
        // stable for the whole game.
        var archetypes = Array(BotArchetype.allCases)
        archetypes.fisherYatesShuffle(using: &rng)
        var pending = archetypes
        let minds: [BotMind] = names.indices.map { seat in
            seat == humanSeat ? .neutral : BotMind(archetype: pending.removeFirst(), frustration: 0.3)
        }
        var state = RummyState(
            config: config,
            players: names.enumerated().map { PlayerState(name: $1, isHuman: $0 == humanSeat) },
            dealerSeat: dealerSeat,
            phase: .dealing(shuffles: 0),
            drawPile: pile,
            startedAt: Date(),
            matchID: UUID()
        )
        state.botMinds = minds
        return state
    }

    static func apply(
        _ action: RummyAction,
        by seat: Int,
        to state: RummyState,
        rng: inout some RandomNumberGenerator
    ) throws -> RummyState {
        var s = state
        switch (action, state.phase) {
        case (.shuffle, .dealing(let count)):
            guard seat == s.dealerSeat else { throw RummyError.notYourTurn }
            s.drawPile.fisherYatesShuffle(using: &rng)
            s.phase = .dealing(shuffles: count + 1)

        case (.deal(let pattern), .dealing):
            guard seat == s.dealerSeat else { throw RummyError.notYourTurn }
            try deal(pattern: pattern, in: &s)

        case (.forcePass, .vote(_, let current)):
            guard seat == current else { throw RummyError.notYourTurn }
            guard Self.canForcePass(hand: s.players[seat].hand) else {
                throw RummyError.cannotForcePass
            }
            abandonRound(&s)

        case (.declareIntent(let play), .vote(let proposer, let current)):
            guard seat == current else { throw RummyError.notYourTurn }
            if play {
                // Someone wants to play: the round starts with the DEALER,
                // who throws their 15th card (no purchase on that turn).
                s.phase = .turn(seat: s.dealerSeat, turnStartStage(for: s.dealerSeat, in: s))
            } else {
                let next = s.nextAliveSeat(after: current)
                if next == proposer {
                    // Everyone agreed: round abandoned, next dealer redeals.
                    abandonRound(&s)
                } else {
                    s.phase = .vote(proposerSeat: proposer, currentSeat: next)
                }
            }

        case (.drawFromPile, .turn(let turnSeat, .awaitingDraw)):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            if s.drawPile.isEmpty { try reshuffleThrowStacksIntoPile(&s, rng: &rng) }
            guard let card = s.drawPile.popLast() else { throw RummyError.pileEmpty }
            s.players[seat].hand.append(card)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: .pile, pendingJoker: nil))

        case (.takeThrow, .turn(let turnSeat, .awaitingDraw)):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            let card = try takePreviousThrow(&s, seat: seat)
            s.players[seat].hand.append(card)
            s.players[seat].takenThrows.append(card)
            // Taking before the first lay-down is a commitment: with no
            // qualifying lay-down even possible, the taker is penalized 100,
            // everyone else scores 0, and the round ends on the spot.
            if !s.players[seat].hasLaidDown,
               !Self.qualifyingLayDownExists(hand: s.players[seat].hand, required: s.requiredLayDown) {
                Scoring.settleFailedTake(&s, penalized: seat)
            } else {
                s.phase = .turn(seat: seat, .awaitingThrow(drew: .takenThrow, pendingJoker: nil))
            }

        case (.takeThrowAndLayDown(let melds), .turn(let turnSeat, .awaitingDraw)):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            guard !s.players[seat].hasLaidDown else { throw RummyError.alreadyLaidDown }
            let card = try takePreviousThrow(&s, seat: seat)
            s.players[seat].hand.append(card)
            s.players[seat].takenThrows.append(card)
            try performLayDown(melds: melds, seat: seat, in: &s, pendingJoker: nil)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: .takenThrow, pendingJoker: nil))

        case (.layDown(let melds), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            // First cycle is pure draw-and-throw: the dealer opens by
            // throwing, everyone purchases and throws once, and only when the
            // turn returns to the dealer may anyone lay.
            guard s.turnsCompletedThisRound >= s.aliveCount else {
                throw RummyError.layDownLocked
            }
            let stillPending = try performLayDown(
                melds: melds, seat: seat, in: &s, pendingJoker: pendingJoker)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: drew, pendingJoker: stillPending))

        case (.appendCard(let entry, let meldID), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            guard Self.canTouchMelds(s, seat: seat) else { throw RummyError.notLaidDownYet }
            guard let index = s.tableMelds.firstIndex(where: { $0.id == meldID }) else {
                throw RummyError.meldNotFound
            }
            guard s.tableMelds[index].meld.entries.count < Meld.maxSize else { throw RummyError.meldFull }
            guard let handIndex = s.players[seat].hand.firstIndex(of: entry.card) else {
                throw RummyError.cardNotInHand
            }
            guard s.players[seat].hand.count >= 2 else { throw RummyError.mustKeepACardToThrow }
            guard let grown = s.tableMelds[index].meld.inserting(entry) else {
                throw RummyError.cannotAppendHere
            }
            s.tableMelds[index].meld = grown
            s.players[seat].hand.remove(at: handIndex)
            let stillPending = pendingJoker == entry.card ? nil : pendingJoker
            s.phase = .turn(seat: seat, .awaitingThrow(drew: drew, pendingJoker: stillPending))

        case (.swapJoker(let meldID, let realCard), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            guard Self.canTouchMelds(s, seat: seat) else { throw RummyError.notLaidDownYet }
            guard pendingJoker == nil else { throw RummyError.jokerPending }
            guard let meldIndex = s.tableMelds.firstIndex(where: { $0.id == meldID }) else {
                throw RummyError.meldNotFound
            }
            guard let handIndex = s.players[seat].hand.firstIndex(of: realCard) else {
                throw RummyError.cardNotInHand
            }
            guard let entryIndex = s.tableMelds[meldIndex].meld.entries.firstIndex(where: {
                $0.card.isJoker && $0.asRank == realCard.rank && $0.asSuit == realCard.suit
            }) else {
                throw RummyError.noJokerInMeld
            }
            let joker = s.tableMelds[meldIndex].meld.entries[entryIndex].card
            s.tableMelds[meldIndex].meld.entries[entryIndex].card = realCard
            s.players[seat].hand.remove(at: handIndex)
            s.players[seat].hand.append(joker)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: drew, pendingJoker: joker))

        case (.throwCard(let card), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RummyError.notYourTurn }
            guard pendingJoker == nil else { throw RummyError.jokerPending }
            // A pre-lay-down take must be honored: at least one series must be
            // on the table before the turn can end.
            if drew == .takenThrow, !s.players[seat].hasLaidDown,
               s.players[seat].pendingLayDownValue == nil {
                throw RummyError.mustLayDownWithTake
            }
            guard let handIndex = s.players[seat].hand.firstIndex(of: card) else {
                throw RummyError.cardNotInHand
            }
            // Wasted throw rule: a joker, or a card that fits a table meld,
            // costs +10 and comes back — unless no legal throw exists at all.
            if Self.throwPenalized(card, tableMelds: s.tableMelds) {
                let hasLegalAlternative = s.players[seat].hand.contains {
                    $0.id != card.id && !Self.throwPenalized($0, tableMelds: s.tableMelds)
                }
                if hasLegalAlternative {
                    s.players[seat].penaltiesThisRound += 10
                    return s
                }
            }
            s.players[seat].hand.remove(at: handIndex)
            s.players[seat].throwStack.append(card)
            s.turnsCompletedThisRound += 1
            if s.players[seat].hand.isEmpty {
                // Going out completely never needs the threshold: "it's done".
                s.players[seat].pendingLayDownValue = nil
                Scoring.settleRound(&s, closerSeat: seat)
            } else if !s.players[seat].hasLaidDown,
                      let pending = s.players[seat].pendingLayDownValue {
                // The lay-down check happens here, not when laying: enough
                // confirms it, short stops the round at +100 for the layer.
                if pending >= s.requiredLayDown {
                    s.players[seat].hasLaidDown = true
                    s.players[seat].pendingLayDownValue = nil
                    s.lastInitialLayDownTotal = pending
                    let next = s.nextAliveSeat(after: seat)
                    s.phase = .turn(seat: next, turnStartStage(for: next, in: s))
                } else {
                    s.players[seat].pendingLayDownValue = nil
                    Scoring.settleFailedTake(&s, penalized: seat)
                }
            } else {
                let next = s.nextAliveSeat(after: seat)
                s.phase = .turn(seat: next, turnStartStage(for: next, in: s))
            }

        case (.startNextRound, .roundEnded):
            startNextRound(&s)

        default:
            throw RummyError.illegalPhase
        }
        return s
    }

    // MARK: - Helpers

    /// Melds open up once the player's lay-down is confirmed — or already
    /// laid this turn with the required count met (the discard just seals it).
    static func canTouchMelds(_ s: RummyState, seat: Int) -> Bool {
        s.players[seat].hasLaidDown
            || (s.players[seat].pendingLayDownValue ?? 0) >= s.requiredLayDown
    }

    /// A throw is penalized when the card is a joker or fits any table meld.
    static func throwPenalized(_ card: Card, tableMelds: [TableMeld]) -> Bool {
        if card.isJoker { return true }
        guard let rank = card.rank, let suit = card.suit else { return false }
        let entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
        return tableMelds.contains { $0.meld.inserting(entry) != nil }
    }

    /// True when some meld combination (keeping at least one card to throw)
    /// reaches the required first-lay-down total.
    static func qualifyingLayDownExists(hand: [Card], required: Int) -> Bool {
        HandAnalysis.bestPartition(hand: hand, maxCovered: hand.count - 1).value >= required
    }

    /// A "double" is holding both copies of the same card. A hand dead enough
    /// in doubles may force the round to pass without a vote:
    /// 4+ doubles, or 3+ doubles with a joker, or 2+ doubles with two jokers.
    static func canForcePass(hand: [Card]) -> Bool {
        var copies: [Card.Kind: Int] = [:]
        for card in hand where !card.isJoker {
            copies[card.kind, default: 0] += 1
        }
        let doubles = copies.values.filter { $0 >= 2 }.count
        let jokers = hand.filter(\.isJoker).count
        return doubles >= 4
            || (doubles >= 3 && jokers >= 1)
            || (doubles >= 2 && jokers >= 2)
    }

    /// The dealer's 15th card replaces their first draw of the round.
    private static func turnStartStage(for seat: Int, in state: RummyState) -> TurnStage {
        state.players[seat].hand.count == 15
            ? .awaitingThrow(drew: .dealt, pendingJoker: nil)
            : .awaitingDraw
    }

    private static func deal(pattern: DealPattern, in s: inout RummyState) throws {
        let alive = s.aliveCount
        // Dealing order: player to the dealer's right first, dealer last.
        var order: [Int] = []
        var seat = s.dealerSeat
        for _ in 0..<alive {
            seat = s.nextAliveSeat(after: seat)
            order.append(seat)
        }
        // order ends with dealerSeat; passes()[i][0] is the dealer's amount.
        for pass in pattern.passes(playerCount: alive) {
            for (position, receiver) in order.enumerated() {
                let amount = receiver == s.dealerSeat ? pass[0] : pass[position + 1]
                for _ in 0..<amount {
                    guard let card = s.drawPile.popLast() else { throw RummyError.pileEmpty }
                    s.players[receiver].hand.append(card)
                }
            }
        }
        s.lastDealPattern = pattern
        let firstActor = s.nextAliveSeat(after: s.dealerSeat)
        s.phase = .vote(proposerSeat: firstActor, currentSeat: firstActor)
    }

    private static func abandonRound(_ s: inout RummyState) {
        for seat in s.players.indices {
            s.players[seat].roundScores.append(nil)
        }
        resetForNewRound(&s, nextDealer: s.nextAliveSeat(after: s.dealerSeat))
    }

    static func startNextRound(_ s: inout RummyState) {
        resetForNewRound(&s, nextDealer: s.nextAliveSeat(after: s.dealerSeat))
    }

    private static func resetForNewRound(_ s: inout RummyState, nextDealer: Int) {
        for seat in s.players.indices {
            s.players[seat].hand = []
            s.players[seat].throwStack = []
            s.players[seat].takenThrows = []
            s.players[seat].hasLaidDown = false
            s.players[seat].pendingLayDownValue = nil
            s.players[seat].penaltiesThisRound = 0
        }
        s.tableMelds = []
        s.lastInitialLayDownTotal = nil
        s.turnsCompletedThisRound = 0
        s.roundNumber += 1
        s.dealerSeat = nextDealer
        s.drawPile = Card.fullDeck()
        s.phase = .dealing(shuffles: 0)
    }

    private static func takePreviousThrow(_ s: inout RummyState, seat: Int) throws -> Card {
        guard s.throwTakeUnlocked else { throw RummyError.throwTakeLocked }
        let previous = s.previousAliveSeat(before: seat)
        guard let card = s.players[previous].throwStack.popLast() else {
            throw RummyError.previousThrowUnavailable
        }
        return card
    }

    /// Removes meld cards from the hand and puts the melds on the table. Each
    /// series only needs to be valid — the first-lay-down threshold is checked
    /// when the turn ends with a throw, not here. Until then the total
    /// accumulates in `pendingLayDownValue`. Table touch: laid series never
    /// come back to the hand.
    /// Returns the still-pending joker, if any.
    @discardableResult
    private static func performLayDown(
        melds: [Meld], seat: Int, in s: inout RummyState, pendingJoker: Card?
    ) throws -> Card? {
        guard !melds.isEmpty else { throw RummyError.invalidMeld(.invalidSize) }
        var total = 0
        for meld in melds {
            do { total += try meld.validatedThresholdValue() }
            catch { throw RummyError.invalidMeld(error) }
        }
        let allCards = melds.flatMap(\.cards)
        guard Set(allCards.map(\.id)).count == allCards.count else {
            throw RummyError.invalidMeld(.duplicateCardInstance)
        }
        var hand = s.players[seat].hand
        for card in allCards {
            guard let index = hand.firstIndex(of: card) else { throw RummyError.cardNotInHand }
            hand.remove(at: index)
        }
        guard !hand.isEmpty else { throw RummyError.mustKeepACardToThrow }
        if !s.players[seat].hasLaidDown {
            s.players[seat].pendingLayDownValue =
                (s.players[seat].pendingLayDownValue ?? 0) + total
        }
        s.players[seat].hand = hand
        for meld in melds {
            s.tableMelds.append(TableMeld(id: UUID(), ownerSeat: seat, meld: meld))
        }
        if let pendingJoker, allCards.contains(pendingJoker) { return nil }
        return pendingJoker
    }

    private static func reshuffleThrowStacksIntoPile(
        _ s: inout RummyState, rng: inout some RandomNumberGenerator
    ) throws {
        var collected: [Card] = []
        for seat in s.players.indices {
            collected.append(contentsOf: s.players[seat].throwStack)
            s.players[seat].throwStack = []
        }
        guard !collected.isEmpty else { throw RummyError.pileEmpty }
        collected.fisherYatesShuffle(using: &rng)
        s.drawPile = collected
    }
}
