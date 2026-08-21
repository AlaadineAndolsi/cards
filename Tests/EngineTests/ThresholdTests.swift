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
                           config: RulesConfig = .default) -> RamiState {
        StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [hand, [], [], []],
            laidDown: [laidDown, false, false, false],
            turnsCompleted: 3,  // past the first draw-and-throw cycle
            lastInitialLayDown: lastInitial,
            config: config)
    }

    @Test func layDownIsLockedDuringTheFirstCycle() {
        var config = RulesConfig.default
        config.minimumLayDown = 60
        var s = turnState(hand: handWith(kings + aces, filler: 9), config: config)
        s.turnsCompletedThisRound = 2  // dealer has not had their turn yet
        #expect(throws: RamiError.layDownLocked) {
            try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        }
    }

    @Test func initialLayDownBelowConfiguredMinimumIsRejected() {
        let s = turnState(hand: handWith(smallRun, filler: 12))
        #expect(throws: RamiError.thresholdNotMet(required: 61, got: 9)) {
            try StateBuilder.apply(.layDown(melds: [meldOf(smallRun)]), by: 0, to: s)
        }
    }

    @Test func initialLayDownAtConfiguredMinimumSucceeds() throws {
        var config = RulesConfig.default
        config.minimumLayDown = 60
        let s = turnState(hand: handWith(kings + aces, filler: 9), config: config)
        let after = try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        #expect(after.players[0].hasLaidDown)
        #expect(after.lastInitialLayDownTotal == 60)
        #expect(after.players[0].hand.count == 9)
    }

    @Test func escalationRequiresPreviousPlusOne() {
        // Previous initial lay-down was 65 → this one needs 66; 60 fails.
        let s = turnState(hand: handWith(kings + aces, filler: 9), lastInitial: 65)
        #expect(throws: RamiError.thresholdNotMet(required: 66, got: 60)) {
            try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        }
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
        #expect(throws: RamiError.mustKeepACardToThrow) {
            try StateBuilder.apply(.layDown(melds: [meldOf(kings), meldOf(aces)]), by: 0, to: s)
        }
    }

    @Test func layDownCardsMustComeFromHand() {
        let s = turnState(hand: handWith(kings, filler: 11), laidDown: true)
        #expect(throws: RamiError.cardNotInHand) {
            try StateBuilder.apply(.layDown(melds: [meldOf(aces)]), by: 0, to: s)
        }
    }

    @Test func escalationChainResetsNextRound() throws {
        var s = turnState(hand: handWith(kings, filler: 11), lastInitial: 90)
        s.phase = .roundEnded(RoundResult(closerSeat: 1, deltas: [0, 0, 0, 0], newlyEliminated: []))
        let next = try StateBuilder.apply(.startNextRound, by: 0, to: s)
        #expect(next.lastInitialLayDownTotal == nil)
        #expect(next.requiredLayDown == RulesConfig.default.minimumLayDown)
    }
}

struct AppendAndJokerTests {
    private let runCards = [TestCards.card(.four, .hearts), TestCards.card(.five, .hearts), TestCards.card(.six, .hearts)]

    private func tableWithRun(id: UUID = UUID(), extraEntries: [MeldEntry] = []) -> TableMeld {
        TableMeld(id: id, ownerSeat: 2, meld: Meld(
            entries: runCards.map { MeldEntry(card: $0, asRank: $0.rank!, asSuit: $0.suit!) } + extraEntries))
    }

    private func state(hand: [Card], laidDown: Bool = true, melds: [TableMeld],
                       pendingJoker: Card? = nil) -> RamiState {
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

    @Test func appendBeforeOwnLayDownIsRejected() {
        let seven = TestCards.card(.seven, .hearts)
        let meldID = UUID()
        let s = state(hand: [seven, TestCards.card(.nine, .clubs)], laidDown: false, melds: [tableWithRun(id: meldID)])
        #expect(throws: RamiError.notLaidDownYet) {
            try StateBuilder.apply(
                .appendCard(MeldEntry(card: seven, asRank: .seven, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        }
    }

    @Test func appendThatWouldGrowMeldPastFiveIsRejected() {
        let three = TestCards.card(.three, .hearts)
        let meldID = UUID()
        let five = tableWithRun(id: meldID, extraEntries: [
            MeldEntry(card: TestCards.card(.seven, .hearts), asRank: .seven, asSuit: .hearts),
            MeldEntry(card: TestCards.card(.eight, .hearts), asRank: .eight, asSuit: .hearts),
        ])
        let s = state(hand: [three, TestCards.card(.nine, .clubs)], melds: [five])
        #expect(throws: RamiError.meldFull) {
            try StateBuilder.apply(
                .appendCard(MeldEntry(card: three, asRank: .three, asSuit: .hearts), meldID: meldID), by: 0, to: s)
        }
    }

    @Test func appendThatDoesNotFitIsRejected() {
        let nine = TestCards.card(.nine, .spades)
        let meldID = UUID()
        let s = state(hand: [nine, TestCards.card(.ten, .clubs)], melds: [tableWithRun(id: meldID)])
        #expect(throws: RamiError.cannotAppendHere) {
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
        #expect(throws: RamiError.jokerPending) { try StateBuilder.apply(.throwCard(seven), by: 0, to: s) }
        // Using the joker in a new meld clears the debt.
        let newMeld = Meld(entries: [
            MeldEntry(card: seven, asRank: .seven, asSuit: .clubs),
            MeldEntry(card: eight, asRank: .eight, asSuit: .clubs),
            MeldEntry(card: joker, asRank: .nine, asSuit: .clubs),
        ])
        s = try StateBuilder.apply(.layDown(melds: [newMeld]), by: 0, to: s)
        #expect(s.phase == .turn(seat: 0, .awaitingThrow(drew: .pile, pendingJoker: nil)))
        // The swapped-out real card now lives on the table, not in hand.
        #expect(throws: RamiError.cardNotInHand) { try StateBuilder.apply(.throwCard(five), by: 0, to: s) }
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
        #expect(throws: RamiError.noJokerInMeld) {
            try StateBuilder.apply(.swapJoker(meldID: meldID, realCard: wrong), by: 0, to: s)
        }
    }
}
