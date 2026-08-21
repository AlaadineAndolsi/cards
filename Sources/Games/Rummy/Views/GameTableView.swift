import SwiftUI

/// The table. Bots sit left / top / right with their melds laid along their
/// own side; before each deal the full double deck sits center-table and
/// shuffles visibly; the human hand fans in an arc along the bottom. Pile
/// under the left player, sort actions under the right player, stats top-right.
struct GameTableView: View {
    @State var viewModel: RummyGameViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAbandonConfirm = false
    @State private var showStats = false
    @State private var shufflePulse = 0
    @State private var showLastThrows = false
    /// Melds already seen, to detect fresh lay-downs for the big reveal.
    @State private var knownMeldIDs: Set<UUID> = []
    @State private var layReveal: LayReveal?
    @Namespace private var cardSpace

    private var state: RummyState { viewModel.state }

    struct LayReveal: Identifiable, Equatable {
        let id: UUID
        let melds: [Meld]
        let ownerOffset: Int
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.felt
                tableLayer(in: geometry.size)
                VStack(spacing: 0) {
                    header
                    Spacer()
                    bottomArea
                }
                if let reveal = layReveal {
                    LayDownRevealView(
                        reveal: reveal,
                        center: CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.42),
                        destination: revealDestination(reveal.ownerOffset, in: geometry.size),
                        reduceMotion: reduceMotion) {
                            if layReveal == reveal { layReveal = nil }
                        }
                }
                if viewModel.meldPreviewShown {
                    // Tap anywhere outside the popup to close it.
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.cardSpring) { viewModel.meldPreviewShown = false }
                        }
                    MeldPreviewOverlay(viewModel: viewModel)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .zIndex(40)
                }
                if let banner = viewModel.banner {
                    CenterBannerView(banner: banner)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.40)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(50)
                }
                overlays
            }
            .animation(.cardSpring, value: viewModel.banner)
            .animation(.cardSpring, value: viewModel.meldPreviewShown)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showStats) { ScoreSheetView(state: state) }
        .confirmationDialog(L10n.abandonTitle, isPresented: $showAbandonConfirm, titleVisibility: .visible) {
            Button(L10n.abandon, role: .destructive) {
                viewModel.abandonMatch()
                dismiss()
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.abandonMessage)
        }
        .onAppear {
            knownMeldIDs = Set(state.tableMelds.map(\.id))
            viewModel.runBots()
        }
        .tint(Theme.accent)
    }

    // MARK: Header

    private var turnLine: String? {
        guard let name = viewModel.activeSeatName else { return nil }
        let you = name == L10n.you
        if case .dealing = state.phase { return you ? "You deal" : "\(name) deals" }
        if case .vote = state.phase { return you ? "You decide" : "\(name) decides" }
        return you ? "Your turn" : "\(name)'s turn"
    }

    private var header: some View {
        HStack {
            Button {
                showAbandonConfirm = true
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            VStack(spacing: 1) {
                if let turnLine {
                    Text(turnLine)
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(turnLine.hasPrefix("You") ? Theme.accent : .primary)
                        .contentTransition(.opacity)
                }
                Text("\(L10n.round) \(state.roundNumber)  ·  \(L10n.required): \(state.requiredLayDown)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .animation(.cardSpring, value: turnLine)
            Spacer()
            Button {
                showStats = true
            } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .foregroundStyle(.primary)
    }

    // MARK: Geometry

    /// Display offsets: 0 = human (bottom), 1 = right, 2 = top, 3 = left —
    /// counter-clockwise turn order around the table.
    private func seat(forOffset offset: Int) -> Int {
        (viewModel.humanSeat + offset) % state.players.count
    }

    private func avatarAnchor(_ offset: Int, in size: CGSize) -> CGPoint {
        switch offset {
        case 1: CGPoint(x: size.width - 36, y: size.height * 0.29)
        case 2: CGPoint(x: size.width / 2, y: 128)
        case 3: CGPoint(x: 36, y: size.height * 0.29)
        default: CGPoint(x: size.width / 2, y: size.height * 0.55)
        }
    }

    /// Lays sit directly under their owner's avatar.
    private func meldsAnchor(_ offset: Int, in size: CGSize) -> CGPoint {
        switch offset {
        case 1: CGPoint(x: size.width - 44, y: size.height * 0.29 + 82)
        case 2: CGPoint(x: size.width / 2, y: 184)
        default: CGPoint(x: 44, y: size.height * 0.29 + 82)
        }
    }

    private func revealDestination(_ offset: Int, in size: CGSize) -> CGPoint {
        offset == 0
            ? CGPoint(x: size.width / 2, y: size.height * 0.57)
            : meldsAnchor(offset, in: size)
    }

    private func pileAnchor(in size: CGSize) -> CGPoint {
        CGPoint(x: 46, y: size.height * 0.57)
    }

    /// The exact center of the circle of all four players.
    private func throwCenter(in size: CGSize) -> CGPoint {
        let anchors = [0, 1, 2, 3].map { avatarAnchor($0, in: size) }
        return CGPoint(
            x: anchors.map(\.x).reduce(0, +) / 4,
            y: anchors.map(\.y).reduce(0, +) / 4 + 34)
    }

    private var activeSeat: Int? {
        switch state.phase {
        case .dealing: state.dealerSeat
        case .vote(_, let current): current
        case .turn(let seat, _): seat
        default: nil
        }
    }

    private var isDealingPhase: Bool {
        if case .dealing = state.phase { return true }
        return false
    }

    /// While shuffling and dealing, the whole deck lives center-table.
    private var deckIsCenterStage: Bool {
        isDealingPhase || viewModel.isDealAnimating
    }

    // MARK: Table layer

    private func tableLayer(in size: CGSize) -> some View {
        ZStack {
            ForEach(1..<4) { offset in
                let seatIndex = seat(forOffset: offset)
                Group {
                    if state.players[seatIndex].isEliminated {
                        EliminatedSeatView(name: state.players[seatIndex].name)
                    } else {
                        SeatView(
                            player: state.players[seatIndex],
                            handCount: viewModel.dealtCounts?[offset]
                                ?? state.players[seatIndex].hand.count,
                            isDealer: state.dealerSeat == seatIndex,
                            isActive: activeSeat == seatIndex)
                    }
                }
                .position(avatarAnchor(offset, in: size))
                // Melds along that player's own side.
                SideMeldsView(
                    melds: state.tableMelds.filter { $0.ownerSeat == seatIndex },
                    horizontal: offset == 2,
                    onTap: { id in
                        if let tableMeld = state.tableMelds.first(where: { $0.id == id }) {
                            handleMeldTap(tableMeld)
                        }
                    })
                .position(meldsAnchor(offset, in: size))
            }
            centerStage(in: size)
            // Draw pile under the left player; tap to purchase.
            if !deckIsCenterStage {
                PileView(count: state.drawPile.count, enabled: canPurchase) {
                    guard canPurchase else { return }
                    Haptics.action()
                    withAnimation(reduceMotion ? .default : .cardSpring) {
                        viewModel.apply(.drawFromPile)
                    }
                }
                .position(pileAnchor(in: size))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            // Sort / cancel actions under the right player.
            handActions
                .position(x: size.width - 46, y: size.height * 0.57)
            // Your lays, one serie per line. Table touch rule: laid series
            // never come back; unconfirmed ones just show the dashed border.
            SideMeldsView(
                melds: state.tableMelds.filter { $0.ownerSeat == viewModel.humanSeat },
                horizontal: false,
                pendingHighlight: viewModel.pendingLayDownValue != nil,
                onTap: { id in
                    if let tableMeld = state.tableMelds.first(where: { $0.id == id }) {
                        handleMeldTap(tableMeld)
                    }
                })
            .position(x: size.width / 2, y: size.height * 0.57)
            if !reduceMotion {
                ForEach(viewModel.dealFlights) { flight in
                    DealFlightCard(
                        delay: flight.delay,
                        from: throwCenter(in: size),
                        to: flight.seatOffset == 0
                            ? CGPoint(x: size.width / 2, y: size.height - 110)
                            : avatarAnchor(flight.seatOffset, in: size))
                }
            }
            if let flight = viewModel.throwFlight {
                ThrowFlightCard(
                    card: flight.card,
                    from: avatarAnchor(flight.seatOffset, in: size),
                    to: throwCenter(in: size),
                    reduceMotion: reduceMotion)
                .id(flight.id)
            }
            if let drawn = viewModel.revealedDraw {
                DrawRevealView(card: drawn)
                    .position(x: size.width / 2, y: size.height * 0.42)
            }
        }
        .animation(reduceMotion ? .default : .cardSpring, value: state)
        .onChange(of: state.tableMelds) { old, new in
            detectLayDown(old: old, new: new)
        }
    }

    /// The center of the table: the full deck while shuffling/dealing,
    /// otherwise the single most recent throw.
    @ViewBuilder
    private func centerStage(in size: CGSize) -> some View {
        if deckIsCenterStage {
            DeckCenterView(
                count: viewModel.animatedPileCount ?? state.drawPile.count,
                shuffles: dealingShuffleCount,
                showShuffles: isDealingPhase,
                reduceMotion: reduceMotion)
            .position(throwCenter(in: size))
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        } else {
            // One central throw pile showing only the most recent throw.
            if !showLastThrows {
                ThrowSpotView(
                    card: flightMasked(lastThrow),
                    highlighted: takeableHighlighted,
                    namespace: cardSpace,
                    onTap: {
                        if lastThrow != nil {
                            withAnimation(.cardSpring) { showLastThrows = true }
                        }
                    },
                    onTake: {
                        if takeableHighlighted {
                            withAnimation(reduceMotion ? .default : .cardSpring) {
                                viewModel.tapTakeableThrow()
                            }
                        }
                    })
                .position(throwCenter(in: size))
            }
            if showLastThrows {
                // Tap anywhere outside the popup to close it.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.cardSpring) { showLastThrows = false } }
                LastThrowsView(
                    players: (0..<4).map { offset in
                        let seatIndex = seat(forOffset: offset)
                        return (state.players[seatIndex].name,
                                state.players[seatIndex].throwStack.last)
                    })
                .position(throwCenter(in: size))
                .onTapGesture { withAnimation(.cardSpring) { showLastThrows = false } }
                .onChange(of: state) { _, _ in
                    withAnimation(.cardSpring) { showLastThrows = false }
                }
            }
        }
    }

    private var dealingShuffleCount: Int {
        if case .dealing(let shuffles) = state.phase { return shuffles }
        return 0
    }

    /// Hide the throw-spot card while its flight from the seat is in the air.
    private func flightMasked(_ card: Card?) -> Card? {
        if let flight = viewModel.throwFlight, flight.card == card { return nil }
        return card
    }

    /// The most recent visible throw only — never anything older. Once the
    /// current player takes it, the spot goes empty until the next throw.
    private var lastThrow: Card? {
        guard case .turn(let seat, let stage) = state.phase else { return nil }
        if case .awaitingThrow(let drew, _) = stage, drew == .takenThrow { return nil }
        return state.players[state.previousAliveSeat(before: seat)].throwStack.last
    }

    private var takeableHighlighted: Bool {
        viewModel.isHumanTurn && viewModel.humanStage == .awaitingDraw
            && state.throwTakeUnlocked && lastThrow != nil
    }

    private var canPurchase: Bool {
        viewModel.isHumanTurn && viewModel.humanStage == .awaitingDraw
    }

    /// Both sorts can be active together — the badge shows which is primary.
    private var handActions: some View {
        VStack(spacing: 8) {
            sortAction("textformat.123", key: .rank)
            sortAction("suit.spade.fill", key: .suit)
            smallAction("xmark.circle", active: false) { viewModel.cancelSelection() }
                .opacity(viewModel.selectedCardIDs.isEmpty && viewModel.lockedCardIDs.isEmpty
                         ? 0.35 : 1)
        }
    }

    private func sortAction(_ symbol: String, key: RummyGameViewModel.SortKey) -> some View {
        let order = viewModel.sortPriority.firstIndex(of: key)
        return smallAction(symbol, active: order != nil) { viewModel.toggleSort(key) }
            .overlay(alignment: .topTrailing) {
                if let order, viewModel.sortPriority.count > 1 {
                    Text("\(order + 1)")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .frame(width: 13, height: 13)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .foregroundStyle(Theme.accent)
                }
            }
    }

    private func smallAction(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.cardSpring) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(
                    active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial),
                    in: Circle())
                .foregroundStyle(active ? .black : Theme.accent)
        }
        .buttonStyle(.plain)
    }

    /// New melds on the table → big center reveal that shrinks to the owner.
    private func detectLayDown(old: [TableMeld], new: [TableMeld]) {
        let previous = knownMeldIDs
        knownMeldIDs = Set(new.map(\.id))
        let added = new.filter { !previous.contains($0.id) }
        guard !added.isEmpty, !reduceMotion else { return }
        // Appends grow an existing meld; only whole new series get the reveal.
        let owner = added[0].ownerSeat
        layReveal = LayReveal(
            id: added[0].id,
            melds: added.map(\.meld),
            ownerOffset: (owner - viewModel.humanSeat + state.players.count) % state.players.count)
    }

    // MARK: Bottom: chips row, hint, arc hand

    private var bottomArea: some View {
        VStack(spacing: 4) {
            // The totals line sits a little higher, above a reserved strip
            // where errors and hints appear — between the totals and the
            // cards, without pushing the totals around.
            statusChips
            ZStack { hintArea }
                .frame(height: 34)
                .animation(.cardSpring, value: viewModel.stripNotice)
                .animation(.cardSpring, value: viewModel.lastError)
            ArcHandView(viewModel: viewModel, namespace: cardSpace, reduceMotion: reduceMotion)
        }
        .padding(.bottom, 2)
    }

    /// Always-visible counters: hand size, locked-series totals, pending total.
    private var statusChips: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.dealtHandCount ?? state.players[viewModel.humanSeat].hand.count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
            ForEach(Array(viewModel.lockedValues.enumerated()), id: \.offset) { _, value in
                Text("\(value)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
            }
            if viewModel.lockedTotal > 0 {
                Text("Σ \(viewModel.lockedTotal)")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.35), in: Capsule())
                    .foregroundStyle(.white)
            }
            if let pending = viewModel.pendingLayDownValue {
                Label("\(pending)", systemImage: "tray.and.arrow.up.fill")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.8), in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .animation(.cardSpring, value: viewModel.lockedValues)
    }

    /// Feedback strip between the chips row and the hand — hints and errors
    /// share the header-capsule style.
    @ViewBuilder
    private var hintArea: some View {
        if let error = viewModel.lastError {
            Text(errorMessage(error))
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.red.opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .onAppear {
                    Task {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { viewModel.lastError = nil }
                    }
                }
        } else if let notice = viewModel.stripNotice {
            Text(notice.text)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(notice.warn ? .red : Theme.accent)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else if let hint = viewModel.handHint {
            Text(hint.text)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(hint.warn ? .red : Theme.accent)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    private func handleMeldTap(_ tableMeld: TableMeld) {
        // With exactly one card selected on your turn, tapping a meld appends.
        if viewModel.isHumanTurn, case .awaitingThrow = viewModel.humanStage,
           viewModel.selectedCardIDs.count == 1,
           let card = state.players[viewModel.humanSeat].hand.first(where: {
               viewModel.selectedCardIDs.contains($0.id)
           }) {
            let entry: MeldEntry?
            if card.isJoker {
                entry = tableMeld.meld.jokerEntryToExtend(joker: card)
            } else if let rank = card.rank, let suit = card.suit {
                entry = MeldEntry(card: card, asRank: rank, asSuit: suit)
            } else {
                entry = nil
            }
            if let entry {
                Haptics.action()
                withAnimation(reduceMotion ? .default : .cardSpring) {
                    viewModel.apply(.appendCard(entry, meldID: tableMeld.id))
                }
                return
            }
        }
        // Otherwise the tap opens the same enlarged-melds popup used while
        // dragging — read, tap-append, joker swap, or drag a card over it.
        withAnimation(.cardSpring) { viewModel.meldPreviewShown = true }
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        switch state.phase {
        case .dealing(let shuffles) where state.dealerSeat == viewModel.humanSeat:
            DealControlsView(shuffles: shuffles, shufflePulse: $shufflePulse) { action in
                Haptics.action()
                withAnimation(reduceMotion ? .default : .cardSpring) {
                    viewModel.apply(action)
                }
            }
        case .vote(let proposer, let current)
            where current == viewModel.humanSeat && !viewModel.isDealAnimating:
            VotePanelView(
                isProposer: proposer == viewModel.humanSeat,
                proposerName: state.players[proposer].name,
                canForcePass: RummyEngine.canForcePass(
                    hand: state.players[viewModel.humanSeat].hand),
                onVote: { play in
                    Haptics.action()
                    viewModel.apply(.declareIntent(play: play))
                },
                onForcePass: {
                    Haptics.warning()
                    viewModel.apply(.forcePass)
                })
        case .roundEnded(let result) where !viewModel.roundEndCurtain:
            RoundEndView(state: state, result: result) {
                Haptics.success()
                withAnimation(reduceMotion ? .default : .cardSpring) {
                    viewModel.apply(.startNextRound)
                }
            }
        case .matchEnded(let placements) where !viewModel.roundEndCurtain:
            GameEndView(state: state, placements: placements) { dismiss() }
        default:
            EmptyView()
        }
    }

    private func errorMessage(_ error: RummyError) -> String {
        switch error {
        case .thresholdNotMet(let required, let got):
            "Need \(required) — you have \(got)"
        case .throwTakeLocked: "Taking unlocks after the first full turn"
        case .mustLayDownWithTake: "You took the throw — lay a series first"
        case .layDownLocked: "No lay-downs until the turn returns to the dealer"
        case .meldFull: "Melds hold at most 5 cards"
        case .cannotAppendHere: "Doesn't fit this meld"
        case .jokerPending: "Play the swapped joker first"
        case .mustKeepACardToThrow: "Keep one card to throw"
        case .invalidMeld: "Not a valid series"
        default: "Not allowed"
        }
    }
}

/// The full deck center-table during the shuffle phase: a thick stack that
/// visibly riffles apart and back on every shuffle, with a shuffle counter.
struct DeckCenterView: View {
    let count: Int
    let shuffles: Int
    let showShuffles: Bool
    let reduceMotion: Bool
    @State private var split = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                // One pile at rest: the two halves overlay exactly and only
                // separate for the brief shuffle riffle.
                halfStack
                    .offset(x: split ? -30 : 0, y: split ? -4 : 0)
                    .rotationEffect(.degrees(split ? -10 : 0))
                halfStack
                    .offset(x: split ? 30 : 0, y: split ? 4 : 0)
                    .rotationEffect(.degrees(split ? 10 : 0))
            }
            badge
        }
        .onChange(of: shuffles) { _, _ in
            guard !reduceMotion else { return }
            Haptics.tap()
            withAnimation(.easeOut(duration: 0.16)) { split = true }
            Task {
                try? await Task.sleep(for: .seconds(0.18))
                withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) { split = false }
            }
        }
    }

    private var halfStack: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                CardBackView()
                    .frame(width: 62)
                    .offset(x: CGFloat(index) * -1.4, y: CGFloat(index) * -1.4)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
    }

    private var badge: some View {
        Group {
            if showShuffles {
                Label(shuffles > 0 ? "×\(shuffles)" : "—", systemImage: "shuffle")
            } else {
                Text("\(count)")
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .font(.system(size: 14, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.45), in: Capsule())
        .foregroundStyle(Theme.accent)
    }
}

/// Every center-table message wears the same dress as the "Play!" verdict:
/// icon over black-serif amber text on a glowing glass card. Verdicts are a
/// size up; everything else is identical, just slightly smaller.
struct CenterBannerView: View {
    let banner: RummyGameViewModel.TableBanner

    private var isVerdict: Bool { banner.style == .verdict }

    var body: some View {
        VStack(spacing: 6) {
            if let icon = banner.icon {
                Image(systemName: icon)
                    .font((isVerdict ? Font.title2 : .headline).weight(.bold))
            }
            Text(banner.text)
                .font(.system(isVerdict ? .title2 : .headline, design: .serif).weight(.black))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(banner.style == .warn ? Color.red : Theme.accent)
        .padding(.horizontal, isVerdict ? 26 : 20)
        .padding(.vertical, isVerdict ? 18 : 13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: (banner.style == .warn ? Color.red : Theme.accent).opacity(0.35),
                radius: isVerdict ? 16 : 11)
    }
}

/// Fresh lay-down: the series appear big center-table, then shrink and slide
/// to their owner's side.
struct LayDownRevealView: View {
    let reveal: GameTableView.LayReveal
    let center: CGPoint
    let destination: CGPoint
    let reduceMotion: Bool
    let onFinished: () -> Void
    @State private var departed = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(reveal.melds.enumerated()), id: \.offset) { _, meld in
                HStack(spacing: 4) {
                    ForEach(meld.entries, id: \.card.id) { entry in
                        CardView(card: entry.card)
                            .frame(width: 52)
                    }
                }
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .scaleEffect(departed ? 0.18 : (appeared ? 1 : 0.55))
        .opacity(departed ? 0 : (appeared ? 1 : 0))
        .position(departed ? destination : center)
        .allowsHitTesting(false)
        .onAppear {
            if reduceMotion {
                onFinished()
                return
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { appeared = true }
            Task {
                try? await Task.sleep(for: .seconds(1.05))
                withAnimation(.easeIn(duration: 0.45)) { departed = true }
                try? await Task.sleep(for: .seconds(0.5))
                onFinished()
            }
        }
    }
}

/// The one melds popup: opened by tapping any meld, or by holding a dragged
/// card over the lays. Big cards to read, drop or tap-append a card, swap a
/// joker. Frames are reported globally for hit-testing drag drops.
struct MeldPreviewOverlay: View {
    @State var viewModel: RummyGameViewModel

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.state.tableMelds) { tableMeld in
                        meldRow(tableMeld)
                    }
                }
            }
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
            Text("Drop a card on a series — or select one and tap the series")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
    }

    private func meldRow(_ tableMeld: TableMeld) -> some View {
        HStack(spacing: 3) {
            ForEach(tableMeld.meld.entries, id: \.card.id) { entry in
                VStack(spacing: 2) {
                    CardView(card: entry.card)
                        .frame(width: 44)
                    if entry.card.isJoker {
                        Text("as \(entry.asRank.label)\(entry.asSuit.symbol)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            if let swap = swapOffer(for: tableMeld) {
                Button {
                    Haptics.action()
                    withAnimation(.cardSpring) {
                        viewModel.apply(.swapJoker(meldID: tableMeld.id, realCard: swap))
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        viewModel.meldDropFrames[tableMeld.id] = proxy.frame(in: .global)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        viewModel.meldDropFrames[tableMeld.id] = frame
                    }
            })
        .onTapGesture { viewModel.tapPreviewMeld(tableMeld.id) }
    }

    /// The real card in hand that could free this meld's joker (after lay-down).
    private func swapOffer(for tableMeld: TableMeld) -> Card? {
        let state = viewModel.state
        guard viewModel.isHumanTurn, case .awaitingThrow = viewModel.humanStage,
              state.players[viewModel.humanSeat].hasLaidDown else { return nil }
        for entry in tableMeld.meld.entries where entry.card.isJoker {
            if let real = state.players[viewModel.humanSeat].hand.first(where: {
                $0.rank == entry.asRank && $0.suit == entry.asSuit
            }) {
                return real
            }
        }
        return nil
    }
}

/// A card back that flies from the deck to a seat, then fades. It stays
/// completely invisible until its launch moment — the center deck alone is
/// the pile, never a second stack on top — then departs at the deck's card
/// size and shrinks on the way out.
private struct DealFlightCard: View {
    let delay: Double
    let from: CGPoint
    let to: CGPoint
    @State private var flown = false
    @State private var launched = false

    var body: some View {
        CardBackView()
            .frame(width: 62)
            .scaleEffect(flown ? 0.6 : 1)
            .position(flown ? to : from)
            .opacity(launched && !flown ? 1 : 0)
            .onAppear {
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    launched = true
                    withAnimation(.easeIn(duration: 0.34)) { flown = true }
                }
            }
            .allowsHitTesting(false)
    }
}

/// A bot's thrown card flying face-up from its seat to the throw spot.
private struct ThrowFlightCard: View {
    let card: Card
    let from: CGPoint
    let to: CGPoint
    let reduceMotion: Bool
    @State private var flown = false

    var body: some View {
        CardView(card: card)
            .frame(width: 66)
            .rotationEffect(.degrees(flown ? 0 : 14))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            .position(flown ? to : from)
            .scaleEffect(flown ? 1 : 0.55)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82), value: flown)
            .onAppear { flown = true }
            .allowsHitTesting(false)
    }
}

/// The purchased card flips face-up center-table for a beat.
private struct DrawRevealView: View {
    let card: Card
    @State private var flipped = false

    var body: some View {
        ZStack {
            CardBackView().opacity(flipped ? 0 : 1)
            CardView(card: card).opacity(flipped ? 1 : 0)
        }
        .frame(width: 96)
        .rotation3DEffect(.degrees(flipped ? 0 : 180), axis: (x: 0, y: 1, z: 0))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { flipped = true }
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.5).combined(with: .opacity),
            removal: .offset(y: 220).combined(with: .opacity).combined(with: .scale(scale: 0.5))))
        .allowsHitTesting(false)
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
