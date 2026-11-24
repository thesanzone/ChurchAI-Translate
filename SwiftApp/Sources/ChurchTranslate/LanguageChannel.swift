import AVFoundation
import Foundation
import Observation
import Translation

/// One language being translated: its saved settings (a row in the Outputs tab), its
/// translation session and its voice. TranslatorModel keeps one per row.
@MainActor
@Observable
final class LanguageChannel: Identifiable {
    enum Status: Equatable {
        case checking
        case ready
        case needsDownload
        case unsupported
    }

    let id: UUID
    /// Saved settings. Changes are applied to the voice straight away and saved by the model.
    var config: LanguageOutput {
        didSet {
            guard config != oldValue else { return }
            applyToSpeaker()
            onChange?(oldValue)
        }
    }
    var status: Status = .checking
    var phrases = Languages.Phrases.english
    /// Voice output level for this language's meter (0…1 RMS).
    var outputLevel: Float = 0
    /// Phrases waiting to be spoken.
    var waiting = 0
    /// Mac: the chosen output device isn't plugged in, so this language isn't being spoken.
    var deviceMissing = false
    /// Seconds from the English being spoken to this language's translation (latest sentence).
    var lastDelay: Double?
    var hasPlayedSound = false

    let speaker = Speaker()
    private(set) var session: TranslationSession?
    /// Called after every settings change (the model saves and reacts).
    var onChange: ((LanguageOutput) -> Void)?

    init(_ config: LanguageOutput) {
        self.id = config.id
        self.config = config
        applyToSpeaker()
    }

    var name: String { Languages.name(config.language) }
    var isRightToLeft: Bool { Languages.isRightToLeft(config.language) }
    var target: Locale.Language { Locale.Language(identifier: config.language) }
    /// On, and its translation works.
    var isActive: Bool { config.isOn && status == .ready && session != nil }

    // MARK: Voice

    var voices: [AVSpeechSynthesisVoice] { Languages.voices(for: config.language) }

    /// The voice actually used: the chosen one if it's still installed, else the best installed.
    var effectiveVoice: AVSpeechSynthesisVoice? {
        if let id = config.voiceID, let v = AVSpeechSynthesisVoice(identifier: id), !Languages.isNovelty(v) {
            return v
        }
        return voices.first
    }

    var voiceName: String { effectiveVoice.map(Languages.describe) ?? "No voice installed" }

    /// Apple's basic voices sound robotic; a free Enhanced or Premium download sounds far better.
    var usesBasicVoice: Bool { (effectiveVoice?.quality ?? .default) == .default }
    var betterVoiceInstalled: Bool { voices.contains { $0.quality != .default } }

    func chooseVoice(_ id: String?) {
        config.voiceID = id
        config.voiceChosenByUser = true
    }

    /// After voices were downloaded or removed: keep the volunteer's choice if it's still there,
    /// otherwise use the best installed voice (and move to a better one if one was just added).
    func refreshVoice() {
        let saved = config.voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        if saved == nil || Languages.isNovelty(saved!) {
            if config.voiceID != nil { config.voiceID = nil }
        } else if let s = saved, let best = voices.first,
                  best.quality.rawValue > s.quality.rawValue, !config.voiceChosenByUser {
            config.voiceID = best.identifier
        }
        applyToSpeaker()
    }

    func applyToSpeaker() {
        speaker.language = config.language
        speaker.label = Languages.name(config.language)
        speaker.voiceIdentifier = effectiveVoice?.identifier
        speaker.outputGainDB = Float(config.gainDB)
    }

    // MARK: Translation

    /// Check this language's translation is installed and works, and translate the app's own phrases.
    func prepare() async {
        status = .checking
        session = nil
        let language = config.language
        let availability = await LanguageAvailability().status(from: Languages.english, to: target)
        guard config.language == language else { return }   // changed meanwhile
        if availability == .unsupported {
            status = .unsupported
            return
        }
        // The status check isn't always reliable inside an app, so try a real translation.
        let s = Self.makeSession(target)
        do {
            let test = try await s.translate("Good morning").targetText
            guard config.language == language else { return }
            print("[prepare] \(name): Good morning -> \(test)")
            session = s
            status = .ready
            await translatePhrases(with: s)
        } catch {
            guard config.language == language else { return }
            print("[prepare] \(name) translation not installed: \(error.localizedDescription)")
            status = .needsDownload
        }
    }

    private func translatePhrases(with s: TranslationSession) async {
        if Languages.isSpanish(config.language) {
            phrases = .spanish
            return
        }
        let en = Languages.Phrases.english
        var p = en
        // Best effort: if any of these fail the English wording is kept.
        p.waiting = (try? await s.translate(en.waiting).targetText) ?? en.waiting
        p.soundTest = (try? await s.translate(en.soundTest).targetText) ?? en.soundTest
        p.sample = (try? await s.translate(en.sample).targetText) ?? en.sample
        p.samplePrevious = (try? await s.translate(en.samplePrevious).targetText) ?? en.samplePrevious
        phrases = p
    }

    /// Uses Apple's standard (high-fidelity) translation model. The separate
    /// "low latency" model is a different download and is usually not installed.
    static func makeSession(_ target: Locale.Language) -> TranslationSession {
        if #available(iOS 26.4, macOS 26.4, *) {
            return TranslationSession(installedSource: Languages.english, target: target, preferredStrategy: .highFidelity)
        }
        return TranslationSession(installedSource: Languages.english, target: target)
    }

    // MARK: Speaker

    private var startInProgress = false
    /// Mac: opening the output took too long (a stuck USB audio device). Retried every 2 s.
    var outputNotResponding = false

    /// Start the voice on its output, in the background with a time limit. If the device isn't
    /// plugged in (or doesn't respond), the language keeps being translated (transcript and
    /// captions) and the model tries again every couple of seconds.
    @discardableResult
    func startSpeaker() async -> Bool {
        guard !startInProgress else { return false }
        startInProgress = true
        enum Outcome: Sendable { case started, notConnected, failed(String), timedOut }
        let once = OnceFlag()
        let speaker = self.speaker
        let outcome: Outcome = await withCheckedContinuation { continuation in
            speaker.start(outputDeviceUID: config.deviceUID) { [weak self] error in
                Task { @MainActor in self?.startInProgress = false }
                guard once.claim() else { return }
                switch error {
                case nil: continuation.resume(returning: .started)
                case Speaker.SpeakerError.notConnected?: continuation.resume(returning: .notConnected)
                case let e?: continuation.resume(returning: .failed(e.localizedDescription))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
        switch outcome {
        case .started:
            if deviceMissing || outputNotResponding { print("[voice] \(name): speaker output connected") }
            deviceMissing = false
            outputNotResponding = false
            return true
        case .notConnected:
            if !deviceMissing { print("[!] \(name): speaker output \(config.deviceName ?? "?") isn't connected") }
            deviceMissing = true
            return false
        case .timedOut:
            if !outputNotResponding { print("[!] \(name): speaker output isn't responding (still opening after 6 s)") }
            outputNotResponding = true
            return false
        case .failed(let message):
            print("[!] \(name): couldn't start the voice: \(message)")
            return false
        }
    }

    func stopSpeaker() {
        speaker.stop()
        outputLevel = 0
        waiting = 0
    }

    func tick() {
        let level = speaker.level.value.rms
        if outputLevel != level { outputLevel = level }
        let w = speaker.waiting
        if waiting != w { waiting = w }
        if level > 0, !hasPlayedSound { hasPlayedSound = true }
    }
}

/// Lets exactly one of several callbacks resume a continuation.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
