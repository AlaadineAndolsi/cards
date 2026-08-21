import SwiftUI

struct RummyHomeView: View {
    let settings: SettingsStore
    let store: GameStore
    @State private var savedGame: RummyState?
    @State private var showLevelPicker = false
    @State private var startedViewModel: RummyGameViewModel?

    var body: some View {
        ZStack {
            Theme.felt
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text(L10n.rummy)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                VStack(spacing: 14) {
                    Button {
                        showLevelPicker = true
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
                            GameTableView(viewModel: RummyGameViewModel(state: savedGame, store: store))
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
        .navigationTitle(L10n.rummy)
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
        .confirmationDialog(L10n.botLevel, isPresented: $showLevelPicker, titleVisibility: .visible) {
            Button(L10n.beginner) { start(.beginner) }
            Button(L10n.intermediate) { start(.intermediate) }
            Button(L10n.expert) { start(.expert) }
            Button(L10n.cancel, role: .cancel) {}
        }
        .navigationDestination(item: $startedViewModel) { viewModel in
            GameTableView(viewModel: viewModel)
        }
    }

    private func start(_ level: BotLevel) {
        Haptics.action()
        startedViewModel = RummyGameViewModel.newGame(settings: settings, botLevel: level, store: store)
    }
}

extension RummyGameViewModel: Hashable {
    nonisolated static func == (lhs: RummyGameViewModel, rhs: RummyGameViewModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
