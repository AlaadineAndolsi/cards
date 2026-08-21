import Foundation
@testable import Cards

/// Builds crafted mid-game states for legality tests.
enum StateBuilder {
    static func base(config: RulesConfig = .default) -> RamiState {
        RamiState(
            config: config,
            players: (0..<4).map { PlayerState(name: "P\($0)", isHuman: $0 == 0) },
            dealerSeat: 3,
            phase: .dealing(shuffles: 0),
            drawPile: Card.fullDeck(),
            startedAt: Date(timeIntervalSince1970: 0),
            matchID: UUID()
        )
    }

    /// A state where `seat` is mid-turn with the given stage. Hands and stacks
    /// are set per seat; the draw pile holds whatever ids remain unused.
    static func turn(
        seat: Int,
        stage: TurnStage,
        hands: [[Card]],
        throwStacks: [[Card]] = [[], [], [], []],
        laidDown: [Bool] = [false, false, false, false],
        eliminated: [Bool] = [false, false, false, false],
        turnsCompleted: Int = 0,
        lastInitialLayDown: Int? = nil,
        tableMelds: [TableMeld] = [],
        drawPile: [Card]? = nil,
        config: RulesConfig = .default
    ) -> RamiState {
        var s = base(config: config)
        for i in 0..<4 {
            s.players[i].hand = hands[i]
            s.players[i].throwStack = throwStacks[i]
            s.players[i].hasLaidDown = laidDown[i]
            s.players[i].isEliminated = eliminated[i]
        }
        s.turnsCompletedThisRound = turnsCompleted
        s.lastInitialLayDownTotal = lastInitialLayDown
        s.tableMelds = tableMelds
        let used = Set((hands + throwStacks).flatMap { $0 }.map(\.id) + tableMelds.flatMap { $0.meld.cards.map(\.id) })
        s.drawPile = drawPile ?? Card.fullDeck().filter { !used.contains($0.id) }
        s.phase = .turn(seat: seat, stage)
        return s
    }

    static func apply(_ action: RamiAction, by seat: Int, to state: RamiState) throws -> RamiState {
        var rng = SeededRNG(seed: 7)
        return try RamiEngine.apply(action, by: seat, to: state, rng: &rng)
    }
}
