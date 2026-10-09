import SwiftUI

/// Lightweight password strength estimator based on character-pool entropy
/// with penalties for repetition and trivial patterns. Intentionally simple
/// (not a full zxcvbn) — it is a hint, not a guarantee.
struct PasswordStrength: Equatable {
    enum Level: Int, Comparable {
        case weak
        case fair
        case good
        case excellent

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .weak: return L("Weak")
            case .fair: return L("Fair")
            case .good: return L("Good")
            case .excellent: return L("Excellent")
            }
        }

        var color: Color {
            switch self {
            case .weak: return Color(nsColor: NSColor(hex: 0xFF3B30))
            case .fair: return Color(nsColor: NSColor(hex: 0xFF9500))
            case .good: return Color(nsColor: NSColor(hex: 0x30B0C7))
            case .excellent: return Color(nsColor: NSColor(hex: 0x34C759))
            }
        }
    }

    let entropyBits: Double
    let level: Level
    let weakness: String?

    /// Normalized 0...1 value for progress bars (capped at 128 bits).
    var fraction: CGFloat {
        if weakness != nil {
            return min(0.22, max(CGFloat(entropyBits) / 128.0, 0.04))
        }
        return min(max(CGFloat(entropyBits) / 128.0, 0.04), 1.0)
    }

    /// Strength of what the generator produces, from its exact entropy.
    static func forEntropy(_ bits: Double) -> PasswordStrength {
        let level: Level
        switch bits {
        case ..<40: level = .weak
        case ..<60: level = .fair
        case ..<80: level = .good
        default: level = .excellent
        }
        return PasswordStrength(entropyBits: bits, level: level, weakness: nil)
    }

    static func evaluate(_ password: String) -> PasswordStrength? {
        guard !password.isEmpty else {
            return nil
        }

        let entropy = estimateEntropyBits(password)
        let weakness = weaknessReason(password)
        let level: Level
        if weakness != nil {
            level = .weak
        } else {
            switch entropy {
            case ..<40: level = .weak
            case ..<60: level = .fair
            case ..<80: level = .good
            default: level = .excellent
            }
        }

        return PasswordStrength(entropyBits: entropy, level: level, weakness: weakness)
    }

    static func weaknessReason(_ password: String) -> String? {
        guard !password.isEmpty else {
            return nil
        }
        if password.allSatisfy(\.isNumber) {
            return L("Digits only")
        }
        if password.count < 8 {
            return L("Too short")
        }
        let lowered = password.lowercased()
        if commonWords.contains(where: { lowered.contains($0) }) {
            return L("Common word")
        }
        return nil
    }

    private static let commonWords = [
        "password", "passwort", "admin", "qwerty", "letmein", "welcome", "123456", "iloveyou", "monkey", "dragon",
        "summer", "winter", "spring", "autumn"
    ]

    private static func estimateEntropyBits(_ password: String) -> Double {
        let characters = Array(password)
        let count = characters.count

        var poolSize = 0
        if characters.contains(where: { $0.isLowercase }) { poolSize += 26 }
        if characters.contains(where: { $0.isUppercase }) { poolSize += 26 }
        if characters.contains(where: { $0.isNumber }) { poolSize += 10 }
        if characters.contains(where: { $0.isSymbol || $0.isPunctuation }) { poolSize += 33 }
        if characters.contains(where: { $0 == " " }) { poolSize += 1 }
        // Anything else (e.g. emoji, non-latin) — assume a modest extra pool.
        if characters.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isSymbol && !$0.isPunctuation && $0 != " " }) {
            poolSize += 20
        }
        poolSize = max(poolSize, 1)

        var entropy = Double(count) * log2(Double(poolSize))

        // Penalize low character variety (e.g. "aaaaaa", "121212").
        let uniqueCount = Set(characters).count
        if count > 0 {
            let varietyRatio = Double(uniqueCount) / Double(count)
            if varietyRatio < 0.5 {
                entropy *= (0.5 + varietyRatio)
            }
        }

        return entropy
    }
}
