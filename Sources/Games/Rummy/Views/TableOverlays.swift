import SwiftUI

/// Dealer flow when the human deals: repeatable shuffle + the 5 patterns.
struct DealControlsView: View {
    let shuffles: Int
    @Binding var shufflePulse: Int
    let onAction: (RummyAction) -> Void
    @State private var showPatternInfo = false

    var body: some View {
        VStack {
            Spacer()
            Theme.panel {
                VStack(spacing: 10) {
                    Text("You deal this round")
                        .font(.subheadline.weight(.bold))
                    Button {
                        shufflePulse += 1
                        onAction(.shuffle)
                    } label: {
                        Label("\(L10n.shuffle)\(shuffles > 0 ? " ×\(shuffles)" : "")",
                              systemImage: "shuffle")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .symbolEffect(.bounce, value: shufflePulse)
                    VStack(spacing: 2) {
                        HStack(spacing: 4) {
                            Text(L10n.dealPattern)
                                .font(.caption.weight(.semibold))
                            Button {
                                withAnimation(.cardSpring) { showPatternInfo.toggle() }
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Text("cards per pass — +N goes to the dealer at the end")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if showPatternInfo {
                            Text(L10n.dealPatternInfo)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(8)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(.top, 4)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    let patterns = DealPattern.allCases
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            patternButton(patterns[0])
                            patternButton(patterns[1])
                        }
                        HStack(spacing: 6) {
                            patternButton(patterns[2])
                            patternButton(patterns[3])
                        }
                        // The fifth pattern sits centered on its own row.
                        patternButton(patterns[4])
                            .frame(maxWidth: 150)
                    }
                }
            }
            .padding(.horizontal, 16)
            // Low enough that the shuffling deck stays visible above it.
            .padding(.bottom, 30)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// One pattern as a roomy card: the rhythm digits big, the dealer bonus
    /// spelled out underneath.
    private func patternButton(_ pattern: DealPattern) -> some View {
        let parts = pattern.label.split(separator: " ")
        let digits = String(parts.first ?? "")
        let bonus = parts.count > 1 ? String(parts[1]) : nil
        return Button {
            onAction(.deal(pattern))
        } label: {
            VStack(spacing: 3) {
                Text(digits)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text(bonus.map { "\($0) dealer" } ?? "even passes")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Round-pass vote: play / propose, or confirm / decline someone's proposal.
struct VotePanelView: View {
    let isProposer: Bool
    let proposerName: String
    let canForcePass: Bool
    let onVote: (Bool) -> Void
    let onForcePass: () -> Void

    var body: some View {
        VStack {
            Spacer()
            Theme.panel {
                VStack(spacing: 14) {
                    Text(isProposer
                         ? "Play this round, or propose a redeal?"
                         : "\(proposerName) proposes a redeal")
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
                    if canForcePass {
                        Button(action: onForcePass) {
                            Text(L10n.forcePass)
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(.red.opacity(0.8), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .opacity(0.9)
            .padding(.horizontal, 20)
            .padding(.bottom, 170)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Round-end overlay: closer, deltas, running totals, eliminations.
struct RoundEndView: View {
    let state: RummyState
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
    let state: RummyState
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
    let state: RummyState

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
                    gestureGuide
                }
                .padding(18)
            }
            .navigationTitle(L10n.stats)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
        }
    }

    /// Everything on the table is gesture-driven; the reference lives here.
    private var gestureGuide: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Gestures")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
            gestureRow("hand.tap", "Tap — select / unlock")
            gestureRow("lock.fill", "Long-press — lock a meld")
            gestureRow("arrow.left.arrow.right", "Drag sideways — reorder")
            gestureRow("arrow.up", "Slide up — discard")
            gestureRow("arrow.up.square.fill", "Slide a meld up — lay down")
            gestureRow("hand.point.down.fill", "Slide the discard down — pick it up")
            gestureRow("rectangle.stack.fill", "Tap the stock — purchase")
            gestureRow("plus.rectangle.on.rectangle", "Hold card over melds — add")
            gestureRow("xmark.circle", "✕ — reset selection & locks")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func gestureRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}
