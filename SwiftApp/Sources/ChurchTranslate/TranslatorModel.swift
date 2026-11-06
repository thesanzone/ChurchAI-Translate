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
    var inputUID: String? { didSet { defaults.set(inputUID, forKey: "inputUID") } }
    var outputUID: String? { didSet { defaults.set(outputUID, forKey: "outputUID") } }
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
            transcriptionOptions: [],
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

        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        do {
            let context = AnalysisContext()
            context.contextualStrings[.general] = churchVocabulary
            try await analyzer.setContext(context)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw SimpleError("No audio format is available for speech recognition.")
            }
            try await analyzer.prepareToAnalyze(in: format)

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
            let startTime = Date()
            startedAt = startTime
            lastSpeech = nil
            heardAnySignal = false
            liveEnglish = ""
            openTranscriptFile()
            keepAwake(true)
            state = .listening

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                        if result.isFinal {
                            self.liveEnglish = ""
                            guard !text.isEmpty else { continue }
                            let spokenAt = startTime.addingTimeInterval(result.range.end.seconds)
                            await self.translateAndSpeak(text, spokenAt: spokenAt, using: translator)
                        } else {
                            self.liveEnglish = text
                        }
                    }
                } catch {
                    await MainActor.run { self?.fail("Speech recognition stopped: \(error.localizedDescription)") }
                }
            }
            try await analyzer.start(inputSequence: stream)
        } catch {
            fail("Couldn't start: \(error.localizedDescription)")
        }
    }

    private func translateAndSpeak(_ english: String, spokenAt: Date, using session: TranslationSession) async {
        do {
            let spanish = try await session.translate(english).targetText
            speaker.speak(spanish)
            let delay = max(0, Date().timeIntervalSince(spokenAt))
            lastDelay = delay
            let row = TranscriptRow(time: Date(), english: english, spanish: spanish, delay: delay)
            rows.append(row)
            writeTranscript(row)
            print("[EN] \(english)\n[ES] \(spanish)  (delay \(String(format: "%.1f", delay))s)")
        } catch {
            print("[!] Translation error: \(error)")
        }
    }

    func stop() async {
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
        print("[done] Finished playing recording")
        await stop()
        NotificationCenter.default.post(name: .recordingFinished, object: nil)
    }

    private func fail(_ message: String) {
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
        if !isListening, waiting == 0, startedAt == nil, outputLevel > 0 {
            // test-speakers playback finished: let the meter fall
        }
    }

    // MARK: - Transcripts & sleep

    static var transcriptsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Church Translate Transcripts", isDirectory: true)
    }

    private func openTranscriptFile() {
        let folder = Self.transcriptsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let url = folder.appendingPathComponent(f.string(from: Date()) + ".txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        transcriptFile = try? FileHandle(forWritingTo: url)
        transcriptFile?.seekToEndOfFile()
        let header = "Church Translate — \(Date().formatted(date: .complete, time: .shortened))\n\n"
        transcriptFile?.write(header.data(using: .utf8)!)
    }

    private func writeTranscript(_ row: TranscriptRow) {
        let t = row.time.formatted(date: .omitted, time: .standard)
        let line = "[\(t)] EN: \(row.english)\n[\(t)] ES: \(row.spanish)\n\n"
        transcriptFile?.write(line.data(using: .utf8)!)
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
