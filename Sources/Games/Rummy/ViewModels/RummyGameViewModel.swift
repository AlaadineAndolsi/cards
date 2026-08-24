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

    enum BannerStyle { case note, verdict }
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHOW_MESSAGE_DEMO"] == "1" {
            stripNotice = StripNotice(
                text: "Laid 30 / 61 — discarding now costs +100", warn: true)
        }
        #endif
    }

    static func newGame(settings: SettingsStore, store: GameStore) -> RummyGameViewModel {
        var rng = SystemRandomNumberGenerator()
        let botNames = Array(NamePool.tunisianMen.shuffled(using: &rng).prefix(3))
        let state = RummyEngine.newGame(
            config: settings.config(),
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
        state.turnsCompletedThisRound >= state.aliveCount
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

    /// Single cards reserved for the table: they play on a meld (extend it,
    /// or free its joker) and wear their own lock color in the fan —
    /// distinct from the green series lock. In lock order: they group at the
    /// left of the hand, right after the locked series.
    private(set) var lockedPlaceables: [Int] = []

    /// The card plays on the table: it extends a meld (directly, or chained
    /// behind other free hand cards — A♠ plays on Q♠-J♠-10♠ because the K♠
    /// in hand bridges), or a joker in a meld plays exactly as this card
    /// (a swap seat is waiting for it).
    func isPlaceable(_ card: Card) -> Bool {
        if !chainFittingMelds(for: card).isEmpty { return true }
        guard let rank = card.rank, let suit = card.suit else { return false }
        return state.tableMelds.contains { tableMeld in
            tableMeld.meld.entries.contains {
                $0.card.isJoker && $0.asRank == rank && $0.asSuit == suit
            }
        }
    }

    /// Melds this card reaches once its own prerequisites go first: other
    /// free hand cards extend the meld until this one fits. Jokers never
    /// bridge silently — spending a joker stays the player's explicit call.
    func chainFittingMelds(for card: Card) -> [UUID] {
        state.tableMelds.compactMap { tableMeld in
            chainToFit(card, on: tableMeld) != nil ? tableMeld.id : nil
        }
    }

    /// The free hand cards that must append (in order) before `card` fits
    /// the meld — empty when it already fits, nil when it never will.
    /// Closest ranks are tried first so the chain stays minimal (the K♠
    /// bridges the A♠, the 9♠ stays out of it).
    private func chainToFit(_ card: Card, on tableMeld: TableMeld) -> [Card]? {
        func grownBy(_ c: Card, _ meld: Meld) -> Meld? {
            guard meld.entries.count < Meld.maxRunSize else { return nil }
            let entry: MeldEntry?
            if c.isJoker {
                entry = meld.jokerEntryToExtend(joker: c)
            } else if let rank = c.rank, let suit = c.suit {
                entry = MeldEntry(card: c, asRank: rank, asSuit: suit)
            } else {
                entry = nil
            }
            guard let entry else { return nil }
            return meld.inserting(entry)
        }
        let target = sortRankKey(card)
        func search(_ meld: Meld, _ pool: [Card], _ depth: Int) -> [Card]? {
            if grownBy(card, meld) != nil { return [] }
            guard depth < 4 else { return nil }
            let ordered = pool.sorted {
                abs(sortRankKey($0) - target) < abs(sortRankKey($1) - target)
            }
            for step in ordered {
                guard let grown = grownBy(step, meld) else { continue }
                if let rest = search(grown, pool.filter { $0.id != step.id }, depth + 1) {
                    return [step] + rest
                }
            }
            return nil
        }
        let pool = humanHand.filter {
            !$0.isJoker && $0.id != card.id && !lockedCardIDs.contains($0.id)
        }
        return search(tableMeld.meld, pool, 0)
    }

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
    /// pressed card to the selection if needed). A lone placeable card locks
    /// as a table reservation instead — its own color, unlocked by a tap.
    func longPressLock(_ card: Card) {
        guard !lockedCardIDs.contains(card.id) else { return }
        if selectedCardIDs.isEmpty || selectedCardIDs == [card.id],
           !lockedPlaceables.contains(card.id), isPlaceable(card) {
            Haptics.action()
            selectedCardIDs = []
            lockedPlaceables.append(card.id)
            rebuildHandOrder()
            applySortIfActive()
            return
        }
        if !selectedCardIDs.contains(card.id) { selectedCardIDs.insert(card.id) }
        if selectionAsPartition != nil {
            lockSelection()
            return
        }
        // Not a series, but every selected card plays on the table:
        // the whole selection locks as placeable reservations.
        let picked = humanHand.filter {
            selectedCardIDs.contains($0.id) && !lockedCardIDs.contains($0.id)
        }
        if !picked.isEmpty, picked.allSatisfy({ isPlaceable($0) }) {
            Haptics.action()
            for id in picked.map(\.id) where !lockedPlaceables.contains(id) {
                lockedPlaceables.append(id)
            }
            selectedCardIDs = []
            rebuildHandOrder()
            applySortIfActive()
            return
        }
        Haptics.warning()
        showNotice("Selection isn't a valid meld", warn: true, duration: 1.8)
    }

    /// Placing into table melds is always possible on your throw step — the
    /// count judgment happens at the discard, not here.
    var canAppendToTable: Bool {
        guard isHumanTurn, case .awaitingThrow = humanStage,
              !state.tableMelds.isEmpty else { return false }
        return true
    }

    func lockSelection() {
        guard let partition = selectionAsPartition else { return }
        Haptics.action()
        for meld in partition.melds {
            // Hand display: biggest at the left with the color rule; the
            // meld itself is stored canonically so the engine accepts it.
            lockedSeries.append(meld.displayEntries.map(\.card.id))
            lockedMelds.append(Meld(entries: canonicalEntries(meld)))
        }
        selectedCardIDs = []
        rebuildHandOrder()
    }

    /// Slide a selected (unlocked) series up: it lays directly, selection →
    /// laid, no lock step needed.
    func laySelectedSeries() {
        guard let partition = selectionAsPartition else {
            Haptics.warning()
            showNotice("Selection isn't a valid meld", warn: true, duration: 1.8)
            return
        }
        Haptics.action()
        apply(.layDown(melds: partition.melds.map { Meld(entries: canonicalEntries($0)) }))
    }

    /// The engine's validator expects run entries in ascending order — this
    /// is the canonical form every meld is laid with. The biggest-left,
    /// color-ruled arrangement is display-only (`Meld.displayEntries`).
    private func canonicalEntries(_ meld: Meld) -> [MeldEntry] {
        let lowRun = meld.entries.contains { $0.asRank == .two }
        func rankKey(_ entry: MeldEntry) -> Int {
            entry.asRank == .ace ? (lowRun ? 1 : 14) : entry.asRank.rawValue
        }
        return meld.entries.sorted {
            (rankKey($0), suitIndex($0.card)) < (rankKey($1), suitIndex($1.card))
        }
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

    /// Dropping a card on (or right beside) a locked series absorbs it when
    /// it fits — the series grows and the card locks with the group.
    func absorbIntoLockedSeriesIfFits(_ card: Card) -> Bool {
        guard !lockedCardIDs.contains(card.id) else { return false }
        guard let position = handOrder.firstIndex(of: card.id) else { return false }
        for index in lockedSeries.indices {
            guard let firstID = lockedSeries[index].first,
                  let lastID = lockedSeries[index].last,
                  let start = handOrder.firstIndex(of: firstID),
                  let end = handOrder.firstIndex(of: lastID),
                  position >= start - 1, position <= end + 1,
                  lockedMelds[index].entries.count < Meld.maxSize else { continue }
            let entry: MeldEntry?
            if card.isJoker {
                entry = lockedMelds[index].jokerEntryToExtend(joker: card)
            } else if let rank = card.rank, let suit = card.suit {
                entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
            } else {
                entry = nil
            }
            guard let entry, let grown = lockedMelds[index].inserting(entry) else { continue }
            Haptics.action()
            lockedMelds[index] = Meld(entries: canonicalEntries(grown))
            lockedSeries[index] = grown.displayEntries.map(\.card.id)
            selectedCardIDs.remove(card.id)
            rebuildHandOrder()
            return true
        }
        return false
    }

    private func rebuildHandOrder() {
        // Left edge of the fan: locked series first, then the reserved
        // placeable cards, then everything else in its current order.
        let locked = lockedSeries.flatMap { $0 } + lockedPlaceables
        handOrder = locked + humanHand.map(\.id).filter { !locked.contains($0) }
    }

    /// A purchased or taken card that is exactly what a locked joker stands
    /// for slides straight into the joker's seat: the series keeps its
    /// shape, and the freed joker pops out — unlocked, at the left of the
    /// free cards, ready to work somewhere else.
    private func swapFreshIntoLockedJokers(addedSince before: RummyState) {
        guard !lockedMelds.isEmpty else { return }
        let beforeIDs = Set(before.players[humanSeat].hand.map(\.id))
        let fresh = state.players[humanSeat].hand.filter { !beforeIDs.contains($0.id) }
        // A whole fresh hand is a deal, not a purchase.
        guard !fresh.isEmpty, fresh.count < state.players[humanSeat].hand.count else { return }
        var freedJokers: [Int] = []
        for card in fresh {
            guard let rank = card.rank, let suit = card.suit else { continue }
            for index in lockedMelds.indices {
                guard let entryIndex = lockedMelds[index].entries.firstIndex(where: {
                    $0.card.isJoker && $0.asRank == rank && $0.asSuit == suit
                }) else { continue }
                let joker = lockedMelds[index].entries[entryIndex].card
                lockedMelds[index].entries[entryIndex].card = card
                lockedSeries[index] = lockedMelds[index].displayEntries.map(\.card.id)
                freedJokers.append(joker.id)
                break
            }
        }
        guard !freedJokers.isEmpty else { return }
        Haptics.action()
        showNotice("The joker's seat is taken — it's free again")
        // The freed joker leads the free cards; locked groups keep the edge.
        handOrder.removeAll { freedJokers.contains($0) }
        let lockedIDs = lockedSeries.flatMap { $0 } + lockedPlaceables
        let insertAt = handOrder.firstIndex { !lockedIDs.contains($0) } ?? handOrder.count
        handOrder.insert(contentsOf: freedJokers, at: insertAt)
        rebuildHandOrder()
    }

    /// Drop any locked series whose cards left the hand (laid or thrown).
    private func pruneLocks() {
        let handIDs = Set(state.players[humanSeat].hand.map(\.id))
        for index in lockedSeries.indices.reversed()
        where !lockedSeries[index].allSatisfy({ handIDs.contains($0) }) {
            lockedSeries.remove(at: index)
            lockedMelds.remove(at: index)
        }
        lockedPlaceables = lockedPlaceables.filter { handIDs.contains($0) }
    }

    // MARK: Pending lay-down (confirmed only by the throw)

    var pendingLayDownValue: Int? { state.players[humanSeat].pendingLayDownValue }

    /// The hint shown between the chips row and the hand.
    var handHint: (text: String, warn: Bool)? {
        guard isHumanTurn else { return nil }
        let player = state.players[humanSeat]
        guard case .awaitingThrow(_, let pendingJoker) = humanStage else { return nil }
        if pendingJoker != nil {
            if player.hand.count == 1 {
                return ("Discard the joker to go out!", false)
            }
            return ("Place the freed joker on a meld to end your turn", false)
        }
        if let pending = player.pendingLayDownValue, !player.hasLaidDown {
            if player.hand.count == 1 {
                return ("Discard your last card to go out!", false)
            }
            if pending < state.requiredLayDown {
                return ("Laid \(pending) / \(state.requiredLayDown) — discarding now costs +100", true)
            }
            return ("Laid \(pending) — discard to confirm", false)
        }
        if mustLayDownNow {
            return ("You picked up the discard — lay down a meld first", true)
        }
        if !player.hasLaidDown, layDownUnlocked, lockedTotal >= state.requiredLayDown {
            return ("You can lay down — slide a locked meld up", false)
        }
        return nil
    }

    // MARK: Melds popup — pick one of your playable cards and place it

    /// Card picked inside the melds popup, waiting for a target meld.
    var popupPickedCardID: Int?

    /// Hand cards that can currently be placed somewhere on the table:
    /// they extend a meld, or they free a joker by taking its place.
    /// Outside the placement window they still SHOW — the moment somebody
    /// lays, the popup tells you what you hold for it (tap to reserve);
    /// only the placing itself waits for your throw step.
    var popupCandidates: [Card] {
        guard !state.tableMelds.isEmpty else { return [] }
        if canAppendToTable {
            return humanHand.filter {
                !chainFittingMelds(for: $0).isEmpty || !swapMelds(for: $0).isEmpty
            }
        }
        return humanHand.filter { isPlaceable($0) }
    }

    /// Joker swaps share the append window (your throw step) but pause while
    /// a freed joker is still waiting to be replayed.
    var swapAllowed: Bool {
        if case .awaitingThrow(_, pendingJoker: nil) = humanStage { return canAppendToTable }
        return false
    }

    /// Melds where a joker plays exactly as this card, so the card can take
    /// its place and free the joker. Only offered when the freed joker could
    /// be replayed by extending some meld — a swap must never strand a joker
    /// the turn can't end with.
    func swapMelds(for card: Card) -> [UUID] {
        guard swapAllowed, let rank = card.rank, let suit = card.suit else { return [] }
        return state.tableMelds.compactMap { tableMeld in
            guard let entryIndex = tableMeld.meld.entries.firstIndex(where: {
                $0.card.isJoker && $0.asRank == rank && $0.asSuit == suit
            }) else { return nil }
            let joker = tableMeld.meld.entries[entryIndex].card
            var swapped = tableMeld.meld
            swapped.entries[entryIndex].card = card
            let jokerReplayable = state.tableMelds.contains { other in
                let meld = other.id == tableMeld.id ? swapped : other.meld
                return meld.entries.count < Meld.maxRunSize
                    && meld.jokerEntryToExtend(joker: joker) != nil
            }
            return jokerReplayable ? tableMeld.id : nil
        }
    }

    /// Everywhere this card can go right now: appends (direct or chained
    /// behind its prerequisites) first, then swaps.
    func placementTargets(for card: Card) -> [UUID] {
        var targets = chainFittingMelds(for: card)
        for id in swapMelds(for: card) where !targets.contains(id) {
            targets.append(id)
        }
        return targets
    }

    /// Places a hand card onto a table meld: extend it when the card fits,
    /// otherwise take a joker's place (the joker comes back to the hand).
    func placeCard(_ card: Card, on meldID: UUID, keepPopup: Bool = false) {
        if fittingMelds(for: card).contains(meldID) {
            appendCard(card, to: meldID, keepPopup: keepPopup)
        } else if swapMelds(for: card).contains(meldID) {
            swapJoker(with: card, in: meldID, keepPopup: keepPopup)
        } else if let tableMeld = state.tableMelds.first(where: { $0.id == meldID }),
                  let chain = chainToFit(card, on: tableMeld), !chain.isEmpty {
            // The prerequisites go first, then the card itself: placing the
            // A♠ on Q♠-J♠-10♠ lays the bridging K♠ on its way.
            for step in chain {
                appendCard(step, to: meldID, keepPopup: true)
            }
            appendCard(card, to: meldID, keepPopup: keepPopup)
        } else {
            lastError = .cannotAppendHere
            Haptics.warning()
        }
    }

    /// The real card takes the joker's seat in the meld; the joker flies to
    /// the hand and must be replayed this turn.
    func swapJoker(with card: Card, in meldID: UUID, keepPopup: Bool = false) {
        Haptics.action()
        apply(.swapJoker(meldID: meldID, realCard: card), keepMeldPreview: keepPopup)
    }

    /// The melds this card could legally extend right now.
    func fittingMelds(for card: Card) -> [UUID] {
        state.tableMelds.compactMap { tableMeld in
            guard tableMeld.meld.entries.count < Meld.maxRunSize else { return nil }
            let entry: MeldEntry?
            if card.isJoker {
                entry = tableMeld.meld.jokerEntryToExtend(joker: card)
            } else if let rank = card.rank, let suit = card.suit {
                entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
            } else {
                entry = nil
            }
            guard let entry, tableMeld.meld.inserting(entry) != nil else { return nil }
            return tableMeld.id
        }
    }

    /// Tap one of your cards in the popup: places it straight away when only
    /// one meld takes it, otherwise waits for you to tap the target meld.
    func popupPick(_ card: Card) {
        Haptics.tap()
        // Before your throw step the tap reserves the card (placeable lock)
        // instead of placing — it is held ready for when the window opens.
        guard canAppendToTable else {
            if lockedPlaceables.contains(card.id) {
                lockedPlaceables.removeAll { $0 == card.id }
            } else if isPlaceable(card), !lockedCardIDs.contains(card.id) {
                lockedPlaceables.append(card.id)
            }
            rebuildHandOrder()
            applySortIfActive()
            return
        }
        if popupPickedCardID == card.id {
            popupPickedCardID = nil
            return
        }
        let targets = placementTargets(for: card)
        if targets.count == 1 {
            popupPickedCardID = nil
            placeCard(card, on: targets[0], keepPopup: true)
        } else {
            popupPickedCardID = card.id
        }
    }

    /// Tap a meld in the popup: places the picked card (or the single
    /// selected hand card) onto it — append or joker swap, whichever fits.
    func popupTapMeld(_ id: UUID) {
        guard canAppendToTable else { return }
        let picked = humanHand.first { $0.id == popupPickedCardID }
            ?? (selectedCardIDs.count == 1
                ? humanHand.first { selectedCardIDs.contains($0.id) } : nil)
        guard let card = picked else { return }
        popupPickedCardID = nil
        placeCard(card, on: id, keepPopup: true)
    }

    /// Appends a hand card to a table meld (popup, tap or hover-drop).
    func appendCard(_ card: Card, to meldID: UUID, keepPopup: Bool = false) {
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
        apply(.appendCard(entry, meldID: meldID), keepMeldPreview: keepPopup)
    }

    // MARK: Human actions

    /// The one card the player was already warned about throwing — a second
    /// throw of the same card is a confirmation and goes through.
    private var seriesThrowWarnedID: Int?

    /// The card sits inside an ORGANIZED series: three unlocked neighbors in
    /// the fan, exactly as arranged, that form a valid meld together. The
    /// arrangement is the player's own plan — a throw out of it is almost
    /// always a slip of the finger.
    private func isPartOfOrganizedSeries(_ card: Card) -> Bool {
        let excluded = lockedCardIDs.union(lockedPlaceables)
        guard !excluded.contains(card.id) else { return false }
        let fan = humanHand.filter { !excluded.contains($0.id) }
        guard let position = fan.firstIndex(where: { $0.id == card.id }) else { return false }
        for start in max(0, position - 2)...position where start + 3 <= fan.count {
            let window = Array(fan[start..<(start + 3)])
            if HandAnalysis.bestPartition(hand: window, maximizeCoverage: true)
                .coveredCount == 3 {
                return true
            }
        }
        return false
    }

    func apply(_ action: RummyAction, keepMeldPreview: Bool = false) {
        // A throw out of an organized series bounces once with a warning —
        // repeating the exact throw confirms it was no accident.
        if case .throwCard(let card) = action {
            if seriesThrowWarnedID != card.id, isPartOfOrganizedSeries(card) {
                seriesThrowWarnedID = card.id
                Haptics.warning()
                let name = card.rank.map { "\($0.label)\(card.suit?.symbol ?? "")" } ?? "that card"
                showNotice("Attention — \(name) is part of a series. Throw it again if you mean it.",
                           warn: true)
                return
            }
            seriesThrowWarnedID = nil
        }
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
            if !keepMeldPreview {
                meldPreviewShown = false
                popupPickedCardID = nil
            }
            syncHandOrder()
            pruneLocks()
            swapFreshIntoLockedJokers(addedSince: before)
            if activeSort != nil {
                applySortIfActive()  // fresh draws slot straight into the active sort
            } else {
                // A manual drag only switched the FULL sort off — purchases
                // keep slotting in beside their sorted neighbor.
                slotFreshCards(addedSince: before)
            }
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
        // Tapping a reserved placeable card releases the reservation.
        if lockedPlaceables.contains(card.id) {
            Haptics.tap()
            lockedPlaceables.removeAll { $0 == card.id }
            rebuildHandOrder()
            applySortIfActive()
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

    // MARK: Sorting — one sort at a time; activating one removes the other.

    enum SortMode: Equatable { case rank, suit, smart }
    /// The single active sort. It stays applied — fresh draws slot into
    /// place — until a manual drag clears it.
    private(set) var activeSort: SortMode?
    /// The rule fresh purchases keep following after a manual drag switched
    /// the full sort off. Only explicitly toggling the sort off clears it.
    private(set) var slotSort: SortMode?

    func toggleSort(_ mode: SortMode) {
        Haptics.tap()
        if activeSort == mode {
            activeSort = nil
            slotSort = nil
        } else {
            activeSort = mode
            slotSort = mode
        }
        applySortIfActive()
    }

    /// Places every card that just entered the hand beside its sorted
    /// neighbor — the position it would hold under `slotSort` — instead of
    /// leaving it appended at the end. The manual arrangement stays intact.
    private func slotFreshCards(addedSince before: RummyState) {
        guard let mode = slotSort else { return }
        let beforeIDs = Set(before.players[humanSeat].hand.map(\.id))
        let fresh = state.players[humanSeat].hand.filter { !beforeIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        // A whole fresh hand (a deal) has no manual arrangement to respect —
        // it lands fully sorted by the remembered rule.
        if fresh.count == state.players[humanSeat].hand.count {
            applySort(mode)
            return
        }
        let locked = Set(lockedSeries.flatMap { $0 }).union(lockedPlaceables)
        for card in fresh where !locked.contains(card.id) {
            let loose = state.players[humanSeat].hand.filter { !locked.contains($0.id) }
            let ordered: [Card]
            switch mode {
            case .rank: ordered = rankChainedOrder(loose)
            case .suit: ordered = suitGroupedOrder(loose)
            case .smart: ordered = smartOrder(loose)
            }
            guard let sortedIndex = ordered.firstIndex(where: { $0.id == card.id }) else { continue }
            handOrder.removeAll { $0 == card.id }
            let target: Int?
            if sortedIndex > 0, let anchor = handOrder.firstIndex(of: ordered[sortedIndex - 1].id) {
                target = anchor + 1
            } else if sortedIndex + 1 < ordered.count {
                target = handOrder.firstIndex(of: ordered[sortedIndex + 1].id)
            } else {
                target = nil
            }
            handOrder.insert(card.id, at: target ?? handOrder.count)
        }
    }

    private func applySortIfActive() {
        guard let mode = activeSort else { return }
        applySort(mode)
    }

    private func applySort(_ mode: SortMode) {
        let locked = lockedSeries.flatMap { $0 } + lockedPlaceables
        let rest = state.players[humanSeat].hand.filter { !locked.contains($0.id) }
        let ordered: [Card]
        switch mode {
        case .rank: ordered = rankChainedOrder(rest)
        case .suit: ordered = suitGroupedOrder(rest)
        case .smart: ordered = smartOrder(rest)
        }
        handOrder = locked + ordered.map(\.id)
    }

    /// Smart sort — the hand arranged by combo potential:
    /// 0. Complete sets first: three or more suits of one rank (rank ≥ 5)
    ///    claim their cards before any suit chain forms, duplicates riding
    ///    along — but a member refuses when its own suit runs LONGER
    ///    through it than the set is wide; a leftover card one below a set
    ///    that holds its suit lines up beneath it.
    /// 1. Same-suit near-runs (one missing card bridges — gap ≤ 2, never
    ///    more: a joker fills a single hole, so a two-card hole is no combo;
    ///    the ace sits beside its king when possible, else beside a 2 — only
    ///    a complete A-2-3 keeps it low; low fragments of 2–4 without an ace
    ///    dissolve unless three consecutive cards complete the run). A card
    ///    always prefers its own suit's near-run over attaching beside a
    ///    same-rank mate in another suit.
    /// 2. Loose cards that share a rank with a run card attach right beside
    ///    it, printed on the side that keeps the run line unbroken — but a
    ///    card keeping an immediate same-suit neighbor (3♦-2♦) stays with
    ///    that neighbor in the clusters instead.
    /// 3. Jokers always print at the far LEFT of the hand. A joker in hand
    ///    also promotes the best weak cards (rank ≥ 5) to a combo block: a
    ///    two-suit rank group always, a lone card only when it crowns the
    ///    leading block (exactly one rank above it).
    /// 4. Combos order by their top card; leftovers cluster by number with
    ///    isolated cards last; anything that fits a lay on the table goes to
    ///    the far right.
    ///
    /// Ground-truth examples live in docs/SMART_SORT_EXAMPLES.md — read it
    /// before changing this, and record every new example there.
    private func smartOrder(_ cards: [Card]) -> [Card] {
        let jokers = cards.filter(\.isJoker)
        let nonJokers = cards.filter { !$0.isJoker }

        struct ProtoRun {
            let suit: Suit
            var values: [Int]                     // display values, descending
            var members: [Int: Card] = [:]        // value → the run card
            var attachments: [Int: [Card]] = [:]  // value → same-rank mates
            var tailMates: [Card] = []            // a pair lining up below the run
        }
        var runs: [ProtoRun] = []

        // Complete sets claim their cards before any suit chain forms:
        // three or more suits of one rank are a meld as they stand, and a
        // run they break leaves at most an equal fragment behind — four
        // kings plus three queens beat K♠-Q♠-J♠ plus K♦-Q♦. Low ranks
        // (2–4) stay out: a low set is weak and lives in the clusters.
        // Sets print diamonds-to-spades so a tail-mate chains on its suit.
        var setBlocks: [(top: Int, cards: [Card])] = []
        var setClaimed = Set<Int>()
        for (value, group) in Dictionary(grouping: nonJokers, by: { sortRankKey($0) })
        where value >= 5 {
            let suits = Set(group.compactMap(\.suit))
            guard suits.count >= 3 else { continue }
            // A member whose own suit runs LONGER through it than the set
            // is wide refuses the claim — 7♥ inside 9-8-7-6 melds four
            // cards, the set of 7s only three. An equal-length run never
            // outbids the set (example 4's kings hold their claim).
            let keepers = group.filter { card in
                guard let suit = card.suit else { return false }
                let values = Set(nonJokers.filter { $0.suit == suit }
                    .compactMap { $0.rank.map { $0 == .ace ? 14 : $0.rawValue } })
                var length = 1
                var below = value - 1
                while values.contains(below) { length += 1; below -= 1 }
                var above = value + 1
                while values.contains(above) { length += 1; above += 1 }
                return length <= suits.count
            }
            guard Set(keepers.compactMap(\.suit)).count >= 3 else { continue }
            let ordered = keepers.sorted {
                suitIndex($0) != suitIndex($1)
                    ? suitIndex($0) > suitIndex($1)
                    : $0.id < $1.id
            }
            setBlocks.append((value, ordered))
            for card in ordered { setClaimed.insert(card.id) }
        }
        setBlocks.sort { $0.top > $1.top }
        let free = nonJokers.filter { !setClaimed.contains($0.id) }

        for suit in [Suit.spades, .hearts, .clubs, .diamonds] {
            let suited = free.filter { $0.suit == suit }
            guard !suited.isEmpty else { continue }
            var values = Set(suited.compactMap { $0.rank?.rawValue })
            let hasAce = values.contains(1)
            if hasAce { values.insert(14) }
            // A chain carries at most ONE hole: a joker (or draw) fills a
            // single missing card, so 6-4-2 is no combo — it splits.
            var chains: [[Int]] = []
            var current: [Int] = []
            var holes = 0
            for value in values.sorted() {
                if let last = current.last {
                    let gap = value - last
                    if gap > 2 || (gap == 2 && holes > 0) {
                        chains.append(current)
                        current = []
                        holes = 0
                    } else if gap == 2 {
                        holes += 1
                    }
                }
                current.append(value)
            }
            if !current.isEmpty { chains.append(current) }
            if hasAce {
                // Ace-king if possible, else 2-ace: the ace prefers its
                // high chain (an A-K line) over a low fragment — only a
                // complete low run (A-2-3) keeps it low. The phantom twin
                // value disappears.
                let lowCount = chains.first { $0.contains(1) }?.count ?? 0
                let highCount = chains.first { $0.contains(14) }?.count ?? 0
                let aceLow = lowCount >= 3 || (lowCount >= 2 && highCount < 2)
                chains = chains.compactMap { chain -> [Int]? in
                    var chain = chain
                    chain.removeAll { $0 == (aceLow ? 14 : 1) }
                    return chain.isEmpty ? nil : chain
                }
            }
            for chain in chains {
                // Low fragments (2–4, no ace) dissolve — but three consecutive
                // low cards are a COMPLETE run and always hold together.
                let lowOnly = chain.allSatisfy { $0 <= 4 } && !chain.contains(1) && chain.count < 3
                guard chain.count >= 2, !lowOnly else { continue }
                runs.append(ProtoRun(suit: suit, values: chain.sorted(by: >)))
            }
        }

        // One run card per value; every other card starts out pending.
        var pending: [Card] = []
        for card in free {
            guard let suit = card.suit, let raw = card.rank?.rawValue else { continue }
            let candidates = raw == 1 ? [1, 14] : [raw]
            var placed = false
            for index in runs.indices where runs[index].suit == suit && !placed {
                for value in candidates
                where runs[index].values.contains(value) && runs[index].members[value] == nil {
                    runs[index].members[value] = card
                    placed = true
                    break
                }
            }
            if !placed { pending.append(card) }
        }

        // Same-rank mates attach beside their run card — unless the card's
        // own suit holds its immediate neighbor among the leftovers (a
        // dissolved low fragment like 3♦-2♦): those stay together in the
        // number clusters instead of one being ripped away as a mate.
        func attachByRank(_ cards: [Card]) -> [Card] {
            var loose: [Card] = []
            for card in cards {
                guard let raw = card.rank?.rawValue else { continue }
                let keepsSuitNeighbor = cards.contains { other in
                    other.id != card.id && other.suit == card.suit
                        && other.rank.map { abs($0.rawValue - raw) == 1 } ?? false
                }
                if keepsSuitNeighbor {
                    loose.append(card)
                    continue
                }
                let candidates = raw == 1 ? [1, 14] : [raw]
                var placed = false
                // An END seat first: a mate beside a run's top or bottom
                // keeps the line readable (7♦ beside the 7♣-6♣ block, not
                // buried inside 9-8-7-6); mid-run anchors are the fallback.
                for edgesOnly in [true, false] where !placed {
                    for index in runs.indices where !placed {
                        for value in candidates
                        where runs[index].values.contains(value)
                            && (!edgesOnly || value == runs[index].values.first
                                || value == runs[index].values.last) {
                            runs[index].attachments[value, default: []].append(card)
                            placed = true
                            break
                        }
                    }
                }
                if !placed { loose.append(card) }
            }
            return loose
        }
        var loose = attachByRank(pending)

        // A two-gap at either end of a run chains (one missing card). Never
        // three: even a joker fills only one hole, and K over 10-9-7 would
        // need both the Q and the J.
        let maxEndGap = 2
        var still: [Card] = []
        for card in loose {
            guard let suit = card.suit, let raw = card.rank?.rawValue else {
                still.append(card)
                continue
            }
            let displays = raw == 1 ? [14, 1] : [raw]
            var placed = false
            for index in runs.indices where runs[index].suit == suit && !placed {
                for value in displays {
                    let top = runs[index].values.first!
                    let bottom = runs[index].values.last!
                    // The one-hole rule holds here too: a two-gap end
                    // extension is only open while the run has no hole yet.
                    let holes = (top - bottom + 1) - runs[index].values.count
                    let allowed = holes > 0 ? 1 : maxEndGap
                    if value > top, value - top <= allowed {
                        runs[index].values.insert(value, at: 0)
                    } else if value < bottom, bottom - value <= allowed {
                        runs[index].values.append(value)
                    } else {
                        continue
                    }
                    runs[index].members[value] = card
                    placed = true
                    break
                }
            }
            if !placed { still.append(card) }
        }
        loose = still

        // Leftover same-suit chains: gaps of two still read as run material —
        // K-J-9-7 of one suit stays a single block even without any
        // one-gaps. Weak all-low chains (2-4) don't count.
        var chainClaimed = Set<Int>()
        for suit in [Suit.spades, .hearts, .clubs, .diamonds] {
            let suited = loose.filter { $0.suit == suit }
            guard suited.count >= 2 else { continue }
            var values: [Int] = []
            var cardsByValue: [Int: [Card]] = [:]
            for card in suited {
                guard let raw = card.rank?.rawValue else { continue }
                let value = raw == 1 ? 14 : raw   // a loose ace reads high
                if !values.contains(value) { values.append(value) }
                cardsByValue[value, default: []].append(card)
            }
            values.sort(by: >)
            var chain: [Int] = []
            func flush() {
                defer { chain = [] }
                // Same exemption as above: {4,3,2} complete is a real run.
                guard chain.count >= 2,
                      !(chain.allSatisfy { $0 <= 4 } && chain.count < 3) else { return }
                var run = ProtoRun(suit: suit, values: chain)
                for value in chain {
                    let copies = cardsByValue[value] ?? []
                    run.members[value] = copies.first
                    if copies.count > 1 {
                        run.attachments[value, default: []]
                            .append(contentsOf: copies.dropFirst())
                    }
                    for copy in copies { chainClaimed.insert(copy.id) }
                }
                runs.append(run)
            }
            var holes = 0
            for value in values {
                if let last = chain.last {
                    let gap = last - value
                    if gap > maxEndGap || (gap == 2 && holes > 0) {
                        flush()
                        holes = 0
                    } else if gap == 2 {
                        holes += 1
                    }
                }
                chain.append(value)
            }
            flush()
        }
        loose.removeAll { chainClaimed.contains($0.id) }

        // Bridging and chaining may have added new run values — rank mates
        // get one more chance to attach beside them.
        loose = attachByRank(loose)

        // Rescue: a leftover pair whose member chains two below (same suit)
        // to a card parked as a rank-mate pulls it into a real chain —
        // 8♣ 8♦ 6♦ beats leaving the eights stranded behind the sixes.
        // Downward only: a low pair never steals support from above.
        do {
            var byRank: [Int: [Card]] = [:]
            for card in loose { byRank[sortRankKey(card), default: []].append(card) }
            for (value, group) in byRank where group.count >= 2 {
                var rescued = false
                for member in group where !rescued {
                    guard let suit = member.suit else { continue }
                    for runIndex in runs.indices where !rescued {
                        for (attachValue, mates) in runs[runIndex].attachments {
                            guard attachValue < value, value - attachValue <= 2,
                                  let mateIndex = mates.firstIndex(where: { $0.suit == suit })
                            else { continue }
                            let mate = mates[mateIndex]
                            runs[runIndex].attachments[attachValue]?.remove(at: mateIndex)
                            var chain = ProtoRun(suit: suit, values: [value, attachValue])
                            chain.members[value] = member
                            chain.members[attachValue] = mate
                            let others = group.filter { $0.id != member.id }
                            if !others.isEmpty { chain.attachments[value] = others }
                            runs.append(chain)
                            loose.removeAll { card in group.contains { $0.id == card.id } }
                            rescued = true
                            break
                        }
                    }
                }
            }
        }

        // A leftover REAL pair (distinct suits) sitting right under a run's
        // bottom lines up beneath it: K-K-Q-J-10 followed by the two nines.
        // A duplicate pair (two copies of one card) is dead and stays weak.
        do {
            var byRank: [Int: [Card]] = [:]
            for card in loose { byRank[sortRankKey(card), default: []].append(card) }
            for (value, group) in byRank where group.count >= 2 {
                let distinctSuits = Set(group.compactMap(\.suit))
                guard distinctSuits.count >= 2,
                      let runIndex = runs.indices.first(where: {
                          runs[$0].values.last == value + 1
                      })
                else { continue }
                runs[runIndex].tailMates.append(contentsOf: group.sorted {
                    (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
                })
                loose.removeAll { card in group.contains { $0.id == card.id } }
            }
        }

        // With two jokers in hand, a leftover pair is a ready set (the pair
        // plus joker twins) — it becomes a combo block placed by its rank.
        if jokers.count >= 2 {
            var byRank: [Int: [Card]] = [:]
            for card in loose {
                byRank[sortRankKey(card), default: []].append(card)
            }
            var promoted = Set<Int>()
            for (value, group) in byRank where group.count >= 2 && value >= 5 {
                guard Set(group.compactMap(\.suit)).count >= 2 else { continue }
                let ordered = group.sorted {
                    (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
                }
                var run = ProtoRun(suit: ordered[0].suit ?? .spades, values: [value])
                run.members[value] = ordered[0]
                run.attachments[value] = Array(ordered.dropFirst())
                runs.append(run)
                for card in ordered { promoted.insert(card.id) }
            }
            loose.removeAll { promoted.contains($0.id) }
        }

        // A leftover card one below a set that holds its suit lines up
        // beneath it — J♠ under Q♦-Q♣-Q♠ keeps reading as a line.
        for index in setBlocks.indices {
            let below = setBlocks[index].top - 1
            let suits = Set(setBlocks[index].cards.compactMap(\.suit))
            let tails = loose.filter {
                sortRankKey($0) == below && ($0.suit.map(suits.contains) ?? false)
            }
            guard !tails.isEmpty else { continue }
            let ordered = tails.sorted {
                (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
            }
            // The set exits on the first tail's suit so the line connects:
            // 10♣ 10♠ 10♥ · 9♥ 9♣, never 10♥ buried mid-set.
            if let lead = ordered.first?.suit,
               let exit = setBlocks[index].cards.firstIndex(where: { $0.suit == lead }) {
                let card = setBlocks[index].cards.remove(at: exit)
                setBlocks[index].cards.append(card)
            }
            setBlocks[index].cards.append(contentsOf: ordered)
            loose.removeAll { card in tails.contains { $0.id == card.id } }
        }

        // Strong section: combos flatten into blocks placed by their top
        // card, descending inside; a mate prints before its anchor when the
        // run continues below it, after when the anchor closes the run.
        var blocks: [(top: Int, cards: [Card])] = setBlocks + runs.map { run in
            var flat: [Card] = []
            for (index, value) in run.values.enumerated() {
                let mates = (run.attachments[value] ?? []).sorted {
                    (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
                }
                let isBottom = index == run.values.count - 1
                if isBottom {
                    if let member = run.members[value] { flat.append(member) }
                    flat.append(contentsOf: mates)
                } else {
                    flat.append(contentsOf: mates)
                    if let member = run.members[value] { flat.append(member) }
                }
            }
            flat.append(contentsOf: run.tailMates)
            return (run.values.first!, flat)
        }

        // Loose cards that fit somebody's lays go to the far right, with
        // their own sort: grouped by the meld they extend (in table order),
        // smallest first within a group — the order you would append them.
        let appendable = loose.filter {
            RummyEngine.throwPenalized($0, tableMelds: state.tableMelds)
        }
        var weak = loose.filter { card in !appendable.contains { $0.id == card.id } }

        // A joker-backed hand promotes its best weak cards to a combo block
        // (rank ≥ 5 — low cards stay in the clusters): a rank group of two
        // or more suits is set material and always earns a block; a lone
        // card only when it CROWNS the leading block, sitting exactly one
        // rank above it — a K over a Q-10 block. A lone A over a 9-block
        // or a J parked mid-hand stays in the clusters.
        if !jokers.isEmpty,
           let top = weak.map({ sortRankKey($0) }).filter({ $0 >= 5 }).max() {
            var group = weak.filter { sortRankKey($0) == top }.sorted {
                (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
            }
            if Set(group.compactMap(\.suit)).count < 2 { group = [group[0]] }
            let crowns = blocks.map(\.top).max().map { top == $0 + 1 } ?? true
            if group.count >= 2 || crowns {
                blocks.append((top, group))
                weak.removeAll { card in group.contains { $0.id == card.id } }
            }
        }

        // Blocks print by top card; ties keep their build order, a promoted
        // weak card after an equal-topped run.
        let strong = blocks.enumerated()
            .sorted { ($0.element.top, -$0.offset) > ($1.element.top, -$1.offset) }
            .flatMap(\.element.cards)
        func targetMeldIndex(_ card: Card) -> Int {
            fittingMelds(for: card).first
                .flatMap { id in state.tableMelds.firstIndex { $0.id == id } }
                ?? Int.max
        }
        let appendableOrdered = appendable.sorted { a, b in
            let meldA = targetMeldIndex(a)
            let meldB = targetMeldIndex(b)
            if meldA != meldB { return meldA < meldB }
            return (sortRankKey(a), suitIndex(a), a.id) < (sortRankKey(b), suitIndex(b), b.id)
        }
        return jokers + strong
            + numberClusters(weak, leadingSuit: strong.last?.suit,
                             support: nonJokers, endGap: maxEndGap)
            + appendableOrdered
    }

    /// The number side of the smart sort: same-and-adjacent ranks cluster
    /// together (4-4-3-2-2). Clusters with more paired cards come first (set
    /// potential), ties by higher rank — so 7-7 precedes a loose 4-3-3, and
    /// lone singles land at the far right. Suits chain across the boundaries
    /// (…9♣ | 7♣ 7♠…) so same-suit near-runs stay adjacent.
    private func numberClusters(
        _ cards: [Card], leadingSuit: Suit? = nil,
        support: [Card] = [], endGap: Int = 2
    ) -> [Card] {
        let groups = Dictionary(grouping: cards) { sortRankKey($0) }
        let keys = groups.keys.sorted(by: >)
        var clusters: [[Int]] = []
        var current: [Int] = []
        for (index, key) in keys.enumerated() {
            if let last = current.last, last - key == 1 {
                current.append(key)  // chains grow downward through anything
                continue
            }
            if !current.isEmpty { clusters.append(current) }
            current = []
            // A lone single may only HEAD a chain when it links to the group
            // below by suit — a stray K never rides along with foreign queens.
            let group = groups[key] ?? []
            if group.count == 1, index + 1 < keys.count, keys[index + 1] == key - 1 {
                let suits = Set(group.compactMap(\.suit))
                let linksBelow = (groups[keys[index + 1]] ?? []).contains {
                    $0.suit.map(suits.contains) ?? false
                }
                if !linksBelow {
                    clusters.append([key])
                    continue
                }
            }
            current = [key]
        }
        if !current.isEmpty { clusters.append(current) }
        func pairedCards(_ cluster: [Int]) -> Int {
            cluster.reduce(0) { total, key in
                let count = groups[key]?.count ?? 0
                return total + (count >= 2 ? count : 0)
            }
        }
        // A cluster is real combo material when it spans ranks, or when a
        // same-rank pair has same-suit support nearby in the hand. Unsupported
        // pairs (like two foreign queens) drift right, before the singles.
        func isCombo(_ cluster: [Int]) -> Bool {
            if cluster.count > 1 { return true }
            let group = groups[cluster[0]] ?? []
            guard group.count >= 2 else { return false }
            let suits = Set(group.compactMap(\.suit))
            return support.contains { card in
                guard let suit = card.suit else { return false }
                let key = sortRankKey(card)
                return suits.contains(suit) && key != cluster[0]
                    && abs(key - cluster[0]) <= endGap
            }
        }
        let ordered = clusters.sorted { a, b in
            let pairsA = pairedCards(a)
            let pairsB = pairedCards(b)
            if pairsA != pairsB { return pairsA > pairsB }
            let comboA = isCombo(a)
            let comboB = isCombo(b)
            if comboA != comboB { return comboA }
            return a.first! > b.first!
        }
        // Flatten with suit chaining: each rank group enters on the suit the
        // previous card handed over and exits on a suit the next group holds.
        let flatKeys = ordered.flatMap { $0 }
        var result: [Card] = []
        var lead = leadingSuit
        for (index, key) in flatKeys.enumerated() {
            var group = (groups[key] ?? []).sorted {
                (suitIndex($0), $0.id) < (suitIndex($1), $1.id)
            }
            if let lead, let entry = group.firstIndex(where: { $0.suit == lead }) {
                group.insert(group.remove(at: entry), at: 0)
            }
            let nextSuits: Set<Suit> = index + 1 < flatKeys.count
                ? Set((groups[flatKeys[index + 1]] ?? []).compactMap(\.suit))
                : []
            let exits = group.indices.filter {
                group[$0].suit.map(nextSuits.contains) ?? false
            }
            if group.count > 1, let pick = exits.last(where: { $0 != 0 }) {
                group.append(group.remove(at: pick))
            }
            lead = group.last?.suit
            result.append(contentsOf: group)
        }
        return result
    }

    /// Type-first sort: jokers leftmost, suits in fixed order, ranks
    /// descending with the ace as the biggest card on the left of its suit —
    /// EXCEPT when that suit holds no K/Q/J but does hold a 2, 3 or 4: then
    /// the ace slides to the right end of the suit, next to its low run.
    private func suitGroupedOrder(_ cards: [Card]) -> [Card] {
        let jokers = cards.filter(\.isJoker)
        let bySuit = Dictionary(grouping: cards.filter { !$0.isJoker }) { $0.suit! }
        var result = jokers
        for suit in [Suit.spades, .hearts, .clubs, .diamonds] {
            guard var group = bySuit[suit] else { continue }
            group.sort {
                (sortRankKey($1), $0.id) < (sortRankKey($0), $1.id)
            }
            let hasHonor = group.contains {
                $0.rank == .king || $0.rank == .queen || $0.rank == .jack
            }
            let hasLowRun = group.contains {
                ($0.rank?.rawValue).map { (2...4).contains($0) } ?? false
            }
            if !hasHonor, hasLowRun {
                let aces = group.filter { $0.rank == .ace }
                group.removeAll { $0.rank == .ace }
                group.append(contentsOf: aces)
            }
            result.append(contentsOf: group)
        }
        return result
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

    /// Manual reordering takes over: it clears the active sort.
    func reorderHand(_ order: [Int]) {
        noteSortCleared()
        handOrder = order
    }

    /// Only a drag that ENDS as a deliberate reorder turns the sort off —
    /// a slide that ends as a discard or lay never touches it.
    func commitManualReorder() {
        noteSortCleared()
    }

    /// Never silent: dropping out of the full sort is announced, and the
    /// slotting rule stays so purchases keep landing beside their neighbors.
    private func noteSortCleared() {
        guard activeSort != nil else { return }
        activeSort = nil
        showNotice("Sort off — new cards still slot into place")
    }

    func moveHandCard(fromOffsets: IndexSet, toOffset: Int) {
        var order = humanHand.map(\.id)
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        reorderHand(order)
    }

    /// The reset button clears the selection AND every lock — series and
    /// reserved placeables alike.
    func cancelSelection() {
        guard !selectedCardIDs.isEmpty || !lockedSeries.isEmpty
                || !lockedPlaceables.isEmpty else { return }
        Haptics.tap()
        selectedCardIDs = []
        lockedSeries = []
        lockedMelds = []
        lockedPlaceables = []
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

    func showBanner(_ text: String, style: BannerStyle = .note,
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
                    (TableBanner(text: "\(name): let's play", style: .note, icon: "play.fill"), 1.0),
                    (TableBanner(text: L10n.playVerdict, style: .verdict, icon: "play.fill"), 1.8),
                ])
            case .declareIntent(true):
                showBanners([
                    (TableBanner(text: "\(name) wants to play", style: .note, icon: "play.fill"), 1.2),
                    (TableBanner(text: L10n.playVerdict, style: .verdict, icon: "play.fill"), 1.8),
                ])
            case .declareIntent(false) where seat == proposer:
                showBanner("\(name) proposes a redeal", style: .note, icon: "hand.raised.fill", duration: 3.0)
            case .declareIntent(false) where resolvedToPass:
                showBanners([
                    (TableBanner(text: "\(name) agrees to redeal", style: .note, icon: "hand.raised.fill"), 1.0),
                    (TableBanner(text: L10n.passVerdict, style: .verdict, icon: "hand.raised.fill"), 1.8),
                ])
            case .declareIntent(false):
                showBanner("\(name) agrees to redeal", style: .note, icon: "hand.raised.fill", duration: 3.0)
            case .forcePass:
                showBanners([
                    (TableBanner(text: "\(name) forced a redeal — doubles", style: .note, icon: "hand.raised.fill"), 1.4),
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
                    showBanner("\(name) picked up the discard", icon: "hand.point.down.fill", duration: 1.8)
                }
            case .swapJoker:
                showBanner("\(name) swapped a joker", icon: "star.circle.fill", duration: 1.8)
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
            // Closing goes straight to the score sheet. A missed count is
            // announced first so the +100 is unmistakable, then the sheet;
            // the match end also gets its beat.
            var announcement: (text: String, hold: Double)?
            switch state.phase {
            case .roundEnded(let result):
                if result.closerSeat == nil, let failed = result.deltas.firstIndex(of: 100) {
                    announcement = ("\(displayName(failed)) missed the count — +100", 2.6)
                }
            case .matchEnded:
                announcement = (L10n.gameOver, 1.9)
            default:
                break
            }
            if let announcement {
                roundEndCurtain = true
                showBanner(announcement.text, style: .verdict, duration: announcement.hold + 0.1)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(announcement.hold))
                    self?.roundEndCurtain = false
                }
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
                        ? "Your turn — purchase or pick up the discard"
                        : "Your turn — purchase a card"
                default:
                    "Discard a card"
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
                // Decide first, then "think" for a duration matching the
                // decision's weight — a snap throw is instant, a big lay-down
                // gets a beat.
                let snapshot = self.state
                let view = PublicGameView(state: snapshot, seat: seat)
                var rng = SystemRandomNumberGenerator()
                let action = bot.decide(view, rng: &rng)
                let pause = self.pauseForNextBotAction(action: action, mind: view.mind)
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled else { return }
                // If anything moved the state during the pause, the decision
                // is stale — re-decide instead of applying it blindly.
                guard self.state == snapshot else { continue }
                #if DEBUG
                print("RUMMY bot \(seat) apply: \(action)")
                #endif
                do {
                    let before = self.state
                    self.state = try RummyEngine.apply(action, by: seat, to: self.state, rng: &rng)
                    // A bot throw that bounced (+10 wasted-throw penalty, card
                    // still in hand) must not spin: a legal alternative exists
                    // whenever the engine bounces, so play it directly.
                    if case .throwCard = action,
                       self.state.players[seat].hand.count == before.players[seat].hand.count,
                       let legal = self.state.players[seat].hand.first(where: {
                           !RummyEngine.throwPenalized($0, tableMelds: self.state.tableMelds)
                       }) {
                        self.state = try RummyEngine.apply(.throwCard(legal), by: seat, to: self.state, rng: &rng)
                    }
                    if case .deal = action {
                        self.startDealHold()
                        // The fresh hand honors the sort right away — the
                        // cards land already ordered, no re-click needed.
                        self.syncHandOrder()
                        self.applySortIfActive()
                        if self.activeSort == nil { self.slotFreshCards(addedSince: before) }
                    }
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

    /// Natural pacing: obvious moves come fast, big commitments get a beat,
    /// and a tilted bot snaps its cards down noticeably quicker.
    private func pauseForNextBotAction(action: RummyAction, mind: BotMind) -> Double {
        switch state.phase {
        case .dealing: return 0.7  // let each shuffle animation read
        case .vote: return 1.1     // opinions land one by one in the center
        case .roundEnded, .matchEnded: return 0.4
        case .turn: break
        }
        let base: Double
        switch action {
        case .layDown(let melds):
            // The full-hand slam deserves its dramatic pause.
            base = melds.reduce(0) { $0 + $1.entries.count } >= 10
                ? 2.0
                : Double.random(in: 1.2...1.8, using: &rng)
        case .takeThrow, .takeThrowAndLayDown:
            base = Double.random(in: 1.0...1.7, using: &rng)
        case .appendCard, .swapJoker:
            base = Double.random(in: 0.75...1.2, using: &rng)
        case .throwCard:
            base = Double.random(in: 0.5...0.95, using: &rng)
        default:
            base = 0.4
        }
        return min(2.0, base * (1 - 0.35 * mind.frustration))
    }

    /// Mood cue for a bot seat (nil for the human, the eliminated, or old
    /// saves without minds).
    func botMood(seat: Int) -> BotMood? {
        guard !state.players[seat].isHuman, !state.players[seat].isEliminated,
              let minds = state.botMinds, minds.indices.contains(seat) else { return nil }
        return minds[seat].mood
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
