import Foundation

/// Phone-number normalisation for duplicate matching.
///
/// Deliberately country-code tolerant: "+91 98765 43210", "09876543210" and
/// "98765 43210" all reduce to the same key. We compare the trailing national
/// significant digits because that is the part users actually re-enter
/// inconsistently. Short codes are kept whole.
enum PhoneNormalizer {
    /// Number of trailing digits used as the comparison key.
    static let significantDigits = 9

    static func normalize(_ raw: String) -> String {
        let digits = raw.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
        guard !digits.isEmpty else { return "" }
        // Numbers shorter than the window (short codes, extensions) compare whole.
        guard digits.count > significantDigits else { return digits }
        return String(digits.suffix(significantDigits))
    }

    /// Formats for display without altering the stored value.
    static func isPlausible(_ raw: String) -> Bool {
        normalize(raw).count >= 5
    }
}

/// Email normalisation.
///
/// Lower-cases and trims. For Gmail-family domains it also strips dots and
/// `+tag` suffixes, which are genuinely the same mailbox. Other providers treat
/// those as distinct, so we leave them alone.
enum EmailNormalizer {
    private static let dotInsensitiveDomains: Set<String> = [
        "gmail.com", "googlemail.com"
    ]

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return trimmed }

        var local = String(parts[0])
        let domain = String(parts[1])

        if let plus = local.firstIndex(of: "+") {
            local = String(local[local.startIndex..<plus])
        }
        if dotInsensitiveDomains.contains(domain) {
            local = local.replacingOccurrences(of: ".", with: "")
        }
        guard !local.isEmpty else { return trimmed }
        return "\(local)@\(domain)"
    }
}

/// Name normalisation: case-folded, diacritic-stripped, punctuation-free,
/// whitespace-collapsed. "José  O'Brien-Smith" → "jose obriensmith".
enum NameNormalizer {

    /// Marks deleted outright rather than treated as separators.
    ///
    /// An apostrophe sits *inside* a word: "O'Brien" and "OBrien" are the same
    /// surname, so replacing it with a space would split one token into two and
    /// stop the two spellings matching. Periods behave the same way in
    /// initialisms ("J.R.R." → "jrr"). Hyphens deliberately are *not* here —
    /// "Brien-Smith" really is two name parts and should tokenise as two.
    private static let elidedMarks = CharacterSet(charactersIn: "'\u{2019}\u{02BC}`.")

    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX"))
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if elidedMarks.contains(scalar) { continue }
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : space)
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// A sorted token key so "Ronit Ladkat" and "Ladkat Ronit" match.
    static func sortedKey(given: String, family: String) -> String {
        let tokens = normalize("\(given) \(family)")
            .split(separator: " ")
            .map(String.init)
            .sorted()
        return tokens.joined(separator: " ")
    }
}
