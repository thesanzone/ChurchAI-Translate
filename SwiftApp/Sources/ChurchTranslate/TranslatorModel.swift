import AVFoundation
import Foundation
import Observation
import Speech
import Translation
#if os(iOS)
import UIKit
#endif

/// One English phrase and its translations, keyed by language (LanguageChannel.id).
struct TranscriptRow: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let english: String
    /// Filled in as each language's translation arrives.
    var translations: [UUID: String]
    var delay: Double
    /// Shown in place of a translation the word filter removed completely.
    static let filtered = "(filtered)"
}

/// An external screen captions can be shown on (Mac).
struct CaptionScreen: Identifiable, Equatable {
    let id: String          // display UUID, stable across reconnects
    let name: String
}

enum EngineState: Equatable {
    case preparing(String)
    case ready
    case listening
    case error(String)
}

/// Runs the whole pipeline: audio in -> Apple speech recognition -> Apple translation into each
/// language that's on -> each language's voice, captions and the transcript.
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
    /// Loudest voice output right now, across all languages.
    var outputLevel: Float = 0
    var lastSpeech: Date?
    var lastClip: Date?
    var startedAt: Date?
    var lastDelay: Double?
    var waiting = 0
    var playingFile: String?
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []

    // MARK: Languages (the Outputs tab)
    /// One per row in the Outputs tab, in the order shown.
    var channels: [LanguageChannel] = []
    /// Languages Apple's translation offers (for the Language menus).
    var languageOptions: [Languages.Option] = []
    /// Languages that are on and ready to translate.
    var activeChannels: [LanguageChannel] { channels.filter(\.isActive) }
    /// Languages that are on (whether or not their translation is ready).
    var onChannels: [LanguageChannel] { channels.filter(\.config.isOn) }

    // MARK: Captions
    var captionStyle: CaptionStyle { didSet { saveJSON(captionStyle, key: "captionStyle") } }
    /// Mac: true while captions windows are shown on their screens.
    var captionsShowing = false
    /// Mac: external screens available for captions right now.
    var captionScreens: [CaptionScreen] = []

    // MARK: Settings (remembered between launches)
    var inputUID: String? { didSet { if persistEnabled { defaults.set(inputUID, forKey: "inputUID") }; loadGains() } }
    /// True when the input is the Mac's own sound (a video or browser) rather than a microphone.
    var usingSystemAudio: Bool { inputUID == SystemAudio.deviceUID }

    // MARK: Volume faders (dB)
    static let inputGainRange: ClosedRange<Double> = -12...24
    static let outputGainRange: ClosedRange<Double> = -24...12
    /// Microphone level going to the translator (applied before the meter and recogniser).
    var inputGainDB: Double = 0 {
        didSet {
            capture.gain.set(db: inputGainDB)
            saveGain(inputGainDB, key: "inputGains", device: inputUID)
        }
    }
    /// Seconds left while Auto level is listening (nil when not running).
    var autoLevelSecondsLeft: Int?
    /// Message to show the volunteer after Auto level (nil when none).
    var autoLevelMessage: String?
    var fastSpeech: Bool {
        didSet {
            defaults.set(fastSpeech, forKey: "fastSpeech")
            for c in channels { c.speaker.fast = fastSpeech }
        }
    }
    /// False during command-line tests, so test settings never replace the volunteer's.
    var persistEnabled = true

    /// Sound quieter than this counts as silence for the "speech heard" indicator.
    let silenceThreshold: Float = 0.003

    // MARK: Internals
    private let defaults = UserDefaults.standard
    private let capture = AudioCapture()
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
        fastSpeech = defaults.bool(forKey: "fastSpeech")
        var style = Self.loadJSON(CaptionStyle.self, key: "captionStyle") ?? CaptionStyle()
        if defaults.object(forKey: "captionStyle") == nil, defaults.double(forKey: "captionSize") > 0 {
            style.size = defaults.double(forKey: "captionSize")      // from version 2
        }
        captionStyle = style
        refreshDevices()
        channels = loadOutputs().map(makeChannel)
        refreshVoices()
        loadGains()
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

    // MARK: - Languages (Outputs tab)

    private func makeChannel(_ config: LanguageOutput) -> LanguageChannel {
        let c = LanguageChannel(config)
        c.speaker.fast = fastSpeech
        c.speaker.onRecovery = { [weak self] message in
            Task { @MainActor in self?.showNotice(message) }
        }
        c.onChange = { [weak self, weak c] old in
            guard let self, let c else { return }
            self.channelChanged(c, from: old)
        }
        return c
    }

    /// The saved Outputs rows. The first time version 3 runs, version 2's Spanish settings
    /// (speakers, voice, volume) become the first row.
    private func loadOutputs() -> [LanguageOutput] {
        if let saved = Self.loadJSON([LanguageOutput].self, key: "outputs") { return saved }
        var row = LanguageOutput(language: "es")
        let oldOutput = defaults.string(forKey: "outputUID")
        #if os(macOS)
        row.deviceUID = oldOutput ?? (outputDevices.first { $0.name.lowercased().contains("usb") })?.id
        row.deviceName = outputDevices.first { $0.id == row.deviceUID }?.name
        #endif
        if let v = defaults.string(forKey: "voiceID"), !v.lowercased().contains("piper") {
            row.voiceID = v
            row.voiceChosenByUser = defaults.bool(forKey: "voiceChosenByUser")
        }
        let outs = defaults.dictionary(forKey: "outputGains") as? [String: Double] ?? [:]
        row.gainDB = outs[oldOutput ?? "default"] ?? 0
        print("[settings] first run of version 3: created the Spanish row from earlier settings")
        let rows = [row]
        saveJSON(rows, key: "outputs")
        return rows
    }

    func saveOutputs() {
        saveJSON(channels.map(\.config), key: "outputs")
    }

    private func saveJSON<T: Encodable>(_ value: T, key: String) {
        guard persistEnabled, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// A row's settings changed in the Outputs or Settings tab.
    private func channelChanged(_ c: LanguageChannel, from old: LanguageOutput) {
        saveOutputs()
        if c.config.language != old.language {
            c.phrases = .english
            Task { await c.prepare() }
        }
        if c.config.isOn != old.isOn {
            #if os(iOS)
            // iPad sends sound to one output, so only one language can be on
            if c.config.isOn { for other in channels where other !== c && other.config.isOn { other.config.isOn = false } }
            #endif
            if isListening {
                if c.config.isOn, c.isActive { Task { await c.startSpeaker() } } else if !c.config.isOn { c.stopSpeaker() }
            }
        }
        if c.config.deviceUID != old.deviceUID, c.speaker.isStarted || (isListening && c.isActive) {
            Task { await c.startSpeaker() }   // moves the voice to the newly chosen output
        }
    }

    /// Add a language row (the first language not already in the list). It starts switched off
    /// during a service, so nothing new is heard until the volunteer turns it on.
    func addLanguage() {
        let used = Set(channels.map(\.config.language))
        let preferred = ["es", "ko", "pt", "zh", "vi", "fr", "ar", "ru", "uk", "ja"]
        let options = languageOptions.map(\.id)
        let code = preferred.first { !used.contains($0) && (options.isEmpty || options.contains($0)) }
            ?? options.first { !used.contains($0) } ?? "es"
        var row = LanguageOutput(language: code)
        row.isOn = !isListening
        #if os(iOS)
        row.isOn = false
        #endif
        let c = makeChannel(row)
        channels.append(c)
        saveOutputs()
        Task { await c.prepare() }
    }

    func removeChannel(_ c: LanguageChannel) {
        c.stopSpeaker()
        channels.removeAll { $0 === c }
        saveOutputs()
    }

    func moveChannels(from: IndexSet, to: Int) {
        channels.move(fromOffsets: from, toOffset: to)
        saveOutputs()
    }

    func channel(_ id: UUID?) -> LanguageChannel? { channels.first { $0.id == id } }

    /// Testing: use these languages for this run only (nothing is saved).
    func useTestLanguages(_ codes: [String], deviceUIDs: [String?]) {
        persistEnabled = false
        channels = codes.enumerated().map { i, code in
            var row = LanguageOutput(language: code)
            row.deviceUID = i < deviceUIDs.count ? deviceUIDs[i] : nil
            row.deviceName = row.deviceUID.map { uid in outputDevices.first { $0.id == uid }?.name ?? "Test device" }
            return makeChannel(row)
        }
        refreshVoices()
    }

    /// Every language's voice list after voices were downloaded or removed.
    func refreshVoices() {
        for c in channels { c.refreshVoice() }
    }

    // MARK: - Volume faders

    /// Apply the saved microphone fader setting for the selected input.
    func loadGains() {
        let ins = defaults.dictionary(forKey: "inputGains") as? [String: Double] ?? [:]
        let i = ins[inputUID ?? "default"] ?? 0
        if inputGainDB != i { inputGainDB = i } else { capture.gain.set(db: i) }
    }

    private func saveGain(_ db: Double, key: String, device: String?) {
        guard saveGainsEnabled, persistEnabled else { return }
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
    /// Start can be pressed: speech recognition is ready and at least one language is on and ready.
    var canStart: Bool { state == .ready && !activeChannels.isEmpty && !isStarting }

    /// Why Start can't be pressed yet (nil when it can, or while translating).
    var startProblem: String? {
        guard state == .ready, activeChannels.isEmpty else { return nil }
        let on = onChannels
        if on.isEmpty { return "No language is turned on. Turn one on in the Outputs tab." }
        if on.contains(where: { $0.status == .checking }) { return "Checking translation…" }
        if let c = on.first(where: { $0.status == .needsDownload }) {
            return "\(c.name) translation needs a one-time download."
        }
        return "The languages that are on can't be translated on this device. Pick another in the Outputs tab."
    }
    /// The first language that's on and needs its translation downloaded.
    var languageNeedingDownload: LanguageChannel? { onChannels.first { $0.status == .needsDownload } }

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

        state = .preparing("Checking translations…")
        languageOptions = await Languages.supported()
        await prepareChannels(channels)
        state = .ready
    }

    private func prepareChannels(_ list: [LanguageChannel]) async {
        await withTaskGroup(of: Void.self) { group in
            for c in list { group.addTask { await c.prepare() } }
        }
    }

    /// Called after Apple's translation download sheet finishes for a language.
    func translationDownloaded(_ language: String) async {
        let list = channels.filter { $0.config.language == language }
        await prepareChannels(list)
        if list.contains(where: { $0.status == .needsDownload }) {
            showNotice("\(Languages.name(language)) translation wasn't downloaded. Try again, or use System Settings → General → Language & Region → Translation Languages.")
        } else if isListening {
            for c in list where c.isActive { await c.startSpeaker() }
        }
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

    /// Read the device lists now (blocking; used at launch).
    func refreshDevices() {
        applyDevices(inputs: AudioDevices.inputs(), outputs: AudioDevices.outputs())
    }

    private var refreshingDevices = false

    /// Read the device lists on a background thread, then apply them. Used while translating:
    /// if macOS's audio system is slow to answer (a misbehaving USB device), the window and the
    /// translation carry on instead of waiting. Skipped if the previous check hasn't finished.
    func refreshDevicesInBackground() async {
        guard !refreshingDevices else { return }
        refreshingDevices = true
        let lists = await Task.detached { (AudioDevices.inputs(), AudioDevices.outputs()) }.value
        refreshingDevices = false
        applyDevices(inputs: lists.0, outputs: lists.1)
    }

    private func applyDevices(inputs: [AudioDevice], outputs: [AudioDevice]) {
        var inputs = inputs
        #if os(macOS)
        if SystemAudio.isSupported {
            inputs.append(AudioDevice(id: SystemAudio.deviceUID, name: SystemAudio.displayName))
        }
        #endif
        if inputDevices != inputs { inputDevices = inputs }
        if outputDevices != outputs { outputDevices = outputs }
        #if os(macOS)
        if inputUID == nil {
            inputUID = (inputDevices.first { $0.name.lowercased().contains("usb") } ?? inputDevices.first)?.id
        } else if let uid = inputUID, uid != SystemAudio.deviceUID,
                  let moved = AudioDevices.currentUID(for: uid, in: inputDevices), moved != uid {
            // Same microphone, plugged into another USB port: keep using it (and its fader level)
            print("[devices] microphone moved to another USB port: \(moved)")
            var gains = defaults.dictionary(forKey: "inputGains") as? [String: Double] ?? [:]
            if let g = gains[uid], gains[moved] == nil, persistEnabled { gains[moved] = g; defaults.set(gains, forKey: "inputGains") }
            let keepGain = inputGainDB
            inputUID = moved
            inputGainDB = keepGain
            capture.useDevice(moved)
        }
        for c in channels {
            if let uid = c.config.deviceUID, let moved = AudioDevices.currentUID(for: uid, in: outputDevices), moved != uid {
                print("[devices] \(c.name) output moved to another USB port: \(moved)")
                c.config.deviceUID = moved
            }
        }
        // Remember each output's name, to show while it isn't plugged in
        for c in channels {
            if let uid = c.config.deviceUID, let d = outputDevices.first(where: { $0.id == uid }), c.config.deviceName != d.name {
                c.config.deviceName = d.name
            }
        }
        #endif
    }

    /// Refresh devices and voices (the Refresh buttons).
    func refreshAll() {
        Task {
            await refreshDevicesInBackground()
            refreshVoices()
        }
    }

    func deviceName(_ uid: String?, in list: [AudioDevice]) -> String {
        guard let uid else { return "Mac default output" }
        return list.first { $0.id == uid }?.name ?? "Not connected"
    }

    // MARK: - Start / stop

    func startMicrophone() async {
        await start(fileURL: nil)
    }

    func startFile(_ url: URL) async {
        await start(fileURL: url)
    }

    /// True while Start is opening the voices and microphone (Start can't be pressed twice).
    var isStarting = false

    private func start(fileURL: URL?) async {
        guard canStart, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        #if os(macOS)
        if fileURL == nil, inputUID == nil || !inputDevices.contains(where: { $0.id == inputUID }) {
            state = .error("The microphone isn't connected. Check the cable, then pick it in the Microphone list.")
            return
        }
        #endif
        if fileURL == nil, !usingSystemAudio, !(await AVAudioApplication.requestRecordPermission()) {
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

            // Each language's voice on its own output. A language whose output isn't plugged in
            // still gets captions and the transcript, and its voice starts once it's connected.
            await withTaskGroup(of: Void.self) { group in
                for c in activeChannels { group.addTask { await c.startSpeaker() } }
            }
            let stream: AsyncStream<AnalyzerInput>
            if let fileURL {
                stream = try capture.startFile(url: fileURL, analyzerFormat: format) { [weak self] in
                    Task { @MainActor in await self?.fileFinished() }
                }
                playingFile = fileURL.lastPathComponent
            } else {
                // Opened in the background with a time limit: a slow or stuck audio device mustn't
                // freeze the window or leave Start stuck on "Starting…"
                stream = try await openInput(format: format)
            }
            startedAt = Date()
            lastSpeech = nil
            heardAnySignal = false
            liveEnglish = ""
            openTranscriptFile()
            keepAwake(true)
            state = .listening
            #if os(macOS)
            if !onChannels.filter({ $0.config.captionScreenID != nil }).isEmpty { captionsShowing = true }
            #endif
            if fileURL == nil { startMicWatchdog() }
            startOutputWatchdog()

            try await startRecognition(stream: stream, format: format, isFile: fileURL != nil)
        } catch {
            fail("Couldn't start: \(error.localizedDescription)")
        }
    }

    private func openInput(format: AVAudioFormat) async throws -> AsyncStream<AnalyzerInput> {
        let capture = self.capture, uid = inputUID
        let what = usingSystemAudio ? "The Mac's sound" : "The microphone"
        let once = OnceFlag()
        let result: Result<AsyncStream<AnalyzerInput>, Error> = await withCheckedContinuation { continuation in
            Task.detached {
                let r = Result { try capture.startMicrophone(deviceUID: uid, analyzerFormat: format) }
                if once.claim() { continuation.resume(returning: r) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if once.claim() {
                    continuation.resume(returning: .failure(SimpleError(
                        "\(what) didn't respond. Unplug the audio interface and plug it back in, then press Try again. (If it keeps happening, restart the Mac.)")))
                }
            }
        }
        return try result.get()
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
                                  isFile: Bool) async throws {
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
                        if self.verboseTiming { print(String(format: "[timing] recognised %.2fs after speech ended", Date().timeIntervalSince(spokenAt))) }
                        await self.translateAndSpeak(text, spokenAt: spokenAt)
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
                if !isFile { await self?.recognitionFailed(SimpleError("the recogniser stopped")) }
            } catch is CancellationError {
                return
            } catch {
                await self?.recognitionFailed(error)
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Restart speech recognition instead of ending the service, up to 5 times in 10 minutes.
    private func recognitionFailed(_ error: Error) async {
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
            try await startRecognition(stream: stream, format: format, isFile: playingFile != nil)
            showNotice("Speech recognition had a hiccup and restarted by itself.")
            print("[recognition] restarted (\(recognitionRestarts.count) in the last 10 minutes)")
        } catch {
            fail("Speech recognition stopped: \(error.localizedDescription)")
        }
    }

    // MARK: - Translation queue

    /// One English sentence waiting to be translated into some languages.
    private struct Job {
        let rowID: UUID
        let text: String
        let spokenAt: Date
        var remaining: [UUID]        // languages still to translate, by LanguageChannel.id
        var filterChanges: Int
    }
    private var jobs: [Job] = []
    private var translateTask: Task<Void, Never>?
    private var translateWake: AsyncStream<Void>.Continuation?
    /// A language more than this many sentences behind skips ahead to keep up.
    static let maxBacklog = 4
    /// Testing (--fake-second-translation): languages after the first wait 0.6 s instead of translating.
    var fakeSecondTranslation = ProcessInfo.processInfo.arguments.contains("--fake-second-translation")
    /// Testing (--timing): print how long each translation takes.
    var verboseTiming = ProcessInfo.processInfo.arguments.contains("--timing")
    /// True while sentences are still waiting to be translated (used by the recording test).
    var translationsPending: Bool { !jobs.isEmpty }

    /// A finished English sentence: show it straight away and queue its translations.
    private func translateAndSpeak(_ english: String, spokenAt: Date) async {
        // Word filter, English side: misheard swears show as ••• and are left out of the translation
        let shownEnglish = filterEnglish(english, mask: "•••")
        let toTranslate = filterEnglish(english, mask: "")
        guard !toTranslate.text.isEmpty else {
            noteFiltered(shownEnglish.changed)
            return
        }
        let targets = activeChannels.map(\.id)
        guard !targets.isEmpty else { return }
        let row = TranscriptRow(time: Date(), english: shownEnglish.text, translations: [:], delay: 0)
        appendRow(row)
        jobs.append(Job(rowID: row.id, text: toTranslate.text, spokenAt: spokenAt,
                        remaining: targets, filterChanges: shownEnglish.changed))
        dropBacklog()
        startTranslating()
        translateWake?.yield()
    }

    /// Apple's translation works on one sentence at a time, whichever language it's for. So the
    /// languages take turns in Outputs order: the first language always gets each new sentence
    /// first (about half a second), and the others follow.
    private func startTranslating() {
        guard translateTask == nil else { return }
        let (wake, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        translateWake = continuation
        translateTask = Task { @MainActor [weak self] in
            var iterator = wake.makeAsyncIterator()
            while !Task.isCancelled {
                guard let self else { return }
                if let (jobIndex, channel) = self.nextTranslation() {
                    await self.translate(jobIndex: jobIndex, channel: channel)
                } else {
                    if await iterator.next() == nil { return }
                }
            }
        }
    }

    private func stopTranslating() {
        translateTask?.cancel()
        translateTask = nil
        translateWake?.finish()
        translateWake = nil
        jobs = []
    }

    /// The highest language in the Outputs list that has a sentence waiting, and its oldest sentence.
    private func nextTranslation() -> (Int, LanguageChannel)? {
        // Forget languages that were turned off, removed or lost their translation meanwhile
        let active = Set(activeChannels.map(\.id))
        for k in jobs.indices { jobs[k].remaining.removeAll { !active.contains($0) } }
        finishCompletedJobs()
        for c in channels where active.contains(c.id) {
            if let k = jobs.firstIndex(where: { $0.remaining.contains(c.id) }) { return (k, c) }
        }
        return nil
    }

    private func translate(jobIndex: Int, channel c: LanguageChannel) async {
        guard let session = c.session else { return }
        let job = jobs[jobIndex]
        let language = c.config.language
        var text: String?
        var changed = 0
        let began = Date()
        do {
            let raw: String
            if fakeSecondTranslation, c.id != activeChannels.first?.id {
                // Testing: same timing as a translation, but no AI model is used
                try await Task.sleep(for: .milliseconds(600))
                raw = "[test] " + job.text
            } else {
                raw = try await session.translate(job.text).targetText
            }
            if verboseTiming { print(String(format: "[timing] %@ %.2fs (sentence waited %.2fs)", language, Date().timeIntervalSince(began), began.timeIntervalSince(job.spokenAt))) }
            if Languages.isSpanish(language) {
                // Word filter, Spanish side: swap risky regional words and drop blocked ones
                // before anything is spoken, captioned or saved
                let cleaned = wordFilter.clean(raw, mask: "")
                text = cleaned.text
                changed = cleaned.changed
            } else {
                text = raw
            }
        } catch {
            print("[!] Translation error (\(c.name)): \(error.localizedDescription)")
        }
        // The job list may have changed while translating; find this sentence again
        guard let k = jobs.firstIndex(where: { $0.rowID == job.rowID }) else { return }
        jobs[k].remaining.removeAll { $0 == c.id }
        jobs[k].filterChanges += changed
        if let text {
            if c.config.isOn, isListening, !text.isEmpty, !c.deviceMissing, !c.outputNotResponding { c.speaker.speak(text) }
            let delay = max(0, Date().timeIntervalSince(job.spokenAt))
            c.lastDelay = delay
            if c.id == activeChannels.first?.id { lastDelay = delay }
            updateRow(job.rowID) { $0.translations[c.id] = text.isEmpty ? TranscriptRow.filtered : text; $0.delay = max($0.delay, delay) }
        }
        finishCompletedJobs()
    }

    /// Sentences every language has finished: save them to the transcript, in order.
    private func finishCompletedJobs() {
        while let first = jobs.first, first.remaining.isEmpty {
            jobs.removeFirst()
            noteFiltered(first.filterChanges)
            guard let row = rows.last(where: { $0.id == first.rowID }) else { continue }
            if row.translations.isEmpty { rows.removeAll { $0.id == row.id }; continue }
            writeTranscript(row)
            var log = "[EN] \(row.english)"
            for c in channels {
                if let t = row.translations[c.id] {
                    log += "\n[\(Languages.shortCode(c.config.language))] \(t)  (\(String(format: "%.1f", c.lastDelay ?? 0))s)"
                }
            }
            print(log)
        }
    }

    /// A language that has fallen too far behind (fast speech, many languages) skips its oldest
    /// sentences, so its listeners hear what's being said now rather than minutes ago.
    private func dropBacklog() {
        for c in activeChannels {
            let waitingJobs = jobs.indices.filter { jobs[$0].remaining.contains(c.id) }
            guard waitingJobs.count > Self.maxBacklog else { continue }
            for k in waitingJobs.prefix(waitingJobs.count - Self.maxBacklog) {
                jobs[k].remaining.removeAll { $0 == c.id }
            }
            print("[!] \(c.name) fell behind; skipped \(waitingJobs.count - Self.maxBacklog) sentence(s)")
            if let last = behindNoticeAt[c.id], Date().timeIntervalSince(last) < 60 { continue }
            behindNoticeAt[c.id] = Date()
            showNotice("\(c.name) fell behind and skipped a sentence to catch up. Fewer languages, or the Faster speech setting, will help.")
        }
        finishCompletedJobs()
    }

    /// When each language last showed "fell behind" (at most once a minute each).
    @ObservationIgnored private var behindNoticeAt: [UUID: Date] = [:]

    private func updateRow(_ id: UUID, _ change: (inout TranscriptRow) -> Void) {
        guard let k = rows.lastIndex(where: { $0.id == id }) else { return }
        change(&rows[k])
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

    func simulateVoiceStall() { channels.first { $0.config.isOn }?.speaker.simulateMissingEndSignal = true }
    func simulateOutputDropout() { activeChannels.first?.speaker.simulateOutputDropout() }
    func simulateMicDropout() { capture.simulateMicDropout() }
    var speakerWaiting: Int { channels.map(\.speaker.waiting).max() ?? 0 }
    var micSecondsSinceAudio: TimeInterval { capture.secondsSinceLastAudio }

    private func noteFiltered(_ count: Int) {
        guard count > 0 else { return }
        filteredCount += count
        print("[filter] Changed or removed \(count) word(s) in this phrase.")   // never logs the words
    }

    func stop() async {
        stopping = true
        stopMicWatchdog()
        stopOutputWatchdog()
        capture.stop()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // Give the last phrase a moment to translate before tearing down
        var waited = 0
        repeat {
            try? await Task.sleep(nanoseconds: 300_000_000)
            waited += 1
        } while translationsPending && waited < 5
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        stopTranslating()
        for c in channels { c.stopSpeaker() }
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
        while (translationsPending || speakerWaiting > 0), waited < 240 {   // at most 60 s
            try? await Task.sleep(nanoseconds: 250_000_000)
            waited += 1
        }
        print(String(format: "[levels] input gain %+.0f dB, loudest input RMS %.4f; loudest output RMS %.4f",
                     inputGainDB, loudestInputRMS, loudestOutputRMS))
        for c in channels where c.config.isOn {
            print("[levels] \(c.name): volume \(Int(c.config.gainDB)) dB, played sound: \(c.hasPlayedSound)")
        }
        print("[done] Finished playing recording")
        await stop()
        NotificationCenter.default.post(name: .recordingFinished, object: nil)
    }

    private func fail(_ message: String) {
        stopMicWatchdog()
        stopOutputWatchdog()
        capture.stop()
        for c in channels { c.stopSpeaker() }
        stopTranslating()
        resultsTask?.cancel()
        analyzer = nil
        startedAt = nil
        playingFile = nil
        keepAwake(false)
        closeTranscriptFile()
        state = .error(message)
        print("[!] \(message)")
    }

    /// The app is quitting: release the input (microphone or Mac's sound) right away, so macOS
    /// isn't left tidying up an open audio capture.
    func releaseAudioNow() {
        capture.stop()
        for c in channels { c.stopSpeaker() }
    }

    /// Clear an error so the volunteer can try again.
    func resetError() {
        guard case .error = state else { return }
        state = .preparing("Retrying…")
        Task { await prepare() }
    }

    /// Play a short sentence in one language on its output (the Test button).
    func testSpeaker(_ c: LanguageChannel) {
        guard !isListening else { return }
        Task {
            if await c.startSpeaker() {
                c.speaker.speak(c.phrases.soundTest)
            } else if c.deviceMissing {
                showNotice("\(c.name): \(c.config.deviceName ?? "the speaker output") isn't connected.")
            } else if c.outputNotResponding {
                showNotice("\(c.name): \(c.config.deviceName ?? "the speaker output") isn't responding. Unplug it and plug it back in.")
            }
        }
    }

    /// Every language that's on says its test sentence on its own output at the same time.
    func testAllOutputs() {
        for c in onChannels { testSpeaker(c) }
    }

    // MARK: - Meters

    private func tickMeters() {
        // Only assign values that changed: every assignment redraws the views that show it,
        // and redrawing 20 times a second for nothing slows the whole app down.
        let i = capture.level.value
        if inputLevel != i.rms { inputLevel = i.rms }
        if inputPeak != i.peak { inputPeak = i.peak }
        var loudest: Float = 0, mostWaiting = 0
        for c in channels {
            c.tick()
            loudest = max(loudest, c.outputLevel)
            mostWaiting = max(mostWaiting, c.waiting)
        }
        if outputLevel != loudest { outputLevel = loudest }
        if waiting != mostWaiting { waiting = mostWaiting }
        let now = Date()
        if isListening, i.rms >= silenceThreshold,
           lastSpeech.map({ now.timeIntervalSince($0) > 0.25 }) ?? true { lastSpeech = now }
        if isListening, i.peak > 0, !heardAnySignal { heardAnySignal = true }
        if i.peak >= 0.99 { lastClip = now }
        if isListening {
            loudestInputRMS = max(loudestInputRMS, i.rms)
            loudestOutputRMS = max(loudestOutputRMS, outputLevel)
        }
    }

    /// Loudest meter readings during the current run (printed by the recording test).
    @ObservationIgnored private(set) var loudestInputRMS: Float = 0
    @ObservationIgnored private(set) var loudestOutputRMS: Float = 0
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

    // MARK: - Language outputs that aren't plugged in

    private var outputWatchTask: Task<Void, Never>?

    /// While translating, every 2 seconds try to start the voice of any language whose output
    /// wasn't plugged in, so it starts speaking as soon as the device is connected.
    private func startOutputWatchdog() {
        outputWatchTask?.cancel()
        var warned = Set<UUID>()
        for c in activeChannels where c.deviceMissing || c.outputNotResponding {
            showNotice("\(c.name): \(c.config.deviceName ?? "the speaker output") isn't "
                       + (c.deviceMissing ? "connected. It will start by itself when it's plugged in." : "responding. Unplug it and plug it back in."))
            warned.insert(c.id)
        }
        outputWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isListening else { continue }
                if self.activeChannels.contains(where: { $0.deviceMissing }) {
                    await self.refreshDevicesInBackground()   // finds a device plugged back into another USB port
                }
                for c in self.activeChannels where c.deviceMissing || c.outputNotResponding || !c.speaker.isStarted {
                    if await c.startSpeaker() {
                        if warned.remove(c.id) != nil { self.showNotice("\(c.name): speaker output connected. Its voice has started.") }
                    } else if (c.deviceMissing || c.outputNotResponding), warned.insert(c.id).inserted {
                        self.showNotice("\(c.name): \(c.config.deviceName ?? "the speaker output") isn't "
                                        + (c.deviceMissing ? "connected. It will start by itself when it's plugged in." : "responding. Unplug it and plug it back in."))
                    }
                }
            }
        }
    }

    private func stopOutputWatchdog() {
        outputWatchTask?.cancel()
        outputWatchTask = nil
    }

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
            var reconnecting = false
            var lastAttempt = Date.distantPast
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.isListening, self.capture.usingMicrophone else { continue }
                let silentFor = self.capture.secondsSinceLastAudio
                if silentFor > 3 || self.micDropoutReported {
                    if !recovering {
                        recovering = true
                        self.showNotice(self.usingSystemAudio ? "The Mac's sound stopped arriving. Reconnecting…"
                                        : "The microphone stopped sending sound. Reconnecting…")
                    }
                    if Date().timeIntervalSince(lastAttempt) >= 2, !reconnecting {
                        lastAttempt = Date()
                        if !self.usingSystemAudio { await self.refreshDevicesInBackground() }   // replugged into another port?
                        self.micDropoutReported = false
                        reconnecting = true
                        let capture = self.capture
                        let result = await Task.detached { () -> String? in
                            do { try capture.reconnectMicrophone(); return nil } catch { return error.localizedDescription }
                        }.value
                        reconnecting = false
                        if let result { print("[!] Microphone not available yet: \(result)") } else { print("[mic] reconnect attempt made") }
                    }
                } else if recovering, silentFor < 1 {
                    recovering = false
                    self.showNotice(self.usingSystemAudio ? "The Mac's sound is arriving again. Translation continues."
                                    : "The microphone reconnected. Translation continues.")
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
        let langs = activeChannels.map(\.name).joined(separator: ", ")
        appendTranscript("Church Translate — \(Date().formatted(date: .complete, time: .shortened))\nEnglish → \(langs)\n\n")
    }

    private func writeTranscript(_ row: TranscriptRow) {
        let t = row.time.formatted(date: .omitted, time: .standard)
        var text = "[\(t)] EN: \(row.english)\n"
        for c in channels {
            if let tr = row.translations[c.id] { text += "[\(t)] \(Languages.shortCode(c.config.language)): \(tr)\n" }
        }
        appendTranscript(text + "\n")
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
