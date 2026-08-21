import SwiftUI

/// Dealer flow when the human deals: repeatable shuffle + the 5 patterns.
struct DealControlsView: View {
    let shuffles: Int
    @Binding var shufflePulse: Int
    let onAction: (RamiAction) -> Void

    var body: some View {
        VStack {
            Spacer()
            Theme.panel {
                VStack(spacing: 14) {
                    Text("You deal this round")
                        .font(.headline)
                    Button {
                        shufflePulse += 1
                        onAction(.shuffle)
                    } label: {
                        Label("\(L10n.shuffle)\(shuffles > 0 ? " ×\(shuffles)" : "")",
                              systemImage: "shuffle")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .symbolEffect(.bounce, value: shufflePulse)
                    Text(L10n.dealPattern)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(DealPattern.allCases, id: \.self) { pattern in
                            Button {
                                onAction(.deal(pattern))
                            } label: {
                                Text(pattern.label)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 9)
                                    .frame(maxWidth: .infinity)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 180)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Round-pass vote: play / propose, or confirm / decline someone's proposal.
struct VotePanelView: View {
    let isProposer: Bool
    let proposerName: String
    let onVote: (Bool) -> Void

    var body: some View {
        VStack {
            Spacer()
            Theme.panel {
                VStack(spacing: 14) {
                    Text(isProposer
                         ? "Play this round, or propose to pass it?"
                         : "\(proposerName) proposes to pass the round")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button {
                            onVote(true)
                        } label: {
                            Text(isProposer ? L10n.play : L10n.decline)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        Button {
                            onVote(false)
                        } label: {
                            Text(isProposer ? L10n.proposePass : L10n.confirmPass)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 170)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Round-end overlay: closer, deltas, running totals, eliminations.
struct RoundEndView: View {
    let state: RamiState
    let result: RoundResult
    let onNext: () -> Void
    @State private var revealed = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            Theme.panel {
                VStack(spacing: 14) {
                    Text(L10n.roundOver)
                        .font(.system(.title2, design: .serif).weight(.bold))
                    if let closer = result.closerSeat {
                        Label("\(state.players[closer].name) \(L10n.closed)", systemImage: "crown.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Grid(horizontalSpacing: 14, verticalSpacing: 8) {
                        ForEach(state.players.indices, id: \.self) { seat in
                            let player = state.players[seat]
                            GridRow {
                                Text(player.name)
                                    .font(.subheadline.weight(.semibold))
                                    .gridColumnAlignment(.leading)
                                Group {
                                    if player.isEliminated && !result.newlyEliminated.contains(seat)
                                        && result.deltas[seat] == 0 && player.roundScores.last == nil {
                                        Text("—")
                                    } else {
                                        Text("+\(result.deltas[seat])")
                                            .foregroundStyle(result.deltas[seat] == 0 ? Theme.accent : .primary)
                                    }
                                }
                                .font(.system(.subheadline, design: .monospaced))
                                Text("\(player.totalScore)")
                                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                    .contentTransition(.numericText())
                                if result.newlyEliminated.contains(seat) {
                                    Text(L10n.eliminated)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.red)
                                } else {
                                    Text("")
                                }
                            }
                        }
                    }
                    .opacity(revealed ? 1 : 0)
                    Button(action: onNext) {
                        Text(L10n.nextRound)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6).delay(0.25)) { revealed = true }
        }
    }
}

/// Final ranking when the second player dies.
struct GameEndView: View {
    let state: RamiState
    let placements: [FinalPlacement]
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            Theme.panel {
                VStack(spacing: 16) {
                    Text(L10n.gameOver)
                        .font(.system(.title, design: .serif).weight(.bold))
                    ForEach(placements, id: \.seat) { placement in
                        HStack {
                            Text(medal(placement.place))
                            Text(state.players[placement.seat].name)
                                .font(.headline)
                            Spacer()
                            Text("\(placement.score)")
                                .font(.system(.headline, design: .monospaced))
                                .foregroundStyle(placement.place <= 2 ? Theme.accent : .secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            placement.place == 1 ? Theme.accent.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("The two survivors win together.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: onExit) {
                        Text(L10n.newGame)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }
            .padding(.horizontal, 28)
        }
        .transition(.opacity)
    }

    private func medal(_ place: Int) -> String {
        switch place {
        case 1: "🥇"
        case 2: "🥈"
        case 3: "🥉"
        default: "4."
        }
    }
}

/// Live score table for the current match.
struct ScoreSheetView: View {
    let state: RamiState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Label("\(L10n.required): \(state.requiredLayDown)", systemImage: "target")
                        Spacer()
                        Label("\(L10n.pile): \(state.drawPile.count)", systemImage: "rectangle.stack")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            Text(L10n.round).font(.caption2).foregroundStyle(.secondary)
                            ForEach(state.players.indices, id: \.self) { seat in
                                VStack(spacing: 1) {
                                    Text(state.players[seat].name)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    if state.players[seat].isEliminated {
                                        Text(L10n.eliminated)
                                            .font(.system(size: 7, weight: .bold))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        let rounds = state.players.map(\.roundScores.count).max() ?? 0
                        ForEach(0..<rounds, id: \.self) { round in
                            GridRow {
                                Text("\(round + 1)").font(.caption2).foregroundStyle(.secondary)
                                ForEach(state.players.indices, id: \.self) { seat in
                                    let scores = state.players[seat].roundScores
                                    let value = round < scores.count ? scores[round] : nil
                                    Text(value.map(String.init) ?? "—")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(value == 0 ? Theme.accent : .primary)
                                }
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("Σ").font(.caption.weight(.bold))
                            ForEach(state.players.indices, id: \.self) { seat in
                                Text("\(state.players[seat].totalScore)")
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                    .foregroundStyle(
                                        state.players[seat].totalScore >= state.config.eliminationScore
                                            ? .red : .primary)
                            }
                        }
                    }
                    Text("\(L10n.eliminationScore): \(state.config.eliminationScore)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .navigationTitle(L10n.stats)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
        }
    }
}

/// Zoomed meld for reading, appending, and joker swapping.
struct MeldZoomSheet: View {
    @State var viewModel: RamiGameViewModel
    let meldID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = viewModel.state
        VStack(spacing: 16) {
            if let tableMeld = state.tableMelds.first(where: { $0.id == meldID }) {
                Text("\(state.players[tableMeld.ownerSeat].name)'s meld")
                    .font(.headline)
                HStack(spacing: 6) {
                    ForEach(tableMeld.meld.entries, id: \.card.id) { entry in
                        VStack(spacing: 3) {
                            CardView(card: entry.card)
                                .frame(width: 56)
                            if entry.card.isJoker {
                                Text("as \(entry.asRank.label)\(entry.asSuit.symbol)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                if viewModel.isHumanTurn, case .awaitingThrow = viewModel.humanStage,
                   state.players[viewModel.humanSeat].hasLaidDown {
                    meldActions(tableMeld: tableMeld, state: state)
                }
            } else {
                Text("Meld updated").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func meldActions(tableMeld: TableMeld, state: RamiState) -> some View {
        let hand = state.players[viewModel.humanSeat].hand
        let selected = hand.first { viewModel.selectedCardIDs.contains($0.id) }
        // Append the single selected card when it fits.
        if viewModel.selectedCardIDs.count == 1, let card = selected {
            let entry: MeldEntry? = card.isJoker
                ? tableMeld.meld.jokerEntryToExtend(joker: card)
                : card.rank.flatMap { rank in
                    card.suit.map { MeldEntry(card: card, asRank: rank, asSuit: $0) }
                }
            if let entry, tableMeld.meld.inserting(entry) != nil {
                Button {
                    Haptics.action()
                    viewModel.apply(.appendCard(entry, meldID: tableMeld.id))
                    dismiss()
                } label: {
                    Label(L10n.addToMeld, systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
        // Swap a joker for its real card from hand.
        ForEach(tableMeld.meld.entries.filter(\.card.isJoker), id: \.card.id) { entry in
            if let real = hand.first(where: { $0.rank == entry.asRank && $0.suit == entry.asSuit }) {
                Button {
                    Haptics.action()
                    viewModel.apply(.swapJoker(meldID: tableMeld.id, realCard: real))
                    dismiss()
                } label: {
                    Label("\(L10n.swapJoker) — use \(entry.asRank.label)\(entry.asSuit.symbol)",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }
}
