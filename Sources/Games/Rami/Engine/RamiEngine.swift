import Foundation

/// Pure, deterministic Rami state machine. Every action either produces a new
/// validated state or throws a `RamiError`. No hidden information ever leaks:
/// the RNG is injected and bots only ever receive a `PublicGameView`.
enum RamiEngine {

    static func newGame(
        config: RulesConfig,
        names: [String],
        humanSeat: Int = 0,
        dealerSeat: Int,
        rng: inout some RandomNumberGenerator
    ) -> RamiState {
        precondition(names.count == 4)
        var pile = Card.fullDeck()
        // Base fairness shuffle; the dealer's explicit shuffles come on top.
        pile.fisherYatesShuffle(using: &rng)
        return RamiState(
            config: config,
            players: names.enumerated().map { PlayerState(name: $1, isHuman: $0 == humanSeat) },
            dealerSeat: dealerSeat,
            phase: .dealing(shuffles: 0),
            drawPile: pile,
            startedAt: Date(),
            matchID: UUID()
        )
    }

    static func apply(
        _ action: RamiAction,
        by seat: Int,
        to state: RamiState,
        rng: inout some RandomNumberGenerator
    ) throws -> RamiState {
        var s = state
        switch (action, state.phase) {
        case (.shuffle, .dealing(let count)):
            guard seat == s.dealerSeat else { throw RamiError.notYourTurn }
            s.drawPile.fisherYatesShuffle(using: &rng)
            s.phase = .dealing(shuffles: count + 1)

        case (.deal(let pattern), .dealing):
            guard seat == s.dealerSeat else { throw RamiError.notYourTurn }
            try deal(pattern: pattern, in: &s)

        case (.declareIntent(let play), .vote(let proposer, let current)):
            guard seat == current else { throw RamiError.notYourTurn }
            if play {
                // Someone wants to play: the round starts normally with the
                // player to the dealer's right.
                s.phase = .turn(seat: proposer, turnStartStage(for: proposer, in: s))
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
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            if s.drawPile.isEmpty { try reshuffleThrowStacksIntoPile(&s, rng: &rng) }
            guard let card = s.drawPile.popLast() else { throw RamiError.pileEmpty }
            s.players[seat].hand.append(card)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: .pile, pendingJoker: nil))

        case (.takeThrow, .turn(let turnSeat, .awaitingDraw)):
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            guard s.players[seat].hasLaidDown else { throw RamiError.mustLayDownWithTake }
            let card = try takePreviousThrow(&s, seat: seat)
            s.players[seat].hand.append(card)
            s.players[seat].takenThrows.append(card)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: .takenThrow, pendingJoker: nil))

        case (.takeThrowAndLayDown(let melds), .turn(let turnSeat, .awaitingDraw)):
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            guard !s.players[seat].hasLaidDown else { throw RamiError.alreadyLaidDown }
            let card = try takePreviousThrow(&s, seat: seat)
            s.players[seat].hand.append(card)
            s.players[seat].takenThrows.append(card)
            try performLayDown(melds: melds, seat: seat, in: &s, pendingJoker: nil)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: .takenThrow, pendingJoker: nil))

        case (.layDown(let melds), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            let stillPending = try performLayDown(
                melds: melds, seat: seat, in: &s, pendingJoker: pendingJoker)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: drew, pendingJoker: stillPending))

        case (.appendCard(let entry, let meldID), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            guard s.players[seat].hasLaidDown else { throw RamiError.notLaidDownYet }
            guard let index = s.tableMelds.firstIndex(where: { $0.id == meldID }) else {
                throw RamiError.meldNotFound
            }
            guard s.tableMelds[index].meld.entries.count < Meld.maxSize else { throw RamiError.meldFull }
            guard let handIndex = s.players[seat].hand.firstIndex(of: entry.card) else {
                throw RamiError.cardNotInHand
            }
            guard s.players[seat].hand.count >= 2 else { throw RamiError.mustKeepACardToThrow }
            s.tableMelds[index].meld = try inserting(entry: entry, into: s.tableMelds[index].meld)
            s.players[seat].hand.remove(at: handIndex)
            let stillPending = pendingJoker == entry.card ? nil : pendingJoker
            s.phase = .turn(seat: seat, .awaitingThrow(drew: drew, pendingJoker: stillPending))

        case (.swapJoker(let meldID, let realCard), .turn(let turnSeat, .awaitingThrow(let drew, let pendingJoker))):
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            guard s.players[seat].hasLaidDown else { throw RamiError.notLaidDownYet }
            guard pendingJoker == nil else { throw RamiError.jokerPending }
            guard let meldIndex = s.tableMelds.firstIndex(where: { $0.id == meldID }) else {
                throw RamiError.meldNotFound
            }
            guard let handIndex = s.players[seat].hand.firstIndex(of: realCard) else {
                throw RamiError.cardNotInHand
            }
            guard let entryIndex = s.tableMelds[meldIndex].meld.entries.firstIndex(where: {
                $0.card.isJoker && $0.asRank == realCard.rank && $0.asSuit == realCard.suit
            }) else {
                throw RamiError.noJokerInMeld
            }
            let joker = s.tableMelds[meldIndex].meld.entries[entryIndex].card
            s.tableMelds[meldIndex].meld.entries[entryIndex].card = realCard
            s.players[seat].hand.remove(at: handIndex)
            s.players[seat].hand.append(joker)
            s.phase = .turn(seat: seat, .awaitingThrow(drew: drew, pendingJoker: joker))

        case (.throwCard(let card), .turn(let turnSeat, .awaitingThrow(_, let pendingJoker))):
            guard seat == turnSeat else { throw RamiError.notYourTurn }
            guard pendingJoker == nil else { throw RamiError.jokerPending }
            guard let handIndex = s.players[seat].hand.firstIndex(of: card) else {
                throw RamiError.cardNotInHand
            }
            s.players[seat].hand.remove(at: handIndex)
            s.players[seat].throwStack.append(card)
            s.turnsCompletedThisRound += 1
            if s.players[seat].hand.isEmpty {
                Scoring.settleRound(&s, closerSeat: seat)
            } else {
                let next = s.nextAliveSeat(after: seat)
                s.phase = .turn(seat: next, turnStartStage(for: next, in: s))
            }

        case (.startNextRound, .roundEnded):
            startNextRound(&s)

        default:
            throw RamiError.illegalPhase
        }
        return s
    }

    // MARK: - Helpers

    /// The dealer's 15th card replaces their first draw of the round.
    private static func turnStartStage(for seat: Int, in state: RamiState) -> TurnStage {
        state.players[seat].hand.count == 15
            ? .awaitingThrow(drew: .dealt, pendingJoker: nil)
            : .awaitingDraw
    }

    private static func deal(pattern: DealPattern, in s: inout RamiState) throws {
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
                    guard let card = s.drawPile.popLast() else { throw RamiError.pileEmpty }
                    s.players[receiver].hand.append(card)
                }
            }
        }
        let firstActor = s.nextAliveSeat(after: s.dealerSeat)
        s.phase = .vote(proposerSeat: firstActor, currentSeat: firstActor)
    }

    private static func abandonRound(_ s: inout RamiState) {
        for seat in s.players.indices {
            s.players[seat].roundScores.append(nil)
        }
        resetForNewRound(&s, nextDealer: s.nextAliveSeat(after: s.dealerSeat))
    }

    static func startNextRound(_ s: inout RamiState) {
        resetForNewRound(&s, nextDealer: s.nextAliveSeat(after: s.dealerSeat))
    }

    private static func resetForNewRound(_ s: inout RamiState, nextDealer: Int) {
        for seat in s.players.indices {
            s.players[seat].hand = []
            s.players[seat].throwStack = []
            s.players[seat].takenThrows = []
            s.players[seat].hasLaidDown = false
        }
        s.tableMelds = []
        s.lastInitialLayDownTotal = nil
        s.turnsCompletedThisRound = 0
        s.roundNumber += 1
        s.dealerSeat = nextDealer
        s.drawPile = Card.fullDeck()
        s.phase = .dealing(shuffles: 0)
    }

    private static func takePreviousThrow(_ s: inout RamiState, seat: Int) throws -> Card {
        guard s.throwTakeUnlocked else { throw RamiError.throwTakeLocked }
        let previous = s.previousAliveSeat(before: seat)
        guard let card = s.players[previous].throwStack.popLast() else {
            throw RamiError.previousThrowUnavailable
        }
        return card
    }

    /// Removes meld cards from the hand and puts the melds on the table.
    /// Enforces the first-lay-down threshold (with escalation) and updates the
    /// escalation chain. Returns the still-pending joker, if any.
    @discardableResult
    private static func performLayDown(
        melds: [Meld], seat: Int, in s: inout RamiState, pendingJoker: Card?
    ) throws -> Card? {
        guard !melds.isEmpty else { throw RamiError.invalidMeld(.invalidSize) }
        var total = 0
        for meld in melds {
            do { total += try meld.validatedThresholdValue() }
            catch { throw RamiError.invalidMeld(error) }
        }
        let allCards = melds.flatMap(\.cards)
        guard Set(allCards.map(\.id)).count == allCards.count else {
            throw RamiError.invalidMeld(.duplicateCardInstance)
        }
        var hand = s.players[seat].hand
        for card in allCards {
            guard let index = hand.firstIndex(of: card) else { throw RamiError.cardNotInHand }
            hand.remove(at: index)
        }
        guard !hand.isEmpty else { throw RamiError.mustKeepACardToThrow }
        if !s.players[seat].hasLaidDown {
            let required = s.requiredLayDown
            guard total >= required else {
                throw RamiError.thresholdNotMet(required: required, got: total)
            }
            s.players[seat].hasLaidDown = true
            s.lastInitialLayDownTotal = total
        }
        s.players[seat].hand = hand
        for meld in melds {
            s.tableMelds.append(TableMeld(id: UUID(), ownerSeat: seat, meld: meld))
        }
        if let pendingJoker, allCards.contains(pendingJoker) { return nil }
        return pendingJoker
    }

    /// Tries the new entry at every position; first arrangement that validates wins.
    private static func inserting(entry: MeldEntry, into meld: Meld) throws -> Meld {
        for position in 0...meld.entries.count {
            var candidate = meld
            candidate.entries.insert(entry, at: position)
            if (try? candidate.validate()) != nil { return candidate }
        }
        throw RamiError.cannotAppendHere
    }

    private static func reshuffleThrowStacksIntoPile(
        _ s: inout RamiState, rng: inout some RandomNumberGenerator
    ) throws {
        var collected: [Card] = []
        for seat in s.players.indices {
            collected.append(contentsOf: s.players[seat].throwStack)
            s.players[seat].throwStack = []
        }
        guard !collected.isEmpty else { throw RamiError.pileEmpty }
        collected.fisherYatesShuffle(using: &rng)
        s.drawPile = collected
    }
}
