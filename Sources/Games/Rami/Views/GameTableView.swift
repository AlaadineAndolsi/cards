import SwiftUI

/// The table: circular seating (human bottom, bots right/top/left in turn
/// order), throw stacks in the center, pile bottom-left, stats bottom-right,
/// mini-melds beside each seat, and the human hand fanned along the bottom.
struct GameTableView: View {
    @State var viewModel: RamiGameViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showAbandonConfirm = false
    @State private var showStats = false
    @State private var expandedThrowSeat: Int?
    @State private var zoomedMeldID: UUID?
    @State private var shufflePulse = 0

    private var state: RamiState { viewModel.state }

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
        .sheet(item: $expandedThrowSeat.animation()) { seat in
            ThrowHistorySheet(player: state.players[seat], seatName: state.players[seat].name)
        }
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
        .preferredColorScheme(.dark)
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
            if let note = viewModel.lastBotNote {
                Text(note)
                    .font(.caption2)
                    .lineLimit(2)
                    .frame(maxWidth: 110)
                    .padding(6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity)
            } else {
                Color.clear.frame(width: 44, height: 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .foregroundStyle(.white)
    }

    // MARK: Table (bots + center throws)

    /// Seat display positions: offset 0 = human (bottom), then counter-clockwise
    /// right → top → left for the following seats in turn order.
    private func seatAnchor(_ offset: Int, in size: CGSize) -> CGPoint {
        let midX = size.width / 2
        switch offset {
        case 1: return CGPoint(x: size.width - 54, y: size.height * 0.40)
        case 2: return CGPoint(x: midX, y: size.height * 0.16)
        case 3: return CGPoint(x: 54, y: size.height * 0.40)
        default: return CGPoint(x: midX, y: size.height * 0.70)
        }
    }

    private func throwAnchor(_ offset: Int, in size: CGSize) -> CGPoint {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
        switch offset {
        case 1: return CGPoint(x: center.x + 62, y: center.y)
        case 2: return CGPoint(x: center.x, y: center.y - 74)
        case 3: return CGPoint(x: center.x - 62, y: center.y)
        default: return CGPoint(x: center.x, y: center.y + 74)
        }
    }

    private func seat(forOffset offset: Int) -> Int {
        (viewModel.humanSeat + offset) % state.players.count
    }

    private var activeSeat: Int? {
        switch state.phase {
        case .dealing: state.dealerSeat
        case .vote(_, let current): current
        case .turn(let seat, _): seat
        default: nil
        }
    }

    private func tableLayer(in size: CGSize) -> some View {
        ZStack {
            // Center throws, one stack leaning toward each seat.
            ForEach(1..<4) { offset in
                let seatIndex = seat(forOffset: offset)
                if !state.players[seatIndex].isEliminated {
                    SeatView(
                        player: state.players[seatIndex],
                        isDealer: state.dealerSeat == seatIndex,
                        isActive: activeSeat == seatIndex,
                        melds: state.tableMelds.filter { $0.ownerSeat == seatIndex },
                        meldsOnLeft: offset == 1,
                        onMeldTap: { zoomedMeldID = $0 })
                    .position(seatAnchor(offset, in: size))
                } else {
                    EliminatedSeatView(name: state.players[seatIndex].name)
                        .position(seatAnchor(offset, in: size))
                }
            }
            ForEach(0..<4) { offset in
                let seatIndex = seat(forOffset: offset)
                ThrowStackView(
                    cards: state.players[seatIndex].throwStack,
                    isTakeable: takeHighlight(seatIndex),
                    onTap: { expandedThrowSeat = seatIndex })
                .position(throwAnchor(offset, in: size))
            }
        }
        .animation(reduceMotion ? .default : .cardSpring, value: state)
    }

    private func takeHighlight(_ seatIndex: Int) -> Bool {
        guard viewModel.isHumanTurn, viewModel.humanStage == .awaitingDraw,
              state.throwTakeUnlocked else { return false }
        return seatIndex == state.previousAliveSeat(before: viewModel.humanSeat)
            && !state.players[seatIndex].throwStack.isEmpty
    }

    // MARK: Bottom area (melds, actions, pile/stats, hand)

    private var bottomArea: some View {
        VStack(spacing: 8) {
            humanMeldsRow
            actionBar
            HStack(alignment: .bottom) {
                PileView(count: state.drawPile.count, enabled: canPurchase) {
                    guard canPurchase else { return }
                    Haptics.action()
                    withAnimation(reduceMotion ? .default : .cardSpring) {
                        viewModel.apply(.drawFromPile)
                    }
                }
                Spacer()
                HandView(viewModel: viewModel)
                Spacer()
                Button {
                    showStats = true
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "chart.bar.fill")
                        Text(L10n.stats).font(.system(size: 9, weight: .semibold))
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 4)
    }

    private var canPurchase: Bool {
        viewModel.isHumanTurn && viewModel.humanStage == .awaitingDraw
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
                .frame(height: 34)
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

    private var actionBar: some View {
        ActionBarView(viewModel: viewModel, reduceMotion: reduceMotion)
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
        case .vote(let proposer, let current) where current == viewModel.humanSeat:
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
        if let error = viewModel.lastError {
            VStack {
                Spacer()
                Text(errorMessage(error))
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 190)
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
            "Need at least \(required) points — selection is \(got)"
        case .throwTakeLocked: "Taking unlocks after everyone has played once"
        case .mustLayDownWithTake: "Taking the throw requires laying down now"
        case .meldFull: "Melds hold at most 5 cards"
        case .cannotAppendHere: "That card doesn't fit this meld"
        case .jokerPending: "Play the swapped joker before throwing"
        case .mustKeepACardToThrow: "Keep one card to throw"
        case .invalidMeld: "Selection is not valid melds"
        default: "That move isn't allowed"
        }
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
