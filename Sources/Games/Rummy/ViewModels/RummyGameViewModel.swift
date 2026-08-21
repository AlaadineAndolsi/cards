import Foundation
import Observation

/// Owns the game state, applies human actions, runs bot turns with natural
/// pauses, and autosaves after every action. Killing the app mid-turn and
/// reopening restores exactly this state.
@MainActor
@Observable
final class RummyGameViewModel {
    private(set) var state: RummyState
    let store: GameStore
    private var rng = SystemRandomNumberGenerator()
    private var botTask: Task<Void, Never>?

    /// Card ids the human selected in their hand (and possibly the takeable throw).
    var selectedCardIDs: Set<Int> = []
    /// Manual hand order (card ids); updated by sorting or dragging.
    var handOrder: [Int] = []
    /// Locked series: confirmed melds kept grouped at the left of the hand.
    private(set) var lockedSeries: [[Int]] = []
    private(set) var lockedMelds: [Meld] = []
    var lastError: RummyError?
    var matchFinished = false
    /// True while the card-by-card deal animation plays; gates the vote UI
    /// and pauses the bot loop so the rhythm is visible.
    var isDealAnimating = false
    /// The card the human just purchased, briefly revealed center-table.
    var revealedDraw: Card?

    // MARK: Center banner (all table feedback shares this one style)

    enum BannerStyle { case info, warn, announce, verdict }
    struct TableBanner: Equatable {
        let text: String
        let style: BannerStyle
        var icon: String?
    }
    private(set) var banner: TableBanner?
    private var bannerTask: Task<Void, Never>?
    /// Covers the round/match-end sheet while the closing announcement plays.
    private(set) var roundEndCurtain = false
    private var nudgeTask: Task<Void, Never>?

    // MARK: Deal animation (owned here so the pile count can never go stale)

    struct DealFlight: Identifiable, Equatable {
        let id: Int
        let seatOffset: Int
        let delay: Double
    }
    private(set) var dealFlights: [DealFlight] = []
    /// Pile count during the deal animation, ticking down from 108.
    private(set) var animatedPileCount: Int?
    /// Cards "arrived" so far per seat offset during the deal animation —
    /// fans and counters build up card by card following the pattern.
    private(set) var dealtCounts: [Int]?
    var dealtHandCount: Int? { dealtCounts?[0] }
    private var dealTask: Task<Void, Never>?

    /// A bot's thrown card flying from its seat to the throw spot.
    private(set) var throwFlight: (id: Int, seatOffset: Int, card: Card)?
    private var throwFlightID = 0

    // MARK: Hover-to-append drag support

    /// Shown after holding a dragged card over the melds for a moment.
    var meldPreviewShown = false
    /// Global frames of the big meld drop targets, reported by the overlay.
    var meldDropFrames: [UUID: CGRect] = [:]

    var humanSeat: Int { state.players.firstIndex(where: \.isHuman) ?? 0 }

    init(state: RummyState, store: GameStore) {
        self.state = state
        self.store = store
        syncHandOrder()
        scheduleTurnNudge()
        resumeBotsIfNeeded()
    }

    static func newGame(settings: SettingsStore, botLevel: BotLevel, store: GameStore) -> RummyGameViewModel {
        var rng = SystemRandomNumberGenerator()
        let botNames = Array(NamePool.tunisianMen.shuffled(using: &rng).prefix(3))
        let state = RummyEngine.newGame(
            config: settings.config(botLevel: botLevel),
            names: [L10n.you] + botNames,
            dealerSeat: Int.random(in: 0..<4, using: &rng),
            rng: &rng)
        return RummyGameViewModel(state: state, store: store)
    }

    // MARK: Derived state for the UI

    var humanHand: [Card] {
        let hand = state.players[humanSeat].hand
        let byID = Dictionary(uniqueKeysWithValues: hand.map { ($0.id, $0) })
        var ordered = handOrder.compactMap { byID[$0] }
        let missing = hand.filter { !handOrder.contains($0.id) }
        ordered.append(contentsOf: missing)
        return ordered
    }

    var isHumanTurn: Bool {
        if case .turn(let seat, _) = state.phase, seat == humanSeat { return true }
        return false
    }

    var humanStage: TurnStage? {
        if case .turn(let seat, let stage) = state.phase, seat == humanSeat { return stage }
        return nil
    }

    var isHumanDealingPhase: Bool {
        if case .dealing = state.phase, state.dealerSeat == humanSeat { return true }
        return false
    }

    var humanVoteRole: (isProposer: Bool, proposerSeat: Int)? {
        if case .vote(let proposer, let current) = state.phase, current == humanSeat {
            return (proposer == humanSeat, proposer)
        }
        return nil
    }

    var takeableThrow: Card? { state.takeableThrow(for: humanSeat) }

    var layDownUnlocked: Bool {
        state.turnsCompletedThisRound >= state.aliveCount - 1
    }

    /// Whose turn/phase it is, for the header.
    var activeSeatName: String? {
        switch state.phase {
        case .dealing: displayName(state.dealerSeat)
        case .vote(_, let current): displayName(current)
        case .turn(let seat, _): displayName(seat)
        default: nil
        }
    }

    func displayName(_ seat: Int) -> String {
        state.players[seat].isHuman ? L10n.you : state.players[seat].name
    }

    // MARK: Locked series

    var lockedCardIDs: Set<Int> { Set(lockedSeries.flatMap { $0 }) }

    var lockedValues: [Int] {
        lockedMelds.map { (try? $0.validatedThresholdValue()) ?? 0 }
    }

    var lockedTotal: Int { lockedValues.reduce(0, +) }

    /// The current selection partitioned into one or more valid series —
    /// consecutive series selected together lock correctly, not just one.
    var selectionAsPartition: (melds: [Meld], value: Int)? {
        let cards = state.players[humanSeat].hand.filter {
            selectedCardIDs.contains($0.id) && !lockedCardIDs.contains($0.id)
        }
        guard cards.count == selectedCardIDs.count, cards.count >= Meld.minSize else { return nil }
        let partition = HandAnalysis.bestPartition(hand: cards, maximizeCoverage: true)
        guard partition.coveredCount == cards.count else { return nil }
        return (partition.melds, partition.value)
    }

    /// Long-press on a card locks the current selection as series (adding the
    /// pressed card to the selection if needed).
    func longPressLock(_ card: Card) {
        guard !lockedCardIDs.contains(card.id) else { return }
        if !selectedCardIDs.contains(card.id) { selectedCardIDs.insert(card.id) }
        if selectionAsPartition != nil {
            lockSelection()
        } else {
            Haptics.warning()
            showNotice("Selection isn't a valid series", warn: true, duration: 1.8)
        }
    }

    /// Hover-to-append is only meaningful once the human can append at all.
    var canAppendToTable: Bool {
        guard isHumanTurn, case .awaitingThrow = humanStage,
              state.players[humanSeat].hasLaidDown,
              !state.tableMelds.isEmpty else { return false }
        return true
    }

    func lockSelection() {
        guard let partition = selectionAsPartition else { return }
        Haptics.action()
        for meld in partition.melds {
            lockedSeries.append(meld.entries.map(\.card.id))
            lockedMelds.append(meld)
        }
        selectedCardIDs = []
        rebuildHandOrder()
    }

    func unlockSeries(containing id: Int) {
        guard let index = lockedSeries.firstIndex(where: { $0.contains(id) }) else { return }
        Haptics.tap()
        lockedSeries.remove(at: index)
        lockedMelds.remove(at: index)
        rebuildHandOrder()
    }

    func lockedSeriesIndex(containing id: Int) -> Int? {
        lockedSeries.firstIndex { $0.contains(id) }
    }

    /// Card ids in the same locked series as `id` (for group dragging).
    func lockedGroup(containing id: Int) -> [Int] {
        lockedSeries.first { $0.contains(id) } ?? []
    }

    /// Lays one locked series onto the table (pending until the throw).
    func layLockedSeries(at index: Int) {
        guard lockedMelds.indices.contains(index) else { return }
        apply(.layDown(melds: [lockedMelds[index]]))
    }

    private func rebuildHandOrder() {
        let locked = lockedSeries.flatMap { $0 }
        handOrder = locked + humanHand.map(\.id).filter { !locked.contains($0) }
    }

    /// Drop any locked series whose cards left the hand (laid or thrown).
    private func pruneLocks() {
        let handIDs = Set(state.players[humanSeat].hand.map(\.id))
        for index in lockedSeries.indices.reversed()
        where !lockedSeries[index].allSatisfy({ handIDs.contains($0) }) {
            lockedSeries.remove(at: index)
            lockedMelds.remove(at: index)
        }
    }

    // MARK: Pending lay-down (confirmed only by the throw)

    var pendingLayDownValue: Int? { state.players[humanSeat].pendingLayDownValue }

    /// The hint shown between the chips row and the hand.
    var handHint: (text: String, warn: Bool)? {
        guard isHumanTurn else { return nil }
        let player = state.players[humanSeat]
        guard case .awaitingThrow = humanStage else { return nil }
        if let pending = player.pendingLayDownValue, !player.hasLaidDown {
            if player.hand.count == 1 {
                return ("Throw your last card — it's done!", false)
            }
            if pending < state.requiredLayDown {
                return ("Laid \(pending) / \(state.requiredLayDown) — throwing now costs +100", true)
            }
            return ("Laid \(pending) — throw a card to confirm", false)
        }
        if mustLayDownNow {
            return ("You took the throw — lay a series first", true)
        }
        if !player.hasLaidDown, layDownUnlocked, lockedTotal >= state.requiredLayDown {
            return ("You can lay down — slide a locked series up", false)
        }
        return nil
    }

    /// Tapping a big meld in the popup appends the single selected card.
    func tapPreviewMeld(_ id: UUID) {
        guard selectedCardIDs.count == 1,
              let card = state.players[humanSeat].hand.first(where: {
                  selectedCardIDs.contains($0.id)
              }) else { return }
        appendCard(card, to: id)
    }

    /// Appends a hand card to a table meld (tap or hover-drop).
    func appendCard(_ card: Card, to meldID: UUID) {
        guard let tableMeld = state.tableMelds.first(where: { $0.id == meldID }) else { return }
        let entry: MeldEntry?
        if card.isJoker {
            entry = tableMeld.meld.jokerEntryToExtend(joker: card)
        } else if let rank = card.rank, let suit = card.suit {
            entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
        } else {
            entry = nil
        }
        guard let entry else {
            lastError = .cannotAppendHere
            Haptics.warning()
            return
        }
        Haptics.action()
        apply(.appendCard(entry, meldID: meldID))
    }

    // MARK: Human actions

    func apply(_ action: RummyAction) {
        #if DEBUG
        print("RUMMY human apply: \(action)")
        #endif
        do {
            let before = state
            let penaltiesBefore = state.players[humanSeat].penaltiesThisRound
            state = try RummyEngine.apply(action, by: humanSeat, to: state, rng: &rng)
            if state.players[humanSeat].penaltiesThisRound > penaltiesBefore {
                Haptics.warning()
                showNotice("+10 — that card plays on a meld, it comes back", warn: true)
            }
            lastError = nil
            selectedCardIDs = []
            meldPreviewShown = false
            syncHandOrder()
            pruneLocks()
            applySortIfActive()  // fresh draws slot straight into the active sort
            if case .deal = action { startDealHold() }
            if case .drawFromPile = action,
               let drawn = state.players[humanSeat].hand.last,
               !before.players[humanSeat].hand.contains(drawn) {
                revealDraw(drawn)
            }
            announceTransition(from: before, action: action, seat: humanSeat)
            scheduleTurnNudge()
            autosave()
            resumeBotsIfNeeded()
        } catch let error as RummyError {
            lastError = error
            Haptics.warning()
        } catch {
            assertionFailure("unexpected error \(error)")
        }
    }

    func toggleSelection(_ card: Card) {
        // Tapping a locked card unlocks its series.
        if lockedCardIDs.contains(card.id) {
            unlockSeries(containing: card.id)
            return
        }
        Haptics.tap()
        if selectedCardIDs.contains(card.id) {
            selectedCardIDs.remove(card.id)
        } else {
            selectedCardIDs.insert(card.id)
        }
    }

    /// Sorting is always big-to-small from the left; the ace sorts above the
    /// king (it still plays low in A-2-3 runs). Jokers first. Locked series
    /// stay grouped at the very left.
    private func sortRankKey(_ card: Card) -> Int {
        if card.isJoker { return 15 }
        if card.rank == .ace { return 14 }
        return card.rank?.rawValue ?? 0
    }

    private func suitIndex(_ card: Card) -> Int {
        switch card.suit {
        case .spades: 0
        case .hearts: 1
        case .clubs: 2
        case .diamonds: 3
        case nil: -1
        }
    }

    // MARK: Sorting — the two sorts combine; the first one activated wins ties.

    enum SortKey: Equatable { case rank, suit }
    /// Active sort keys in activation order (first = primary). Sorting stays
    /// applied: fresh draws slot into place until a manual drag clears it.
    private(set) var sortPriority: [SortKey] = []

    func toggleSort(_ key: SortKey) {
        Haptics.tap()
        if let index = sortPriority.firstIndex(of: key) {
            sortPriority.remove(at: index)
        } else {
            sortPriority.append(key)
        }
        applySortIfActive()
    }

    private func applySortIfActive() {
        guard !sortPriority.isEmpty else { return }
        let locked = lockedSeries.flatMap { $0 }
        let rest = state.players[humanSeat].hand.filter { !locked.contains($0.id) }
        let ordered: [Card]
        if sortPriority.first == .rank {
            ordered = rankChainedOrder(rest)
        } else {
            ordered = rest.sorted {
                (suitIndex($0), sortRankKey($1), $0.id)
                    < (suitIndex($1), sortRankKey($0), $1.id)
            }
        }
        handOrder = locked + ordered.map(\.id)
    }

    /// Number-first sort: jokers leftmost, ranks descending (ace above king),
    /// and within each rank group the suits are chained — a group's last card
    /// matches the next group's first suit whenever possible, so budding runs
    /// sit next to each other across the rank boundaries.
    private func rankChainedOrder(_ cards: [Card]) -> [Card] {
        let jokers = cards.filter(\.isJoker)
        let grouped = Dictionary(grouping: cards.filter { !$0.isJoker }) { sortRankKey($0) }
        let keys = grouped.keys.sorted(by: >)
        var result = jokers
        var leadSuit: Suit?
        for (index, key) in keys.enumerated() {
            var group = grouped[key]!.sorted {
                (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
            }
            // Enter on the suit the previous group handed over.
            if let lead = leadSuit,
               let entry = group.firstIndex(where: { $0.suit == lead }) {
                group.insert(group.remove(at: entry), at: 0)
            }
            // Exit on a suit the next group can pick up.
            let nextSuits: Set<Suit> = index + 1 < keys.count
                ? Set(grouped[keys[index + 1]]!.compactMap(\.suit))
                : []
            var exitCard: Card?
            let candidates = group.indices.filter {
                group[$0].suit.map(nextSuits.contains) ?? false
            }
            if let pick = candidates.last(where: { $0 != 0 }) {
                let card = group.remove(at: pick)
                group.append(card)
                exitCard = card
            } else if group.count == 1, candidates.first != nil {
                exitCard = group[0]  // one card serves as entry and exit
            }
            leadSuit = exitCard?.suit
            result.append(contentsOf: group)
        }
        return result
    }

    /// Manual reordering takes over: it clears the active sorts.
    func reorderHand(_ order: [Int]) {
        sortPriority = []
        handOrder = order
    }

    func moveHandCard(fromOffsets: IndexSet, toOffset: Int) {
        var order = humanHand.map(\.id)
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        reorderHand(order)
    }

    /// The reset button clears the selection AND every locked series.
    func cancelSelection() {
        guard !selectedCardIDs.isEmpty || !lockedSeries.isEmpty else { return }
        Haptics.tap()
        selectedCardIDs = []
        lockedSeries = []
        lockedMelds = []
    }

    /// Slide-to-throw from the hand; only when a throw is currently legal.
    var canThrow: Bool {
        if case .awaitingThrow = humanStage { return true }
        return false
    }

    /// Tap on the previous player's last throw takes it. Before the first
    /// lay-down this is a commitment: with no qualifying lay-down even
    /// possible the round ends at +100 on the spot.
    func tapTakeableThrow() {
        guard isHumanTurn, humanStage == .awaitingDraw, state.throwTakeUnlocked,
              takeableThrow != nil else { return }
        Haptics.action()
        apply(.takeThrow)
    }

    /// True while a pre-lay-down take must still be honored.
    var mustLayDownNow: Bool {
        if case .turn(let seat, .awaitingThrow(drew: .takenThrow, _)) = state.phase,
           seat == humanSeat, !state.players[humanSeat].hasLaidDown,
           state.players[humanSeat].pendingLayDownValue == nil {
            return true
        }
        return false
    }

    // MARK: Banner

    func showBanner(_ text: String, style: BannerStyle = .info,
                    icon: String? = nil, duration: Double = 2.4) {
        showBanners([(TableBanner(text: text, style: style, icon: icon), duration)])
    }

    private func showBanners(_ items: [(TableBanner, Double)]) {
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            for (item, duration) in items {
                guard let self, !Task.isCancelled else { return }
                self.banner = item
                try? await Task.sleep(for: .seconds(duration))
            }
            guard let self, !Task.isCancelled else { return }
            self.banner = nil
        }
    }

    /// Center-table narration for everything that just happened.
    private func announceTransition(from old: RummyState, action: RummyAction, seat: Int) {
        let name = displayName(seat)

        // Vote chatter and the final verdict.
        if case .vote(let proposer, _) = old.phase {
            var resolvedToPass = false
            if case .dealing = state.phase { resolvedToPass = true }
            switch action {
            case .declareIntent(true) where seat == proposer:
                showBanners([
                    (TableBanner(text: "\(name): let's play", style: .announce, icon: "play.fill"), 1.0),
                    (TableBanner(text: L10n.playVerdict, style: .verdict, icon: "play.fill"), 1.8),
                ])
            case .declareIntent(true):
                showBanners([
                    (TableBanner(text: "\(name) wants to play", style: .announce, icon: "play.fill"), 1.2),
                    (TableBanner(text: L10n.playVerdict, style: .verdict, icon: "play.fill"), 1.8),
                ])
            case .declareIntent(false) where seat == proposer:
                showBanner("\(name) said pass", style: .announce, icon: "hand.raised.fill", duration: 3.0)
            case .declareIntent(false) where resolvedToPass:
                showBanners([
                    (TableBanner(text: "\(name): pass too", style: .announce, icon: "hand.raised.fill"), 1.0),
                    (TableBanner(text: L10n.passVerdict, style: .verdict, icon: "hand.raised.fill"), 1.8),
                ])
            case .declareIntent(false):
                showBanner("\(name): pass too", style: .announce, icon: "hand.raised.fill", duration: 3.0)
            case .forcePass:
                showBanners([
                    (TableBanner(text: "\(name) forced the pass — doubles", style: .warn, icon: "hand.raised.fill"), 1.4),
                    (TableBanner(text: L10n.passVerdict, style: .verdict, icon: "hand.raised.fill"), 1.8),
                ])
            default: break
            }
        }

        // Turn actions worth narrating.
        if case .turn = old.phase {
            switch action {
            case .takeThrow, .takeThrowAndLayDown:
                if seat != humanSeat {
                    showBanner("\(name) took the throw", icon: "hand.point.down.fill", duration: 1.8)
                }
            case .swapJoker:
                showBanner("\(name) swapped a joker", icon: "arrow.triangle.2.circlepath", duration: 1.8)
            case .throwCard(let card):
                if seat != humanSeat,
                   state.players[seat].throwStack.count > old.players[seat].throwStack.count {
                    startThrowFlight(seat: seat, card: card)
                }
            default: break
            }
        }

        // Round or match end: play the closing announcement over a curtain,
        // then reveal the score sheet.
        let endedNow: Bool = {
            switch (old.phase, state.phase) {
            case (.roundEnded, _), (.matchEnded, _): return false
            case (_, .roundEnded), (_, .matchEnded): return true
            default: return false
            }
        }()
        if endedNow {
            roundEndCurtain = true
            switch state.phase {
            case .roundEnded(let result):
                if let closer = result.closerSeat {
                    showBanner("\(displayName(closer)) said it's done!",
                               style: .verdict, icon: "crown.fill", duration: 2.0)
                } else if let failed = result.deltas.firstIndex(of: 100) {
                    showBanner("\(displayName(failed)) missed the count — +100",
                               style: .verdict, icon: "exclamationmark.triangle.fill", duration: 2.0)
                }
            case .matchEnded:
                showBanner(L10n.gameOver, style: .verdict, icon: "trophy.fill", duration: 2.0)
            default:
                break
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.9))
                self?.roundEndCurtain = false
            }
        }
    }

    /// Every tip, reminder, and warning for the human lives in the strip
    /// between the totals and the cards — never in the center of the table.
    /// The center is reserved for table events (votes, verdicts, closings).
    struct StripNotice: Equatable {
        let text: String
        let warn: Bool
    }
    private(set) var stripNotice: StripNotice?
    private var noticeTask: Task<Void, Never>?

    func showNotice(_ text: String, warn: Bool = false, duration: Double = 2.6) {
        noticeTask?.cancel()
        let notice = StripNotice(text: text, warn: warn)
        stripNotice = notice
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            if self?.stripNotice == notice { self?.stripNotice = nil }
        }
    }

    /// Nudges the human when their turn sits idle too long.
    private func scheduleTurnNudge() {
        nudgeTask?.cancel()
        guard isHumanTurn else { return }
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            while !Task.isCancelled {
                guard let self, self.isHumanTurn else { return }
                let text: String = switch self.humanStage {
                case .awaitingDraw:
                    self.state.throwTakeUnlocked && self.takeableThrow != nil
                        ? "Your turn — purchase or take the throw"
                        : "Your turn — purchase a card"
                default:
                    "Throw a card"
                }
                self.showNotice(text, duration: 3)
                try? await Task.sleep(for: .seconds(11))
            }
        }
    }

    private func startThrowFlight(seat: Int, card: Card) {
        throwFlightID += 1
        let id = throwFlightID
        throwFlight = (id, (seat - humanSeat + state.players.count) % state.players.count, card)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.55))
            if self?.throwFlight?.id == id { self?.throwFlight = nil }
        }
    }

    // MARK: Deal & draw animation state

    private func startDealHold() {
        guard let pattern = state.lastDealPattern else { return }
        var order: [Int] = []
        var seatIndex = state.dealerSeat
        for _ in 0..<state.aliveCount {
            seatIndex = state.nextAliveSeat(after: seatIndex)
            order.append(seatIndex)
        }
        var flights: [DealFlight] = []
        var delay = 0.0
        var flightID = 0
        for pass in pattern.passes(playerCount: state.aliveCount) {
            for (position, receiver) in order.enumerated() {
                let amount = receiver == state.dealerSeat ? pass[0] : pass[position + 1]
                for _ in 0..<amount {
                    let offset = (receiver - humanSeat + state.players.count) % state.players.count
                    flights.append(DealFlight(id: flightID, seatOffset: offset, delay: delay))
                    flightID += 1
                    delay += 0.065
                }
            }
            delay += 0.22  // breath between passes: the rhythm reads
        }
        isDealAnimating = true
        dealFlights = flights
        animatedPileCount = 108
        dealtCounts = [Int](repeating: 0, count: state.players.count)
        dealTask?.cancel()
        dealTask = Task { [weak self] in
            var previous = 0.0
            for (index, flight) in flights.enumerated() {
                try? await Task.sleep(for: .seconds(flight.delay - previous))
                previous = flight.delay
                guard let self, !Task.isCancelled else { return }
                self.animatedPileCount = 108 - index - 1
                self.dealtCounts?[flight.seatOffset] += 1
            }
            try? await Task.sleep(for: .seconds(0.7))
            guard let self, !Task.isCancelled else { return }
            self.dealFlights = []
            self.animatedPileCount = nil
            self.dealtCounts = nil
            self.isDealAnimating = false
        }
    }

    private func revealDraw(_ card: Card) {
        revealedDraw = card
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            if self?.revealedDraw == card { self?.revealedDraw = nil }
        }
    }

    func abandonMatch() {
        botTask?.cancel()
        nudgeTask?.cancel()
        dealTask?.cancel()
        Task { await store.clearActiveGame() }
    }

    // MARK: Bot loop

    private func resumeBotsIfNeeded() {
        if case .matchEnded(let placements) = state.phase {
            finishMatch(placements: placements)
            return
        }
        runBots()
    }

    private var actingSeat: Int? {
        switch state.phase {
        case .dealing: state.dealerSeat
        case .vote(_, let current): current
        case .turn(let seat, _): seat
        case .roundEnded, .matchEnded: nil
        }
    }

    private var actingSeatIsBot: Bool {
        guard let seat = actingSeat else { return false }
        return !state.players[seat].isHuman
    }

    /// Runs bot actions with short randomized pauses until it is the human's
    /// turn (or the round/match ends). Idempotent: only one loop at a time.
    func runBots() {
        guard botTask == nil, actingSeatIsBot else { return }
        let bot = RummyBot(level: state.config.botLevel)
        botTask = Task { [weak self] in
            defer { self?.botTask = nil }
            while let self, !Task.isCancelled, let seat = self.actingSeat,
                  !self.state.players[seat].isHuman {
                while self.isDealAnimating, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.2))
                }
                let pause = self.pauseForNextBotAction()
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled else { return }
                let view = PublicGameView(state: self.state, seat: seat)
                var rng = SystemRandomNumberGenerator()
                let action = bot.decide(view, rng: &rng)
                #if DEBUG
                print("RUMMY bot \(seat) apply: \(action)")
                #endif
                do {
                    let before = self.state
                    self.state = try RummyEngine.apply(action, by: seat, to: self.state, rng: &rng)
                    if case .deal = action { self.startDealHold() }
                    self.announceTransition(from: before, action: action, seat: seat)
                    self.scheduleTurnNudge()
                    self.syncHandOrder()
                    self.autosave()
                } catch {
                    assertionFailure("bot played an illegal action: \(error)")
                    return
                }
                if case .matchEnded(let placements) = self.state.phase {
                    self.finishMatch(placements: placements)
                    return
                }
            }
        }
    }

    private func pauseForNextBotAction() -> Double {
        switch state.phase {
        case .dealing: 0.7  // let each shuffle animation read
        case .vote: 1.1     // opinions land one by one in the center
        case .turn: Double.random(in: 0.55...1.15, using: &rng)
        default: 0.4
        }
    }

    private func finishMatch(placements: [FinalPlacement]) {
        guard !matchFinished else { return }
        matchFinished = true
        let record = MatchRecord(state: state, placements: placements, endedAt: Date())
        Task {
            await store.appendToHistory(record)
            await store.clearActiveGame()
        }
    }

    private func autosave() {
        let snapshot = state
        Task { await store.saveActiveGame(snapshot) }
    }

    private func syncHandOrder() {
        let hand = state.players[humanSeat].hand
        let existing = Set(handOrder)
        let handIDs = Set(hand.map(\.id))
        handOrder = handOrder.filter { handIDs.contains($0) }
        for card in hand where !existing.contains(card.id) {
            handOrder.append(card.id)
        }
    }
}
