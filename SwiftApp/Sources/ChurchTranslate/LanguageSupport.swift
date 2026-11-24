import AVFoundation
import Foundation
import Translation

/// One row in the Outputs tab: a language the sermon is translated into, with its voice,
/// speaker output, volume and captions screen. Saved between launches (see TranslatorModel).
struct LanguageOutput: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Translation target as Apple's translation names it, e.g. "es", "es-MX", "ko", "pt-PT".
    var language: String
    var isOn = true
    /// Apple voice identifier; nil means "the best installed voice for this language".
    var voiceID: String?
    /// True once the volunteer picked a voice, so a newly downloaded voice doesn't replace it.
    var voiceChosenByUser = false
    /// Mac: CoreAudio UID of the speaker/headset output; nil means the Mac's default output.
    var deviceUID: String?
    /// Last known name of that output, shown while it isn't connected.
    var deviceName: String?
    /// Voice volume in dB (-24…+12).
    var gainDB: Double = 0
    /// Mac: the external screen showing this language's captions (display UUID); nil = Off.
    var captionScreenID: String?
    /// Last known name of that screen, shown while it isn't connected.
    var captionScreenName: String?
}

/// Language names, voices and other per-language facts.
enum Languages {
    struct Option: Identifiable, Hashable {
        let id: String      // e.g. "ko"
        let name: String    // e.g. "Korean"
    }

    static let english = Locale.Language(identifier: "en")

    /// Languages Apple's translation can turn English into (any variant of English is left out).
    static func supported() async -> [Option] {
        let all = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return all.compactMap { lang -> Option? in
            let code = lang.minimalIdentifier
            guard lang.languageCode?.identifier != "en", seen.insert(code).inserted else { return nil }
            return Option(id: code, name: name(code))
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Plain-English name, e.g. "Spanish (Mexico)", "Korean", "Chinese, Traditional (Taiwan)".
    static func name(_ code: String) -> String {
        let lang = Locale.Language(identifier: code)
        let base = Locale(identifier: "en").localizedString(forLanguageCode: lang.languageCode?.identifier ?? code) ?? code
        var parts: [String] = []
        if lang.languageCode?.identifier == "zh" {
            let script = lang.maximalIdentifier.contains("Hant") ? "Traditional" : "Simplified"
            let region = lang.region.flatMap { Locale(identifier: "en").localizedString(forRegionCode: $0.identifier) }
            return "Chinese, \(script)" + (region.map { " (\($0))" } ?? "")
        }
        if let region = lang.region?.identifier,
           let r = Locale(identifier: "en").localizedString(forRegionCode: region) {
            parts.append(r)
        }
        return parts.isEmpty ? base : "\(base) (\(parts.joined(separator: ", ")))"
    }

    /// Short label for transcript files, e.g. "ES", "KO", "PT-PT".
    static func shortCode(_ code: String) -> String { code.uppercased() }

    static func isSpanish(_ code: String) -> Bool { Locale.Language(identifier: code).languageCode?.identifier == "es" }

    /// Arabic, Hebrew, Persian and Urdu are written right to left.
    static func isRightToLeft(_ code: String) -> Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    // MARK: Voices

    /// True for Apple's old "Eloquence" novelty voices (Eddy, Flo, Grandpa, Rocko…), which sound robotic.
    static func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.contains(".eloquence.") || v.identifier.contains(".speech.synthesis.")
    }

    /// Installed Apple voices for a language, best first: Premium, then Enhanced, then basic;
    /// the matching region first (Mexican Spanish for plain "Spanish"). Novelty voices are left out.
    static func voices(for code: String) -> [AVSpeechSynthesisVoice] {
        let target = Locale.Language(identifier: code)
        let targetScript = target.maximalIdentifier.split(separator: "-").dropFirst().first.map(String.init)
        // Plain "Spanish" prefers Mexico (as earlier versions did); otherwise the language's
        // usual region, e.g. Brazil for plain "Portuguese"
        let wantedRegion = target.region?.identifier
            ?? (target.languageCode?.identifier == "es" ? "MX"
                : Locale.Language(identifier: target.maximalIdentifier).region?.identifier)
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            let vl = Locale.Language(identifier: v.language)
            var s = v.quality.rawValue * 100
            if let wantedRegion, vl.region?.identifier == wantedRegion { s += 20 }
            if v.identifier.contains(".super-compact.") { s -= 10 }   // lowest-fidelity build
            if ["Paulina", "Mónica", "Monica"].contains(v.name) { s += 5 }
            return s
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { v in
                guard !isNovelty(v) else { return false }
                let vl = Locale.Language(identifier: v.language)
                guard vl.languageCode == target.languageCode else { return false }
                // Chinese: Simplified voices for Simplified, Traditional (Taiwan/Hong Kong) for Traditional
                let vScript = vl.maximalIdentifier.split(separator: "-").dropFirst().first.map(String.init)
                return targetScript == nil || vScript == nil || vScript == targetScript
            }
            .sorted { score($0) != score($1) ? score($0) > score($1) : $0.name < $1.name }
    }

    /// e.g. "Juan, Mexico (Enhanced)", "Yuna (Premium)".
    static func describe(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = "Premium"
        case .enhanced: q = "Enhanced"
        default: q = ""
        }
        // Downloaded voices often already carry the quality in their name, e.g. "Juan (Enhanced)".
        let name = q.isEmpty ? v.name : v.name.replacingOccurrences(of: "(\(q))", with: "")
            .trimmingCharacters(in: .whitespaces)
        let region = Locale.Language(identifier: v.language).region
            .flatMap { $0.identifier == "001" ? nil : $0 }   // "world"
            .flatMap { Locale(identifier: "en").localizedString(forRegionCode: $0.identifier) }
        return name + (region.map { ", \($0)" } ?? "") + (q.isEmpty ? "" : " (\(q))")
    }

    // MARK: Fixed phrases

    /// Phrases the app shows or says itself. Spanish keeps the wording earlier versions used;
    /// other languages get them translated by Apple's translation when the language is prepared.
    struct Phrases: Equatable {
        var waiting = "Waiting for the translation…"
        var soundTest = "Sound test. One, two, three."
        var sample = "For God so loved the world, that he gave his only begotten Son."
        var samplePrevious = "Let us open our Bibles to John chapter three."

        static let english = Phrases()
        static let spanish = Phrases(
            waiting: "Esperando la traducción…",
            soundTest: "Prueba de sonido. Uno, dos, tres.",
            sample: "Porque de tal manera amó Dios al mundo, que ha dado a su Hijo unigénito.",
            samplePrevious: "Abramos nuestras Biblias en Juan capítulo tres.")
    }
}
