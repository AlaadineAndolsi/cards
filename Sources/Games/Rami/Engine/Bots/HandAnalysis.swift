import Foundation

/// Pure meld-search utilities shared by all bot levels (and usable for hints).
/// Works on a hand of at most ~16 cards using bitmasks over hand indices.
enum HandAnalysis {

    struct Candidate {
        let meld: Meld
        let value: Int
        let mask: UInt32
        let cardCount: Int
    }

    struct Partition {
        var melds: [Meld]
        var value: Int
        var mask: UInt32
        var coveredCount: Int

        static let empty = Partition(melds: [], value: 0, mask: 0, coveredCount: 0)
    }

    // MARK: - Candidate generation

    /// All distinct runs/sets buildable from this hand, jokers included
    /// (at most 2 jokers per meld, at least 1 real card).
    static func candidates(hand: [Card]) -> [Candidate] {
        var result: [Candidate] = []
        let jokerIndices = hand.indices.filter { hand[$0].isJoker }

        // Suit → rank → hand indices (both copies).
        var bySuit: [Suit: [Int: [Int]]] = [:]
        var byRank: [Int: [Suit: [Int]]] = [:]
        for index in hand.indices {
            guard let rank = hand[index].rank, let suit = hand[index].suit else { continue }
            bySuit[suit, default: [:]][rank.rawValue, default: []].append(index)
            byRank[rank.rawValue, default: [:]][suit, default: []].append(index)
        }

        // Runs: rank sequences r..r+len-1 (ace low at r=1) and high runs ending in an ace.
        for (suit, ranks) in bySuit {
            for length in 3...5 {
                var sequences: [[Int]] = []
                for start in 1...(14 - length) where start + length - 1 <= 13 {
                    sequences.append(Array(start..<(start + length)))
                }
                // …Q-K-A: ranks (15-length)…13 then ace.
                sequences.append(Array((15 - length)...13) + [1])
                for sequence in sequences {
                    appendRunCandidates(
                        suit: suit, sequence: sequence, ranks: ranks,
                        jokerIndices: jokerIndices, hand: hand, into: &result)
                }
            }
        }

        // Sets: rank + distinct suits, optionally 1–2 jokers on missing suits.
        for (rankValue, suits) in byRank {
            let availableSuits = Array(suits.keys)
            let missingSuits = Suit.allCases.filter { !availableSuits.contains($0) }
            for realCount in 1...availableSuits.count {
                for combo in combinations(of: availableSuits, choose: realCount) {
                    for jokerCount in 0...min(2, jokerIndices.count) {
                        let size = realCount + jokerCount
                        guard size >= 3, size <= Meld.maxSetSize, jokerCount <= missingSuits.count else { continue }
                        var entries: [MeldEntry] = []
                        var mask: UInt32 = 0
                        for suit in combo {
                            let index = suits[suit]!.first!
                            entries.append(MeldEntry(card: hand[index], asRank: Rank(rawValue: rankValue)!, asSuit: suit))
                            mask |= 1 << index
                        }
                        for j in 0..<jokerCount {
                            let index = jokerIndices[j]
                            entries.append(MeldEntry(
                                card: hand[index], asRank: Rank(rawValue: rankValue)!, asSuit: missingSuits[j]))
                            mask |= 1 << index
                        }
                        addCandidate(Meld(entries: entries), mask: mask, into: &result)
                    }
                }
            }
        }
        return result
    }

    private static func appendRunCandidates(
        suit: Suit, sequence: [Int], ranks: [Int: [Int]],
        jokerIndices: [Int], hand: [Card], into result: inout [Candidate]
    ) {
        var entries: [MeldEntry] = []
        var mask: UInt32 = 0
        var jokersUsed = 0
        for rankValue in sequence {
            if let index = ranks[rankValue]?.first {
                entries.append(MeldEntry(card: hand[index], asRank: Rank(rawValue: rankValue)!, asSuit: suit))
                mask |= 1 << index
            } else {
                guard jokersUsed < min(2, jokerIndices.count) else { return }
                let index = jokerIndices[jokersUsed]
                jokersUsed += 1
                entries.append(MeldEntry(card: hand[index], asRank: Rank(rawValue: rankValue)!, asSuit: suit))
                mask |= 1 << index
            }
        }
        guard entries.count > jokersUsed else { return }  // at least one real card
        addCandidate(Meld(entries: entries), mask: mask, into: &result)
    }

    private static func addCandidate(_ meld: Meld, mask: UInt32, into result: inout [Candidate]) {
        guard let value = try? meld.validatedThresholdValue() else { return }
        result.append(Candidate(meld: meld, value: value, mask: mask, cardCount: meld.entries.count))
    }

    private static func combinations<T>(of items: [T], choose k: Int) -> [[T]] {
        guard k > 0 else { return [[]] }
        guard items.count >= k else { return [] }
        if items.count == k { return [items] }
        let head = items[0]
        let rest = Array(items.dropFirst())
        return combinations(of: rest, choose: k - 1).map { [head] + $0 } + combinations(of: rest, choose: k)
    }

    // MARK: - Partition search

    /// Best disjoint combination of candidate melds. `maximizeCoverage` ranks
    /// by covered card count first (for closing), otherwise by total value
    /// (for reaching the lay-down threshold).
    static func bestPartition(hand: [Card], maximizeCoverage: Bool = false) -> Partition {
        let cands = candidates(hand: hand).sorted {
            maximizeCoverage
                ? ($0.cardCount, $0.value) > ($1.cardCount, $1.value)
                : ($0.value, $0.cardCount) > ($1.value, $1.cardCount)
        }
        var best = Partition.empty
        var nodes = 0
        let maxNodes = 60_000

        func better(_ a: Partition, than b: Partition) -> Bool {
            maximizeCoverage
                ? (a.coveredCount, a.value) > (b.coveredCount, b.value)
                : (a.value, a.coveredCount) > (b.value, b.coveredCount)
        }

        func dfs(_ start: Int, _ current: Partition) {
            nodes += 1
            if better(current, than: best) { best = current }
            guard nodes < maxNodes else { return }
            for i in start..<cands.count {
                let candidate = cands[i]
                guard candidate.mask & current.mask == 0 else { continue }
                var next = current
                next.melds.append(candidate.meld)
                next.value += candidate.value
                next.mask |= candidate.mask
                next.coveredCount += candidate.cardCount
                dfs(i + 1, next)
            }
        }
        dfs(0, .empty)
        return best
    }

    /// Melds covering exactly `hand.count - 1` cards (everything but the final
    /// throw), or nil if closing is impossible right now.
    static func closingMelds(hand: [Card]) -> [Meld]? {
        let partition = bestPartition(hand: hand, maximizeCoverage: true)
        guard partition.coveredCount >= Meld.minSize,
              partition.coveredCount == hand.count - 1 else { return nil }
        return partition.melds
    }
}
