import SwiftUI

/// The complete rules of the game, readable any time from the Rummy screen.
struct RulesView: View {
    var body: some View {
        ZStack {
            Theme.felt
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("The table", "square.grid.3x3.fill", [
                        "108 cards: two full decks plus 4 jokers.",
                        "Four players — you and three bots — playing counter-clockwise.",
                        "The dealer gets 15 cards, everyone else 14.",
                    ])
                    section("Dealing & the vote", "shuffle", [
                        "The dealer shuffles as many times as they like, then deals with one of five patterns.",
                        "Before play, each player in turn says play or proposes a redeal. One player wanting to play starts the round; a unanimous agreement redeals with the next dealer.",
                        "Forced redeal: with 4 doubles, 3 doubles and a joker, or 2 doubles and two jokers, the round is redealt without a vote. A double is holding both copies of the same card.",
                    ])
                    section("The opening cycle", "arrow.triangle.2.circlepath", [
                        "The dealer opens the round by discarding their 15th card — no purchase on that turn.",
                        "Each player then purchases one card and discards one card.",
                        "Nobody may lay down or pick up a discard until the turn returns to the dealer.",
                    ])
                    section("Your turn", "hand.tap.fill", [
                        "Purchase from the stock, or pick up the previous player's discard (once unlocked).",
                        "Melds: runs of 3–5 consecutive cards of one suit, or sets of 3–4 same-rank cards of distinct suits. Once on the table a run keeps growing by appends — up to the full suit.",
                        "The ace plays low in A-2-3 and high in Q-K-A — never around the corner.",
                        "Jokers substitute any card (at most two per meld). Once you have laid down, you can swap a table joker for its real card — the joker must be replayed the same turn.",
                        "End your turn by discarding one card.",
                    ])
                    section("Laying down", "tray.and.arrow.up.fill", [
                        "Lay melds one by one whenever it is your turn — table touch: a laid meld never comes back to your hand.",
                        "The count is checked when you discard: your first lay-down must reach the required total (61 by default). Each first lay-down after another player's must beat it by one point.",
                        "Discard while short of the count and the round stops: +100 for you, 0 for everyone else.",
                        "Picking up the discard before your first lay-down commits you to laying down that turn — if no qualifying lay-down is even possible, it is an instant +100.",
                        "Going out completely (laying everything and discarding your last card) never needs the count.",
                        "After laying down, add fitting cards to any meld on the table.",
                    ])
                    section("Discard penalties", "exclamationmark.triangle.fill", [
                        "Discarding a joker, or a card that fits a meld on the table, costs +10 and the card comes back — unless you have no legal alternative.",
                    ])
                    section("Scoring & elimination", "trophy.fill", [
                        "The player who goes out scores 0. A player who never laid down takes +100 flat. Everyone else counts the cards left in hand: 2–10 at face value, J/Q/K/A and jokers 10 each.",
                        "Reach the elimination score (800 by default) and you are out. Ties die by the higher total.",
                        "When only two players remain, they both win together.",
                    ])
                    section("Settings", "gearshape.fill", [
                        "The minimum lay-down and the elimination score are configurable — a game keeps the values it started with.",
                    ])
                }
                .padding(18)
            }
        }
        .navigationTitle(L10n.rules)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }

    private func section(_ title: String, _ symbol: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(Theme.accent)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.accent.opacity(0.7))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
