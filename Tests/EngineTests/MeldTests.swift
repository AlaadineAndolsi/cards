import Testing
@testable import Cards

/// Helpers to build cards/melds tersely in tests.
enum TestCards {
    static func card(_ rank: Rank, _ suit: Suit, copy: Int = 0) -> Card {
        let deck = Card.fullDeck()
        let matches = deck.filter { $0.kind == .standard(rank: rank, suit: suit) }
        return matches[copy]
    }

    static func joker(_ index: Int = 0) -> Card {
        Card.fullDeck().filter(\.isJoker)[index]
    }

    static func entry(_ rank: Rank, _ suit: Suit, copy: Int = 0) -> MeldEntry {
        MeldEntry(card: card(rank, suit, copy: copy), asRank: rank, asSuit: suit)
    }

    static func jokerEntry(as rank: Rank, _ suit: Suit, index: Int = 0) -> MeldEntry {
        MeldEntry(card: joker(index), asRank: rank, asSuit: suit)
    }

    static func run(_ suit: Suit, _ ranks: Rank...) -> Meld {
        Meld(entries: ranks.map { entry($0, suit) })
    }

    static func set(_ rank: Rank, _ suits: Suit...) -> Meld {
        Meld(entries: suits.map { entry(rank, $0) })
    }
}

struct MeldValidationTests {
    @Test func validRunsOfThreeFourFive() throws {
        #expect(try TestCards.run(.hearts, .four, .five, .six).validate() == .run)
        #expect(try TestCards.run(.spades, .nine, .ten, .jack, .queen).validate() == .run)
        #expect(try TestCards.run(.clubs, .two, .three, .four, .five, .six).validate() == .run)
    }

    @Test func runOfSixIsRejected() {
        let meld = TestCards.run(.hearts, .two, .three, .four, .five, .six, .seven)
        #expect(throws: MeldError.invalidSize) { try meld.validate() }
    }

    @Test func runOfTwoIsRejected() {
        #expect(throws: MeldError.invalidSize) { try TestCards.run(.hearts, .four, .five).validate() }
    }

    @Test func runMustBeSameSuitAndConsecutive() {
        let mixedSuit = Meld(entries: [
            TestCards.entry(.four, .hearts), TestCards.entry(.five, .spades), TestCards.entry(.six, .hearts),
        ])
        #expect(throws: MeldError.self) { try mixedSuit.validate() }
        let gap = TestCards.run(.hearts, .four, .five, .seven)
        #expect(throws: MeldError.self) { try gap.validate() }
        let unordered = TestCards.run(.hearts, .five, .four, .six)
        #expect(throws: MeldError.self) { try unordered.validate() }
    }

    @Test func aceLowAndHighRuns() throws {
        #expect(try TestCards.run(.diamonds, .ace, .two, .three).validate() == .run)
        #expect(try TestCards.run(.diamonds, .queen, .king, .ace).validate() == .run)
    }

    @Test func aroundTheCornerIsRejected() {
        #expect(throws: MeldError.self) { try TestCards.run(.diamonds, .king, .ace, .two).validate() }
    }

    @Test func validSetsOfThreeAndFour() throws {
        #expect(try TestCards.set(.nine, .hearts, .spades, .clubs).validate() == .set)
        #expect(try TestCards.set(.king, .hearts, .spades, .clubs, .diamonds).validate() == .set)
    }

    @Test func setWithDuplicateSuitIsRejectedEvenAcrossDecks() {
        let meld = Meld(entries: [
            TestCards.entry(.nine, .hearts, copy: 0),
            TestCards.entry(.nine, .hearts, copy: 1),
            TestCards.entry(.nine, .spades),
        ])
        #expect(throws: MeldError.duplicateSuitInSet) { try meld.validate() }
    }

    @Test func setOfFiveIsRejected() {
        // 5-card set impossible with 4 distinct suits; duplicate suit triggers first,
        // but size is also structurally invalid for sets.
        let meld = Meld(entries: [
            TestCards.entry(.nine, .hearts), TestCards.entry(.nine, .spades),
            TestCards.entry(.nine, .clubs), TestCards.entry(.nine, .diamonds),
            TestCards.entry(.nine, .hearts, copy: 1),
        ])
        #expect(throws: MeldError.self) { try meld.validate() }
    }

    @Test func jokerSubstitutesInRunAndSet() throws {
        let run = Meld(entries: [
            TestCards.entry(.four, .hearts),
            TestCards.jokerEntry(as: .five, .hearts),
            TestCards.entry(.six, .hearts),
        ])
        #expect(try run.validate() == .run)
        let set = Meld(entries: [
            TestCards.entry(.queen, .hearts),
            TestCards.jokerEntry(as: .queen, .spades),
            TestCards.entry(.queen, .clubs),
        ])
        #expect(try set.validate() == .set)
    }

    @Test func standardCardEntryMustMatchItsOwnFace() {
        // A real 4♥ cannot pretend to be 5♥.
        let meld = Meld(entries: [
            MeldEntry(card: TestCards.card(.four, .hearts), asRank: .five, asSuit: .hearts),
            TestCards.entry(.six, .hearts),
            TestCards.entry(.seven, .hearts),
        ])
        #expect(throws: MeldError.entryFaceMismatch) { try meld.validate() }
    }

    @Test func duplicateCardInstanceInOneMeldIsRejected() {
        let card = TestCards.card(.four, .hearts)
        let meld = Meld(entries: [
            MeldEntry(card: card, asRank: .four, asSuit: .hearts),
            MeldEntry(card: card, asRank: .four, asSuit: .hearts),
            TestCards.entry(.four, .spades),
        ])
        #expect(throws: MeldError.self) { try meld.validate() }
    }
}

struct MeldValueTests {
    @Test func numberCardsCountFaceValueAndFacesCountTen() throws {
        #expect(try TestCards.run(.hearts, .four, .five, .six).validatedThresholdValue() == 15)
        #expect(try TestCards.set(.king, .hearts, .spades, .clubs).validatedThresholdValue() == 30)
        #expect(try TestCards.run(.spades, .nine, .ten, .jack).validatedThresholdValue() == 29)
    }

    @Test func aceCountsOneInAceLowRun() throws {
        #expect(try TestCards.run(.diamonds, .ace, .two, .three).validatedThresholdValue() == 6)
    }

    @Test func aceCountsTenInHighRunAndInSets() throws {
        #expect(try TestCards.run(.diamonds, .queen, .king, .ace).validatedThresholdValue() == 30)
        #expect(try TestCards.set(.ace, .hearts, .spades, .clubs).validatedThresholdValue() == 30)
    }

    @Test func jokerCountsAsRepresentedValue() throws {
        let run = Meld(entries: [
            TestCards.entry(.four, .hearts),
            TestCards.jokerEntry(as: .five, .hearts),
            TestCards.entry(.six, .hearts),
        ])
        #expect(try run.validatedThresholdValue() == 15)
        // Joker as the ace of an ace-low run counts 1.
        let aceLow = Meld(entries: [
            TestCards.jokerEntry(as: .ace, .diamonds),
            TestCards.entry(.two, .diamonds),
            TestCards.entry(.three, .diamonds),
        ])
        #expect(try aceLow.validatedThresholdValue() == 6)
    }
}
