import SwiftUI

/// A bot seat: avatar, name, score chip, hand count, dealer badge, active ring.
struct SeatView: View {
    let player: PlayerState
    let isDealer: Bool
    let isActive: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(String(player.name.prefix(1)))
                            .font(.system(size: 16, design: .serif).weight(.bold))
                            .foregroundStyle(.white))
                    .overlay(
                        Circle().strokeBorder(
                            isActive ? Theme.accent : Color.white.opacity(0.2),
                            lineWidth: isActive ? 2.5 : 1))
                    .shadow(color: isActive ? Theme.accent.opacity(0.55) : .clear, radius: 7)
                if isDealer {
                    Text("D")
                        .font(.system(size: 8, weight: .black))
                        .padding(3)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(.black)
                        .offset(x: 4, y: -3)
                }
            }
            Text(player.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 3) {
                Text("\(player.totalScore)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .foregroundStyle(Theme.accent)
                Label("\(player.hand.count)", systemImage: "rectangle.portrait.on.rectangle.portrait.fill")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .animation(.cardSpring, value: isActive)
    }
}

/// Popup: each player's most recent throw.
struct LastThrowsView: View {
    let players: [(name: String, card: Card?)]

    init(players: [(name: String, card: Card?)]) {
        self.players = players
        #if DEBUG
        print("RAMI LastThrowsView init with \(players.count) players")
        #endif
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(players, id: \.name) { entry in
                VStack(spacing: 4) {
                    if let card = entry.card {
                        CardView(card: card).frame(width: 48)
                    } else {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary.opacity(0.4),
                                          style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .frame(width: 48, height: 65)
                    }
                    Text(entry.name)
                        .font(.system(size: 9, weight: .semibold))
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

struct EliminatedSeatView: View {
    let name: String

    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .fill(Color.black.opacity(0.12))
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "xmark").foregroundStyle(.red.opacity(0.7)))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// A player's laid melds stacked along their own side of the table.
struct SideMeldsView: View {
    let melds: [TableMeld]
    let horizontal: Bool
    let onTap: (UUID) -> Void

    var body: some View {
        Group {
            if horizontal {
                HStack(spacing: 4) { chips }
            } else {
                VStack(spacing: 4) { chips }
            }
        }
    }

    private var chips: some View {
        ForEach(melds.prefix(4)) { tableMeld in
            MiniMeldView(meld: tableMeld.meld)
                .onTapGesture { onTap(tableMeld.id) }
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

/// One player's last thrown card, aligned with their seat. Tapping the
/// previous player's card takes it (when legal).
struct ThrowSpotView: View {
    let card: Card?
    let highlighted: Bool
    let namespace: Namespace.ID
    let onTap: () -> Void
    let onTake: () -> Void

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            // Slide the thrown card down toward your hand to take it —
            // the mirror of sliding a hand card up to throw.
            .gesture(
                DragGesture(minimumDistance: 15).onEnded { value in
                    if value.translation.height > 55 { onTake() }
                })
    }

    private var content: some View {
        ZStack {
            if let card {
                CardView(card: card)
                    .matchedGeometryEffect(id: card.id, in: namespace)
                    .frame(width: 66)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .frame(width: 66, height: 90)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(highlighted ? Theme.accent : .clear, lineWidth: 2.5)
                .shadow(color: highlighted ? Theme.accent.opacity(0.6) : .clear, radius: 7)
                .frame(width: 74, height: 98))
    }
}

/// Face-down draw pile with a clear remaining count below. Tap = purchase.
struct PileView: View {
    let count: Int
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack {
                    ForEach(0..<3) { index in
                        CardBackView()
                            .frame(width: 46)
                            .offset(x: CGFloat(index) * -1.5, y: CGFloat(index) * -1.5)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(enabled ? Theme.accent : .clear, lineWidth: 2.5)
                        .shadow(color: enabled ? Theme.accent.opacity(0.5) : .clear, radius: 6)
                        .frame(width: 54, height: 72))
                Text("\(count)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(L10n.pile): \(count)")
    }
}

/// The human hand as an arc. Tap selects, dragging sideways reorders,
/// sliding a card upward throws it.
struct ArcHandView: View {
    @State var viewModel: RamiGameViewModel
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @State private var draggedID: Int?
    @State private var dragStartX: CGFloat = 0
    @State private var dragTranslation: CGSize = .zero

    private let cardWidth: CGFloat = 70
    private let handHeight: CGFloat = 200

    var body: some View {
        GeometryReader { geometry in
            let cards = viewModel.humanHand
            let count = max(cards.count, 1)
            let width = geometry.size.width
            let step = count > 1 ? min(42, (width - cardWidth - 20) / CGFloat(count - 1)) : 0
            let baseY = handHeight - 104

            ZStack {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    let centerOffset = CGFloat(index) - CGFloat(count - 1) / 2
                    let isDragged = draggedID == card.id
                    let selected = viewModel.selectedCardIDs.contains(card.id)
                    let locked = viewModel.lockedCardIDs.contains(card.id)
                    let x = isDragged
                        ? dragStartX + dragTranslation.width
                        : width / 2 + centerOffset * step
                    let y = baseY
                        + pow(centerOffset, 2) * 0.95         // arc: edges dip
                        + (selected ? -22 : 0)
                        + (isDragged ? dragTranslation.height : 0)

                    CardView(card: card)
                        .matchedGeometryEffect(id: card.id, in: namespace)
                        .frame(width: cardWidth)
                        .shadow(color: .black.opacity(0.4), radius: 3, x: -2, y: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    selected ? Theme.accent : (locked ? Color.green : .clear),
                                    lineWidth: 2.5))
                        .rotationEffect(.degrees(isDragged ? 0 : centerOffset * 3.0))
                        .scaleEffect(isDragged ? 1.1 : 1)
                        .position(x: x, y: y)
                        // Classic fan: each card shows its left part with the
                        // index on top; the card to the right overlaps it.
                        .zIndex(isDragged ? 100 : Double(index))
                        .onTapGesture { viewModel.toggleSelection(card) }
                        .gesture(dragGesture(for: card, index: index, step: step, width: width))
                }
            }
            .animation(.cardSpring, value: cards.map(\.id))
            .animation(.cardSpring, value: viewModel.selectedCardIDs)
        }
        .frame(height: handHeight)
    }

    private func dragGesture(for card: Card, index: Int, step: CGFloat, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let cards = viewModel.humanHand
                if draggedID != card.id {
                    draggedID = card.id
                    let count = CGFloat(cards.count - 1)
                    let centerOffset = CGFloat(index) - count / 2
                    dragStartX = width / 2 + centerOffset * step
                }
                dragTranslation = value.translation
                // Live reorder while sliding sideways.
                guard step > 0, abs(value.translation.height) < 60 else { return }
                guard let current = cards.firstIndex(where: { $0.id == card.id }) else { return }
                let target = max(0, min(cards.count - 1,
                    Int(round((dragStartX + value.translation.width - width / 2) / step
                        + CGFloat(cards.count - 1) / 2))))
                if target != current {
                    var order = cards.map(\.id)
                    order.remove(at: current)
                    order.insert(card.id, at: target)
                    withAnimation(.cardSpring) { viewModel.handOrder = order }
                }
            }
            .onEnded { value in
                let translation = value.translation
                withAnimation(.cardSpring) {
                    draggedID = nil
                    dragTranslation = .zero
                }
                // Slide up = throw. Generous drop zone: any clear upward slide.
                if translation.height < -45, viewModel.canThrow {
                    Haptics.action()
                    withAnimation(reduceMotion ? .default : .cardSpring) {
                        viewModel.apply(.throwCard(card))
                    }
                }
            }
    }
}
