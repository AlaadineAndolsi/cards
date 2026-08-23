import Foundation
import Testing
@testable import Cards

/// Smart sort must never break up a COMPLETE low run: 4-3-2 of one suit is a
/// valid meld even though every card is "weak". Only low fragments (a bare
/// 2-3 without an ace) dissolve into the number clusters.
@MainActor
struct SmartSortTests {

    private func makeVM(hand: [Card]) -> RummyGameViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let s = StateBuilder.turn(
            seat: 0, stage: .awaitingThrow(drew: .dealt, pendingJoker: nil),
            hands: [hand, [], [], []],
            turnsCompleted: 0)
        return RummyGameViewModel(state: s, store: GameStore(directory: dir))
    }

    private func position(of card: Card, in vm: RummyGameViewModel) -> Int {
        vm.handOrder.firstIndex(of: card.id) ?? -1
    }

    @Test func completeLowRunStaysTogether() {
        // The reported hand: smart sort paired 4♥+4♠ and 2♠+2♦ and dumped 3♠
        // into the loose tail — but 4♠-3♠-2♠ is a complete run.
        let four = TestCards.card(.four, .spades)
        let three = TestCards.card(.three, .spades)
        let two = TestCards.card(.two, .spades)
        let hand = [
            TestCards.joker(), TestCards.card(.jack, .spades),
            TestCards.card(.jack, .hearts), TestCards.card(.jack, .diamonds),
            TestCards.card(.ten, .diamonds), TestCards.card(.eight, .clubs),
            TestCards.card(.seven, .clubs), TestCards.card(.six, .clubs),
            TestCards.card(.four, .hearts), four, two,
            TestCards.card(.two, .diamonds), TestCards.card(.ace, .diamonds),
            TestCards.card(.nine, .spades), three,
        ]
        let vm = makeVM(hand: hand)
        vm.toggleSort(.smart)
        let positions = [position(of: four, in: vm), position(of: three, in: vm), position(of: two, in: vm)]
        #expect(positions == [positions[0], positions[0] + 1, positions[0] + 2],
                "4♠ 3♠ 2♠ must sit together as a run, got positions \(positions)")
    }

    @Test func bareLowRunOfThreeIsARunNotDeadwood() {
        let four = TestCards.card(.four, .hearts)
        let three = TestCards.card(.three, .hearts)
        let two = TestCards.card(.two, .hearts)
        let hand = [
            TestCards.card(.king, .spades), four,
            TestCards.card(.nine, .clubs), three,
            TestCards.card(.queen, .diamonds), two,
        ]
        let vm = makeVM(hand: hand)
        vm.toggleSort(.smart)
        let positions = [position(of: four, in: vm), position(of: three, in: vm), position(of: two, in: vm)]
        #expect(positions == [positions[0], positions[0] + 1, positions[0] + 2],
                "4♥ 3♥ 2♥ must stay one block, got \(vm.handOrder)")
        // A complete run outranks loose court cards: it leads the hand.
        #expect(positions[0] == 0, "the only combo in hand belongs at the left")
    }

    @Test func lowFragmentWithoutAceStillDissolves() {
        // 3♣ 2♣ alone stays weak — the fragment rule survives the fix.
        let three = TestCards.card(.three, .clubs)
        let two = TestCards.card(.two, .clubs)
        let king = TestCards.card(.king, .spades)
        let queen = TestCards.card(.queen, .spades)
        let jack = TestCards.card(.jack, .spades)
        let vm = makeVM(hand: [three, king, queen, two, jack])
        vm.toggleSort(.smart)
        // The K-Q-J run leads; the low fragment sits behind it, not ahead.
        #expect(position(of: king, in: vm) == 0, "got \(vm.handOrder)")
        #expect(position(of: three, in: vm) > position(of: jack, in: vm))
    }
}
