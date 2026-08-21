import SwiftUI

/// Game hub: Rummy playable, Chkobba teased. Settings top-right, history
/// top-left — mirrored on the Rummy home for consistency.
struct HubView: View {
    @State private var settings = SettingsStore()
    @State private var store = GameStore()
    @State private var chkobbaBounce = false
    @State private var showChkobbaToast = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.felt
                VStack(spacing: 22) {
                    Spacer(minLength: 8)
                    Text(L10n.appTitle)
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                        .foregroundStyle(.white)
                    fannedCards
                        .frame(height: 110)
                    NavigationLink {
                        RummyHomeView(settings: settings, store: store)
                    } label: {
                        GameCard(
                            title: L10n.rummy,
                            subtitle: "108 cards · 1 vs 3 bots",
                            symbol: "suit.spade.fill",
                            enabled: true)
                    }
                    .buttonStyle(.plain)
                    GameCard(
                        title: L10n.chkobba,
                        subtitle: "10 cards · classic capture",
                        symbol: "suit.club.fill",
                        enabled: false)
                    .scaleEffect(chkobbaBounce ? 1.03 : 1)
                    .onTapGesture {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) {
                            chkobbaBounce = true
                        }
                        withAnimation(.spring(response: 0.3).delay(0.12)) {
                            chkobbaBounce = false
                        }
                        showChkobbaToast = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.8))
                            withAnimation { showChkobbaToast = false }
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                if showChkobbaToast {
                    VStack {
                        Spacer()
                        Text(L10n.chkobbaToast)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 30)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        HistoryView(store: store)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(settings: settings)
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .tint(Theme.accent)
        }
    }

    private var fannedCards: some View {
        let deck = Card.fullDeck()
        return ZStack {
            ForEach(Array([12, 24, 51, 0].enumerated()), id: \.offset) { index, cardID in
                CardView(card: deck[cardID])
                    .frame(width: 68)
                    .rotationEffect(.degrees(Double(index) * 14 - 21), anchor: .bottom)
                    .offset(x: CGFloat(index) * 16 - 24)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            }
        }
    }
}

private struct GameCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(enabled ? Theme.accent : .secondary)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if enabled {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.comingSoon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(enabled ? 0.14 : 0.07), lineWidth: 1))
        .opacity(enabled ? 1 : 0.75)
    }
}
