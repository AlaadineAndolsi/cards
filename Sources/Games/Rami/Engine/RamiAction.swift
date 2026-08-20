import Foundation

enum RamiAction: Codable, Hashable, Sendable {
    // Dealing phase (dealer only)
    case shuffle
    case deal(DealPattern)
    // Vote phase: first actor `play: true` starts play, `play: false` proposes the pass;
    // subsequent players `play: true` decline (play begins), `play: false` agree to pass.
    case declareIntent(play: Bool)
    // Turn: draw step
    case drawFromPile
    case takeThrow                              // only after first lay-down
    case takeThrowAndLayDown(melds: [Meld])     // before first lay-down: atomic take + qualifying lay-down
    // Turn: meld step
    case layDown(melds: [Meld])
    case appendCard(MeldEntry, meldID: UUID)
    case swapJoker(meldID: UUID, realCard: Card)
    // Turn: end
    case throwCard(Card)
    // Round flow
    case startNextRound
}

enum RamiError: Error, Equatable, Sendable {
    case notYourTurn
    case illegalPhase
    case invalidMeld(MeldError)
    case thresholdNotMet(required: Int, got: Int)
    case throwTakeLocked
    case previousThrowUnavailable
    case mustLayDownWithTake
    case alreadyLaidDown
    case notLaidDownYet
    case meldNotFound
    case meldFull
    case jokerPending
    case cardNotInHand
    case mustKeepACardToThrow
    case jokerMismatch
    case noJokerInMeld
    case cannotAppendHere
    case pileEmpty
}
