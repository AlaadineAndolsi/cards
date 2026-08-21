import Foundation
import Testing
@testable import Cards

struct BotMindTests {

    // MARK: - Level scaling (§5): execution quality rises with level

    @Test func memoryGrowsWithLevel() {
        let beginner = BotWeights.resolve(level: .beginner, archetype: .accountant, frustration: 0.3)
        let mid = BotWeights.resolve(level: .intermediate, archetype: .accountant, frustration: 0.3)
        let expert = BotWeights.resolve(level: .expert, archetype: .accountant, frustration: 0.3)
        #expect(beginner.memoryWindow < mid.memoryWindow)
        #expect(mid.memoryWindow < expert.memoryWindow)
        #expect(beginner.memoryDecay < expert.memoryDecay)
    }

    @Test func noiseShrinksWithLevel() {
        let beginner = BotWeights.resolve(level: .beginner, archetype: .accountant, frustration: 0.3)
        let mid = BotWeights.resolve(level: .intermediate, archetype: .accountant, frustration: 0.3)
        let expert = BotWeights.resolve(level: .expert, archetype: .accountant, frustration: 0.3)
        #expect(expert.noiseTemperature < mid.noiseTemperature)
        #expect(mid.noiseTemperature < beginner.noiseTemperature)
    }

    @Test func opponentModelDeepensWithLevel() {
        #expect(BotWeights.resolve(level: .beginner, archetype: .blocker, frustration: 0.3).opponentModelDepth == 0)
        #expect(BotWeights.resolve(level: .intermediate, archetype: .blocker, frustration: 0.3).opponentModelDepth == 1)
        #expect(BotWeights.resolve(level: .expert, archetype: .blocker, frustration: 0.3).opponentModelDepth == 2)
    }

    // MARK: - Archetypes bias the same level into different opponents

    @Test func blockerJailsMoreThanAccountant() {
        let blocker = BotWeights.resolve(level: .expert, archetype: .blocker, frustration: 0.3)
        let accountant = BotWeights.resolve(level: .expert, archetype: .accountant, frustration: 0.3)
        // Lower threshold = more cards considered dangerous enough to jail,
        // higher cost cap = holds them longer.
        #expect(blocker.jailThreshold < accountant.jailThreshold)
        #expect(blocker.jailCostCap > accountant.jailCostCap)
    }

    @Test func gloryHunterHuntsMoreThanAccountant() {
        let hunter = BotWeights.resolve(level: .expert, archetype: .gloryHunter, frustration: 0.3)
        let accountant = BotWeights.resolve(level: .expert, archetype: .accountant, frustration: 0.3)
        #expect(hunter.gloryAppetite > accountant.gloryAppetite)
        #expect(hunter.layEagerness < accountant.layEagerness)
    }

    // MARK: - Frustration modulates play, never information

    @Test func frustrationAddsNoiseAndRiskAndEagerness() {
        let calm = BotWeights.resolve(level: .expert, archetype: .blocker, frustration: 0.0)
        let tilted = BotWeights.resolve(level: .expert, archetype: .blocker, frustration: 1.0)
        #expect(tilted.noiseTemperature > calm.noiseTemperature)   // sloppier picks
        #expect(tilted.jailThreshold > calm.jailThreshold)         // riskier throws
        #expect(tilted.gloryBail > calm.gloryBail)                 // abandons hunts in disgust
        #expect(tilted.layEagerness > calm.layEagerness)           // lays "just to be safe"
        // Memory is unchanged — tilt never blinds or informs.
        #expect(tilted.memoryWindow == calm.memoryWindow)
    }

    @Test func gloryCommitStaysAboveBailForHysteresis() {
        for level in BotLevel.allCases {
            for archetype in BotArchetype.allCases {
                for frustration in [0.0, 0.5, 1.0] {
                    let weights = BotWeights.resolve(level: level, archetype: archetype, frustration: frustration)
                    #expect(weights.gloryCommit > weights.gloryBail,
                            "hunt must be sticky at \(level)/\(archetype)/f=\(frustration)")
                }
            }
        }
    }

    // MARK: - Tilt dynamics

    @Test func eatingHundredRaisesFrustration() {
        var mind = BotMind(archetype: .gloryHunter, frustration: 0.3)
        mind.absorbRound(myDelta: 100, iClosed: false, someoneElseClosed: false, level: .intermediate)
        #expect(mind.frustration > 0.5)
    }

    @Test func closingCalmsDown() {
        var mind = BotMind(archetype: .gloryHunter, frustration: 0.8)
        mind.absorbRound(myDelta: 0, iClosed: true, someoneElseClosed: false, level: .intermediate)
        #expect(mind.frustration < 0.6)
    }

    @Test func quietGoodRoundDecays() {
        var mind = BotMind(archetype: .accountant, frustration: 0.5)
        mind.absorbRound(myDelta: 6, iClosed: false, someoneElseClosed: true, level: .expert)
        #expect(mind.frustration < 0.5)
    }

    @Test func someoneElseClosingOnABadHandStings() {
        var calm = BotMind(archetype: .blocker, frustration: 0.3)
        calm.absorbRound(myDelta: 55, iClosed: false, someoneElseClosed: true, level: .intermediate)
        #expect(calm.frustration > 0.3)
    }

    @Test func frustrationStaysClamped() {
        var mind = BotMind(archetype: .gloryHunter, frustration: 0.95)
        for _ in 0..<10 {
            mind.absorbRound(myDelta: 100, iClosed: false, someoneElseClosed: true, level: .beginner)
        }
        #expect(mind.frustration <= 1.0)
        for _ in 0..<20 {
            mind.absorbRound(myDelta: 0, iClosed: true, someoneElseClosed: false, level: .expert)
        }
        #expect(mind.frustration >= 0.0)
    }

    @Test func beginnerTiltsHarderThanExpert() {
        var beginner = BotMind(archetype: .accountant, frustration: 0.3)
        var expert = BotMind(archetype: .accountant, frustration: 0.3)
        beginner.absorbRound(myDelta: 100, iClosed: false, someoneElseClosed: true, level: .beginner)
        expert.absorbRound(myDelta: 100, iClosed: false, someoneElseClosed: true, level: .expert)
        #expect(beginner.frustration > expert.frustration)
    }

    @Test func expertRecoversFaster() {
        var beginner = BotMind(archetype: .accountant, frustration: 0.7)
        var expert = BotMind(archetype: .accountant, frustration: 0.7)
        beginner.absorbRound(myDelta: 4, iClosed: false, someoneElseClosed: false, level: .beginner)
        expert.absorbRound(myDelta: 4, iClosed: false, someoneElseClosed: false, level: .expert)
        #expect(expert.frustration < beginner.frustration)
    }

    // MARK: - Mood surface

    @Test func moodBands() {
        #expect(BotMind(archetype: .blocker, frustration: 0.7).mood == .annoyed)
        #expect(BotMind(archetype: .blocker, frustration: 0.3).mood == .neutral)
        #expect(BotMind(archetype: .blocker, frustration: 0.05).mood == .confident)
    }
}
