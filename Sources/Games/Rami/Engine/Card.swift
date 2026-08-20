import Foundation

enum Suit: String, Codable, CaseIterable, Sendable, Hashable {
    case hearts, diamonds, clubs, spades

    var isRed: Bool { self == .hearts || self == .diamonds }

    var symbol: String {
        switch self {
        case .hearts: "♥"
        case .diamonds: "♦"
        case .clubs: "♣"
        case .spades: "♠"
        }
    }
}

enum Rank: Int, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case ace = 1, two, three, four, five, six, seven, eight, nine, ten, jack, queen, king

    static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .ace: "A"
        case .jack: "J"
        case .queen: "Q"
        case .king: "K"
        default: String(rawValue)
        }
    }

    /// Point value of a card left in hand at round end.
    var handValue: Int {
        switch self {
        case .jack, .queen, .king, .ace: 10
        default: rawValue
        }
    }
}

struct Card: Hashable, Codable, Identifiable, Sendable {
    enum Kind: Hashable, Codable, Sendable {
        case standard(rank: Rank, suit: Suit)
        case joker
    }

    let id: Int  // 0..107, stable for the whole game
    let kind: Kind

    var rank: Rank? {
        if case .standard(let rank, _) = kind { rank } else { nil }
    }

    var suit: Suit? {
        if case .standard(_, let suit) = kind { suit } else { nil }
    }

    var isJoker: Bool { kind == .joker }

    /// Point value when left in hand at round end (joker = 10).
    var handValue: Int { rank?.handValue ?? 10 }

    /// 108 cards: two 52-card decks + 4 jokers, ids 0..107.
    static func fullDeck() -> [Card] {
        var cards: [Card] = []
        var id = 0
        for _ in 0..<2 {
            for suit in Suit.allCases {
                for rank in Rank.allCases {
                    cards.append(Card(id: id, kind: .standard(rank: rank, suit: suit)))
                    id += 1
                }
            }
        }
        for _ in 0..<4 {
            cards.append(Card(id: id, kind: .joker))
            id += 1
        }
        return cards
    }
}

extension Array {
    /// In-place Fisher–Yates shuffle with an injectable RNG.
    mutating func fisherYatesShuffle(using rng: inout some RandomNumberGenerator) {
        guard count > 1 else { return }
        for i in stride(from: count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i, using: &rng)
            if i != j { swapAt(i, j) }
        }
    }
}
