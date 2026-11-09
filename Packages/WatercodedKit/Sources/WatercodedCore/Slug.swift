import Foundation

/// Turns free text into git-branch- and path-safe slugs.
public enum Slug {
    /// `"Fix the auth token refresh!"` → `"fix-the-auth-token-refresh"`.
    ///
    /// Lowercased ASCII letters and digits joined by single hyphens, trimmed at a word
    /// boundary to `maxLength`. Falls back to `fallback` when nothing usable remains.
    public static func make(from text: String, maxLength: Int = 40, fallback: String = "current") -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
        var words: [String] = []
        var word = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty {
            words.append(word)
        }

        var slug = ""
        for candidate in words {
            let next = slug.isEmpty ? candidate : slug + "-" + candidate
            if next.count > maxLength {
                break
            }
            slug = next
        }
        if slug.isEmpty, let first = words.first {
            slug = String(first.prefix(maxLength))
        }
        return slug.isEmpty ? fallback : slug.lowercased()
    }
}
