import SwiftUI

/// A bot seat: avatar, name, score chip, hand count, dealer badge, active ring.
struct SeatView: View {
    let player: PlayerState
    /// Shown count — during the deal animation it ticks up with the cards.
    let handCount: Int
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
                Label("\(handCount)", systemImage: "rectangle.portrait.on.rectangle.portrait.fill")
                    .font(.system(size: 7.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .animation(.cardSpring, value: isActive)
    }
}

/// Popup: each player's most recent throw. Tapping anywhere closes it.
struct LastThrowsView: View {
    let players: [(name: String, card: Card?)]

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
    var pendingHighlight: Bool = false
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
            MiniMeldView(meld: tableMeld.meld, pending: pendingHighlight)
                .onTapGesture { onTap(tableMeld.id) }
        }
    }
}

extension Meld {
    /// Display arrangement everywhere melds render: biggest at the LEFT;
    /// in sets the minority ("different") color leads, and on a two-red /
    /// two-black split the black cards lead. Runs stay consecutive.
    var displayEntries: [MeldEntry] {
        let lowRun = entries.contains { $0.asRank == .two }
        func rankKey(_ entry: MeldEntry) -> Int {
            entry.asRank == .ace ? (lowRun ? 1 : 14) : entry.asRank.rawValue
        }
        let reds = entries.filter(\.asSuit.isRed).count
        let blacks = entries.count - reds
        func colorKey(_ entry: MeldEntry) -> Int {
            let isRed = entry.asSuit.isRed
            if reds == blacks { return isRed ? 1 : 0 }   // 2–2: black at left
            return isRed == (reds > blacks) ? 1 : 0      // minority color left
        }
        func suitOrder(_ entry: MeldEntry) -> Int {
            switch entry.asSuit {
            case .spades: 0
            case .hearts: 1
            case .clubs: 2
            case .diamonds: 3
            }
        }
        return entries.sorted {
            (rankKey($1), colorKey($0), suitOrder($0))
                < (rankKey($0), colorKey($1), suitOrder($1))
        }
    }
}

/// A player's meld rendered as tiny readable chips (rank + suit glyph).
/// Jokers read unmistakably: an amber chip with a star over the face they play.
struct MiniMeldView: View {
    let meld: Meld
    var pending = false

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(meld.displayEntries, id: \.card.id) { entry in
                VStack(spacing: -1.5) {
                    if entry.card.isJoker {
                        Image(systemName: "star.fill")
                            .font(.system(size: 6.5, weight: .black))
                        Text(entry.asRank.label)
                            .font(.system(size: 7, weight: .black, design: .rounded))
                    } else {
                        Text(entry.asRank.label)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        Text(entry.asSuit.symbol)
                            .font(.system(size: 7.5))
                    }
                }
                .foregroundStyle(
                    entry.card.isJoker
                        ? Color.black
                        : (entry.asSuit.isRed ? Color(red: 0.9, green: 0.15, blue: 0.15) : .black))
                .frame(width: 13, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(entry.card.isJoker ? Theme.accent : .white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5)
                                .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)))
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    pending ? Theme.accent.opacity(0.9) : .clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: pending ? [3] : [])))
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
/// On your draw it grows slightly and breathes instead of wearing a border.
struct PileView: View {
    let count: Int
    let enabled: Bool
    let onTap: () -> Void
    @State private var breathe = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    ForEach(0..<3) { index in
                        CardBackView()
                            .frame(width: 46)
                            .offset(x: CGFloat(index) * -1.5, y: CGFloat(index) * -1.5)
                    }
                }
                .shadow(color: enabled ? Theme.accent.opacity(0.65) : .black.opacity(0.3),
                        radius: enabled ? 10 : 4, y: 3)
                .scaleEffect(enabled ? (breathe ? 1.16 : 1.09) : 1)
                Text("\(count)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(enabled ? Theme.accent : .white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .onChange(of: enabled) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                withAnimation(.cardSpring) { breathe = false }
            }
        }
        .accessibilityLabel("\(L10n.pile): \(count)")
    }
}

/// The human hand as an arc, driven by gestures:
/// tap = select / unlock · long-press = lock the selected series ·
/// drag sideways = reorder · slide up = throw (or lay a locked series) ·
/// hold a dragged card high = big melds appear, drop on one to append.
struct ArcHandView: View {
    @State var viewModel: RummyGameViewModel
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @State private var draggedID: Int?
    @State private var dragStartX: CGFloat = 0
    @State private var dragTranslation: CGSize = .zero
    @State private var draggedGroup: [Int] = []
    @State private var didLiveReorder = false
    @State private var hoverTask: Task<Void, Never>?

    private let cardWidth: CGFloat = 70
    private let handHeight: CGFloat = 200

    var body: some View {
        GeometryReader { geometry in
            let all = viewModel.humanHand
            let cards = viewModel.dealtHandCount.map { Array(all.prefix($0)) } ?? all
            let count = max(cards.count, 1)
            let width = geometry.size.width
            let step = count > 1 ? min(42, (width - cardWidth - 20) / CGFloat(count - 1)) : 0
            let baseY = handHeight - 104

            ZStack {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    let centerOffset = CGFloat(index) - CGFloat(count - 1) / 2
                    let isDragged = draggedID == card.id
                    let inDraggedGroup = !isDragged && draggedGroup.contains(card.id)
                    let selected = viewModel.selectedCardIDs.contains(card.id)
                    let locked = viewModel.lockedCardIDs.contains(card.id)
                    let restX = width / 2 + centerOffset * step
                    let x = isDragged
                        ? dragStartX + dragTranslation.width
                        : restX + (inDraggedGroup ? dragTranslation.width : 0)
                    let y = baseY
                        + pow(centerOffset, 2) * 0.95         // arc: edges dip
                        + (selected ? -22 : 0)
                        + (locked ? 12 : 0)                    // locked series sit lower
                        + ((isDragged || inDraggedGroup) ? dragTranslation.height : 0)

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
                        .zIndex(isDragged || inDraggedGroup ? 100 + Double(index) : Double(index))
                        .onTapGesture { viewModel.toggleSelection(card) }
                        .onLongPressGesture(minimumDuration: 0.45) {
                            viewModel.longPressLock(card)
                        }
                        .gesture(dragGesture(for: card, index: index, step: step, width: width))
                }
            }
            .animation(.cardSpring, value: cards.map(\.id))
            .animation(.cardSpring, value: viewModel.selectedCardIDs)
            .animation(.cardSpring, value: viewModel.lockedSeries)
        }
        .frame(height: handHeight)
    }

    private func dragGesture(for card: Card, index: Int, step: CGFloat, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let cards = viewModel.humanHand
                let locked = viewModel.lockedCardIDs.contains(card.id)
                let inSelection = viewModel.selectedCardIDs.contains(card.id)
                    && viewModel.selectedCardIDs.count > 1
                if draggedID != card.id {
                    draggedID = card.id
                    if locked {
                        draggedGroup = viewModel.lockedGroup(containing: card.id)
                    } else if inSelection {
                        // A selected series travels together too.
                        draggedGroup = Array(viewModel.selectedCardIDs)
                    } else {
                        draggedGroup = []
                    }
                    let count = CGFloat(cards.count - 1)
                    let centerOffset = CGFloat(index) - count / 2
                    dragStartX = width / 2 + centerOffset * step
                }
                dragTranslation = value.translation
                if locked || inSelection {
                    // Groups travel as one block — no reorder.
                    return
                }
                // Hold the card high over the table → big melds fade in so the
                // card can be dropped straight onto one.
                if viewModel.canAppendToTable, value.translation.height < -60 {
                    startHoverCountdown()
                } else if value.translation.height > -40 {
                    cancelHoverCountdown(hidePreview: true)
                }
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
                    // Live reorder only — the sort stays on unless the drag
                    // ENDS as a deliberate reorder.
                    didLiveReorder = true
                    withAnimation(.cardSpring) { viewModel.handOrder = order }
                }
            }
            .onEnded { value in
                let translation = value.translation
                let locked = viewModel.lockedCardIDs.contains(card.id)
                let previewWasShown = viewModel.meldPreviewShown
                let reordered = didLiveReorder
                didLiveReorder = false
                cancelHoverCountdown(hidePreview: false)
                withAnimation(.cardSpring) {
                    draggedID = nil
                    draggedGroup = []
                    dragTranslation = .zero
                }
                if locked {
                    // Slide a locked series up = lay it (pending until the throw).
                    if translation.height < -70,
                       let seriesIndex = viewModel.lockedSeriesIndex(containing: card.id) {
                        Haptics.action()
                        withAnimation(reduceMotion ? .default : .cardSpring) {
                            viewModel.layLockedSeries(at: seriesIndex)
                        }
                    }
                    return
                }
                if viewModel.selectedCardIDs.contains(card.id),
                   viewModel.selectedCardIDs.count > 1 {
                    // Slide a selected series up = lay it directly, no lock step.
                    if translation.height < -70 {
                        withAnimation(reduceMotion ? .default : .cardSpring) {
                            viewModel.laySelectedSeries()
                        }
                    }
                    return
                }
                if previewWasShown {
                    // Drop on a big meld = append; anywhere else just closes it.
                    defer { withAnimation(.cardSpring) { viewModel.meldPreviewShown = false } }
                    if let target = viewModel.meldDropFrames.first(where: {
                        $0.value.insetBy(dx: -12, dy: -12).contains(value.location)
                    }) {
                        withAnimation(reduceMotion ? .default : .cardSpring) {
                            viewModel.appendCard(card, to: target.key)
                        }
                        return
                    }
                    if translation.height < -45 { return }  // near the preview: don't throw by accident
                }
                // Slide up = discard. Generous drop zone: any clear upward slide.
                if translation.height < -45, viewModel.canThrow {
                    Haptics.action()
                    withAnimation(reduceMotion ? .default : .cardSpring) {
                        viewModel.apply(.throwCard(card))
                    }
                    return
                }
                // The drag ended as a plain reorder: now the sort turns off.
                if reordered {
                    viewModel.commitManualReorder()
                }
            }
    }

    private func startHoverCountdown() {
        guard hoverTask == nil, !viewModel.meldPreviewShown else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            Haptics.tap()
            withAnimation(.cardSpring) { viewModel.meldPreviewShown = true }
        }
    }

    private func cancelHoverCountdown(hidePreview: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        if hidePreview, viewModel.meldPreviewShown {
            withAnimation(.cardSpring) { viewModel.meldPreviewShown = false }
        }
    }
}
