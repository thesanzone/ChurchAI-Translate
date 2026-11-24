import AVFoundation

/// Speaks one language's translation with Apple's voices.
/// The voice is rendered into audio buffers and played through this speaker's own audio
/// engine, so each language can go to its own output device (on Mac) and drive its own meter.
final class Speaker: NSObject, @unchecked Sendable {
    let level = LevelBox()
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Output volume fader: a gain stage between the voice and the speakers (changes apply instantly).
    private let gainNode = AVAudioUnitEQ(numberOfBands: 0)

    /// Voice volume in dB (the Volume slider). Range -24…+12.
    var outputGainDB: Float = 0 {
        didSet {
            // On the engine queue: touching the audio unit from the main thread could freeze
            // the window while a stuck device is being opened
            let db = max(-24, min(12, outputGainDB))
            engineQueue.async { self.gainNode.globalGain = db }
        }
    }
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var converters: [String: AVAudioConverter] = [:]
    private let queue = DispatchQueue(label: "Speaker")
    private var pendingTexts: [String] = []
    private var synthesizing = false
    // State the window reads (waiting count, running, device) sits behind its own small lock,
    // so reading it never waits on the voice or the audio hardware.
    private let stateLock = NSLock()
    private var _waitingCount = 0
    private var _started = false
    private var _deviceUID: String?
    private var _startedAt = Date()
    private func locked<T>(_ body: () -> T) -> T { stateLock.lock(); defer { stateLock.unlock() }; return body() }
    private var waitingCount: Int {
        get { locked { _waitingCount } }
        set { locked { _waitingCount = newValue } }
    }
    private var started: Bool {
        get { locked { _started } }
        set { locked { _started = newValue } }
    }
    private var outputDeviceUID: String? {
        get { locked { _deviceUID } }
        set { locked { _deviceUID = newValue } }
    }
    private var startedAt: Date {
        get { locked { _startedAt } }
        set { locked { _startedAt = newValue } }
    }
    /// Increases for every phrase and on Stop, so late callbacks from an old phrase are ignored.
    private var phraseGeneration = 0
    /// Testing: pretend Apple's "phrase finished" signal never arrives for the next phrase.
    var simulateMissingEndSignal = false
    /// Called (on any thread) when the speaker had to recover, e.g. a stuck phrase was skipped.
    var onRecovery: ((String) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var forceRecoveryForTest = false

    /// Language code (e.g. "es") used to pick a voice when none is chosen.
    var language = "es"
    /// Name used in messages, e.g. "Spanish".
    var label = "Spanish"
    var voiceIdentifier: String?
    var fast = false

    /// True while the audio engine is running (started, and not stopped since).
    var isStarted: Bool { started }
    /// The output device the speaker is playing to (nil = the Mac's default output).
    var currentDeviceUID: String? { outputDeviceUID }

    enum SpeakerError: LocalizedError {
        case notConnected
        var errorDescription: String? { "The speaker output isn't connected." }
    }

    /// Number of phrases waiting to be spoken or still speaking.
    var waiting: Int { waitingCount }

    /// All audio-engine work (open, close, recover) happens here, never on the main thread:
    /// a misbehaving USB audio device can make macOS take many seconds to open it, and that
    /// must not freeze the app's window.
    private let engineQueue = DispatchQueue(label: "Speaker.engine")

    /// Start playing to `outputDeviceUID` (Mac) in the background, then call `completion` (on
    /// the engine queue) with nil or the error. If it's already playing to another device it
    /// moves there. Fails with `.notConnected` if that device isn't plugged in, rather than
    /// quietly playing through the wrong speakers.
    func start(outputDeviceUID: String?, completion: @escaping @Sendable (Error?) -> Void) {
        engineQueue.async {
            do {
                try self.startNow(outputDeviceUID: outputDeviceUID)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Testing (--simulate-slow-output N): the first start takes N extra seconds, like a stuck USB device.
    private static var slowStartSeconds: Double? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--simulate-slow-output"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    // Runs on engineQueue
    private func startNow(outputDeviceUID: String?) throws {
        if let delay = Self.slowStartSeconds {
            Self.slowStartSeconds = nil
            print("[test] \(label): opening the output slowly (\(Int(delay)) s)")
            Thread.sleep(forTimeInterval: delay)
        }
        if started {
            if currentDeviceUID == outputDeviceUID { return }
            stopEngineNow()
        }
        #if os(macOS)
        if let outputDeviceUID, AudioDevices.deviceID(forUID: outputDeviceUID) == nil {
            throw SpeakerError.notConnected
        }
        #endif
        engine.attach(player)
        engine.attach(gainNode)
        gainNode.globalGain = max(-24, min(12, outputGainDB))
        engine.connect(player, to: gainNode, format: playFormat)
        engine.connect(gainNode, to: engine.mainMixerNode, format: playFormat)
        #if os(macOS)
        if let outputDeviceUID { AudioDevices.assign(uid: outputDeviceUID, to: engine.outputNode) }
        #else
        try AudioDevices.configureSession()
        #endif
        let mixFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixFormat) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0, peak: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i]; peak = max(peak, abs(ch[i])) }
            self.level.set(rms: (sum / Float(n)).squareRoot(), peak: peak)
        }
        // `--mute` (testing): run the whole pipeline without sound
        if ProcessInfo.processInfo.arguments.contains("--mute") { player.volume = 0 }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.detach(player)
            engine.detach(gainNode)
            throw error
        }
        player.play()
        self.outputDeviceUID = outputDeviceUID
        startedAt = Date()
        started = true

        // If the audio hardware changes (USB interface unplugged/replugged, sample rate change),
        // macOS stops this engine. Restart it so the voice doesn't go silent.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.engineQueue.async { self?.recoverOutput(attempt: 1) }
        }
    }

    /// Runs on engineQueue. Restarts the voice engine after a hardware change, retrying every
    /// 2 seconds (for up to 2 minutes) until the chosen speaker output is available again.
    private func recoverOutput(attempt: Int) {
        let (isStarted, uid, began) = (started, outputDeviceUID, startedAt)
        guard isStarted else { return }
        // macOS also sends this notice right after the engine starts; only act if it really stopped
        if attempt == 1, engine.isRunning, !forceRecoveryForTest { return }
        forceRecoveryForTest = false
        let quiet = Date().timeIntervalSince(began) < 5   // settling after Start: don't alarm anyone
        #if os(macOS)
        if let uid, AudioDevices.deviceID(forUID: uid) == nil {
            if attempt == 1 {
                print("[!] \(label) speaker output disconnected; waiting for it to come back")
                onRecovery?("\(label): the speaker output was disconnected. Waiting for it to be plugged back in…")
            }
            if attempt < 60 {
                engineQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recoverOutput(attempt: attempt + 1) }
            }
            return
        }
        #endif
        player.stop()
        engine.stop()
        #if os(macOS)
        if let uid { AudioDevices.assign(uid: uid, to: engine.outputNode) }
        #endif
        do {
            engine.prepare()
            try engine.start()
            player.play()
            // Phrases that were scheduled on the old engine are gone; keep the count honest
            queue.async { self.waitingCount = self.pendingTexts.count + (self.synthesizing ? 1 : 0) }
            print("[voice] \(label) speaker output restarted after an audio hardware change")
            if !quiet || attempt > 1 { onRecovery?("\(label): the speaker output reconnected.") }
        } catch {
            print("[!] Couldn't restart the \(label) speaker output (attempt \(attempt)): \(error)")
            if attempt < 60 {
                engineQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recoverOutput(attempt: attempt + 1) }
            }
        }
    }

    /// Testing: behave as if macOS reported an audio hardware change.
    func simulateOutputDropout() {
        engineQueue.async {
            self.engine.stop()                 // what macOS does on a real hardware change
            self.forceRecoveryForTest = true
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self.engine)
        }
    }

    /// Stop speaking straight away (queued phrases are dropped); the audio engine is closed in
    /// the background.
    func stop() {
        waitingCount = 0
        queue.async {
            self.pendingTexts.removeAll()
            self.waitingCount = 0
            // Forget any phrase in progress: without this, a phrase whose "finished" signal was
            // lost would block the voice even after Stop/Start.
            self.synthesizing = false
            self.phraseGeneration += 1
        }
        synth.stopSpeaking(at: .immediate)
        level.set(rms: 0, peak: 0)
        engineQueue.async { self.stopEngineNow() }
    }

    // Runs on engineQueue
    private func stopEngineNow() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard started else { return }
        started = false
        player.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
        engine.detach(player)
        engine.detach(gainNode)
        level.set(rms: 0, peak: 0)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            self.pendingTexts.append(trimmed)
            self.waitingCount += 1
            self.synthesizeNextIfIdle()
        }
    }

    // Runs on `queue`
    private func synthesizeNextIfIdle() {
        guard !synthesizing, !pendingTexts.isEmpty else { return }
        synthesizing = true
        let text = pendingTexts.removeFirst()

        let utterance = AVSpeechUtterance(string: text)
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id), !Languages.isNovelty(v) {
            utterance.voice = v
        } else {
            utterance.voice = Languages.voices(for: language).first ?? AVSpeechSynthesisVoice(language: language)
        }
        // Speed up when phrases are piling up, like the Python version
        let catchUp = fast || waitingCount > 2
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (catchUp ? 1.15 : 1.0)

        phraseGeneration += 1
        let generation = phraseGeneration
        let dropEnd = simulateMissingEndSignal
        simulateMissingEndSignal = false

        // Watchdog: Apple renders a phrase far faster than real time, so if its "finished"
        // signal hasn't arrived well after that, skip the phrase instead of blocking the voice
        // for the rest of the service.
        let timeout = 10 + Double(text.count) * 0.05
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.synthesizing, self.phraseGeneration == generation else { return }
            print("[!] \(self.label) voice: a phrase didn't finish after \(Int(timeout))s; skipping it")
            self.synth.stopSpeaking(at: .immediate)
            self.phraseGeneration += 1          // ignore anything that phrase sends later
            self.waitingCount = max(0, self.waitingCount - 1)
            self.synthesizing = false
            self.onRecovery?("The \(self.label) voice skipped a phrase that got stuck.")
            self.synthesizeNextIfIdle()
        }

        var lastScheduled: AVAudioPCMBuffer?
        synth.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                if dropEnd { return }   // testing the watchdog
                // End of this phrase: when its last buffer finishes playing, count it done
                self.queue.async {
                    guard self.phraseGeneration == generation else { return }   // stale (skipped or stopped)
                    if let last = lastScheduled {
                        self.player.scheduleBuffer(last) {
                            self.queue.async { self.waitingCount = max(0, self.waitingCount - 1) }
                        }
                    } else {
                        self.waitingCount = max(0, self.waitingCount - 1)
                    }
                    self.synthesizing = false
                    self.synthesizeNextIfIdle()
                }
                return
            }
            guard let converted = self.convert(pcm) else { return }
            // Hold back one buffer so the final one can carry the completion handler
            self.queue.async {
                guard self.phraseGeneration == generation else { return }
                if let prev = lastScheduled, self.started { self.player.scheduleBuffer(prev) }
                lastScheduled = converted
            }
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let key = "\(buf.format.sampleRate)-\(buf.format.commonFormat.rawValue)-\(buf.format.channelCount)"
        let conv: AVAudioConverter
        if let c = converters[key] { conv = c } else {
            guard let c = AVAudioConverter(from: buf.format, to: playFormat) else { return nil }
            converters[key] = c
            conv = c
        }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * playFormat.sampleRate / buf.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: cap) else { return nil }
        var supplied = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        return err == nil ? out : nil
    }
}
