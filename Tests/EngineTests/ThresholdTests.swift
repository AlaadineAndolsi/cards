import Foundation
import Testing
@testable import Cards

private func meldOf(_ cards: [Card]) -> Meld {
    Meld(entries: cards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) })
}

private func handWith(_ meldCards: [Card], filler: Int) -> [Card] {
    meldCards + Array(Card.fullDeck().filter { card in
        !meldCards.contains(card) && !card.isJoker
    }.suffix(filler))
}

struct LayDownTests {
    private let kings = [TestCards.card(.king, .hearts), TestCards.card(.king, .spades), TestCards.card(.king, .clubs)]
    private let aces = [TestCards.card(.ace, .hearts), TestCards.card(.ace, .spades), TestCards.card(.ace, .clubs)]
    private let smallRun = [TestCards.card(.two, .hearts), TestCards.card(.three, .hearts), TestCards.card(.four, .hearts)]

    private func turnState(hand: [Card], laidDown: Bool = false, lastInitial: Int? = nil,
                           config: RulesConfig = .default) -> RummyState {
        StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [hand, [], [], []],
            laidDown: [laidDown, false, false, false],
            turnsCompleted: 4,  // the turn has come back to the dealer
            lastInitialLayDown: lastInitial,
            config: config)
    }

    @Test func layDownIsLockedDuringTheFirstCycle() {
        var config = RulesConfig.default
        config.minimumLayDown = 60
        var s = turnState(hand: handWith(kings + aces, filler: 9), config: config)
        s.turnsCompletedThisRound = 3  // the turn is not back to the dealer yet
        #expect(throws: RummyError.layDownLocked) {
            try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        }
    }

    @Test func initialLayDownBelowMinimumPendsThenThrowPenalizes() throws {
        // Laying is always allowed serie by serie — the count check happens at
        // the throw: short of the minimum, the round stops at +100.
        let s = turnState(hand: handWith(smallRun, filler: 12))
        let laid = try StateBuilder.apply(.layDown(melds: [meldOf(smallRun)]), by: 0, to: s)
        #expect(!laid.players[0].hasLaidDown)
        #expect(laid.players[0].pendingLayDownValue == 9)
        let safeThrow = laid.players[0].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: laid.tableMelds)
        }!
        let thrown = try StateBuilder.apply(.throwCard(safeThrow), by: 0, to: laid)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected the round to stop, got \(thrown.phase)")
            return
        }
        #expect(result.closerSeat == nil)
        #expect(result.deltas[0] == 100)
        #expect(result.deltas[1...] == [0, 0, 0])
    }

    @Test func initialLayDownAtMinimumConfirmsOnTheThrow() throws {
        var config = RulesConfig.default
        config.minimumLayDown = 60
        let s = turnState(hand: handWith(kings + aces, filler: 9), config: config)
        let laid = try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        #expect(!laid.players[0].hasLaidDown)
        #expect(laid.players[0].pendingLayDownValue == 60)
        #expect(laid.lastInitialLayDownTotal == nil)
        #expect(laid.players[0].hand.count == 9)
        let safeThrow = laid.players[0].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: laid.tableMelds)
        }!
        let thrown = try StateBuilder.apply(.throwCard(safeThrow), by: 0, to: laid)
        #expect(thrown.players[0].hasLaidDown)
        #expect(thrown.players[0].pendingLayDownValue == nil)
        #expect(thrown.lastInitialLayDownTotal == 60)
    }

    @Test func pendingAccumulatesSerieBySerie() throws {
        // Series can be laid one at a time; the pending total accumulates.
        let s = turnState(hand: handWith(kings + smallRun, filler: 8))
        var laid = try StateBuilder.apply(
            .layDown(melds: [meldOf(kings)]), by: 0, to: s)
        #expect(laid.players[0].pendingLayDownValue == 30)
        laid = try StateBuilder.apply(.layDown(melds: [meldOf(smallRun)]), by: 0, to: laid)
        #expect(laid.players[0].pendingLayDownValue == 39)
        #expect(laid.tableMelds.count == 2)
    }

    @Test func layingTheWholeHandClosesWithoutTheMinimum() throws {
        // "All lay down": going out completely never needs the count.
        let spare = TestCards.card(.nine, .diamonds)
        let s = turnState(hand: smallRun + [spare])
        let laid = try StateBuilder.apply(.layDown(melds: [meldOf(smallRun)]), by: 0, to: s)
        let thrown = try StateBuilder.apply(.throwCard(spare), by: 0, to: laid)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected a closed round, got \(thrown.phase)")
            return
        }
        #expect(result.closerSeat == 0)
        #expect(result.deltas[0] == 0)
    }

    @Test func escalationChecksPreviousPlusOneAtTheThrow() throws {
        // Previous initial lay-down was 65 → this one needs 66; 60 stops the
        // round with the +100 penalty when the turn ends.
        let s = turnState(hand: handWith(kings + aces, filler: 9), lastInitial: 65)
        let laid = try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        #expect(laid.players[0].pendingLayDownValue == 60)
        let safeThrow = laid.players[0].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: laid.tableMelds)
        }!
        let thrown = try StateBuilder.apply(.throwCard(safeThrow), by: 0, to: laid)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected the round to stop, got \(thrown.phase)")
            return
        }
        #expect(result.deltas[0] == 100)
    }

    @Test func appendsAreAlwaysAllowedAndCountTowardThePending() throws {
        // Laid 60/60 this turn (unconfirmed): appending works and adds value.
        var config = RulesConfig.default
        config.minimumLayDown = 60
        let queenOfKings = TestCards.card(.king, .diamonds)
        let s = turnState(hand: handWith(kings + aces + [queenOfKings], filler: 8), config: config)
        var laid = try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        #expect(!laid.players[0].hasLaidDown)
        let kingsMeldID = laid.tableMelds[0].id
        laid = try StateBuilder.apply(
            .appendCard(MeldEntry(card: queenOfKings, asRank: .king, asSuit: .diamonds),
                        meldID: kingsMeldID),
            by: 0, to: laid)
        #expect(laid.tableMelds[0].meld.entries.count == 4)
        #expect(laid.players[0].pendingLayDownValue == 70)

        // Short of the count the append still works — placement is always
        // possible; the judgment waits for the discard.
        let fiveOfHearts = TestCards.card(.five, .hearts)
        let short = turnState(hand: handWith(smallRun + [fiveOfHearts], filler: 8), config: config)
        var shortLaid = try StateBuilder.apply(.layDown(melds: [meldOf(smallRun)]), by: 0, to: short)
        let smallPending = shortLaid.players[0].pendingLayDownValue!
        shortLaid = try StateBuilder.apply(
            .appendCard(MeldEntry(card: fiveOfHearts, asRank: .five, asSuit: .hearts),
                        meldID: shortLaid.tableMelds[0].id),
            by: 0, to: shortLaid)
        #expect(shortLaid.players[0].pendingLayDownValue == smallPending + 5)
        // And the discard judges it: still short → +100, round stops.
        let safeThrow = shortLaid.players[0].hand.first {
            !RummyEngine.throwPenalized($0, tableMelds: shortLaid.tableMelds)
        }!
        let thrown = try StateBuilder.apply(.throwCard(safeThrow), by: 0, to: shortLaid)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected the round to stop, got \(thrown.phase)")
            return
        }
        #expect(result.deltas[0] == 100)
    }

    @Test func subsequentLayDownsHaveNoThreshold() throws {
        let s = turnState(hand: handWith(smallRun, filler: 12), laidDown: true, lastInitial: 80)
        let after = try StateBuilder.apply(.layDown(melds: [meldOf(smallRun)]), by: 0, to: s)
        #expect(after.tableMelds.count == 1)
        // And they do not move the escalation chain.
        #expect(after.lastInitialLayDownTotal == 80)
    }

    @Test func layDownMayNotEmptyTheHand() {
        let s = turnState(hand: kings + aces, laidDown: true)
        #expect(throws: RummyError.mustKeepACardToThrow) {
            try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        }
    }

    @Test func layDownCardsMustComeFromHand() {
        let s = turnState(hand: handWith(kings, filler: 11), laidDown: true)
        #expect(throws: RummyError.cardNotInHand) {
            try StateBuilder.apply(.layDown(melds: [meldOf(aces)]), by: 0, to: s)
        }
    }

    @Test func escalationChainResetsNextRound() throws {
        var s = turnState(hand: handWith(kings, filler: 11), lastInitial: 90)
        s.phase = .roundEnded(RoundResult(closerSeat: 1, deltas: [0, 0, 0, 0], newlyEliminated: []))
        s.drawPile = Array(s.drawPile.prefix(3))  // simulate a nearly spent pile
        let next = try StateBuilder.apply(.startNextRound, by: 0, to: s)
        #expect(next.lastInitialLayDownTotal == nil)
        #expect(next.requiredLayDown == RulesConfig.default.minimumLayDown)
        // The pile is rebuilt to the full double deck every round.
        #expect(next.drawPile.count == 108)
    }
}

struct AppendAndJokerTests {
    private let runCards = [TestCards.card(.four, .hearts), TestCards.card(.five, .hearts), TestCards.card(.six, .hearts)]

    private func tableWithRun(id: UUID = UUID(), extraEntries: [MeldEntry] = []) -> TableMeld {
        TableMeld(id: id, ownerSeat: 2, meld: Meld(
            entries: runCards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) } + extraEntries))
    }

    private func state(hand: [Card], laidDown: Bool = true, melds: [TableMeld],
                       pendingJoker: Card? = nil) -> RummyState {
        StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: pendingJoker),
            hands: [hand, [], [], []],
            laidDown: [laidDown, false, false, false],
            turnsCompleted: 4,
            tableMelds: melds)
    }

    @Test func appendToAnyPlayersMeldAfterLayDown() throws {
        let seven = TestCards.card(.seven, .hearts)
        let meldID = UUID()
        let s = state(hand: [seven] + Array(Card.fullDeck().suffix(5)), melds: [tableWithRun(id: meldID)])
        let after = try StateBuilder.apply(
            .appendCard(MeldEntry(card: seven, asRank: .seven, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        #expect(after.tableMelds[0].meld.entries.count == 4)
        #expect(!after.players[0].hand.contains(seven))
    }

    @Test func appendBeforeOwnLayDownPendsAndIsJudgedAtTheThrow() throws {
        // Placement into melds is always possible; the appended value pends
        // and the discard judges it — short of the count means +100.
        let seven = TestCards.card(.seven, .hearts)
        let meldID = UUID()
        let s = state(hand: [seven, TestCards.card(.nine, .clubs), TestCards.card(.queen, .spades)],
                      laidDown: false, melds: [tableWithRun(id: meldID)])
        let appended = try StateBuilder.apply(
            .appendCard(MeldEntry(card: seven, asRank: .seven, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        #expect(appended.tableMelds[0].meld.entries.count == 4)
        #expect(appended.players[0].pendingLayDownValue == 7)
        let thrown = try StateBuilder.apply(
            .throwCard(TestCards.card(.nine, .clubs)), by: 0, to: appended)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected the round to stop, got \(thrown.phase)")
            return
        }
        #expect(result.deltas[0] == 100)
    }

    @Test func underCountFullCloseViaAppendsIsAllowed() throws {
        // The reported trap: everything left fits into table melds, but the
        // pending total is under the count. Going out never needs the count —
        // append it all, throw the last card, close clean at 0.
        let seven = TestCards.card(.seven, .hearts)
        let eight = TestCards.card(.eight, .hearts)
        let three = TestCards.card(.three, .hearts)
        let last = TestCards.card(.nine, .clubs)
        let meldID = UUID()
        var s = state(hand: [seven, eight, three, last], laidDown: false, melds: [tableWithRun(id: meldID)])
        s = try StateBuilder.apply(
            .appendCard(MeldEntry(card: seven, asRank: .seven, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        s = try StateBuilder.apply(
            .appendCard(MeldEntry(card: eight, asRank: .eight, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        s = try StateBuilder.apply(
            .appendCard(MeldEntry(card: three, asRank: .three, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        #expect(s.players[0].pendingLayDownValue == 18, "7+8+3 pended, well under 61")
        let thrown = try StateBuilder.apply(.throwCard(last), by: 0, to: s)
        guard case .roundEnded(let result) = thrown.phase else {
            Issue.record("expected a clean close, got \(thrown.phase)")
            return
        }
        #expect(result.closerSeat == 0)
        #expect(result.deltas[0] == 0)
        #expect(thrown.tableMelds[0].meld.entries.count == 6)
    }

    @Test func runOnTheTableGrowsPastFiveByAppending() throws {
        // The 5-card cap applies to laying a series; a run already on the
        // table keeps growing (up to the full suit).
        let three = TestCards.card(.three, .hearts)
        let meldID = UUID()
        let five = tableWithRun(id: meldID, extraEntries: [
            MeldEntry(card: TestCards.card(.seven, .hearts), asRank: .seven, asSuit: .hearts),
            MeldEntry(card: TestCards.card(.eight, .hearts), asRank: .eight, asSuit: .hearts),
        ])
        let s = state(hand: [three, TestCards.card(.nine, .clubs)], melds: [five])
        let after = try StateBuilder.apply(
            .appendCard(MeldEntry(card: three, asRank: .three, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        #expect(after.tableMelds[0].meld.entries.count == 6)
        #expect(!after.players[0].hand.contains(three))
    }

    @Test func appendThatDoesNotFitIsRejected() {
        let nine = TestCards.card(.nine, .spades)
        let meldID = UUID()
        let s = state(hand: [nine, TestCards.card(.ten, .clubs)], melds: [tableWithRun(id: meldID)])
        #expect(throws: RummyError.cannotAppendHere) {
            try StateBuilder.apply(
                .appendCard(MeldEntry(card: nine, asRank: .nine, asSuit: .spades), meldID: meldID), by: 0, to: s)
        }
    }

    @Test func swapJokerPutsJokerInHandAndItMustBeReused() throws {
        let joker = TestCards.joker()
        let five = TestCards.card(.five, .hearts, copy: 1)
        let meldID = UUID()
        let meldWithJoker = TableMeld(id: meldID, ownerSeat: 1, meld: Meld(entries: [
            MeldEntry(card: runCards[0], asRank: .four, asSuit: .hearts),
            MeldEntry(card: joker, asRank: .five, asSuit: .hearts),
            MeldEntry(card: runCards[2], asRank: .six, asSuit: .hearts),
        ]))
        let seven = TestCards.card(.seven, .clubs)
        let eight = TestCards.card(.eight, .clubs)
        let spare = TestCards.card(.queen, .diamonds)
        var s = state(hand: [five, seven, eight, spare], melds: [meldWithJoker])
        s = try StateBuilder.apply(.swapJoker(meldID: meldID, realCard: five), by: 0, to: s)
        #expect(s.players[0].hand.contains(joker))
        #expect(s.tableMelds[0].meld.entries[1].card == five)
        #expect(s.phase == .turn(seat: 0, .awaitingThrow(drew: .pile, pendingJoker: joker)))
        // Throwing with the joker still in hand is illegal.
        #expect(throws: RummyError.jokerPending) { try StateBuilder.apply(.throwCard(seven), by: 0, to: s) }
        // Using the joker in a new meld clears the debt.
        let newMeld = Meld(entries: [
            MeldEntry(card: seven, asRank: .seven, asSuit: .clubs),
            MeldEntry(card: eight, asRank: .eight, asSuit: .clubs),
            MeldEntry(card: joker, asRank: .nine, asSuit: .clubs),
        ])
        s = try StateBuilder.apply(.layDown(melds: [newMeld]), by: 0, to: s)
        #expect(s.phase == .turn(seat: 0, .awaitingThrow(drew: .pile, pendingJoker: nil)))
        // The swapped-out real card now lives on the table, not in hand.
        #expect(throws: RummyError.cardNotInHand) { try StateBuilder.apply(.throwCard(five), by: 0, to: s) }
        _ = try StateBuilder.apply(.throwCard(spare), by: 0, to: s)
    }

    @Test func swapJokerRequiresMatchingRealCard() {
        let joker = TestCards.joker()
        let meldID = UUID()
        let meldWithJoker = TableMeld(id: meldID, ownerSeat: 1, meld: Meld(entries: [
            MeldEntry(card: runCards[0], asRank: .four, asSuit: .hearts),
            MeldEntry(card: joker, asRank: .five, asSuit: .hearts),
            MeldEntry(card: runCards[2], asRank: .six, asSuit: .hearts),
        ]))
        let wrong = TestCards.card(.five, .spades)
        let s = state(hand: [wrong, TestCards.card(.nine, .clubs)], melds: [meldWithJoker])
        #expect(throws: RummyError.noJokerInMeld) {
            try StateBuilder.apply(.swapJoker(meldID: meldID, realCard: wrong), by: 0, to: s)
        }
    }
}
