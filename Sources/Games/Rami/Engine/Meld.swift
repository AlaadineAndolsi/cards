import Foundation

enum MeldError: Error, Equatable, Sendable {
    case invalidSize
    case entryFaceMismatch
    case duplicateCardInstance
    case duplicateSuitInSet
    case notARunOrSet
}

/// One card inside a meld together with the face it plays as.
/// For a standard card the face must equal the card's own rank/suit;
/// for a joker it is the card the joker represents.
struct MeldEntry: Codable, Hashable, Sendable {
    var card: Card
    var asRank: Rank
    var asSuit: Suit
}

struct Meld: Codable, Hashable, Sendable {
    var entries: [MeldEntry]

    enum Kind: Sendable { case run, set }

    static let minSize = 3
    static let maxSize = 5
    static let maxSetSize = 4

    /// Validates structure and returns whether this is a run or a set.
    @discardableResult
    func validate() throws(MeldError) -> Kind {
        guard entries.count >= Self.minSize, entries.count <= Self.maxSize else {
            throw MeldError.invalidSize
        }
        guard Set(entries.map(\.card.id)).count == entries.count else {
            throw MeldError.duplicateCardInstance
        }
        for entry in entries where !entry.card.isJoker {
            guard entry.card.rank == entry.asRank, entry.card.suit == entry.asSuit else {
                throw MeldError.entryFaceMismatch
            }
        }

        if isRun() { return .run }
        if entries.count <= Self.maxSetSize, entries.allSatisfy({ $0.asRank == entries[0].asRank }) {
            guard Set(entries.map(\.asSuit)).count == entries.count else {
                throw MeldError.duplicateSuitInSet
            }
            return .set
        }
        throw MeldError.notARunOrSet
    }

    /// A run is 3–5 same-suit consecutive faces in ascending order.
    /// Ace may lead (A-2-3…) or close (…Q-K-A); never around-the-corner.
    private func isRun() -> Bool {
        guard entries.allSatisfy({ $0.asSuit == entries[0].asSuit }) else { return false }
        let ranks = entries.map(\.asRank)
        guard Set(ranks).count == ranks.count else { return false }
        // Ace-high: ...Q-K-A means the last entry is an ace following a king.
        if ranks.last == .ace, ranks.count >= 2, ranks[ranks.count - 2] == .king {
            let body = Array(ranks.dropLast())
            return isConsecutive(body) && body.last == .king
        }
        return isConsecutive(ranks)
    }

    private func isConsecutive(_ ranks: [Rank]) -> Bool {
        guard !ranks.isEmpty else { return false }
        for i in 1..<ranks.count where ranks[i].rawValue != ranks[i - 1].rawValue + 1 {
            return false
        }
        return true
    }

    /// Value counted toward the first-lay-down threshold, per validated kind:
    /// 2–10 face value, J/Q/K 10, ace 1 only when it leads an ace-low run
    /// (10 in high runs and sets), joker = value of the face it represents.
    func validatedThresholdValue() throws(MeldError) -> Int {
        let kind = try validate()
        let aceLowRun = kind == .run && entries.first?.asRank == .ace
        return entries.reduce(0) { total, entry in
            let value: Int
            switch entry.asRank {
            case .ace: value = aceLowRun ? 1 : 10
            case .jack, .queen, .king: value = 10
            default: value = entry.asRank.rawValue
            }
            return total + value
        }
    }

    var cards: [Card] { entries.map(\.card) }
}
