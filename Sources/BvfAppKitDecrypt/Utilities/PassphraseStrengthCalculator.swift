import Foundation

/// Passphrase strength levels
enum PassphraseStrength: Sendable {
    case weak
    case moderate
    case strong

    var colorName: String {
        switch self {
        case .weak: return "red"
        case .moderate: return "orange"
        case .strong: return "green"
        }
    }

    var label: String {
        switch self {
        case .weak: return "Weak"
        case .moderate: return "Moderate"
        case .strong: return "Strong"
        }
    }
}

/// Utility for assessing passphrase strength
struct PassphraseStrengthCalculator: Sendable {

    /// Calculate passphrase strength with detailed feedback
    /// - Parameter passphrase: The passphrase to assess
    /// - Returns: Tuple of (strength level, user-friendly message)
    static func calculate(_ passphrase: String) -> (strength: PassphraseStrength, message: String) {
        let length = passphrase.count

        guard length > 0 else {
            return (.weak, "Passphrase is required")
        }

        if length < 8 {
            return (.weak, "Too short (minimum 8 characters recommended)")
        }

        var score = 0

        if length >= 8 { score += 1 }
        if length >= 12 { score += 1 }
        if length >= 16 { score += 1 }
        if length >= 20 { score += 1 }

        let hasLowercase = passphrase.contains(where: { $0.isLowercase })
        let hasUppercase = passphrase.contains(where: { $0.isUppercase })
        let hasDigits = passphrase.contains(where: { $0.isNumber })
        let hasSpecialChars = passphrase.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace })
        let hasSpaces = passphrase.contains(where: { $0.isWhitespace })

        if hasLowercase { score += 1 }
        if hasUppercase { score += 1 }
        if hasDigits { score += 1 }
        if hasSpecialChars { score += 1 }
        if hasSpaces { score += 1 } // Encourage passphrases with spaces (e.g., "correct horse battery staple")

        let weakPatterns = [
            "password", "123456", "qwerty", "letmein", "welcome",
            "admin", "login", "abc123", "111111", "password123"
        ]
        let lowercased = passphrase.lowercased()
        let hasWeakPattern = weakPatterns.contains { lowercased.contains($0) }

        let hasSequential = containsSequentialChars(passphrase)

        if hasWeakPattern || hasSequential {
            return (.weak, "Contains common patterns or sequential characters")
        }

        if score >= 7 {
            return (.strong, "Strong passphrase")
        } else if score >= 4 {
            var suggestions: [String] = []
            if length < 12 { suggestions.append("longer") }
            if !hasUppercase { suggestions.append("uppercase") }
            if !hasDigits { suggestions.append("numbers") }
            if !hasSpecialChars && !hasSpaces { suggestions.append("special characters or spaces") }

            let suggestionText = suggestions.isEmpty ? "" : " (consider adding: \(suggestions.joined(separator: ", ")))"
            return (.moderate, "Moderate strength\(suggestionText)")
        } else {
            return (.weak, "Add more character variety (uppercase, numbers, special characters)")
        }
    }

    /// Check for sequential characters (e.g., "abc", "123", "xyz")
    private static func containsSequentialChars(_ string: String) -> Bool {
        let chars = Array(string.lowercased())
        guard chars.count >= 3 else { return false }

        for i in 0..<(chars.count - 2) {
            let char1 = chars[i]
            let char2 = chars[i + 1]
            let char3 = chars[i + 2]

            if let ascii1 = char1.asciiValue,
               let ascii2 = char2.asciiValue,
               let ascii3 = char3.asciiValue {
                if ascii2 == ascii1 + 1 && ascii3 == ascii2 + 1 {
                    return true
                }
            }
        }

        return false
    }
}
