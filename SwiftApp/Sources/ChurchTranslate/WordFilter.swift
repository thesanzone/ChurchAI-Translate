import Foundation

/// Swear-word filter. Reads word_filter.txt (the same file the Python app uses; it is
/// copied into the app bundle when the app is built) and cleans text so that no blocked
/// word is ever spoken, shown in captions or saved to a transcript.
/// See word_filter.txt for how the list works.
final class WordFilter: @unchecked Sendable {
    private(set) var blockedExact = Set<String>()
    private(set) var blockedPrefixes: [String] = []
    private(set) var allowed = Set<String>()
    private(set) var replacements: [String: String] = [:]
    private(set) var loaded = false

    /// A "word" is a run of letters (any language, incl. accents) with inner apostrophes.
    private static let wordRegex = try! NSRegularExpression(pattern: "\\p{L}+(?:'\\p{L}+)*")

    init(url: URL? = WordFilter.bundledList) {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("[!] word_filter.txt not found; swear-word filter is OFF.")
            return
        }
        load(text)
        loaded = true
        print("[filter] Loaded \(blockedExact.count + blockedPrefixes.count) blocked, "
              + "\(replacements.count) replacements, \(allowed.count) allowed")
    }

    static var bundledList: URL? {
        Bundle.main.url(forResource: "word_filter", withExtension: "txt")
    }

    /// Lowercase and strip accents: "Cabrón" -> "cabron".
    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    private func load(_ text: String) {
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = (raw.components(separatedBy: "#").first ?? "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            switch section {
            case "allow":
                allowed.insert(Self.normalize(line))
            case "replace":
                let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                    replacements[Self.normalize(parts[0])] = parts[1]
                }
            case "block":
                if line.hasSuffix("*") {
                    blockedPrefixes.append(Self.normalize(String(line.dropLast())))
                } else {
                    blockedExact.insert(Self.normalize(line))
                }
            default:
                break
            }
        }
    }

    func isBlocked(_ word: String) -> Bool {
        let w = Self.normalize(word)
        if allowed.contains(w) { return false }
        return blockedExact.contains(w) || blockedPrefixes.contains { w.hasPrefix($0) }
    }

    /// Returns the cleaned text and how many words were changed.
    /// Risky words are replaced with safe ones; blocked words become `mask`
    /// (use "" to drop them, as for the Spanish voice and captions).
    func clean(_ text: String, mask: String = "•••") -> (text: String, changed: Int) {
        guard loaded, !text.isEmpty else { return (text, 0) }
        let ns = text as NSString
        var out = ""
        var last = 0
        var changed = 0
        for m in Self.wordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let word = ns.substring(with: m.range)
            let key = Self.normalize(word)
            if allowed.contains(key) {
                out += word
            } else if let safe = replacements[key] {
                out += Self.matchCase(word, safe)
                changed += 1
            } else if isBlocked(word) {
                out += mask
                changed += 1
            } else {
                out += word
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)

        if changed > 0 && mask.isEmpty {
            out = Self.tidy(out)
        }
        return (out, changed)
    }

    private static func matchCase(_ original: String, _ replacement: String) -> String {
        if original.count > 1 && original == original.uppercased() { return replacement.uppercased() }
        if let f = original.first, f.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }

    /// Tidy spacing and punctuation left behind by removed words.
    private static func tidy(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            ("\\s{2,}", " "),
            ("\\s+([,.;:!?])", "$1"),
            ("[,;:]+([.!?])", "$1"),        // "vino,." -> "vino."
            ("([¿¡])\\s+", "$1"),
            ("[¿¡][?!]", ""),              // empty "¡!" left behind
            ("^[\\s,;:]+", ""),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.range(of: "\\p{L}", options: .regularExpression) == nil ? "" : t
    }
}
