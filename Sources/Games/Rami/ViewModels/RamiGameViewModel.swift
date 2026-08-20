import Foundation
import Observation

/// Owns the game state, applies human actions, runs bot turns with natural
/// pauses, and autosaves after every action. Killing the app mid-turn and
/// reopening restores exactly this state.
@MainActor
@Observable
final class RamiGameViewModel {
    private(set) var state: RamiState
    let store: GameStore
    private var rng = SystemRandomNumberGenerator()
    private var botTask: Task<Void, Never>?

    /// Card ids the human selected in their hand (and possibly the takeable throw).
    var selectedCardIDs: Set<Int> = []
    /// Manual hand order (card ids); updated by sorting or dragging.
    var handOrder: [Int] = []
    var lastError: RamiError?
    /// Seat whose bot action just happened, for UI callouts.
    var lastBotNote: String?
    var matchFinished = false

    var humanSeat: Int { state.players.firstIndex(where: \.isHuman) ?? 0 }

    init(state: RamiState, store: GameStore) {
        self.state = state
        self.store = store
        syncHandOrder()
        resumeBotsIfNeeded()
    }

    static func newGame(settings: SettingsStore, botLevel: BotLevel, store: GameStore) -> RamiGameViewModel {
        var rng = SystemRandomNumberGenerator()
        let state = RamiEngine.newGame(
            config: settings.config(botLevel: botLevel),
            names: [L10n.you, "Salah", "Moufida", "Hamadi"],
            dealerSeat: Int.random(in: 0..<4, using: &rng),
            rng: &rng)
        return RamiGameViewModel(state: state, store: store)
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

    /// Interpretation of the current selection as melds (nil when invalid).
    /// Cards may include the takeable throw during a take-and-lay-down.
    var selectedMelds: (melds: [Meld], total: Int)? {
        var pool = state.players[humanSeat].hand.filter { selectedCardIDs.contains($0.id) }
        if let takeable = takeableThrow, selectedCardIDs.contains(takeable.id) {
            pool.append(takeable)
        }
        guard pool.count >= Meld.minSize else { return nil }
        let partition = HandAnalysis.bestPartition(hand: pool, maximizeCoverage: true)
        guard partition.coveredCount == pool.count else { return nil }
        return (partition.melds, partition.value)
    }

    var selectionIncludesTakeable: Bool {
        takeableThrow.map { selectedCardIDs.contains($0.id) } ?? false
    }

    // MARK: Human actions

    func apply(_ action: RamiAction) {
        #if DEBUG
        print("RAMI human apply: \(action)")
        #endif
        do {
            state = try RamiEngine.apply(action, by: humanSeat, to: state, rng: &rng)
            lastError = nil
            selectedCardIDs = []
            syncHandOrder()
            autosave()
            resumeBotsIfNeeded()
        } catch let error as RamiError {
            lastError = error
            Haptics.warning()
        } catch {
            assertionFailure("unexpected error \(error)")
        }
    }

    func toggleSelection(_ card: Card) {
        Haptics.tap()
        if selectedCardIDs.contains(card.id) {
            selectedCardIDs.remove(card.id)
        } else {
            selectedCardIDs.insert(card.id)
        }
    }

    func sortHandByRank() {
        handOrder = state.players[humanSeat].hand
            .sorted {
                ($0.rank?.rawValue ?? 14, $0.suit?.rawValue ?? "z", $0.id)
                    < ($1.rank?.rawValue ?? 14, $1.suit?.rawValue ?? "z", $1.id)
            }
            .map(\.id)
    }

    func sortHandBySuit() {
        handOrder = state.players[humanSeat].hand
            .sorted {
                ($0.suit?.rawValue ?? "z", $0.rank?.rawValue ?? 14, $0.id)
                    < ($1.suit?.rawValue ?? "z", $1.rank?.rawValue ?? 14, $1.id)
            }
            .map(\.id)
    }

    func moveHandCard(fromOffsets: IndexSet, toOffset: Int) {
        var order = humanHand.map(\.id)
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        handOrder = order
    }

    func abandonMatch() {
        botTask?.cancel()
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
        let bot = RamiBot(level: state.config.botLevel)
        botTask = Task { [weak self] in
            defer { self?.botTask = nil }
            while let self, !Task.isCancelled, let seat = self.actingSeat,
                  !self.state.players[seat].isHuman {
                let pause = self.pauseForNextBotAction()
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled else { return }
                let view = PublicGameView(state: self.state, seat: seat)
                var rng = SystemRandomNumberGenerator()
                let action = bot.decide(view, rng: &rng)
                #if DEBUG
                print("RAMI bot \(seat) apply: \(action)")
                #endif
                do {
                    self.state = try RamiEngine.apply(action, by: seat, to: self.state, rng: &rng)
                    self.noteBotAction(action, seat: seat)
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
        case .dealing: 0.25
        case .vote: 0.8
        case .turn: Double.random(in: 0.55...1.15, using: &rng)
        default: 0.4
        }
    }

    private func noteBotAction(_ action: RamiAction, seat: Int) {
        let name = state.players[seat].name
        switch action {
        case .takeThrow, .takeThrowAndLayDown:
            lastBotNote = "\(name) took the throw"
        case .layDown(let melds):
            lastBotNote = "\(name) laid down \(melds.count) meld\(melds.count > 1 ? "s" : "")"
        case .swapJoker:
            lastBotNote = "\(name) swapped a joker"
        default:
            return
        }
        let note = lastBotNote
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if self?.lastBotNote == note { self?.lastBotNote = nil }
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
