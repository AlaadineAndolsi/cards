import SwiftUI

struct RamiHomeView: View {
    let settings: SettingsStore
    let store: GameStore
    @State private var savedGame: RamiState?
    @State private var path = NavigationPath()

    var body: some View {
        ZStack {
            Theme.felt
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text(L10n.rami)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                VStack(spacing: 14) {
                    NavigationLink {
                        NewGameView(settings: settings, store: store)
                    } label: {
                        Label(L10n.newGame, systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.black)
                    }
                    if let savedGame {
                        NavigationLink {
                            GameTableView(viewModel: RamiGameViewModel(state: savedGame, store: store))
                        } label: {
                            Label(L10n.resumeGame, systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .padding(.horizontal, 40)
                Spacer()
                Spacer()
            }
        }
        .navigationTitle(L10n.rami)
        .navigationBarTitleDisplayMode(.inline)
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
        .task { savedGame = await store.loadActiveGame() }
    }
}

struct NewGameView: View {
    let settings: SettingsStore
    let store: GameStore
    @State private var botLevel: BotLevel = .intermediate
    @State private var startedViewModel: RamiGameViewModel?

    var body: some View {
        ZStack {
            Theme.felt
            VStack(spacing: 20) {
                Theme.panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.botLevel).font(.headline)
                        Picker(L10n.botLevel, selection: $botLevel) {
                            Text(L10n.beginner).tag(BotLevel.beginner)
                            Text(L10n.intermediate).tag(BotLevel.intermediate)
                            Text(L10n.expert).tag(BotLevel.expert)
                        }
                        .pickerStyle(.segmented)
                        Text(levelDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Theme.panel {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.minimumLayDown).font(.subheadline)
                            Spacer()
                            Text("\(settings.minimumLayDown)")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                        HStack {
                            Text(L10n.eliminationScore).font(.subheadline)
                            Spacer()
                            Text("\(settings.eliminationScore)")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                        NavigationLink {
                            SettingsView(settings: settings)
                        } label: {
                            Label(L10n.settings, systemImage: "gearshape")
                                .font(.caption)
                        }
                    }
                }
                Button {
                    Haptics.action()
                    startedViewModel = RamiGameViewModel.newGame(
                        settings: settings, botLevel: botLevel, store: store)
                } label: {
                    Label(L10n.newGame, systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.black)
                }
                Spacer()
            }
            .padding(20)
        }
        .navigationTitle(L10n.newGame)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .navigationDestination(item: $startedViewModel) { viewModel in
            GameTableView(viewModel: viewModel)
        }
    }

    private var levelDescription: String {
        switch botLevel {
        case .beginner: "Bots play their own hands and never watch yours."
        case .intermediate: "Bots remember recent throws and avoid feeding you."
        case .expert: "Bots track every visible card and play to block you."
        }
    }
}

extension RamiGameViewModel: Hashable {
    nonisolated static func == (lhs: RamiGameViewModel, rhs: RamiGameViewModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
