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

    /// SMART_SORT_EXAMPLES.md #1 — near-runs beat rank-mate attachment, a
    /// gap of three never bridges, the joker prints far left and promotes
    /// the hand-leading weak card. Blocks: Joker · K♦ (13) · Q♣ 10♣ (12) ·
    /// J♠ 9♠ (11) · 10♦ 9♦ 7♦ (10) · the 3♦-2s cluster · 6♠.
    @Test func nearRunsBeatRankMatesAndJokerClaimsTopWeakCard() {
        let joker = TestCards.joker()
        let kd = TestCards.card(.king, .diamonds)
        let qc = TestCards.card(.queen, .clubs)
        let js = TestCards.card(.jack, .spades)
        let tc = TestCards.card(.ten, .clubs)
        let td = TestCards.card(.ten, .diamonds)
        let ns = TestCards.card(.nine, .spades)
        let nd = TestCards.card(.nine, .diamonds)
        let sd = TestCards.card(.seven, .diamonds)
        let threeD = TestCards.card(.three, .diamonds)
        let twoD = TestCards.card(.two, .diamonds)
        let twoS = TestCards.card(.two, .spades)
        let twoH = TestCards.card(.two, .hearts)
        let sixS = TestCards.card(.six, .spades)
        let vm = makeVM(hand: [joker, kd, qc, js, tc, td, ns, nd, sd,
                               threeD, twoD, twoS, twoH, sixS])
        vm.toggleSort(.smart)
        let prefix = [joker, kd, qc, tc, js, ns, td, nd, sd].map(\.id)
        #expect(Array(vm.handOrder.prefix(9)) == prefix,
                "joker far left, then combo blocks by top card, got \(vm.handOrder)")
        // The tail: 3♦ heads the cluster of twos; the stray 6♠ ends the hand.
        #expect(position(of: threeD, in: vm) == 9)
        let twos = [position(of: twoD, in: vm), position(of: twoS, in: vm),
                    position(of: twoH, in: vm)].sorted()
        #expect(twos == [10, 11, 12], "the twos hold together, got \(vm.handOrder)")
        #expect(position(of: sixS, in: vm) == 13)
    }

    /// SMART_SORT_EXAMPLES.md #2 — a weak two-suit pair plus the joker is a
    /// READY meld: the joker leads that block at the left of the hand
    /// instead of parking last. And 8♥-6♥ (one missing 7♥) is a near-run
    /// block. Blocks: Joker K♥ K♣ (13) · Q♦ J♦ (12) · 9♠ 9♣ 8♣ (9) ·
    /// 8♥ 6♥ (8) · the four twos.
    @Test func jokerLeadsAReadyMeldWithAWeakPair() {
        let joker = TestCards.joker()
        let kh = TestCards.card(.king, .hearts)
        let kc = TestCards.card(.king, .clubs)
        let qd = TestCards.card(.queen, .diamonds)
        let jd = TestCards.card(.jack, .diamonds)
        let nc = TestCards.card(.nine, .clubs)
        let ns = TestCards.card(.nine, .spades)
        let ec = TestCards.card(.eight, .clubs)
        let eh = TestCards.card(.eight, .hearts)
        let sh = TestCards.card(.six, .hearts)
        let twoH = TestCards.card(.two, .hearts)
        let twoD = TestCards.card(.two, .diamonds)
        let twoD2 = TestCards.card(.two, .diamonds, copy: 1)
        let twoC = TestCards.card(.two, .clubs)
        let vm = makeVM(hand: [joker, qd, jd, nc, ns, ec, eh,
                               twoH, twoD, twoD2, twoC, kc, kh, sh])
        vm.toggleSort(.smart)
        let prefix = [joker, kh, kc, qd, jd, ns, nc, ec, eh, sh].map(\.id)
        #expect(Array(vm.handOrder.prefix(10)) == prefix,
                "joker heads the ready king set, 6♥ chains under 8♥, got \(vm.handOrder)")
        let twos = [twoH, twoD, twoD2, twoC].map { position(of: $0, in: vm) }.sorted()
        #expect(twos == [10, 11, 12, 13], "the twos hold together at the tail")
    }

    /// SMART_SORT_EXAMPLES.md #3 — 2♦ is not ripped away from 3♦ to sit as
    /// a rank-mate beside the hearts: the dissolved 3♦-2♦ fragment stays
    /// together in the clusters, 3 printed before 2. The ace sits high
    /// beside Q♥ (A-K-line if possible), the 9♠ is NOT promoted (it does
    /// not lead the hand). Jokers far left: Joker Joker · A♥ Q♥ (14) ·
    /// K♠ K♣ (13) · 7♣ 7♦ (7) · 3♦ 2♦ 2♥ 9♠ 5♥ 4♠.
    @Test func dissolvedLowFragmentKeepsThreeBeforeTwo() {
        let j1 = TestCards.joker(0)
        let j2 = TestCards.joker(1)
        let ks = TestCards.card(.king, .spades)
        let kc = TestCards.card(.king, .clubs)
        let sc = TestCards.card(.seven, .clubs)
        let sd = TestCards.card(.seven, .diamonds)
        let fh = TestCards.card(.five, .hearts)
        let twoD = TestCards.card(.two, .diamonds)
        let twoH = TestCards.card(.two, .hearts)
        let ah = TestCards.card(.ace, .hearts)
        let qh = TestCards.card(.queen, .hearts)
        let ns = TestCards.card(.nine, .spades)
        let fs = TestCards.card(.four, .spades)
        let threeD = TestCards.card(.three, .diamonds)
        let vm = makeVM(hand: [j1, j2, ks, kc, sc, sd, fh,
                               twoD, twoH, ah, qh, ns, fs, threeD])
        vm.toggleSort(.smart)
        let expected = [j1, j2, ah, qh, ks, kc, sc, sd,
                        threeD, twoD, twoH, ns, fh, fs].map(\.id)
        #expect(vm.handOrder == expected,
                "3♦ prints right before 2♦, got \(vm.handOrder)")
    }

    /// SMART_SORT_EXAMPLES.md #4 — complete sets beat runs: four kings and
    /// three queens claim their cards even though that breaks the complete
    /// K♠-Q♠-J♠ run and the K♦-Q♦ pair; the leftover J♠ lines up under the
    /// queens. Blocks: K♦ K♥ K♥ K♠ (13) · Q♦ Q♣ Q♠ J♠ (12) · 6♦ 5♦ (6) ·
    /// 5♠ 3♠ (5) · 8♣ 4♥.
    @Test func completeSetsClaimCardsBeforeRuns() {
        let kd = TestCards.card(.king, .diamonds)
        let kh1 = TestCards.card(.king, .hearts)
        let kh2 = TestCards.card(.king, .hearts, copy: 1)
        let ks = TestCards.card(.king, .spades)
        let qd = TestCards.card(.queen, .diamonds)
        let qc = TestCards.card(.queen, .clubs)
        let qs = TestCards.card(.queen, .spades)
        let js = TestCards.card(.jack, .spades)
        let sxd = TestCards.card(.six, .diamonds)
        let fd = TestCards.card(.five, .diamonds)
        let fs = TestCards.card(.five, .spades)
        let threeS = TestCards.card(.three, .spades)
        let ec = TestCards.card(.eight, .clubs)
        let fh = TestCards.card(.four, .hearts)
        let vm = makeVM(hand: [kh1, kh2, ks, qc, qs, js, kd, qd,
                               sxd, fd, fs, ec, fh, threeS])
        vm.toggleSort(.smart)
        let expected = [kd, kh1, kh2, ks, qd, qc, qs, js,
                        sxd, fd, fs, threeS, ec, fh].map(\.id)
        #expect(vm.handOrder == expected,
                "sets lead, J♠ tails the queens, got \(vm.handOrder)")
    }

    /// SMART_SORT_EXAMPLES.md #5 — ace-king if possible, not 2-ace: A♠
    /// joins K♠ (leaving the 2♠ weak), and the twos pair lines up under
    /// the club run's 3. Joker far left: Joker · A♠ K♠ (14) ·
    /// 10♠ 10♥ (10, promoted pair) · 6♥ 6♣ 5♣ 3♣ 2♠ 2♥ (6) · 9♦ 7♠ 4♥.
    @Test func acePrefersKingOverTwo() {
        let joker = TestCards.joker()
        let ks = TestCards.card(.king, .spades)
        let th = TestCards.card(.ten, .hearts)
        let ts = TestCards.card(.ten, .spades)
        let ss = TestCards.card(.seven, .spades)
        let sh = TestCards.card(.six, .hearts)
        let sc = TestCards.card(.six, .clubs)
        let fc = TestCards.card(.five, .clubs)
        let threeC = TestCards.card(.three, .clubs)
        let twoH = TestCards.card(.two, .hearts)
        let twoS = TestCards.card(.two, .spades)
        let ace = TestCards.card(.ace, .spades)
        let nd = TestCards.card(.nine, .diamonds)
        let fh = TestCards.card(.four, .hearts)
        let vm = makeVM(hand: [joker, ks, th, ts, ss, sh, sc,
                               fc, threeC, twoH, twoS, ace, nd, fh])
        vm.toggleSort(.smart)
        let expected = [joker, ace, ks, ts, th, sh, sc, fc,
                        threeC, twoS, twoH, nd, ss, fh].map(\.id)
        #expect(vm.handOrder == expected,
                "A♠ sits beside K♠, not the 2♠, got \(vm.handOrder)")
    }

    /// SMART_SORT_EXAMPLES.md #6 — the joker prints far LEFT, and a lone
    /// weak card (J♦) is NOT promoted when it would not lead the hand: it
    /// stays in the clusters. The 10-set exits on the tail nines' suit.
    /// Joker · K♣ Q♣ (13) · 10♣ 10♠ 10♥ 9♥ 9♣ (10) · 4♣ 3♣ 3♥ 3♦ · J♦ 8♠.
    @Test func jokerLeftAndMidHandSingleStaysWeak() {
        let joker = TestCards.joker()
        let kc = TestCards.card(.king, .clubs)
        let qc = TestCards.card(.queen, .clubs)
        let jh = TestCards.card(.jack, .diamonds)
        let tc = TestCards.card(.ten, .clubs)
        let th = TestCards.card(.ten, .hearts)
        let ts = TestCards.card(.ten, .spades)
        let nh = TestCards.card(.nine, .hearts)
        let nc = TestCards.card(.nine, .clubs)
        let fc = TestCards.card(.four, .clubs)
        let threeC = TestCards.card(.three, .clubs)
        let threeH = TestCards.card(.three, .hearts)
        let threeD = TestCards.card(.three, .diamonds)
        let es = TestCards.card(.eight, .spades)
        let vm = makeVM(hand: [kc, qc, jh, tc, th, ts, nh, nc,
                               fc, threeC, threeH, threeD, es, joker])
        vm.toggleSort(.smart)
        let prefix = [joker, kc, qc, tc, ts, th, nh, nc].map(\.id)
        #expect(Array(vm.handOrder.prefix(8)) == prefix,
                "joker left, 10-set exits on hearts to meet 9♥, got \(vm.handOrder)")
        #expect(position(of: fc, in: vm) == 8, "4♣ heads the threes")
        let threes = [position(of: threeC, in: vm), position(of: threeH, in: vm),
                      position(of: threeD, in: vm)].sorted()
        #expect(threes == [9, 10, 11], "the threes hold together")
        #expect(position(of: jh, in: vm) == 12,
                "J♥ stays weak — it would not lead the hand")
        #expect(position(of: es, in: vm) == 13)
    }

    /// SMART_SORT_EXAMPLES.md #7 — a set member refuses the claim when its
    /// suit runs longer through it (7♥ stays in 9-8-7-6, killing the 7s
    /// set), a rank-mate prefers an END seat (7♦ beside 7♣-6♣, not buried
    /// mid-run), and a lone single only promotes when it CROWNS the top
    /// block (A♣ over a 9-block stays weak). Joker · 9♥ 8♥ 7♥ 6♥ ·
    /// 7♦ 7♣ 6♣ · 4♠ 4♦ 3♦ 3♥ · A♣ · Q♥.
    @Test func runThroughASetMemberBeatsTheSet() {
        let joker = TestCards.joker()
        let ac = TestCards.card(.ace, .clubs)
        let nh = TestCards.card(.nine, .hearts)
        let eh = TestCards.card(.eight, .hearts)
        let sevenH = TestCards.card(.seven, .hearts)
        let sevenD = TestCards.card(.seven, .diamonds)
        let sevenC = TestCards.card(.seven, .clubs)
        let sixH = TestCards.card(.six, .hearts)
        let sixC = TestCards.card(.six, .clubs)
        let fourS = TestCards.card(.four, .spades)
        let fourD = TestCards.card(.four, .diamonds)
        let threeD = TestCards.card(.three, .diamonds)
        let threeH = TestCards.card(.three, .hearts)
        let qh = TestCards.card(.queen, .hearts)
        let vm = makeVM(hand: [joker, ac, nh, eh, sixH, sixC, sevenD,
                               sevenC, sevenH, fourS, fourD, threeD, threeH, qh])
        vm.toggleSort(.smart)
        let expected = [joker, nh, eh, sevenH, sixH, sevenD, sevenC, sixC,
                        fourS, fourD, threeD, threeH, ac, qh].map(\.id)
        #expect(vm.handOrder == expected,
                "the heart run keeps its 7, got \(vm.handOrder)")
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
