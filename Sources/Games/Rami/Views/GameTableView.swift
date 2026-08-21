import SwiftUI

/// The table. Bots sit left / top / right with their melds laid along their
/// own side and their last throw aligned with their seat; the human hand fans
/// in an arc along the bottom. Pile under the left player, sort actions under
/// the right player, stats top-right.
struct GameTableView: View {
    @State var viewModel: RamiGameViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAbandonConfirm = false
    @State private var showStats = false
    @State private var zoomedMeldID: UUID?
    @State private var shufflePulse = 0
    @State private var showLastThrows = false
    @State private var dealFlights: [DealFlight] = []
    @Namespace private var cardSpace

    private var state: RamiState { viewModel.state }

    struct DealFlight: Identifiable {
        let id: Int
        let seatOffset: Int
        let delay: Double
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
                overlays
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showStats) { ScoreSheetView(state: state) }
        .sheet(item: $zoomedMeldID) { meldID in
            MeldZoomSheet(viewModel: viewModel, meldID: meldID)
                .presentationDetents([.height(300)])
        }
        .confirmationDialog(L10n.abandonTitle, isPresented: $showAbandonConfirm, titleVisibility: .visible) {
            Button(L10n.abandon, role: .destructive) {
                viewModel.abandonMatch()
                dismiss()
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.abandonMessage)
        }
        .onAppear { viewModel.runBots() }
        .tint(Theme.accent)
    }

    // MARK: Header

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
            VStack(spacing: 2) {
                Text("\(L10n.round) \(state.roundNumber)")
                    .font(.caption.weight(.semibold))
                Text("\(L10n.required): \(state.requiredLayDown)")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
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
        case 1: CGPoint(x: size.width - 36, y: size.height * 0.33)
        case 2: CGPoint(x: size.width / 2, y: 162)
        case 3: CGPoint(x: 36, y: size.height * 0.33)
        default: CGPoint(x: size.width / 2, y: size.height * 0.60)
        }
    }

    /// Lays hug their owner: right under the side seats, beside the top seat.
    private func meldsAnchor(_ offset: Int, in size: CGSize) -> CGPoint {
        switch offset {
        case 1: CGPoint(x: size.width - 44, y: size.height * 0.33 + 82)
        case 2: CGPoint(x: size.width / 2 - 94, y: 158)
        default: CGPoint(x: 44, y: size.height * 0.33 + 82)
        }
    }

    private func pileAnchor(in size: CGSize) -> CGPoint {
        CGPoint(x: 46, y: size.height * 0.62)
    }

    /// Exactly the centroid of the three bot seats.
    private func throwCenter(in size: CGSize) -> CGPoint {
        let anchors = [1, 2, 3].map { avatarAnchor($0, in: size) }
        return CGPoint(
            x: anchors.map(\.x).reduce(0, +) / 3,
            y: anchors.map(\.y).reduce(0, +) / 3 + 14)  // clear of the top seat's chips
    }

    private var activeSeat: Int? {
        switch state.phase {
        case .dealing: state.dealerSeat
        case .vote(_, let current): current
        case .turn(let seat, _): seat
        default: nil
        }
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
                            isDealer: state.dealerSeat == seatIndex,
                            isActive: activeSeat == seatIndex)
                    }
                }
                .position(avatarAnchor(offset, in: size))
                // Melds along that player's own side.
                SideMeldsView(
                    melds: state.tableMelds.filter { $0.ownerSeat == seatIndex },
                    horizontal: false,
                    onTap: { zoomedMeldID = $0 })
                .position(meldsAnchor(offset, in: size))
            }
            // One central throw pile showing only the most recent throw.
            if !showLastThrows {
            ThrowSpotView(
                card: lastThrow,
                highlighted: takeableHighlighted,
                namespace: cardSpace,
                onTap: {
                    #if DEBUG
                    print("RAMI throw spot tapped, takeable=\(takeableHighlighted), last=\(String(describing: lastThrow?.id))")
                    #endif
                    if takeableHighlighted {
                        viewModel.tapTakeableThrow()
                    } else if lastThrow != nil {
                        withAnimation(.cardSpring) { showLastThrows = true }
                    }
                })
            .position(throwCenter(in: size))
            }
            if showLastThrows {
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
            // Draw pile under the left player; tap to purchase.
            PileView(count: state.drawPile.count, enabled: canPurchase) {
                guard canPurchase else { return }
                Haptics.action()
                withAnimation(reduceMotion ? .default : .cardSpring) {
                    viewModel.apply(.drawFromPile)
                }
            }
            .position(pileAnchor(in: size))
            // Sort / cancel actions under the right player.
            handActions
                .position(x: size.width - 46, y: size.height * 0.62)
            ForEach(dealFlights) { flight in
                DealFlightCard(
                    delay: flight.delay,
                    from: pileAnchor(in: size),
                    to: flight.seatOffset == 0
                        ? CGPoint(x: size.width / 2, y: size.height - 110)
                        : avatarAnchor(flight.seatOffset, in: size))
            }
            if let drawn = viewModel.revealedDraw {
                DrawRevealView(card: drawn)
                    .position(x: size.width / 2, y: size.height * 0.42)
            }
        }
        .animation(reduceMotion ? .default : .cardSpring, value: state)
        .onChange(of: isVotePhase) { _, started in
            guard started, !reduceMotion else { return }
            buildDealFlights()
        }
    }

    private var isVotePhase: Bool {
        if case .vote = state.phase { return true }
        return false
    }

    /// The most recent visible throw: the top of the previous player's stack.
    private var lastThrow: Card? {
        guard case .turn(let seat, _) = state.phase else { return nil }
        return state.players[state.previousAliveSeat(before: seat)].throwStack.last
    }

    private var takeableHighlighted: Bool {
        viewModel.isHumanTurn && viewModel.humanStage == .awaitingDraw
            && state.throwTakeUnlocked && lastThrow != nil
    }

    private var canPurchase: Bool {
        viewModel.isHumanTurn && viewModel.humanStage == .awaitingDraw
    }

    private var handActions: some View {
        VStack(spacing: 8) {
            smallAction("textformat.123") { viewModel.sortHandByRank() }
            smallAction("suit.spade.fill") { viewModel.sortHandBySuit() }
            smallAction("xmark.circle") { viewModel.cancelSelection() }
                .opacity(viewModel.selectedCardIDs.isEmpty ? 0.35 : 1)
        }
    }

    private func smallAction(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.cardSpring) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    /// One flying card back per dealt card, in the true dealing order and
    /// rhythm of the chosen pattern.
    private func buildDealFlights() {
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
                    let offset = (receiver - viewModel.humanSeat + 4) % 4
                    flights.append(DealFlight(id: flightID, seatOffset: offset, delay: delay))
                    flightID += 1
                    delay += 0.05
                }
            }
            delay += 0.22  // breath between passes: the rhythm reads
        }
        dealFlights = flights
        Task {
            try? await Task.sleep(for: .seconds(delay + 0.6))
            dealFlights = []
        }
    }

    // MARK: Bottom: lay-down pill, own melds, arc hand

    private var bottomArea: some View {
        VStack(spacing: 6) {
            layDownPill
            humanMeldsRow
            ArcHandView(viewModel: viewModel, namespace: cardSpace, reduceMotion: reduceMotion)
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var layDownPill: some View {
        if let selection = viewModel.selectedMelds {
            let hasLaidDown = state.players[viewModel.humanSeat].hasLaidDown
            let needsThreshold = !hasLaidDown
            let meets = !needsThreshold || selection.total >= state.requiredLayDown
            if viewModel.selectionIncludesTakeable {
                if viewModel.humanStage == .awaitingDraw, !hasLaidDown, state.throwTakeUnlocked {
                    pill("\(L10n.takeAndLayDown) (\(selection.total))", prominent: meets) {
                        viewModel.apply(.takeThrowAndLayDown(melds: selection.melds))
                    }
                }
            } else if case .awaitingThrow = viewModel.humanStage {
                pill("\(L10n.layDown) (\(selection.total))", prominent: meets) {
                    viewModel.apply(.layDown(melds: selection.melds))
                }
            }
        }
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.action()
            withAnimation(reduceMotion ? .default : .cardSpring) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule())
                .foregroundStyle(prominent ? AnyShapeStyle(.black) : AnyShapeStyle(Theme.accent))
        }
        .buttonStyle(.plain)
    }

    private var humanMeldsRow: some View {
        let melds = state.tableMelds.filter { $0.ownerSeat == viewModel.humanSeat }
        return Group {
            if !melds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(melds) { tableMeld in
                            MiniMeldView(meld: tableMeld.meld)
                                .onTapGesture { handleMeldTap(tableMeld) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 30)
            }
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
        zoomedMeldID = tableMeld.id
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
                proposerName: state.players[proposer].name
            ) { play in
                Haptics.action()
                viewModel.apply(.declareIntent(play: play))
            }
        case .roundEnded(let result):
            RoundEndView(state: state, result: result) {
                Haptics.success()
                withAnimation(reduceMotion ? .default : .cardSpring) {
                    viewModel.apply(.startNextRound)
                }
            }
        case .matchEnded(let placements):
            GameEndView(state: state, placements: placements) { dismiss() }
        default:
            EmptyView()
        }
        if let note = viewModel.lastBotNote {
            VStack {
                Text(note)
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 54)
                Spacer()
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
        if let error = viewModel.lastError {
            VStack {
                Spacer()
                Text(errorMessage(error))
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 200)
            }
            .transition(.opacity)
            .onAppear {
                Task {
                    try? await Task.sleep(for: .seconds(2.2))
                    withAnimation { viewModel.lastError = nil }
                }
            }
        }
    }

    private func errorMessage(_ error: RamiError) -> String {
        switch error {
        case .thresholdNotMet(let required, let got):
            "Need \(required) — you have \(got)"
        case .throwTakeLocked: "Taking unlocks after the first full turn"
        case .mustLayDownWithTake: "Lay down to take that card"
        case .meldFull: "Melds hold at most 5 cards"
        case .cannotAppendHere: "Doesn't fit this meld"
        case .jokerPending: "Play the swapped joker first"
        case .mustKeepACardToThrow: "Keep one card to throw"
        case .invalidMeld: "Not valid melds"
        default: "Not allowed"
        }
    }
}

/// A card back that flies from the pile to a seat, then fades.
private struct DealFlightCard: View {
    let delay: Double
    let from: CGPoint
    let to: CGPoint
    @State private var flown = false

    var body: some View {
        CardBackView()
            .frame(width: 34)
            .position(flown ? to : from)
            .opacity(flown ? 0 : 1)
            .animation(.easeIn(duration: 0.34).delay(delay), value: flown)
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
