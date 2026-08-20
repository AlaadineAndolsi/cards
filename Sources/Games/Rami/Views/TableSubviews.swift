import SwiftUI

/// A bot seat: avatar, name, score chip, dealer badge, hand-count, active ring,
/// and that player's mini-melds stacked beside it.
struct SeatView: View {
    let player: PlayerState
    let isDealer: Bool
    let isActive: Bool
    let melds: [TableMeld]
    let meldsOnLeft: Bool
    let onMeldTap: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            if meldsOnLeft { meldColumn }
            avatar
            if !meldsOnLeft { meldColumn }
        }
    }

    private var avatar: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 46, height: 46)
                    .overlay(
                        Text(String(player.name.prefix(1)))
                            .font(.system(.title3, design: .serif).weight(.bold))
                            .foregroundStyle(.white))
                    .overlay(
                        Circle().strokeBorder(
                            isActive ? Theme.accent : Color.white.opacity(0.15),
                            lineWidth: isActive ? 2.5 : 1))
                    .shadow(color: isActive ? Theme.accent.opacity(0.55) : .clear, radius: 7)
                if isDealer {
                    Text("D")
                        .font(.system(size: 9, weight: .black))
                        .padding(4)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.black)
                        .offset(x: 4, y: -3)
                }
            }
            Text(player.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 4) {
                Text("\(player.totalScore)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(Theme.accent)
                Label("\(player.handCountLabel)", systemImage: "rectangle.portrait.on.rectangle.portrait.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .labelStyle(.titleAndIcon)
            }
        }
        .animation(.cardSpring, value: isActive)
    }

    private var meldColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(melds.prefix(5)) { tableMeld in
                MiniMeldView(meld: tableMeld.meld)
                    .onTapGesture { onMeldTap(tableMeld.id) }
            }
        }
        .frame(width: 74, alignment: meldsOnLeft ? .trailing : .leading)
    }
}

private extension PlayerState {
    var handCountLabel: String { "\(hand.count)" }
}

struct EliminatedSeatView: View {
    let name: String

    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(Color.white.opacity(0.04))
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "xmark").foregroundStyle(.red.opacity(0.7)))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Text(L10n.eliminated)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.red.opacity(0.7))
        }
    }
}

/// A player's meld rendered as tiny readable chips (rank + suit glyph).
struct MiniMeldView: View {
    let meld: Meld

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(meld.entries, id: \.card.id) { entry in
                VStack(spacing: -1) {
                    Text(entry.card.isJoker ? "★" : entry.asRank.label)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    Text(entry.asSuit.symbol)
                        .font(.system(size: 7.5))
                }
                .foregroundStyle(entry.asSuit.isRed ? Color(red: 0.9, green: 0.15, blue: 0.15) : .black)
                .frame(width: 13, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5)
                                .strokeBorder(
                                    entry.card.isJoker ? Theme.accent : Color.black.opacity(0.15),
                                    lineWidth: entry.card.isJoker ? 1 : 0.5)))
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// One player's throw stack in the center: last card prominent, small depth
/// hint underneath, tap to expand the full history.
struct ThrowStackView: View {
    let cards: [Card]
    let isTakeable: Bool
    let onTap: () -> Void

    var body: some View {
        ZStack {
            if cards.isEmpty {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .frame(width: 40, height: 54)
            } else {
                ForEach(Array(cards.suffix(3).enumerated()), id: \.element.id) { index, card in
                    CardView(card: card)
                        .frame(width: 40)
                        .rotationEffect(.degrees(Double(index) * 4 - 4))
                        .offset(x: CGFloat(index) * 2 - 2)
                }
                if cards.count > 1 {
                    Text("\(cards.count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .padding(3)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                        .offset(x: 22, y: -24)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isTakeable ? Theme.accent : .clear, lineWidth: 2)
                .shadow(color: isTakeable ? Theme.accent.opacity(0.6) : .clear, radius: 6)
                .frame(width: 46, height: 60))
        .onTapGesture { if !cards.isEmpty { onTap() } }
    }
}

/// Face-down draw pile with remaining count. Tap = purchase.
struct PileView: View {
    let count: Int
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    ForEach(0..<3) { index in
                        CardBackView()
                            .frame(width: 46)
                            .offset(x: CGFloat(index) * -1.5, y: CGFloat(index) * -1.5)
                    }
                }
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(x: 6, y: 6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(enabled ? Theme.accent : .clear, lineWidth: 2)
                    .shadow(color: enabled ? Theme.accent.opacity(0.5) : .clear, radius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L10n.pile): \(count)")
    }
}

/// The human hand: overlapping fan, tap to select, drag to reorder, sort buttons.
struct HandView: View {
    @State var viewModel: RamiGameViewModel
    @State private var draggedCardID: Int?

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                sortButton("arrow.up.arrow.down", action: viewModel.sortHandByRank, label: "123")
                sortButton("suit.spade.fill", action: viewModel.sortHandBySuit, label: "♠♥")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: -22) {
                    ForEach(viewModel.humanHand) { card in
                        let selected = viewModel.selectedCardIDs.contains(card.id)
                        CardView(card: card)
                            .frame(width: 52)
                            .shadow(color: .black.opacity(0.4), radius: 3, x: -2, y: 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
                            .offset(y: selected ? -16 : 0)
                            .onTapGesture { viewModel.toggleSelection(card) }
                            .draggable(String(card.id)) {
                                CardView(card: card).frame(width: 52)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let idText = items.first, let sourceID = Int(idText),
                                      sourceID != card.id else { return false }
                                var order = viewModel.humanHand.map(\.id)
                                guard let from = order.firstIndex(of: sourceID),
                                      let to = order.firstIndex(of: card.id) else { return false }
                                order.remove(at: from)
                                order.insert(sourceID, at: to > from ? to : to)
                                viewModel.handOrder = order
                                Haptics.tap()
                                return true
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 2)
            }
            .frame(height: 96)
        }
        .animation(.cardSpring, value: viewModel.humanHand.map(\.id))
        .animation(.cardSpring, value: viewModel.selectedCardIDs)
    }

    private func sortButton(_ symbol: String, action: @escaping () -> Void, label: String) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.cardSpring) { action() }
        } label: {
            Label(label, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// Contextual actions: only legal moves surface.
struct ActionBarView: View {
    @State var viewModel: RamiGameViewModel
    let reduceMotion: Bool

    private var state: RamiState { viewModel.state }

    var body: some View {
        HStack(spacing: 8) {
            switch viewModel.humanStage {
            case .awaitingDraw:
                drawButtons
            case .awaitingThrow:
                meldPhaseButtons
            case nil:
                EmptyView()
            }
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 12)
        .animation(.cardSpring, value: viewModel.selectedCardIDs)
    }

    @ViewBuilder
    private var drawButtons: some View {
        actionButton(L10n.purchase, prominent: true) {
            viewModel.apply(.drawFromPile)
        }
        if state.throwTakeUnlocked, viewModel.takeableThrow != nil {
            if state.players[viewModel.humanSeat].hasLaidDown {
                actionButton(L10n.takeThrow) {
                    viewModel.apply(.takeThrow)
                }
            } else if let selection = viewModel.selectedMelds, viewModel.selectionIncludesTakeable {
                actionButton("\(L10n.takeAndLayDown) (\(selection.total))",
                             prominent: selection.total >= state.requiredLayDown) {
                    viewModel.apply(.takeThrowAndLayDown(melds: selection.melds))
                }
            } else {
                hint("Select melds including the last throw to take it")
            }
        }
    }

    @ViewBuilder
    private var meldPhaseButtons: some View {
        let selectedCount = viewModel.selectedCardIDs.count
        if selectedCount == 0 {
            hint("Select cards to lay down, or one card to throw")
        } else if selectedCount == 1,
                  let card = state.players[viewModel.humanSeat].hand.first(where: {
                      viewModel.selectedCardIDs.contains($0.id)
                  }) {
            actionButton(L10n.throwCard, prominent: true) {
                viewModel.apply(.throwCard(card))
            }
            if !state.tableMelds.isEmpty, state.players[viewModel.humanSeat].hasLaidDown {
                hint("or tap a meld to add this card")
            }
        }
        if selectedCount >= Meld.minSize {
            if let selection = viewModel.selectedMelds, !viewModel.selectionIncludesTakeable {
                let needsThreshold = !state.players[viewModel.humanSeat].hasLaidDown
                let meets = !needsThreshold || selection.total >= state.requiredLayDown
                actionButton("\(L10n.layDown) (\(selection.total))", prominent: meets) {
                    viewModel.apply(.layDown(melds: selection.melds))
                }
            } else if !viewModel.selectionIncludesTakeable {
                hint("Selection is not valid melds")
            }
        }
    }

    private func actionButton(
        _ title: String, prominent: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.action()
            withAnimation(reduceMotion ? .default : .cardSpring) { action() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(
                    prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.ultraThinMaterial),
                    in: Capsule())
                .foregroundStyle(prominent ? .black : Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.25), in: Capsule())
    }
}
