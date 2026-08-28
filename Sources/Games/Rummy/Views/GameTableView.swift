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

    /// A completed same-rank set bursting off the table.
    struct MeldBurst: Identifiable, Equatable {
        let id: UUID
        let cards: [Card]
    }

    @State private var meldBurst: MeldBurst?

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
                if let burst = meldBurst {
                    MeldBurstView(
                        cards: burst.cards,
                        center: CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.42),
                        reduceMotion: reduceMotion) {
                            if meldBurst == burst { meldBurst = nil }
                        }
                    .id(burst.id)
                }
                if viewModel.meldPreviewShown {
                    // Tap anywhere outside the popup to close it.
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.cardSpring) {
                                viewModel.meldPreviewShown = false
                                viewModel.popupPickedCardID = nil
                            }
                        }
                    MeldPreviewOverlay(
                        viewModel: viewModel,
                        panelSize: CGSize(
                            width: geometry.size.width - 24,
                            height: geometry.size.height * 0.80))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.45)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .zIndex(40)
                }
                if let banner = viewModel.banner {
                    if banner.style == .verdict {
                        // Verdicts: big arcade gold text, no popup, under the throws.
                        VerdictTextView(text: banner.text)
                            .position(x: geometry.size.width / 2,
                                      y: throwCenter(in: geometry.size).y + 122)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                            .allowsHitTesting(false)
                            .zIndex(50)
                    } else {
                        // Every note lands in the same spot: above the throw
                        // area, below the top player's lays.
                        CenterBannerView(banner: banner)
                            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.27)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                            .allowsHitTesting(false)
                            .zIndex(50)
                    }
                }
                #if DEBUG
                // Design review: launch with SHOW_MESSAGE_DEMO=1 to see one
                // example of every message category at once.
                if ProcessInfo.processInfo.environment["SHOW_MESSAGE_DEMO"] == "1" {
                    Group {
                        CenterBannerView(banner: .init(
                            text: "Hamadi picked up the discard", style: .note,
                            icon: "hand.point.down.fill"))
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.27)
                        VerdictTextView(text: L10n.playVerdict)
                            .position(x: geometry.size.width / 2,
                                      y: throwCenter(in: geometry.size).y + 122)
                    }
                    .zIndex(60)
                    .allowsHitTesting(false)
                }
                #endif
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
                // Quiet labels, loud values: the round and required numbers
                // read at a glance in the same gold heavy digits as the
                // table's count tags.
                roundLine
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

    private var roundLine: some View {
        let label = Font.system(size: 11, weight: .semibold)
        let number = Font.system(size: 13, weight: .heavy, design: .rounded)
        return (
            Text("\(L10n.round) ").font(label).foregroundStyle(.secondary)
            + Text("\(state.roundNumber)").font(number).foregroundStyle(Theme.accent)
            + Text("  ·  ").font(label).foregroundStyle(.secondary)
            + Text("\(L10n.required): ").font(label).foregroundStyle(.secondary)
            + Text("\(state.requiredLayDown)").font(number).foregroundStyle(Theme.accent)
        )
        .monospacedDigit()
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

    /// Within 100 points of elimination: the player's score reads reddish
    /// everywhere it appears.
    private func dangerScore(_ seat: Int) -> Bool {
        !state.players[seat].isEliminated
            && state.players[seat].totalScore >= state.config.eliminationScore - 100
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
                            isActive: activeSeat == seatIndex,
                            dangerScore: dangerScore(seatIndex),
                            mood: viewModel.botMood(seat: seatIndex))
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
                    },
                    onFrame: { id, frame in viewModel.tableMeldFrames[id] = frame })
                .position(meldsAnchor(offset, in: size))
            }
            centerStage(in: size)
            // The stock: one view, center stage while shuffling and dealing,
            // then it GLIDES down to its corner spot.
            stockView(in: size)
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
                },
                onFrame: { id, frame in viewModel.tableMeldFrames[id] = frame })
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
        .onChange(of: state.destroyedCards ?? []) { old, new in
            // The graveyard only ever GROWS on a destruction (reshuffle and
            // round reset empty it), so growth is the burst signal.
            guard new.count > old.count else { return }
            Haptics.action()
            meldBurst = MeldBurst(id: UUID(), cards: Array(new.dropFirst(old.count)))
        }
    }

    /// The center of the table: the full deck while shuffling/dealing,
    /// otherwise the single most recent throw.
    @ViewBuilder
    /// One persistent stock view: the full deck at center while shuffling and
    /// dealing, gliding to the corner as a small pile once the deal is done.
    private func stockView(in size: CGSize) -> some View {
        Group {
            if deckIsCenterStage {
                DeckCenterView(
                    count: viewModel.animatedPileCount ?? state.drawPile.count,
                    shuffles: dealingShuffleCount,
                    showShuffles: isDealingPhase,
                    reduceMotion: reduceMotion)
                .transition(.opacity)
            } else {
                PileView(count: state.drawPile.count, enabled: canPurchase) {
                    guard canPurchase else { return }
                    Haptics.action()
                    withAnimation(reduceMotion ? .default : .cardSpring) {
                        viewModel.apply(.drawFromPile)
                    }
                }
                .transition(.opacity)
            }
        }
        .position(deckIsCenterStage ? throwCenter(in: size) : pileAnchor(in: size))
        .animation(reduceMotion ? .default : .spring(response: 0.55, dampingFraction: 0.8),
                   value: deckIsCenterStage)
    }

    @ViewBuilder
    private func centerStage(in size: CGSize) -> some View {
        if !deckIsCenterStage {
            // One central throw pile showing only the most recent throw.
            if !showLastThrows {
                ThrowSpotView(
                    card: flightMasked(lastThrow),
                    highlighted: takeableHighlighted,
                    namespace: cardSpace,
                    onTap: {
                        // A tap on the glowing takeable card TAKES it — the
                        // popup is for reading the table, not the way in.
                        if takeableHighlighted {
                            withAnimation(reduceMotion ? .default : .cardSpring) {
                                viewModel.tapTakeableThrow()
                            }
                        } else if lastThrow != nil {
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
                    },
                    takeableOffset: takeableHighlighted
                        ? (state.previousAliveSeat(before: viewModel.humanSeat)
                            - viewModel.humanSeat + state.players.count) % state.players.count
                        : nil,
                    onTake: {
                        withAnimation(reduceMotion ? .default : .cardSpring) {
                            showLastThrows = false
                            viewModel.tapTakeableThrow()
                        }
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
            && state.throwTakeUnlocked && viewModel.takeableThrow != nil
    }

    private var canPurchase: Bool {
        viewModel.isHumanTurn && viewModel.humanStage == .awaitingDraw
    }

    /// One sort at a time: smart (type + number), by number, by type.
    private var handActions: some View {
        VStack(spacing: 8) {
            sortAction("sparkles", mode: .smart)
            sortAction("textformat.123", mode: .rank)
            sortAction("suit.spade.fill", mode: .suit)
            smallAction("xmark.circle", active: false) { viewModel.cancelSelection() }
                .opacity(viewModel.selectedCardIDs.isEmpty && viewModel.lockedCardIDs.isEmpty
                         ? 0.35 : 1)
        }
    }

    private func sortAction(_ symbol: String, mode: RummyGameViewModel.SortMode) -> some View {
        smallAction(symbol, active: viewModel.activeSort == mode) {
            viewModel.toggleSort(mode)
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
            // Errors and hints appear in a reserved strip above the cards,
            // with the totals row tucked UNDER the fan so score and counts
            // stay visible without sitting over the messages.
            ZStack { hintArea }
                .frame(height: 34)
                .padding(.top, 20)
                .animation(.cardSpring, value: viewModel.stripNotice)
                .animation(.cardSpring, value: viewModel.lastError)
            ArcHandView(viewModel: viewModel, namespace: cardSpace, reduceMotion: reduceMotion)
            statusChips
        }
        .padding(.bottom, 2)
    }

    /// Always-visible counters: score, hand size, locked total, pending
    /// total.
    private var statusChips: some View {
        HStack(spacing: 8) {
            Text("\(state.players[viewModel.humanSeat].totalScore)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    dangerScore(viewModel.humanSeat)
                        ? Color.red.opacity(0.75) : Color.black.opacity(0.45),
                    in: Capsule())
                .foregroundStyle(dangerScore(viewModel.humanSeat) ? .white : Theme.accent)
            Text("\(viewModel.dealtHandCount ?? state.players[viewModel.humanSeat].hand.count)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.45), in: Capsule())
                .foregroundStyle(.white)
            if viewModel.lockedTotal > 0 {
                Text("\(viewModel.lockedTotal)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
            }
            if !viewModel.lockedPlaceables.isEmpty {
                Text("\(viewModel.lockedPlaceables.count)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.placeableLock.opacity(0.75), in: Capsule())
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
        .animation(.cardSpring, value: viewModel.lockedPlaceables)
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
        // With exactly one card selected on your turn: a single destination
        // places directly; several open the placement window with the card
        // picked, so its exact slots light up for the player to choose.
        if viewModel.isHumanTurn, case .awaitingThrow = viewModel.humanStage,
           viewModel.selectedCardIDs.count == 1,
           let card = state.players[viewModel.humanSeat].hand.first(where: {
               viewModel.selectedCardIDs.contains($0.id)
           }) {
            let targets = viewModel.placementTargets(for: card)
            if targets.count == 1 {
                withAnimation(reduceMotion ? .default : .cardSpring) {
                    viewModel.placeCard(card, on: targets[0])
                }
                return
            }
            if targets.count > 1 {
                viewModel.popupPickedCardID = card.id
                withAnimation(.cardSpring) { viewModel.meldPreviewShown = true }
                return
            }
        }
        // Otherwise the tap opens the big placement window — read the melds,
        // tap or drag a card onto one, or drop a card on a joker to swap it.
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
        case .throwTakeLocked: "The opening discards can't be picked up — takes start at the 5th"
        case .mustLayDownWithTake: "You picked up the discard — lay down a meld first"
        case .layDownLocked: "No lay-downs until the turn returns to the dealer"
        case .meldFull: "This series can't grow any further"
        case .cannotAppendHere: "Doesn't fit this meld"
        case .jokerPending: "Play the swapped joker first"
        case .mustKeepACardToThrow: "Keep one card to discard"
        case .invalidMeld: "Not a valid meld"
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
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.45), in: Capsule())
        .foregroundStyle(Theme.accent)
    }
}

/// One center-table banner style for all feedback: capsule material like the
/// header for info, big animated text for verdicts.
struct CenterBannerView: View {
    let banner: RummyGameViewModel.TableBanner

    var body: some View {
        switch banner.style {
        case .verdict:
            VerdictTextView(text: banner.text)
        case .note:
            Label(banner.text, systemImage: banner.icon ?? "bubble.left.fill")
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.primary)
        }
    }
}

/// Verdicts as big arcade lettering — golden 3D text with a dark outline and
/// extruded depth, straight on the felt with no popup behind it.
struct VerdictTextView: View {
    let text: String

    private var styledText: Text {
        Text(text).font(.system(size: 40, weight: .heavy, design: .rounded))
    }

    private let outlineColor = Color(red: 0.42, green: 0.24, blue: 0.05)
    private let depthColor = Color(red: 0.35, green: 0.19, blue: 0.04)

    var body: some View {
        ZStack {
            // Extruded depth below the letters.
            ForEach(1..<5) { step in
                styledText
                    .foregroundStyle(depthColor)
                    .offset(y: CGFloat(step) * 1.5)
            }
            // Dark outline all around.
            ForEach(0..<8) { direction in
                let angle = Double(direction) * .pi / 4
                styledText
                    .foregroundStyle(outlineColor)
                    .offset(x: cos(angle) * 2.2, y: sin(angle) * 2.2)
            }
            // Golden face, light on top fading to deep amber.
            styledText
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.93, blue: 0.55),
                            Theme.accent,
                            Color(red: 0.75, green: 0.47, blue: 0.10),
                        ],
                        startPoint: .top, endPoint: .bottom))
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 5)
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
                    ForEach(meld.displayEntries, id: \.card.id) { entry in
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

/// A completed same-rank set (four cards, jokers included) bursting off the
/// table: the set flashes big at center, then blows up and fades — its cards
/// wait out of sight until the pile reshuffle.
struct MeldBurstView: View {
    let cards: [Card]
    let center: CGPoint
    let reduceMotion: Bool
    let onFinished: () -> Void
    @State private var appeared = false
    @State private var burst = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    CardView(card: card)
                        .frame(width: 52)
                        // Cards splay apart as the set blows up.
                        .rotationEffect(.degrees(
                            burst ? (Double(index) - Double(cards.count - 1) / 2) * 16 : 0))
                }
            }
            Text("Set complete — destroyed")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
                .opacity(burst ? 0 : 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .scaleEffect(burst ? 1.6 : (appeared ? 1 : 0.4))
        .opacity(burst ? 0 : (appeared ? 1 : 0))
        .position(center)
        .allowsHitTesting(false)
        .onAppear {
            if reduceMotion {
                Task {
                    try? await Task.sleep(for: .seconds(0.7))
                    onFinished()
                }
                return
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { appeared = true }
            Task {
                try? await Task.sleep(for: .seconds(0.75))
                withAnimation(.easeOut(duration: 0.35)) { burst = true }
                try? await Task.sleep(for: .seconds(0.4))
                onFinished()
            }
        }
    }
}

/// The placement window: opened by tapping any meld, or by holding a dragged
/// card over the lays. Your placeable cards sit big on top; below, every
/// player's melds are grouped under their name. Drag a card onto a meld to
/// extend it — drop it on a matching joker to take the joker's seat and send
/// the joker to your hand. Meld frames are reported globally so a card
/// dragged straight from the hand fan drops here too.
struct MeldPreviewOverlay: View {
    @State var viewModel: RummyGameViewModel
    let panelSize: CGSize

    /// A joker's seat on the table, for precise drop-to-swap hit testing.
    private struct JokerSpot {
        let meldID: UUID
        let rank: Rank
        let suit: Suit
        var frame: CGRect
    }

    /// Live drag: the candidate card under the finger follows it for real —
    /// released over a meld it plays there, anywhere else it springs back.
    @State private var dragCard: Card?
    @State private var dragLocation: CGPoint = .zero   // global
    @State private var dragOrigin: CGPoint = .zero     // global center of the slot
    @State private var dragReturning = false
    /// Global frames of the candidate slots (spring-back destinations).
    @State private var candidateFrames: [Int: CGRect] = [:]
    /// Global frames of the table jokers, keyed by joker card id.
    @State private var jokerFrames: [Int: JokerSpot] = [:]

    /// The width rows and the candidate strip can center within: the panel
    /// minus its own padding.
    private var contentWidth: CGFloat { panelSize.width - 24 }

    var body: some View {
        GeometryReader { geometry in
            let panelOrigin = geometry.frame(in: .global).origin
            VStack(spacing: 10) {
                // Sticky header: your placeable cards stay put while the meld
                // list underneath scrolls through every player.
                candidatesSection
                Divider().overlay(Color.white.opacity(0.25))
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(ownerSeats, id: \.self) { seat in
                            ownerSection(seat)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .overlay {
                // The card in flight, riding the finger.
                if let card = dragCard {
                    CardView(card: card)
                        .frame(width: 62)
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 5)
                        .position(x: dragLocation.x - panelOrigin.x,
                                  y: dragLocation.y - panelOrigin.y)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        // Opaque enough that the table underneath never bleeds through the
        // rows — this window reads as its own screen.
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
    }

    /// Seats that have melds on the table: you first, then around the table.
    private var ownerSeats: [Int] {
        let count = viewModel.state.players.count
        return (0..<count).map { (viewModel.humanSeat + $0) % count }.filter { seat in
            viewModel.state.tableMelds.contains { $0.ownerSeat == seat }
        }
    }

    // MARK: Your placeable cards

    @ViewBuilder
    private var candidatesSection: some View {
        if viewModel.popupCandidates.isEmpty {
            Text("No card in your hand plays on these melds")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        } else {
            VStack(spacing: 5) {
                let candidates = viewModel.popupCandidates
                // Adaptive width: the whole strip always fits (no scroll), so
                // an immediate finger-drag never fights a scroll view.
                let cardWidth = min(
                    58,
                    (contentWidth - 8 - CGFloat(candidates.count - 1) * 6)
                        / CGFloat(max(candidates.count, 1)))
                HStack(spacing: 6) {
                    ForEach(candidates, id: \.id) { card in
                        candidateCard(card, width: cardWidth)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                Text(viewModel.canAppendToTable
                     ? "Drag a card onto a meld — or tap it, then tap the target"
                     : "These play on the table — tap to reserve; placing opens on your turn")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func candidateCard(_ card: Card, width: CGFloat) -> some View {
        CardView(card: card)
            .frame(width: width)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        viewModel.popupPickedCardID == card.id
                            ? Theme.accent
                            : (viewModel.lockedPlaceables.contains(card.id)
                                ? Theme.placeableLock : .clear),
                        lineWidth: 2.5))
            // The slot empties while its card rides the finger.
            .opacity(dragCard?.id == card.id ? 0 : 1)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { candidateFrames[card.id] = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in
                            candidateFrames[card.id] = frame
                        }
                })
            .onTapGesture { viewModel.popupPick(card) }
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .global)
                    .onChanged { value in
                        if dragCard?.id != card.id {
                            dragCard = card
                            dragReturning = false
                            let slot = candidateFrames[card.id]
                            dragOrigin = slot.map { CGPoint(x: $0.midX, y: $0.midY) }
                                ?? value.startLocation
                        }
                        guard !dragReturning else { return }
                        dragLocation = value.location
                    }
                    .onEnded { value in
                        handleDrop(card, at: value.location)
                    })
    }

    // MARK: Drop resolution

    private func handleDrop(_ card: Card, at location: CGPoint) {
        // Placing waits for your throw step — until then a drop springs back.
        guard viewModel.canAppendToTable else {
            dragReturning = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                dragLocation = dragOrigin
            }
            Task {
                try? await Task.sleep(for: .seconds(0.30))
                dragCard = nil
                dragReturning = false
            }
            return
        }
        // A matching joker's own seat wins: release right on it to swap.
        if let spot = jokerFrames.values.first(where: {
            $0.frame.insetBy(dx: -8, dy: -8).contains(location)
        }), card.rank == spot.rank, card.suit == spot.suit,
           viewModel.swapMelds(for: card).contains(spot.meldID) {
            dragCard = nil
            withAnimation(.cardSpring) {
                viewModel.swapJoker(with: card, in: spot.meldID, keepPopup: true)
            }
            return
        }
        // Anywhere on a meld the card plays on: place it (append or swap).
        if let target = viewModel.meldDropFrames.first(where: {
            $0.value.insetBy(dx: -8, dy: -8).contains(location)
        }), viewModel.placementTargets(for: card).contains(target.key) {
            dragCard = nil
            withAnimation(.cardSpring) {
                viewModel.placeCard(card, on: target.key, keepPopup: true)
            }
            return
        }
        // No fit under the finger: the card springs back to its slot.
        dragReturning = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            dragLocation = dragOrigin
        }
        Task {
            try? await Task.sleep(for: .seconds(0.30))
            dragCard = nil
            dragReturning = false
        }
    }

    // MARK: Melds by player

    private func ownerSection(_ seat: Int) -> some View {
        VStack(spacing: 6) {
            Text(viewModel.displayName(seat))
                .font(.footnote.weight(.bold))
                .foregroundStyle(seat == viewModel.humanSeat ? Theme.accent : .white.opacity(0.9))
                .frame(maxWidth: .infinity)
            ForEach(viewModel.state.tableMelds.filter { $0.ownerSeat == seat }) { tableMeld in
                meldRow(tableMeld)
            }
        }
    }

    /// The card whose exact placements light up in the meld rows: the one
    /// riding the finger, else the tap-picked one, else a single hand
    /// selection carried into the window.
    private var activeCard: Card? {
        if let card = dragCard, !dragReturning { return card }
        if let id = viewModel.popupPickedCardID {
            return viewModel.humanHand.first { $0.id == id }
        }
        if viewModel.selectedCardIDs.count == 1 {
            return viewModel.humanHand.first { viewModel.selectedCardIDs.contains($0.id) }
        }
        return nil
    }

    /// A meld row rendered as its cards plus the card-sized SLOTS the active
    /// card could fill — a joker shows every legal end at once.
    private enum RowItem: Identifiable {
        case entry(MeldEntry)
        case slot(RummyGameViewModel.PlacementSpot)
        var id: String {
            switch self {
            case .entry(let entry): "c\(entry.card.id)"
            case .slot(let spot): "s\(spot.id)"
            }
        }
    }

    private func rowItems(_ tableMeld: TableMeld) -> [RowItem] {
        var items: [RowItem] = tableMeld.meld.displayEntries.map { .entry($0) }
        guard let card = activeCard else { return items }
        for spot in viewModel.placementSpots(for: card, in: tableMeld)
            .sorted(by: { $0.gapIndex > $1.gapIndex }) {
            items.insert(.slot(spot), at: min(spot.gapIndex, items.count))
        }
        return items
    }

    private func meldRow(_ tableMeld: TableMeld) -> some View {
        // Long runs scroll sideways inside their row instead of clipping.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(rowItems(tableMeld)) { item in
                    switch item {
                    case .entry(let entry): entryView(entry, in: tableMeld)
                    case .slot(let spot): slotView(spot, in: tableMeld)
                    }
                }
            }
            .padding(7)
            // Centers the meld while it fits; scrolls once it doesn't.
            .frame(minWidth: contentWidth)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .background(frameReporter(tableMeld.id))
        .onTapGesture { viewModel.popupTapMeld(tableMeld.id) }
    }

    /// A card-sized empty seat the active card can take — tap places it
    /// exactly there.
    private func slotView(
        _ spot: RummyGameViewModel.PlacementSpot, in tableMeld: TableMeld
    ) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Theme.accent.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5])))
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent))
            .frame(width: 50, height: 50 / CardView.aspectRatio)
            .onTapGesture {
                guard let card = activeCard else { return }
                withAnimation(.cardSpring) { viewModel.placeSpot(spot, card: card) }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    @ViewBuilder
    private func entryView(_ entry: MeldEntry, in tableMeld: TableMeld) -> some View {
        // The active card's matching joker seat lights up card-sized too —
        // tapping it (or dropping the card on it) performs the swap.
        let swapSeat = activeCard.map {
            viewModel.swapSeats(for: $0, in: tableMeld).contains(entry.card.id)
        } ?? false
        let base = CardView(card: entry.card)
            .frame(width: 50)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        jokerTargeted(entry) || swapSeat ? Theme.accent : .clear,
                        style: StrokeStyle(
                            lineWidth: 2.5,
                            dash: swapSeat && !jokerTargeted(entry) ? [5] : [])))
            .background(
                Group {
                    if entry.card.isJoker {
                        // The joker's seat is a precise drop target for its
                        // real card — track its frame while it's on screen.
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear {
                                    jokerFrames[entry.card.id] = JokerSpot(
                                        meldID: tableMeld.id, rank: entry.asRank,
                                        suit: entry.asSuit, frame: proxy.frame(in: .global))
                                }
                                .onChange(of: proxy.frame(in: .global)) { _, frame in
                                    jokerFrames[entry.card.id]?.frame = frame
                                }
                                .onDisappear { jokerFrames.removeValue(forKey: entry.card.id) }
                        }
                    }
                })
        if swapSeat {
            base.onTapGesture {
                guard let card = activeCard else { return }
                withAnimation(.cardSpring) {
                    viewModel.swapJoker(with: card, in: tableMeld.id, keepPopup: true)
                }
            }
        } else {
            base
        }
    }

    /// The joker's seat glows while the finger carries its real card over it.
    private func jokerTargeted(_ entry: MeldEntry) -> Bool {
        guard entry.card.isJoker, let card = dragCard, !dragReturning,
              card.rank == entry.asRank, card.suit == entry.asSuit,
              let spot = jokerFrames[entry.card.id] else { return false }
        return spot.frame.insetBy(dx: -8, dy: -8).contains(dragLocation)
    }

    private func frameReporter(_ meldID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    viewModel.meldDropFrames[meldID] = proxy.frame(in: .global)
                }
                .onChange(of: proxy.frame(in: .global)) { _, frame in
                    viewModel.meldDropFrames[meldID] = frame
                }
        }
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
