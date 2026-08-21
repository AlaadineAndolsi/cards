import SwiftUI

/// All past matches, newest first, with the in-progress match pinned on top.
struct HistoryView: View {
    let store: GameStore
    @State private var records: [MatchRecord] = []
    @State private var activeGame: RummyState?

    var body: some View {
        ZStack {
            Theme.felt
            ScrollView {
                VStack(spacing: 14) {
                    if let active = activeGame {
                        NavigationLink {
                            GameTableView(viewModel: RummyGameViewModel(state: active, store: store))
                        } label: {
                            activeCard(active)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(records) { record in
                        NavigationLink {
                            MatchDetailView(record: record)
                        } label: {
                            recordCard(record)
                        }
                        .buttonStyle(.plain)
                    }
                    if records.isEmpty && activeGame == nil {
                        ContentUnavailableView(
                            "No games yet", systemImage: "clock.arrow.circlepath",
                            description: Text("Finished matches will appear here."))
                        .padding(.top, 60)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(L10n.history)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .task {
            records = await store.loadHistory()
            activeGame = await store.loadActiveGame()
        }
    }

    private func activeCard(_ state: RummyState) -> some View {
        Theme.panel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.inProgress, systemImage: "play.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                    Text("\(L10n.round) \(state.roundNumber) · \(state.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(L10n.resume)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }

    private func recordCard(_ record: MatchRecord) -> some View {
        let winner = record.placements.first.map { record.playerNames[$0.seat] } ?? "—"
        return Theme.panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(record.endedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Label(winner, systemImage: "crown.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                HStack(spacing: 10) {
                    ForEach(record.placements, id: \.seat) { placement in
                        let name = record.playerNames[placement.seat]
                        Text("\(placement.place). \(name) (\(placement.score))")
                            .font(.caption2)
                            .foregroundStyle(placement.place == 1 ? Theme.accent : .secondary)
                    }
                }
                Text("Rules: \(record.config.minimumLayDown) / \(record.config.eliminationScore) · Level \(record.config.botLevel.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Full per-round score table for one match.
struct MatchDetailView: View {
    let record: MatchRecord

    var body: some View {
        ZStack {
            Theme.felt
            ScrollView {
                Theme.panel {
                    Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text(L10n.round).font(.caption2).foregroundStyle(.secondary)
                            ForEach(record.playerNames.indices, id: \.self) { seat in
                                Text(record.playerNames[seat])
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        let roundCount = record.roundScores.map(\.count).max() ?? 0
                        ForEach(0..<roundCount, id: \.self) { round in
                            GridRow {
                                Text("\(round + 1)").font(.caption2).foregroundStyle(.secondary)
                                ForEach(record.playerNames.indices, id: \.self) { seat in
                                    let scores = record.roundScores[seat]
                                    let value = round < scores.count ? scores[round] : nil
                                    Text(value.map(String.init) ?? "—")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(value == 0 ? Theme.accent : .primary)
                                }
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("Total").font(.caption2.weight(.bold))
                            ForEach(record.playerNames.indices, id: \.self) { seat in
                                let eliminated = record.placements
                                    .first { $0.seat == seat }.map { $0.place > 2 } ?? false
                                VStack(spacing: 2) {
                                    Text("\(record.finalScores[seat])")
                                        .font(.system(.caption, design: .monospaced).weight(.bold))
                                    if eliminated {
                                        Text(L10n.eliminated)
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(record.endedAt.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }
}
