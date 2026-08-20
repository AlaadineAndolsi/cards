import Foundation

/// The five distribution rhythms a dealer may choose. Digits are the number of
/// cards handed to every player on successive passes, cycling until each
/// non-dealer holds 14; a final pass tops the dealer up to 15.
enum DealPattern: String, Codable, CaseIterable, Sendable {
    case p1111, p1222, p2222, p2111, p3222

    var label: String {
        switch self {
        case .p1111: "1·1·1·1 +1"
        case .p1222: "1·2·2·2 +2"
        case .p2222: "2·2·2·2 +1"
        case .p2111: "2·1·1·1"
        case .p3222: "3·2·2·2"
        }
    }

    var cycle: [Int] {
        switch self {
        case .p1111: [1, 1, 1, 1]
        case .p1222: [1, 2, 2, 2]
        case .p2222: [2, 2, 2, 2]
        case .p2111: [2, 1, 1, 1]
        case .p3222: [3, 2, 2, 2]
        }
    }

    /// How many cards the dealer adds to himself at the very end.
    var dealerTopUp: Int { self == .p1222 ? 2 : 1 }

    /// Per-pass card counts. Index 0 of each pass is the dealer; the remaining
    /// indices are the other players in dealing order. Sums to
    /// 15 for the dealer and 14 for everyone else, for any player count.
    func passes(playerCount: Int) -> [[Int]] {
        precondition(playerCount >= 2)
        let othersTarget = 14
        let dealerRegularTarget = 15 - dealerTopUp
        var result: [[Int]] = []
        var otherTotal = 0
        var dealerTotal = 0
        var cycleIndex = 0
        while otherTotal < othersTarget {
            let amount = Swift.min(cycle[cycleIndex % cycle.count], othersTarget - otherTotal)
            let dealerAmount = Swift.min(amount, dealerRegularTarget - dealerTotal)
            var pass = [Int](repeating: amount, count: playerCount)
            pass[0] = dealerAmount
            result.append(pass)
            otherTotal += amount
            dealerTotal += dealerAmount
            cycleIndex += 1
        }
        var topUp = [Int](repeating: 0, count: playerCount)
        topUp[0] = 15 - dealerTotal
        result.append(topUp)
        return result
    }
}
