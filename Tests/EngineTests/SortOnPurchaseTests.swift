import Foundation
import Testing
@testable import Cards

/// A purchased card must land where the player expects: full re-sort while a
/// sort is active, and after a manual drag switched the full sort off, fresh
/// cards keep slotting in beside their sorted neighbor (never at the end).
/// Only explicitly toggling the sort off stops the slotting.
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
            turnsCompleted: 4)
        if let topOfPile {
            s.drawPile.removeAll { $0.id == topOfPile.id }
            s.drawPile.append(topOfPile)  // drawFromPile pops last
        }
        return RummyGameViewModel(state: s, store: GameStore(directory: dir))
    }

    private func labels(_ vm: RummyGameViewModel) -> [String] {
        vm.humanHand.map { $0.isJoker ? "J" : "\($0.rank!.label)\($0.suit!.symbol)" }
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
