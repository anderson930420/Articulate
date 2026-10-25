import Foundation

/// Finds where a cut in one recognizer's transcript falls in another's. Both hear the same audio, so their
/// letters and digits mostly agree; an edit-distance alignment of those maps a position across.
enum TranscriptAlignment {
    /// The position in `other` matching `cut` in `text`, aligning `text[from..<cut]` with `other` from `otherFrom`.
    /// nil when `other` has not clearly reached the cut yet (its end would have to be stretched over the last
    /// `confirm` characters) or the two disagree too much to trust the mapping.
    static func map(_ text: [Character], from: Int, cut: Int, onto other: [Character], from otherFrom: Int,
                    confirm: Int = 3, maxDisagreement: Double = 0.4) -> Int? {
        let a = content(text, from: from, to: cut)
        let b = content(other, from: otherFrom, to: other.count)
        guard !a.isEmpty else { return otherFrom }
        guard !b.isEmpty else { return nil }

        // D[i][j]: cost of aligning a[0..<i] with b[0..<j]; b may run on past the cut for free.
        let n = a.count, m = b.count, width = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * width)
        var move = [UInt8](repeating: 0, count: (n + 1) * width)  // 0 diagonal, 1 skip a char of a, 2 skip a char of b
        for j in 0...m { cost[j] = Int32(j); move[j] = 2 }
        for i in 1...n {
            cost[i * width] = Int32(i)
            move[i * width] = 1
            for j in 1...m {
                let diagonal = cost[(i - 1) * width + j - 1] + (a[i - 1].char == b[j - 1].char ? 0 : 1)
                let skipA = cost[(i - 1) * width + j] + 1
                let skipB = cost[i * width + j - 1] + 1
                if diagonal <= skipA && diagonal <= skipB {
                    cost[i * width + j] = diagonal
                    move[i * width + j] = 0
                } else if skipA <= skipB {
                    cost[i * width + j] = skipA
                    move[i * width + j] = 1
                } else {
                    cost[i * width + j] = skipB
                    move[i * width + j] = 2
                }
            }
        }
        var end = 0
        for j in 1...m where cost[n * width + j] < cost[n * width + end] { end = j }
        guard Double(cost[n * width + end]) <= maxDisagreement * Double(n) else { return nil }

        // The last few characters before the cut must line up with real characters of `other`, not be skipped
        // because `other` stops short.
        var i = n, j = end, checked = 0
        while i > 0, checked < min(confirm, n) {
            switch move[i * width + j] {
            case 0: i -= 1; j -= 1; checked += 1
            case 1: return nil
            default: j -= 1
            }
        }
        // Up to the next letter or digit of `other`, so its punctuation after the cut stays with this piece.
        return end < m ? b[end].index : other.count
    }

    /// Letters and digits of `chars[from..<to]` with their positions; punctuation and spaces differ between recognizers.
    private static func content(_ chars: [Character], from: Int, to: Int) -> [(char: Character, index: Int)] {
        guard from < to else { return [] }
        return (from..<min(to, chars.count)).compactMap { i in
            let c = chars[i]
            return c.isLetter || c.isNumber ? (Character(c.lowercased()), i) : nil
        }
    }
}
