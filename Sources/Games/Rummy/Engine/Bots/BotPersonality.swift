import Foundation

/// Fixed per-game temperament. Same difficulty level, three recognizably
/// different opponents: the weights below bias strategy, never information.
enum BotArchetype: String, Codable, CaseIterable, Hashable, Sendable {
    /// Cautious: secures the lay-down early, rarely gambles on glory.
    case accountant
    /// Aggressive: loves hunting the full 14-card close, patient with laying.
    case gloryHunter
    /// Vindictive: starves the next player, jails dangerous cards longest.
    case blocker
}

/// Small mood surface for the seat UI (neutral is rendered as nothing).
enum BotMood: String, Codable, Hashable, Sendable {
    case neutral, annoyed, confident
}

/// A bot's evolving emotional state. Lives in `RummyState.botMinds` so it is
/// deterministic, persisted with the save, and updated purely at settlement.
struct BotMind: Codable, Hashable, Sendable {
    var archetype: BotArchetype
    /// 0 (serene) … 1 (fully tilted). Starts mildly alert.
    var frustration: Double

    static let neutral = BotMind(archetype: .accountant, frustration: 0.3)

    var mood: BotMood {
        if frustration > 0.55 { return .annoyed }
        if frustration < 0.15 { return .confident }
        return .neutral
    }

    /// Pure tilt update after a round settles. Bad outcomes (eating 100,
    /// watching someone else close on a heavy hand) push frustration up;
    /// closing or a cheap round lets it bleed back down. Level scales both
    /// directions: beginners tilt hard, experts tilt subtly and recover fast.
    mutating func absorbRound(myDelta: Int, iClosed: Bool, someoneElseClosed: Bool, level: BotLevel) {
        let gain = Self.tiltGain(level: level) * Self.tiltSensitivity(archetype: archetype)
        let recovery = Self.tiltRecovery(level: level)
        var delta = 0.0
        if iClosed {
            delta -= 0.30
        } else if myDelta >= 100 {
            delta += 1.4 * gain
        } else if myDelta >= 40 {
            delta += 0.6 * gain
        }
        if someoneElseClosed && !iClosed && myDelta >= 20 {
            delta += 0.5 * gain
        }
        if myDelta <= 10 && !iClosed {
            delta -= recovery
        }
        frustration = min(1, max(0, frustration + delta))
    }

    static func tiltGain(level: BotLevel) -> Double {
        switch level {
        case .beginner: 0.36
        case .intermediate: 0.25
        case .expert: 0.15
        }
    }

    static func tiltRecovery(level: BotLevel) -> Double {
        switch level {
        case .beginner: 0.06
        case .intermediate: 0.10
        case .expert: 0.16
        }
    }

    static func tiltSensitivity(archetype: BotArchetype) -> Double {
        switch archetype {
        case .accountant: 0.85
        case .gloryHunter: 1.2
        case .blocker: 1.0
        }
    }
}

/// The one config structure (§7): every strategy/psychology knob, resolved
/// from level × archetype × current frustration. Levels scale *execution*,
/// archetypes give flavor, frustration bends both — cards are never touched.
struct BotWeights: Sendable {
    /// Throws remembered per stack when reading the table (`Int.max` = all).
    var memoryWindow: Int
    /// Per-position weight decay for older throws (1 = photographic).
    var memoryDecay: Double
    /// Softmax temperature over discard scores — higher = sloppier picks.
    var noiseTemperature: Double
    /// Danger above this jails a card in hand instead of throwing it.
    var jailThreshold: Double
    /// Cost-to-me above which a jailed card is released anyway.
    var jailCostCap: Double
    /// 0…1 how reliably small cards go first in the early round.
    var smallCardsDiscipline: Double
    /// 0…1 willingness to hunt the 14-card satisfaction close at all.
    var gloryAppetite: Double
    /// Close-potential needed to *start* the hunt…
    var gloryCommit: Double
    /// …and the lower bar under which a running hunt is abandoned (hysteresis).
    var gloryBail: Double
    /// 0…1 how sharply elimination proximity is respected.
    var eliminationAwareness: Double
    /// 0 = none, 1 = takes-adjacency, 2 = full take/decline + append model.
    var opponentModelDepth: Int
    /// 0…1 baseline pull toward securing the lay-down sooner than optimal.
    var layEagerness: Double

    static func resolve(level: BotLevel, archetype: BotArchetype, frustration: Double) -> BotWeights {
        var w = base(level: level)

        switch archetype {
        case .accountant:
            w.gloryAppetite *= 0.35
            w.layEagerness += 0.25
            w.smallCardsDiscipline = min(1, w.smallCardsDiscipline * 1.05)
        case .gloryHunter:
            w.gloryAppetite = min(1, w.gloryAppetite * 1.5 + 0.2)
            w.layEagerness -= 0.15
            w.jailThreshold *= 1.2
        case .blocker:
            w.jailThreshold *= 0.7
            w.jailCostCap *= 1.35
            w.gloryAppetite *= 0.7
        }

        // Tilt: riskier throws, sloppier picks, hunts abandoned, laying "just
        // to be safe" — behavior only, never memory or information.
        w.noiseTemperature *= 1 + 0.8 * frustration
        w.jailThreshold += 0.20 * frustration
        w.gloryBail += 0.12 * frustration
        w.layEagerness += 0.30 * frustration

        w.layEagerness = min(1.2, max(0, w.layEagerness))
        return w
    }

    private static func base(level: BotLevel) -> BotWeights {
        switch level {
        case .beginner:
            BotWeights(
                memoryWindow: 3, memoryDecay: 0.55, noiseTemperature: 0.80,
                jailThreshold: 0.85, jailCostCap: 0.8, smallCardsDiscipline: 0.30,
                gloryAppetite: 0.5, gloryCommit: 0.60, gloryBail: 0.30,
                eliminationAwareness: 0.4, opponentModelDepth: 0, layEagerness: 0.55)
        case .intermediate:
            BotWeights(
                memoryWindow: 8, memoryDecay: 0.75, noiseTemperature: 0.35,
                jailThreshold: 0.60, jailCostCap: 1.4, smallCardsDiscipline: 0.70,
                gloryAppetite: 0.5, gloryCommit: 0.72, gloryBail: 0.48,
                eliminationAwareness: 0.8, opponentModelDepth: 1, layEagerness: 0.50)
        case .expert:
            BotWeights(
                memoryWindow: .max, memoryDecay: 0.92, noiseTemperature: 0.12,
                jailThreshold: 0.45, jailCostCap: 2.2, smallCardsDiscipline: 0.95,
                gloryAppetite: 0.5, gloryCommit: 0.80, gloryBail: 0.60,
                eliminationAwareness: 1.0, opponentModelDepth: 2, layEagerness: 0.45)
        }
    }
}
