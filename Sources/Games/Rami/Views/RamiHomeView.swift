import SwiftUI

struct RamiHomeView: View {
    let settings: SettingsStore
    let store: GameStore
    @State private var savedGame: RamiState?
    @State private var showLevelPicker = false
    @State private var startedViewModel: RamiGameViewModel?

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
        startedViewModel = RamiGameViewModel.newGame(settings: settings, botLevel: level, store: store)
    }
}

extension RamiGameViewModel: Hashable {
    nonisolated static func == (lhs: RamiGameViewModel, rhs: RamiGameViewModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
