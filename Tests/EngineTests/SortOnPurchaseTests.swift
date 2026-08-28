import Foundation
import Testing
@testable import Cards

/// A purchased card must land where the player expects: full re-sort while a
/// sort is active, and after a manual drag switched the full sort off, fresh
/// cards keep slotting in beside their sorted neighbor (never at the end).
/// Only explicitly toggling the sort off stops the slotting.
/// Chained placement: with Q♠-J♠-10♠ on the table and A♠+K♠ in hand, BOTH
/// are placeable — the K♠ bridges the A♠. Both lock blue, both show in the
/// melds popup, and placing the ace lays the king on the way.
@MainActor
struct ChainedPlacementTests {
    private func makeVM() -> (vm: RummyGameViewModel, meldID: UUID, ace: Card, king: Card) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let run = TestCards.run(.spades, .ten, .jack, .queen)
        let ace = TestCards.card(.ace, .spades)
        let king = TestCards.card(.king, .spades)
        let meld = TableMeld(id: UUID(), ownerSeat: 1, meld: run)
        let s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [[ace, king, TestCards.card(.four, .hearts),
                     TestCards.card(.nine, .diamonds)], [], [], []],
            laidDown: [true, true, true, true],
            tableMelds: [meld])
        return (RummyGameViewModel(state: s, store: GameStore(directory: dir)),
                meld.id, ace, king)
    }

    @Test func chainedCardIsACandidateAndLocksBlue() {
        let (vm, meldID, ace, king) = makeVM()
        #expect(vm.popupCandidates.contains { $0.id == king.id })
        #expect(vm.popupCandidates.contains { $0.id == ace.id },
                "the ace shows beside the king — the king bridges it")
        #expect(vm.chainFittingMelds(for: ace) == [meldID])
        vm.longPressLock(ace)
        vm.longPressLock(king)
        #expect(vm.lockedPlaceables.contains(ace.id))
        #expect(vm.lockedPlaceables.contains(king.id))
    }

    @Test func placingTheChainedAceLaysTheKingOnTheWay() {
        let (vm, meldID, ace, king) = makeVM()
        vm.placeCard(ace, on: meldID)
        #expect(!vm.humanHand.contains { $0.id == ace.id })
        #expect(!vm.humanHand.contains { $0.id == king.id })
        #expect(vm.state.tableMelds[0].meld.entries.count == 5,
                "10-J-Q grew by the king and the ace")
    }
}

/// A throw out of an organized (but unlocked) series — three fan neighbors
/// forming a valid meld, like an arranged 6-5-4 — bounces once with a
/// warning; repeating the exact same throw confirms it.
@MainActor
struct SeriesThrowGuardTests {
    private func makeVM(hand: [Card]) -> RummyGameViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .pile, pendingJoker: nil),
            hands: [hand, [], [], []],
            turnsCompleted: 4)
        return RummyGameViewModel(state: s, store: GameStore(directory: dir))
    }

    @Test func throwFromAnArrangedRunBouncesOnceThenConfirms() {
        let six = TestCards.card(.six, .clubs)
        let five = TestCards.card(.five, .clubs)
        let four = TestCards.card(.four, .clubs)
        let kd = TestCards.card(.king, .diamonds)
        let vm = makeVM(hand: [six, five, four, kd])
        vm.apply(.throwCard(five))
        #expect(vm.state.players[0].hand.count == 4, "first throw bounces with a warning")
        vm.apply(.throwCard(five))
        #expect(vm.state.players[0].hand.count == 3, "the repeated throw confirms")
        #expect(vm.state.players[0].throwStack.last == five)
    }

    @Test func throwOutsideAnySeriesGoesStraightThrough() {
        let six = TestCards.card(.six, .clubs)
        let five = TestCards.card(.five, .clubs)
        let four = TestCards.card(.four, .clubs)
        let kd = TestCards.card(.king, .diamonds)
        let vm = makeVM(hand: [six, five, four, kd])
        vm.apply(.throwCard(kd))
        #expect(vm.state.players[0].hand.count == 3, "a loose card throws with no fuss")
    }

    @Test func scatteredCardsDoNotCountAsASeries() {
        // Same three clubs, but the 5♣ is parked away from its mates: the
        // arrangement holds no series, so the throw goes straight through.
        let six = TestCards.card(.six, .clubs)
        let five = TestCards.card(.five, .clubs)
        let four = TestCards.card(.four, .clubs)
        let kd = TestCards.card(.king, .diamonds)
        let nineH = TestCards.card(.nine, .hearts)
        let vm = makeVM(hand: [six, four, kd, nineH, five])
        vm.apply(.throwCard(five))
        #expect(vm.state.players[0].hand.count == 4, "no organized series, no bounce")
    }
}

@MainActor
struct SortOnPurchaseTests {

    private func makeVM(
        hand: [Card], topOfPile: Card? = nil, previousThrow: Card? = nil
    ) -> RummyGameViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        var s = StateBuilder.turn(
            seat: 0, stage: .awaitingDraw,
            hands: [hand, [], [], []],
            throwStacks: [[], [], [], previousThrow.map { [$0] } ?? []],
            turnsCompleted: 5)
        if let topOfPile {
            s.drawPile.removeAll { $0.id == topOfPile.id }
            s.drawPile.append(topOfPile)  // drawFromPile pops last
        }
        return RummyGameViewModel(state: s, store: GameStore(directory: dir))
    }

    private func labels(_ vm: RummyGameViewModel) -> [String] {
        vm.humanHand.map { $0.isJoker ? "J" : "\($0.rank!.label)\($0.suit!.symbol)" }
    }

    // MARK: Locked jokers — the real card takes the seat

    /// A locked K♠-[joker as Q♠]-J♠: purchasing the real Q♠ slides it into
    /// the joker's seat; the freed joker pops out unlocked at the left of
    /// the free cards.
    @Test func purchasedCardTakesALockedJokersSeat() {
        let ks = TestCards.card(.king, .spades)
        let js = TestCards.card(.jack, .spades)
        let joker = TestCards.joker()
        let qs = TestCards.card(.queen, .spades)
        let filler = TestCards.card(.seven, .hearts)
        let vm = makeVM(hand: [ks, joker, js, filler], topOfPile: qs)
        vm.toggleSelection(ks)
        vm.toggleSelection(joker)
        vm.toggleSelection(js)
        vm.lockSelection()
        #expect(vm.lockedCardIDs.contains(joker.id))
        vm.apply(.drawFromPile)
        #expect(vm.lockedCardIDs.contains(qs.id), "the Q♠ locked into the joker's seat")
        #expect(!vm.lockedCardIDs.contains(joker.id), "the joker is free again")
        // Locked block first (K Q J), then the freed joker leads the rest.
        #expect(Array(vm.handOrder.prefix(4)) == [ks.id, qs.id, js.id, joker.id],
                "got \(labels(vm))")
    }

    /// Taking the previous throw frees a locked joker the same way:
    /// 5♦-[joker as 4♦]-3♦ locked, the thrown 4♦ takes the seat.
    @Test func takenThrowTakesALockedJokersSeat() {
        let fiveD = TestCards.card(.five, .diamonds)
        let threeD = TestCards.card(.three, .diamonds)
        let joker = TestCards.joker()
        let fourD = TestCards.card(.four, .diamonds)
        let filler = TestCards.card(.king, .diamonds)
        let vm = makeVM(hand: [fiveD, joker, threeD, filler], previousThrow: fourD)
        vm.toggleSelection(fiveD)
        vm.toggleSelection(joker)
        vm.toggleSelection(threeD)
        vm.lockSelection()
        #expect(vm.lockedCardIDs.contains(joker.id))
        vm.apply(.takeThrow)
        #expect(vm.lockedCardIDs.contains(fourD.id), "the 4♦ locked into the joker's seat")
        #expect(!vm.lockedCardIDs.contains(joker.id))
    }

    // MARK: Active sort — the full re-sort keeps working

    @Test func drawSlotsIntoActiveRankSort() {
        let hand = [
            TestCards.card(.four, .spades), TestCards.card(.king, .hearts),
            TestCards.card(.seven, .clubs), TestCards.card(.two, .diamonds),
        ]
        let drawn = TestCards.card(.ten, .diamonds)
        let vm = makeVM(hand: hand, topOfPile: drawn)
        vm.toggleSort(.rank)
        vm.apply(.drawFromPile)
        #expect(vm.humanHand.last?.id != drawn.id, "drawn card must not just sit at the end")
    }

    @Test func drawSlotsIntoActiveSortWithLockedSeries() {
        let run = [
            TestCards.card(.four, .hearts), TestCards.card(.five, .hearts),
            TestCards.card(.six, .hearts),
        ]
        let loose = [
            TestCards.card(.king, .spades), TestCards.card(.nine, .clubs),
            TestCards.card(.two, .diamonds),
        ]
        let drawn = TestCards.card(.ten, .diamonds)
        let vm = makeVM(hand: run + loose, topOfPile: drawn)
        for card in run { vm.toggleSelection(card) }
        vm.lockSelection()
        vm.toggleSort(.rank)
        vm.apply(.drawFromPile)
        #expect(vm.humanHand.last?.id != drawn.id, "drawn card must not just sit at the end")
        #expect(Set(vm.handOrder.prefix(3)) == Set(run.map(\.id)), "locked series stays grouped left")
    }

    @Test func takenThrowSlotsIntoActiveSort() {
        // KKK + QQQ + JJJ = 90 ≥ 61 so the take commitment check passes.
        let hand = [
            TestCards.card(.jack, .clubs), TestCards.card(.king, .hearts),
            TestCards.card(.seven, .clubs), TestCards.card(.queen, .hearts),
            TestCards.card(.king, .spades), TestCards.card(.king, .clubs),
            TestCards.card(.queen, .spades), TestCards.card(.queen, .clubs),
            TestCards.card(.jack, .hearts), TestCards.card(.jack, .spades),
        ]
        let taken = TestCards.card(.ten, .diamonds)
        let vm = makeVM(hand: hand, previousThrow: taken)
        vm.toggleSort(.rank)
        vm.tapTakeableThrow()
        #expect(vm.humanHand.last?.id != taken.id, "taken card must not just sit at the end")
    }

    // MARK: After a manual drag — fresh cards keep slotting by the last sort

    @Test func manualReorderKeepsSlottingDrawsByTheLastSort() {
        let king = TestCards.card(.king, .hearts)
        let seven = TestCards.card(.seven, .clubs)
        let four = TestCards.card(.four, .spades)
        let two = TestCards.card(.two, .diamonds)
        let drawn = TestCards.card(.ten, .diamonds)
        let vm = makeVM(hand: [four, king, seven, two], topOfPile: drawn)
        vm.toggleSort(.rank)
        // The player drags 7♣ to the front: full sort off, arrangement kept.
        vm.handOrder = [seven.id, king.id, four.id, two.id]
        vm.commitManualReorder()
        #expect(vm.activeSort == nil)
        vm.apply(.drawFromPile)
        // 10♦ slots in beside its sorted predecessor (K♥), not at the end.
        #expect(vm.handOrder == [seven.id, king.id, drawn.id, four.id, two.id],
                "got \(labels(vm))")
    }

    @Test func manualReorderKeepsSlottingTakesByTheLastSort() {
        let hand = [
            TestCards.card(.jack, .clubs), TestCards.card(.king, .hearts),
            TestCards.card(.seven, .clubs), TestCards.card(.queen, .hearts),
            TestCards.card(.king, .spades), TestCards.card(.king, .clubs),
            TestCards.card(.queen, .spades), TestCards.card(.queen, .clubs),
            TestCards.card(.jack, .hearts), TestCards.card(.jack, .spades),
        ]
        let taken = TestCards.card(.ten, .diamonds)
        let vm = makeVM(hand: hand, previousThrow: taken)
        vm.toggleSort(.rank)
        vm.handOrder = vm.handOrder.reversed()  // manual rearrangement
        vm.commitManualReorder()
        vm.tapTakeableThrow()
        #expect(vm.humanHand.last?.id != taken.id,
                "taken card must slot beside its sorted neighbor, got \(labels(vm))")
    }

    @Test func explicitSortToggleOffStopsTheSlotting() {
        let hand = [
            TestCards.card(.four, .spades), TestCards.card(.king, .hearts),
            TestCards.card(.seven, .clubs), TestCards.card(.two, .diamonds),
        ]
        let drawn = TestCards.card(.ten, .diamonds)
        let vm = makeVM(hand: hand, topOfPile: drawn)
        vm.toggleSort(.rank)
        vm.toggleSort(.rank)  // deliberate off
        vm.apply(.drawFromPile)
        #expect(vm.humanHand.last?.id == drawn.id,
                "sorting was explicitly turned off — the draw goes to the end")
    }

    @Test func freshDealLandsFullySortedInManualMode() {
        // A drag switched the full sort off mid-round; the NEXT round's deal
        // has no manual arrangement to respect — it lands fully sorted by the
        // remembered rule, exactly as if the sort button had been tapped.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        var s = StateBuilder.base()
        s.dealerSeat = 0
        let vm = RummyGameViewModel(state: s, store: GameStore(directory: dir))
        vm.toggleSort(.rank)
        vm.commitManualReorder()  // manual mode: activeSort off, slotSort kept
        vm.apply(.deal(.p3222))
        let dealt = vm.handOrder
        #expect(dealt.count == 15)
        vm.toggleSort(.rank)  // reference: the full sort's order
        #expect(dealt == vm.handOrder, "the deal must land already fully sorted")
    }

    @Test func dragThatClearsTheSortShowsANotice() {
        let hand = [
            TestCards.card(.four, .spades), TestCards.card(.king, .hearts),
            TestCards.card(.seven, .clubs), TestCards.card(.two, .diamonds),
        ]
        let vm = makeVM(hand: hand)
        vm.toggleSort(.rank)
        vm.commitManualReorder()
        #expect(vm.stripNotice != nil, "turning the sort off must never be silent")
        // A drag with no sort active stays silent.
        let quiet = makeVM(hand: hand)
        quiet.commitManualReorder()
        #expect(quiet.stripNotice == nil)
    }
}
