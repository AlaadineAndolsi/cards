import Testing
@testable import Cards

struct DeckTests {
    @Test func fullDeckHas108UniqueCards() {
        let deck = Card.fullDeck()
        #expect(deck.count == 108)
        #expect(Set(deck.map(\.id)).count == 108)
        #expect(deck.map(\.id).sorted() == Array(0..<108))
    }

    @Test func fullDeckHasTwoCopiesOfEachStandardCardAndFourJokers() {
        let deck = Card.fullDeck()
        var counts: [Card.Kind: Int] = [:]
        for card in deck { counts[card.kind, default: 0] += 1 }
        #expect(counts[.joker] == 4)
        for suit in Suit.allCases {
            for rank in Rank.allCases {
                #expect(counts[.standard(rank: rank, suit: suit)] == 2)
            }
        }
    }

    @Test func fisherYatesIsDeterministicUnderSeededRNG() {
        var rng1 = SeededRNG(seed: 42)
        var rng2 = SeededRNG(seed: 42)
        var a = Card.fullDeck(), b = Card.fullDeck()
        a.fisherYatesShuffle(using: &rng1)
        b.fisherYatesShuffle(using: &rng2)
        #expect(a == b)
        var rng3 = SeededRNG(seed: 43)
        var c = Card.fullDeck()
        c.fisherYatesShuffle(using: &rng3)
        #expect(a != c)
        #expect(Set(a) == Set(c))
    }
}

struct DealPatternTests {
    @Test(arguments: DealPattern.allCases)
    func patternDeals15ToDealerAnd14ToOthers(pattern: DealPattern) {
        let passes = pattern.passes(playerCount: 4)
        var totals = [0, 0, 0, 0]  // index 0 = dealer
        for pass in passes {
            #expect(pass.count == 4)
            for (i, n) in pass.enumerated() { totals[i] += n }
        }
        #expect(totals[0] == 15)
        #expect(totals[1] == 14 && totals[2] == 14 && totals[3] == 14)
    }

    @Test func patternSchedulesMatchSpec() {
        // 1-1-1-1: fourteen uniform single-card passes, dealer +1 at the end
        let p1111 = DealPattern.p1111.passes(playerCount: 4)
        #expect(p1111.count == 15)
        #expect(p1111.dropLast().allSatisfy { $0 == [1, 1, 1, 1] })
        #expect(p1111.last == [1, 0, 0, 0])
        // 1-2-2-2 finishing by adding 2 to himself: rhythm cycles 1,2,2,2 per pass;
        // dealer stops at 13 during regular passes and takes a final 2
        let p1222 = DealPattern.p1222.passes(playerCount: 4)
        #expect(p1222.last == [2, 0, 0, 0])
        #expect(p1222.dropLast().map { $0[1] } == [1, 2, 2, 2, 1, 2, 2, 2])
        // 2-2-2-2 adding 1 to himself at the end
        let p2222 = DealPattern.p2222.passes(playerCount: 4)
        #expect(p2222.dropLast().allSatisfy { $0 == [2, 2, 2, 2] })
        #expect(p2222.last == [1, 0, 0, 0])
        // 2-1-1-1 rhythm
        let p2111 = DealPattern.p2111.passes(playerCount: 4)
        #expect(p2111.dropLast().map { $0[1] } == [2, 1, 1, 1, 2, 1, 1, 1, 2, 1, 1])
        // 3-2-2-2 rhythm
        let p3222 = DealPattern.p3222.passes(playerCount: 4)
        #expect(p3222.dropLast().map { $0[1] } == [3, 2, 2, 2, 3, 2])
    }

    @Test func threePlayerPatternsDeal15_14_14() {
        for pattern in DealPattern.allCases {
            var totals = [0, 0, 0]
            for pass in pattern.passes(playerCount: 3) {
                #expect(pass.count == 3)
                for (i, n) in pass.enumerated() { totals[i] += n }
            }
            #expect(totals == [15, 14, 14], "\(pattern)")
        }
    }
}
