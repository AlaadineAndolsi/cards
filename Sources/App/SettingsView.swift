import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ZStack {
            Theme.felt
            ScrollView {
                VStack(spacing: 18) {
                    botLevelCard
                    ruleCard(
                        title: L10n.minimumLayDown,
                        value: $settings.minimumLayDown,
                        range: RulesConfig.minimumLayDownRange,
                        defaultValue: RulesConfig.default.minimumLayDown,
                        step: 1)
                    ruleCard(
                        title: L10n.eliminationScore,
                        value: $settings.eliminationScore,
                        range: RulesConfig.eliminationScoreRange,
                        defaultValue: RulesConfig.default.eliminationScore,
                        step: 50)
                    Label(L10n.settingsNote, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
                .padding(20)
            }
        }
        .navigationTitle(L10n.settings)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
    }

    private var botLevelCard: some View {
        Theme.panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.botLevel)
                    .font(.headline)
                Picker(L10n.botLevel, selection: $settings.botLevel) {
                    Text(L10n.beginner).tag(BotLevel.beginner)
                    Text(L10n.intermediate).tag(BotLevel.intermediate)
                    Text(L10n.expert).tag(BotLevel.expert)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func ruleCard(
        title: String, value: Binding<Int>, range: ClosedRange<Int>,
        defaultValue: Int, step: Int
    ) -> some View {
        Theme.panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                HStack {
                    Text("\(value.wrappedValue)")
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                        .frame(minWidth: 76, alignment: .leading)
                    Spacer()
                    Stepper(title, value: value, in: range, step: step)
                        .labelsHidden()
                }
                HStack {
                    Text("\(range.lowerBound) – \(range.upperBound)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button(L10n.resetToDefault) {
                        withAnimation { value.wrappedValue = defaultValue }
                        Haptics.tap()
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(value.wrappedValue == defaultValue)
                }
            }
        }
    }
}
