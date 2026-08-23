import Foundation
import Testing
@testable import Cards

/// The deck holds two copies of every card. The meld search must treat the
/// copies as two distinct resources: one copy in one series, the other copy in
/// another — otherwise real qualifying hands are declared impossible and a
/// legal take gets the +100 failed-take penalty.
struct DuplicateCopyPartitionTests {

    @Test func bothCopiesOfACardServeTwoDifferentRuns() {
        // 6♣ 7♣ 8♣ 9♣ 10♣ 10♣ J♣ Q♣ + spare: the only way past 61 is
        // 6-7-8-9-10 (40) plus 10-J-Q (30) using one 10♣ copy each.
        let hand = [
            TestCards.card(.six, .clubs), TestCards.card(.seven, .clubs),
            TestCards.card(.eight, .clubs), TestCards.card(.nine, .clubs),
            TestCards.card(.ten, .clubs, copy: 0), TestCards.card(.ten, .clubs, copy: 1),
            TestCards.card(.jack, .clubs), TestCards.card(.queen, .clubs),
            TestCards.card(.three, .hearts),
        ]
        let best = HandAnalysis.bestPartition(hand: hand, maxCovered: hand.count - 1)
        #expect(best.value >= 70, "both 10♣ copies must be usable, got \(best.value)")
        #expect(RummyEngine.qualifyingLayDownExists(hand: hand, required: 61))
    }

    @Test func bothCopiesOfACardServeARunAndASet() {
        // 9♥ appears twice: one copy belongs in 8♥-9♥-10♥, the other in the
        // set of nines.
        let hand = [
            TestCards.card(.eight, .hearts), TestCards.card(.nine, .hearts, copy: 0),
            TestCards.card(.ten, .hearts),
            TestCards.card(.nine, .hearts, copy: 1), TestCards.card(.nine, .clubs),
            TestCards.card(.nine, .diamonds),
            TestCards.card(.three, .spades),
        ]
        let best = HandAnalysis.bestPartition(hand: hand, maxCovered: hand.count - 1)
        #expect(best.value >= 27 + 27, "run of 8-9-10 plus set of nines, got \(best.value)")
    }

    @Test func twoIdenticalMeldsFromTheTwoDeckCopies() {
        let hand = [
            TestCards.card(.four, .spades, copy: 0), TestCards.card(.five, .spades, copy: 0),
            TestCards.card(.six, .spades, copy: 0),
            TestCards.card(.four, .spades, copy: 1), TestCards.card(.five, .spades, copy: 1),
            TestCards.card(.six, .spades, copy: 1),
            TestCards.card(.queen, .diamonds),
        ]
        let best = HandAnalysis.bestPartition(hand: hand, maxCovered: hand.count - 1)
        #expect(best.value == 30, "both copies of 4♠5♠6♠ must lay, got \(best.value)")
        #expect(best.coveredCount == 6)
    }

    @Test func twoJokersServeTwoDifferentMelds() {
        // Each joker completes a different run; pinning both candidates to the
        // first joker would make them mutually exclusive.
        let hand = [
            TestCards.card(.six, .clubs), TestCards.card(.seven, .clubs), TestCards.joker(0),
            TestCards.card(.jack, .hearts), TestCards.card(.queen, .hearts), TestCards.joker(1),
            TestCards.card(.two, .diamonds),
        ]
        let best = HandAnalysis.bestPartition(hand: hand, maxCovered: hand.count - 1)
        #expect(best.coveredCount == 6, "both jokers must be usable at once, got \(best.coveredCount)")
    }

    @Test func reportedIncidentHandQualifiesAtNinetyOne() {
        // Round 2, required 91: taking the throw ended the round at +100 even
        // though 7♣-[J=8]-9♣-10♣ (34) + 10♣-J♣-Q♣ (30) + 6♣6♥6♦ (18) +
        // 4♠5♠6♠ (15) = 97 was right there — it needs both 10♣ copies.
        let hand = [
            TestCards.card(.ten, .clubs, copy: 0), TestCards.card(.nine, .clubs),
            TestCards.joker(), TestCards.card(.seven, .clubs), TestCards.card(.six, .clubs),
            TestCards.card(.six, .spades), TestCards.card(.five, .spades),
            TestCards.card(.four, .spades),
            TestCards.card(.three, .clubs), TestCards.card(.queen, .clubs),
            TestCards.card(.jack, .clubs), TestCards.card(.ten, .clubs, copy: 1),
            TestCards.card(.nine, .hearts, copy: 0), TestCards.card(.six, .hearts),
            TestCards.card(.six, .diamonds), TestCards.card(.nine, .hearts, copy: 1),
        ]
        #expect(RummyEngine.qualifyingLayDownExists(hand: hand, required: 91))
    }

    @Test func takeWithDuplicateDependentQualifyingHandIsNotPenalized() throws {
        // Engine-level regression for the same incident: the take must stand,
        // not settle the round at +100.
        let taken = TestCards.card(.nine, .hearts, copy: 1)
        let hand = [
            TestCards.card(.ten, .clubs, copy: 0), TestCards.card(.nine, .clubs),
            TestCards.joker(), TestCards.card(.seven, .clubs), TestCards.card(.six, .clubs),
            TestCards.card(.six, .spades), TestCards.card(.five, .spades),
            TestCards.card(.four, .spades),
            TestCards.card(.three, .clubs), TestCards.card(.queen, .clubs),
            TestCards.card(.jack, .clubs), TestCards.card(.ten, .clubs, copy: 1),
            TestCards.card(.nine, .hearts, copy: 0), TestCards.card(.six, .hearts),
            TestCards.card(.six, .diamonds),
        ]
        let s = StateBuilder.turn(
            seat: 0, stage: .awaitingDraw,
            hands: [hand, [], [], []],
            throwStacks: [[], [], [], [taken]],
            turnsCompleted: 4,
            lastInitialLayDown: 90)
        let after = try StateBuilder.apply(.takeThrow, by: 0, to: s)
        #expect(after.phase == .turn(seat: 0, .awaitingThrow(drew: .takenThrow, pendingJoker: nil)))
    }
}

/// Going out completely never needs the count ("it's done") — the throw path
/// honors an under-count full close, so the take-commitment check must too.
struct UnderCountCloseQualifiesTests {

    @Test func takeEnablingAFullCloseUnderTheCountIsNotPenalized() throws {
        // After taking 3♥ the hand closes: A♠2♠3♠ + A♥2♥3♥ (12 points,
        // far under 61) laid, 9♦ thrown, hand empty.
        let taken = TestCards.card(.three, .hearts)
        let hand = [
            TestCards.card(.ace, .spades), TestCards.card(.two, .spades),
            TestCards.card(.three, .spades),
            TestCards.card(.ace, .hearts), TestCards.card(.two, .hearts),
            TestCards.card(.nine, .diamonds),
        ]
        let s = StateBuilder.turn(
            seat: 0, stage: .awaitingDraw,
            hands: [hand, [], [], []],
            throwStacks: [[], [], [], [taken]],
            turnsCompleted: 4)
        let after = try StateBuilder.apply(.takeThrow, by: 0, to: s)
        #expect(after.phase == .turn(seat: 0, .awaitingThrow(drew: .takenThrow, pendingJoker: nil)))
    }

    @Test func closingMeldsFindsTheCloseWhenCoveringEverythingIsAlsoPossible() {
        // 4♠5♠6♠7♠ + 8♥9♥10♥ covers all 7 cards — but closing means keeping
        // one to throw: 4♠5♠6♠ + 8♥9♥10♥, throwing 7♠.
        let hand = [
            TestCards.card(.four, .spades), TestCards.card(.five, .spades),
            TestCards.card(.six, .spades), TestCards.card(.seven, .spades),
            TestCards.card(.eight, .hearts), TestCards.card(.nine, .hearts),
            TestCards.card(.ten, .hearts),
        ]
        let melds = HandAnalysis.closingMelds(hand: hand)
        #expect(melds != nil, "a 6-card cover exists, closing must be found")
        #expect(melds?.flatMap(\.cards).count == hand.count - 1)
    }
}
