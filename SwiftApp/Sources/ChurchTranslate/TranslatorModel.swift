import AVFoundation
import Foundation
import Observation
import Speech
import Translation
#if os(iOS)
import UIKit
#endif

/// One translated phrase in the transcript.
struct TranscriptRow: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let english: String
    let spanish: String
    let delay: Double
}

enum EngineState: Equatable {
    case preparing(String)
    case needsTranslationDownload
    case ready
    case listening
    case error(String)
}

/// Runs the whole pipeline: audio in -> Apple speech recognition -> Apple translation -> Spanish voice.
@MainActor
@Observable
final class TranslatorModel {
    // MARK: Published state for the UI
    var state: EngineState = .preparing("Starting up…") {
        didSet { if state != oldValue { print("[state] \(state)") } }
    }
    var rows: [TranscriptRow] = []
    var liveEnglish = ""                 // words being heard right now (not final yet)
    /// Phrases kept in the on-screen transcript (the saved transcript file keeps them all).
    static let maxRowsOnScreen = 200
    /// Words changed or removed by the swear-word filter since launch (the words aren't kept).
    var filteredCount = 0
    /// Swear-word filter loaded from word_filter.txt (shared with the Python app).
    let wordFilter = WordFilter()
    var inputLevel: Float = 0
    var inputPeak: Float = 0
    var outputLevel: Float = 0
    var lastSpeech: Date?
    var lastClip: Date?
    var startedAt: Date?
    var lastDelay: Double?
    var waiting = 0
    var playingFile: String?
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []
    var voices: [AVSpeechSynthesisVoice] = []

    // MARK: Settings (remembered between launches)
    var inputUID: String? { didSet { defaults.set(inputUID, forKey: "inputUID"); loadGains() } }
    var outputUID: String? { didSet { defaults.set(outputUID, forKey: "outputUID"); loadGains() } }

    // MARK: Volume faders (dB), remembered per device
    static let inputGainRange: ClosedRange<Double> = -12...24
    static let outputGainRange: ClosedRange<Double> = -24...12
    /// Microphone level going to the translator (applied before the meter and recogniser).
    var inputGainDB: Double = 0 {
        didSet {
            capture.gain.set(db: inputGainDB)
            saveGain(inputGainDB, key: "inputGains", device: inputUID)
        }
    }
    /// Spanish voice volume.
    var outputGainDB: Double = 0 {
        didSet {
            speaker.outputGainDB = Float(outputGainDB)
            saveGain(outputGainDB, key: "outputGains", device: outputUID)
        }
    }
    /// Seconds left while Auto level is listening (nil when not running).
    var autoLevelSecondsLeft: Int?
    /// Message to show the volunteer after Auto level (nil when none).
    var autoLevelMessage: String?
    var voiceID: String? { didSet { defaults.set(voiceID, forKey: "voiceID"); speaker.voiceIdentifier = voiceID } }
    var fastSpeech: Bool { didSet { defaults.set(fastSpeech, forKey: "fastSpeech"); speaker.fast = fastSpeech } }
    var captionSize: Double { didSet { defaults.set(captionSize, forKey: "captionSize") } }

    /// Sound quieter than this counts as silence for the "speech heard" indicator.
    let silenceThreshold: Float = 0.003

    // MARK: Internals
    private let defaults = UserDefaults.standard
    private let capture = AudioCapture()
    private let speaker = SpanishSpeaker()
    private var translator: TranslationSession?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    /// True once any non-zero sample arrives after Start. A switched-off microphone sends exact zeros.
    private(set) var heardAnySignal = false
    private var transcriptFile: FileHandle?
    #if os(macOS)
    private var awakeActivity: NSObjectProtocol?
    #endif

    let english = Locale(identifier: "en-US")
    let source = Locale.Language(identifier: "en")
    let target = Locale.Language(identifier: "es")

    /// Words the recogniser should expect in church.
    let churchVocabulary = [
        "Scripture", "Gospel", "Hallelujah", "Amen", "Genesis", "Exodus", "Leviticus",
        "Deuteronomy", "Psalms", "Proverbs", "Isaiah", "Jeremiah", "Ezekiel", "Matthew",
        "Mark", "Luke", "John", "Romans", "Corinthians", "Galatians", "Ephesians",
        "Philippians", "Colossians", "Thessalonians", "Hebrews", "Revelation",
        "Holy Spirit", "Messiah", "Pharisees", "Nebuchadnezzar", "righteousness",
        "salvation", "grace", "covenant", "communion", "baptism", "tithe", "sanctification",
    ]

    init() {
        inputUID = defaults.string(forKey: "inputUID")
        outputUID = defaults.string(forKey: "outputUID")
        voiceID = defaults.string(forKey: "voiceID")
        fastSpeech = defaults.bool(forKey: "fastSpeech")
        let size = defaults.double(forKey: "captionSize")
        captionSize = size > 0 ? size : 56
        speaker.voiceIdentifier = voiceID
        speaker.fast = fastSpeech
        speaker.preloadPiper()
        refreshDevices()
        loadGains()
        speaker.onRecovery = { [weak self] message in
            Task { @MainActor in self?.showNotice(message) }
        }
        // A main-actor task rather than a Timer + MainActor.assumeIsolated: that executor check
        // crashed the app (EXC_BAD_ACCESS in swift_task_isMainExecutor) on macOS 27.
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let model = self else { return }
                model.tickMeters()
            }
        }
    }

    // MARK: - Volume faders

    /// Apply the saved fader settings for the selected devices.
    func loadGains() {
        let ins = defaults.dictionary(forKey: "inputGains") as? [String: Double] ?? [:]
        let outs = defaults.dictionary(forKey: "outputGains") as? [String: Double] ?? [:]
        let i = ins[inputUID ?? "default"] ?? 0
        let o = outs[outputUID ?? "default"] ?? 0
        if inputGainDB != i { inputGainDB = i } else { capture.gain.set(db: i) }
        if outputGainDB != o { outputGainDB = o } else { speaker.outputGainDB = Float(o) }
    }

    private func saveGain(_ db: Double, key: String, device: String?) {
        guard saveGainsEnabled else { return }
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[device ?? "default"] = (db * 10).rounded() / 10
        defaults.set(all, forKey: key)
    }

    /// Listen for 10 seconds while someone speaks, then set the microphone level so
    /// normal speech sits around -20 dBFS (well above the quiet line, well below clipping).
    func startAutoLevel() {
        guard isListening else {
            autoLevelMessage = "Press Start first. Then click Auto while the pastor (or someone at the pulpit microphone) is speaking normally."
            return
        }
        guard autoLevelSecondsLeft == nil else { return }
        let seconds = 10
        capture.gain.speechFloor = silenceThreshold / max(capture.gain.linear, 0.000_1) * 0.5
        capture.gain.startAuto(seconds: Double(seconds))
        autoLevelSecondsLeft = seconds
        Task { @MainActor [weak self] in
            for left in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if !self.isListening { break }
                self.autoLevelSecondsLeft = left > 0 ? left : nil
            }
            self?.finishAutoLevel()
        }
    }

    private func finishAutoLevel() {
        autoLevelSecondsLeft = nil
        // 20 samples ≈ 1 second of speech (the microphone tap delivers ~20 buffers a second)
        guard let speech = capture.gain.autoSpeechLevel(minimumSamples: 20), speech > 0 else {
            autoLevelMessage = "Not enough speech was heard to set the level. Try again while someone is speaking into the microphone."
            return
        }
        let target: Float = 0.1   // about -20 dBFS
        let db = (20 * log10(Double(target / speech))).rounded()
        let clamped = min(max(db, Self.inputGainRange.lowerBound), Self.inputGainRange.upperBound)
        inputGainDB = clamped
        print("[auto level] speech level \(speech) -> input \(clamped) dB")
        if clamped >= Self.inputGainRange.upperBound {
            autoLevelMessage = "The microphone is very quiet, so the level is at the maximum (+\(Int(clamped)) dB). Turning up the mixer or audio interface will give a cleaner sound."
        }
    }

    var isListening: Bool { state == .listening }
    var isReady: Bool { state == .ready || state == .listening }

    // MARK: - Setup

    /// Make sure the speech and translation models are on this device.
    func prepare() async {
        guard SpeechTranscriber.isAvailable else {
            state = .error("Speech recognition isn't available on this device.")
            return
        }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: english) != nil else {
            state = .error("English speech recognition isn't supported on this device.")
            return
        }
        let probe = makeTranscriber()
        let assetStatus = await AssetInventory.status(forModules: [probe])
        print("[prepare] speech asset status: \(assetStatus)")
        if assetStatus != .installed {
            state = .preparing("Downloading English speech recognition (one time only)…")
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                state = .error("Couldn't download English speech recognition. Check the internet connection. (\(error.localizedDescription))")
                return
            }
        }

        state = .preparing("Checking Spanish translation…")
        let status = await LanguageAvailability().status(from: source, to: target)
        print("[prepare] translation status: \(status)")
        if status == .unsupported {
            state = .error("English to Spanish translation isn't supported on this device.")
            return
        }
        // The status check isn't always reliable inside an app, so try a real translation.
        if await trySession() {
            state = .ready
        } else {
            state = .needsTranslationDownload
        }
    }

    /// Create a session from the installed Spanish model and check it really translates.
    private func trySession() async -> Bool {
        let session = makeSession()
        do {
            let test = try await session.translate("Good morning").targetText
            print("[prepare] translation test: Good morning -> \(test)")
            translator = session
            return true
        } catch {
            print("[prepare] translation test failed: \(error)")
            return false
        }
    }

    /// Called after the system translation download sheet finishes.
    func translationDownloaded() async {
        if await trySession() {
            state = .ready
        } else {
            state = .error("Spanish translation wasn't downloaded. Try again from Settings → General → Language & Region → Translation Languages.")
        }
    }

    /// Uses Apple's standard (high-fidelity) translation model. The separate
    /// "low latency" model is a different download and is usually not installed.
    private func makeSession() -> TranslationSession {
        if #available(iOS 26.4, macOS 26.4, *) {
            return TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
        }
        return TranslationSession(installedSource: source, target: target)
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: english,
            // Apple masks offensive English words (e.g. "f***") as it transcribes;
            // the word filter then removes them before translation.
            transcriptionOptions: [.etiquetteReplacements],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange])
    }

    func refreshDevices() {
        inputDevices = AudioDevices.inputs()
        outputDevices = AudioDevices.outputs()
        voices = SpanishSpeaker.spanishVoices()
        #if os(macOS)
        if inputUID == nil || !inputDevices.contains(where: { $0.id == inputUID }) {
            if inputUID == nil { inputUID = (inputDevices.first { $0.name.lowercased().contains("usb") } ?? inputDevices.first)?.id }
        }
        if outputUID == nil {
            outputUID = (outputDevices.first { $0.name.lowercased().contains("usb") } ?? outputDevices.first)?.id
        }
        #endif
        let chosenByUser = defaults.bool(forKey: "voiceChosenByUser")

        // The built-in Piper voice (Mac builds) is the default: it sounds most natural.
        if PiperVoice.isAvailable {
            if voiceID == PiperVoice.identifier || !chosenByUser || !isInstalledAppleVoice(voiceID) {
                voiceID = PiperVoice.identifier
            }
            return
        }
        if voiceID == PiperVoice.identifier { voiceID = nil }   // build without Piper

        // Otherwise pick the best Apple voice if none is saved, the saved one was uninstalled,
        // or an earlier version saved one of the robotic novelty voices (e.g. "Eddy") by mistake.
        let saved = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        if saved == nil || SpanishSpeaker.isNovelty(saved!) {
            voiceID = voices.first?.identifier
        } else if let s = saved, let best = voices.first,
                  best.quality.rawValue > s.quality.rawValue, !chosenByUser {
            // A better voice was downloaded since: switch to it unless the volunteer chose one
            voiceID = best.identifier
        }
    }

    private func isInstalledAppleVoice(_ id: String?) -> Bool {
        guard let id, let v = AVSpeechSynthesisVoice(identifier: id) else { return false }
        return !SpanishSpeaker.isNovelty(v)
    }

    /// Voice choices for Settings: Piper first (when built in), then Apple voices.
    var voiceOptions: [(id: String, name: String)] {
        var list: [(id: String, name: String)] = []
        if PiperVoice.isAvailable { list.append((PiperVoice.identifier, PiperVoice.displayName)) }
        list += voices.map { ($0.identifier, "Apple — " + SpanishSpeaker.describe($0)) }
        return list
    }

    /// True when the voice in use is one of Apple's basic voices, which sound robotic.
    var usingBasicAppleVoice: Bool {
        guard voiceID != PiperVoice.identifier else { return false }
        let v = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? voices.first
        return v.map { $0.quality == .default } ?? true
    }

    var currentVoiceName: String {
        voiceOptions.first { $0.id == voiceID }?.name ?? "Default"
    }

    /// The volunteer picked a voice in Settings: remember it and stop auto-upgrading.
    func chooseVoice(_ id: String?) {
        voiceID = id
        defaults.set(true, forKey: "voiceChosenByUser")
    }

    func deviceName(_ uid: String?, in list: [AudioDevice]) -> String {
        guard let uid else { return "None" }
        return list.first { $0.id == uid }?.name ?? "Not connected"
    }

    // MARK: - Start / stop

    func startMicrophone() async {
        await start(fileURL: nil)
    }

    func startFile(_ url: URL) async {
        await start(fileURL: url)
    }

    private func start(fileURL: URL?) async {
        guard state == .ready, let translator else { return }
        #if os(macOS)
        if fileURL == nil, inputUID == nil || !inputDevices.contains(where: { $0.id == inputUID }) {
            state = .error("The microphone isn't connected. Check the cable, then pick it in the Microphone list.")
            return
        }
        #endif
        if fileURL == nil, !(await AVAudioApplication.requestRecordPermission()) {
            state = .error("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
            return
        }

        do {
            let probe = makeTranscriber()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
                throw SimpleError("No audio format is available for speech recognition.")
            }
            analyzerFormat = format
            recognitionRestarts = []
            stopping = false

            try speaker.start(outputDeviceUID: outputUID)
            let stream: AsyncStream<AnalyzerInput>
            if let fileURL {
                stream = try capture.startFile(url: fileURL, analyzerFormat: format) { [weak self] in
                    Task { @MainActor in await self?.fileFinished() }
                }
                playingFile = fileURL.lastPathComponent
            } else {
                stream = try capture.startMicrophone(deviceUID: inputUID, analyzerFormat: format)
            }
            startedAt = Date()
            lastSpeech = nil
            heardAnySignal = false
            liveEnglish = ""
            openTranscriptFile()
            keepAwake(true)
            state = .listening
            if fileURL == nil { startMicWatchdog() }

            try await startRecognition(stream: stream, format: format, translator: translator,
                                       isFile: fileURL != nil)
        } catch {
            fail("Couldn't start: \(error.localizedDescription)")
        }
    }

    // MARK: - Speech recognition (restartable)

    private var analyzerFormat: AVAudioFormat?
    private var recognitionRestarts: [Date] = []
    /// True while Stop is tearing things down, so the ending recogniser isn't treated as a failure.
    private var stopping = false
    /// Testing: make the recogniser fail once after its first sentence (--simulate-recognizer-error).
    var simulateRecognizerError = false

    /// Start Apple's speech recogniser on `stream`. If it fails during a service it is restarted
    /// on a fresh stream from the same microphone (see recognitionFailed).
    private func startRecognition(stream: AsyncStream<AnalyzerInput>, format: AVAudioFormat,
                                  translator: TranslationSession, isFile: Bool) async throws {
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        let context = AnalysisContext()
        context.contextualStrings[.general] = churchVocabulary
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)

        let startTime = Date()
        resultsTask = Task { [weak self] in
            do {
                var finals = 0
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    if result.isFinal {
                        self.liveEnglish = ""
                        guard !text.isEmpty else { continue }
                        let spokenAt = startTime.addingTimeInterval(result.range.end.seconds)
                        await self.translateAndSpeak(text, spokenAt: spokenAt, using: translator)
                        finals += 1
                        if self.simulateRecognizerError && finals == 1 {
                            self.simulateRecognizerError = false
                            throw SimpleError("simulated recogniser failure (test)")
                        }
                    } else {
                        self.liveEnglish = self.filterEnglish(text, mask: "•••").text
                    }
                }
                // A live microphone stream never ends by itself, so ending here is a failure
                if !isFile { await self?.recognitionFailed(SimpleError("the recogniser stopped"), translator) }
            } catch is CancellationError {
                return
            } catch {
                await self?.recognitionFailed(error, translator)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Restart speech recognition instead of ending the service, up to 5 times in 10 minutes.
    private func recognitionFailed(_ error: Error, _ translator: TranslationSession) async {
        guard isListening, !stopping, let format = analyzerFormat else { return }
        print("[!] Speech recognition error: \(error.localizedDescription)")
        let now = Date()
        recognitionRestarts = recognitionRestarts.filter { now.timeIntervalSince($0) < 600 } + [now]
        guard recognitionRestarts.count <= 5 else {
            fail("Speech recognition keeps stopping: \(error.localizedDescription)")
            return
        }
        if let old = analyzer { await old.cancelAndFinishNow() }
        analyzer = nil
        liveEnglish = ""
        do {
            let stream = capture.newStream(analyzerFormat: format)   // same microphone, fresh stream
            try await startRecognition(stream: stream, format: format, translator: translator,
                                       isFile: playingFile != nil)
            showNotice("Speech recognition had a hiccup and restarted by itself.")
            print("[recognition] restarted (\(recognitionRestarts.count) in the last 10 minutes)")
        } catch {
            fail("Speech recognition stopped: \(error.localizedDescription)")
        }
    }

    private func translateAndSpeak(_ english: String, spokenAt: Date, using session: TranslationSession) async {
        // Word filter, English side: misheard swears show as ••• and are left out of the translation
        let shownEnglish = filterEnglish(english, mask: "•••")
        let toTranslate = filterEnglish(english, mask: "")
        guard !toTranslate.text.isEmpty else {
            noteFiltered(shownEnglish.changed)
            return
        }
        do {
            let rawSpanish = try await session.translate(toTranslate.text).targetText
            // Word filter, Spanish side: swap risky regional words and drop blocked ones
            // before anything is spoken, captioned or saved
            let spanish = wordFilter.clean(rawSpanish, mask: "")
            noteFiltered(shownEnglish.changed + spanish.changed)
            if !spanish.text.isEmpty { speaker.speak(spanish.text) }
            let delay = max(0, Date().timeIntervalSince(spokenAt))
            lastDelay = delay
            let row = TranscriptRow(time: Date(), english: shownEnglish.text,
                                    spanish: spanish.text.isEmpty ? "(filtered)" : spanish.text, delay: delay)
            appendRow(row)
            writeTranscript(row)
            print("[EN] \(row.english)\n[ES] \(row.spanish)  (delay \(String(format: "%.1f", delay))s)")
        } catch {
            print("[!] Translation error: \(error)")
        }
    }

    /// Clean English text: Apple's masked words ("f***") plus anything on the block list.
    func filterEnglish(_ text: String, mask: String) -> (text: String, changed: Int) {
        var t = text
        var masked = 0
        if let re = try? NSRegularExpression(pattern: "\\S*\\*+\\S*") {
            let ns = t as NSString
            masked = re.numberOfMatches(in: t, range: NSRange(location: 0, length: ns.length))
            if masked > 0 {
                t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: ns.length),
                                                withTemplate: mask.isEmpty ? "" : mask)
            }
        }
        let cleaned = wordFilter.clean(t, mask: mask)
        var result = cleaned.text
        if masked > 0 && mask.isEmpty {
            result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if result.range(of: "\\p{L}", options: .regularExpression) == nil { result = "" }
        }
        return (result, masked + cleaned.changed)
    }

    /// Only the latest phrases stay on screen so a 3-hour service doesn't slow the window down;
    /// the transcript file keeps everything.
    func appendRow(_ row: TranscriptRow) {
        rows.append(row)
        if rows.count > Self.maxRowsOnScreen { rows.removeFirst(rows.count - Self.maxRowsOnScreen) }
    }

    // MARK: - Test hooks (command-line options only)

    func simulateVoiceStall() { speaker.simulateMissingEndSignal = true }
    func simulateOutputDropout() { speaker.simulateOutputDropout() }
    func simulateMicDropout() { capture.simulateMicDropout() }
    var speakerWaiting: Int { speaker.waiting }
    var micSecondsSinceAudio: TimeInterval { capture.secondsSinceLastAudio }

    private func noteFiltered(_ count: Int) {
        guard count > 0 else { return }
        filteredCount += count
        print("[filter] Changed or removed \(count) word(s) in this phrase.")   // never logs the words
    }

    func stop() async {
        stopping = true
        stopMicWatchdog()
        capture.stop()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // Give the last phrase a moment to translate before tearing down
        try? await Task.sleep(nanoseconds: 300_000_000)
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        speaker.stop()
        liveEnglish = ""
        playingFile = nil
        startedAt = nil
        keepAwake(false)
        closeTranscriptFile()
        if state == .listening { state = .ready }
    }

    private func fileFinished() async {
        // End the audio, let the recogniser finish the last sentence, wait for the voice, then stop
        capture.finishInput()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        // Allow the final result to be translated and queued
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var waited = 0
        while speaker.waiting > 0, waited < 120 {   // at most 30 s
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        print(String(format: "[levels] input gain %+.0f dB, loudest input RMS %.4f; output gain %+.0f dB, loudest output RMS %.4f",
                     inputGainDB, loudestInputRMS, outputGainDB, loudestOutputRMS))
        print("[done] Finished playing recording")
        await stop()
        NotificationCenter.default.post(name: .recordingFinished, object: nil)
    }

    private func fail(_ message: String) {
        stopMicWatchdog()
        capture.stop()
        speaker.stop()
        resultsTask?.cancel()
        analyzer = nil
        startedAt = nil
        playingFile = nil
        keepAwake(false)
        closeTranscriptFile()
        state = .error(message)
        print("[!] \(message)")
    }

    /// Clear an error so the volunteer can try again.
    func resetError() {
        if case .error = state { state = translator == nil ? .preparing("Retrying…") : .ready }
        if translator == nil { Task { await prepare() } }
    }

    func testSpeakers() {
        do {
            try speaker.start(outputDeviceUID: outputUID)
            speaker.speak("Prueba de sonido. Uno, dos, tres.")
        } catch {
            state = .error("Couldn't play through the speakers: \(error.localizedDescription)")
        }
    }

    // MARK: - Meters

    private func tickMeters() {
        let i = capture.level.value
        inputLevel = i.rms
        inputPeak = i.peak
        outputLevel = speaker.level.value.rms
        waiting = speaker.waiting
        let now = Date()
        if isListening, i.rms >= silenceThreshold { lastSpeech = now }
        if isListening, i.peak > 0 { heardAnySignal = true }
        if i.peak >= 0.99 { lastClip = now }
        if isListening {
            loudestInputRMS = max(loudestInputRMS, i.rms)
            loudestOutputRMS = max(loudestOutputRMS, outputLevel)
        }
    }

    /// Loudest meter readings during the current run (printed by the recording test).
    private(set) var loudestInputRMS: Float = 0
    private(set) var loudestOutputRMS: Float = 0
    /// False during command-line tests so test fader values aren't saved.
    var saveGainsEnabled = true

    // MARK: - Transcripts & sleep

    static var transcriptsFolder: URL {
        // CHURCH_TRANSCRIPTS_DIR lets tests point transcripts somewhere else (e.g. a full disk)
        if let dir = ProcessInfo.processInfo.environment["CHURCH_TRANSCRIPTS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Church Translate Transcripts", isDirectory: true)
    }

    /// Shown to the volunteer when the transcript can't be saved (translation carries on).
    var transcriptProblem: String?

    /// Short-lived message after the app recovered from a problem by itself (clears after 20 s).
    var notice: String?
    private var noticeTask: Task<Void, Never>?

    // MARK: - Microphone dropout recovery

    private var micWatchTask: Task<Void, Never>?
    private var micDropoutReported = false

    /// While listening to the microphone, check every second that audio is still arriving.
    /// A microphone sends audio continuously (even silence), so none for 3 seconds means the
    /// device dropped out; re-open it every 2 seconds until audio flows again. Speech
    /// recognition keeps running throughout, so nothing else needs restarting.
    private func startMicWatchdog() {
        micWatchTask?.cancel()
        micDropoutReported = false
        capture.onDropout = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                print("[!] \(reason)")
                self.micDropoutReported = true
            }
        }
        micWatchTask = Task { @MainActor [weak self] in
            var recovering = false
            var lastAttempt = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.isListening, self.capture.usingMicrophone else { continue }
                let silentFor = self.capture.secondsSinceLastAudio
                if silentFor > 3 || self.micDropoutReported {
                    if !recovering {
                        recovering = true
                        self.showNotice("The microphone stopped sending sound. Reconnecting…")
                    }
                    if Date().timeIntervalSince(lastAttempt) >= 2 {
                        lastAttempt = Date()
                        self.micDropoutReported = false
                        do {
                            try self.capture.reconnectMicrophone()
                            print("[mic] reconnect attempt made")
                        } catch {
                            print("[!] Microphone not available yet: \(error.localizedDescription)")
                        }
                    }
                } else if recovering, silentFor < 1 {
                    recovering = false
                    self.showNotice("The microphone reconnected. Translation continues.")
                }
            }
        }
    }

    private func stopMicWatchdog() {
        micWatchTask?.cancel()
        micWatchTask = nil
        capture.onDropout = nil
    }

    func showNotice(_ message: String) {
        notice = message
        print("[notice] \(message)")
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    private func openTranscriptFile() {
        transcriptProblem = nil
        let folder = Self.transcriptsFolder
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let url = folder.appendingPathComponent(f.string(from: Date()) + ".txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw SimpleError("couldn't create the file")
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            transcriptFile = handle
        } catch {
            transcriptFile = nil
            transcriptSaveFailed(error)
            return
        }
        appendTranscript("Church Translate — \(Date().formatted(date: .complete, time: .shortened))\n\n")
    }

    private func writeTranscript(_ row: TranscriptRow) {
        let t = row.time.formatted(date: .omitted, time: .standard)
        appendTranscript("[\(t)] EN: \(row.english)\n[\(t)] ES: \(row.spanish)\n\n")
    }

    /// Never lets a full or unwritable disk crash the app: the old FileHandle.write(_:) raised
    /// an exception that killed the app; write(contentsOf:) reports the error instead.
    private func appendTranscript(_ text: String) {
        guard let handle = transcriptFile, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            transcriptFile = nil      // stop trying; keep translating
            transcriptSaveFailed(error)
        }
    }

    private func transcriptSaveFailed(_ error: Error) {
        transcriptProblem = "The transcript isn't being saved (the disk may be full). Translation is still running."
        print("[!] Transcript not saved: \(error.localizedDescription)")
    }

    private func closeTranscriptFile() {
        try? transcriptFile?.close()
        transcriptFile = nil
    }

    private func keepAwake(_ on: Bool) {
        #if os(macOS)
        if on, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "Live translation running")
        } else if !on, let a = awakeActivity {
            ProcessInfo.processInfo.endActivity(a)
            awakeActivity = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

extension Notification.Name {
    static let recordingFinished = Notification.Name("recordingFinished")
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
