import Foundation
import Observation

/// The configurable rules and the bot level. Persisted in UserDefaults;
/// frozen into a game's snapshot at start so later edits never touch a
/// running game.
@MainActor
@Observable
final class SettingsStore {
    private static let layDownKey = "settings.minimumLayDown"
    private static let eliminationKey = "settings.eliminationScore"
    private static let botLevelKey = "settings.botLevel"

    var minimumLayDown: Int {
        didSet {
            minimumLayDown = minimumLayDown.clamped(to: RulesConfig.minimumLayDownRange)
            UserDefaults.standard.set(minimumLayDown, forKey: Self.layDownKey)
        }
    }

    var eliminationScore: Int {
        didSet {
            eliminationScore = eliminationScore.clamped(to: RulesConfig.eliminationScoreRange)
            UserDefaults.standard.set(eliminationScore, forKey: Self.eliminationKey)
        }
    }

    var botLevel: BotLevel {
        didSet { UserDefaults.standard.set(botLevel.rawValue, forKey: Self.botLevelKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        botLevel = BotLevel(rawValue: defaults.integer(forKey: Self.botLevelKey)) ?? .expert
        let storedLayDown = defaults.integer(forKey: Self.layDownKey)
        let storedElimination = defaults.integer(forKey: Self.eliminationKey)
        minimumLayDown = storedLayDown == 0
            ? RulesConfig.default.minimumLayDown
            : storedLayDown.clamped(to: RulesConfig.minimumLayDownRange)
        eliminationScore = storedElimination == 0
            ? RulesConfig.default.eliminationScore
            : storedElimination.clamped(to: RulesConfig.eliminationScoreRange)
    }

    func config() -> RulesConfig {
        RulesConfig(
            minimumLayDown: minimumLayDown,
            eliminationScore: eliminationScore,
            botLevel: botLevel)
    }
}

extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
