import AVFoundation

/// Speaks Spanish text with Apple's built-in voices.
/// The voice is rendered into audio buffers and played through our own audio
/// engine, so we can pick the output device (on Mac) and drive the output meter.
final class SpanishSpeaker: NSObject, @unchecked Sendable {
    let level = LevelBox()
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var converters: [String: AVAudioConverter] = [:]
    private let queue = DispatchQueue(label: "SpanishSpeaker")
    private var pendingTexts: [String] = []
    private var synthesizing = false
    private var _waiting = 0
    private var started = false

    var voiceIdentifier: String?
    var fast = false

    /// Built-in Piper engine, loaded on first use (takes about a second).
    private var piper: PiperVoice?
    private var piperTried = false
    private var usesPiper: Bool { voiceIdentifier == PiperVoice.identifier && PiperVoice.isAvailable }

    /// Load the Piper voice in the background so the first sentence isn't delayed.
    func preloadPiper() {
        guard PiperVoice.isAvailable else { return }
        queue.async { _ = self.loadPiper() }
    }

    // Runs on `queue`
    private func loadPiper() -> PiperVoice? {
        if !piperTried {
            piperTried = true
            piper = PiperVoice()
            print(piper == nil ? "[!] Piper voice failed to load" : "[voice] Piper engine loaded")
        }
        return piper
    }

    /// Number of phrases waiting to be spoken or still speaking.
    var waiting: Int { queue.sync { _waiting } }

    /// True for Apple's old "Eloquence" novelty voices (Eddy, Flo, Grandpa, Rocko…), which sound robotic.
    static func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.identifier.contains(".eloquence.") || v.identifier.contains(".speech.synthesis.")
    }

    /// Natural-sounding Spanish voices installed on this device: Premium, then Enhanced,
    /// then basic; Mexican Spanish first; Paulina/Mónica ahead of others at the same level.
    static func spanishVoices() -> [AVSpeechSynthesisVoice] {
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 100
            if v.language == "es-MX" { s += 20 }
            if v.identifier.contains(".super-compact.") { s -= 10 }   // lowest-fidelity build
            if ["Paulina", "Mónica", "Monica"].contains(v.name) { s += 5 }
            return s
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") && !isNovelty($0) }
            .sorted { score($0) != score($1) ? score($0) > score($1) : $0.name < $1.name }
    }

    /// True when the best installed voice is only basic quality (an Enhanced/Premium download would sound much better).
    static var onlyBasicVoices: Bool {
        !(spanishVoices().contains { $0.quality == .enhanced || $0.quality == .premium })
    }

    static func describe(_ v: AVSpeechSynthesisVoice) -> String {
        let region = v.language == "es-MX" ? "Mexico" : v.language == "es-ES" ? "Spain" : v.language
        let q: String
        switch v.quality {
        case .premium: q = " (Premium)"
        case .enhanced: q = " (Enhanced)"
        default: q = ""
        }
        // Downloaded voices often already carry the quality in their name, e.g. "Juan (Enhanced)".
        let name = v.name.replacingOccurrences(of: q.trimmingCharacters(in: .whitespaces), with: "")
            .trimmingCharacters(in: .whitespaces)
        return "\(q.isEmpty ? v.name : name), \(region)\(q)"
    }

    func start(outputDeviceUID: String?) throws {
        if started { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
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
        try engine.start()
        player.play()
        started = true
    }

    func stop() {
        queue.sync {
            pendingTexts.removeAll()
            _waiting = 0
        }
        synth.stopSpeaking(at: .immediate)
        if started {
            player.stop()
            engine.mainMixerNode.removeTap(onBus: 0)
            engine.stop()
            engine.detach(player)
            started = false
        }
        level.set(rms: 0, peak: 0)
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            self.pendingTexts.append(trimmed)
            self._waiting += 1
            self.synthesizeNextIfIdle()
        }
    }

    // Runs on `queue`
    private func synthesizeNextIfIdle() {
        guard !synthesizing, !pendingTexts.isEmpty else { return }
        synthesizing = true
        let text = pendingTexts.removeFirst()

        if usesPiper, let piper = loadPiper() {
            // Python app pacing: 1.11x normally, 1.25x when catching up
            let speed: Float = (fast || _waiting > 2) ? 1.25 : 1.11
            if let raw = piper.synthesize(text, speed: speed), let buf = convert(raw), started {
                player.scheduleBuffer(buf) {
                    self.queue.async { self._waiting = max(0, self._waiting - 1) }
                }
            } else {
                _waiting = max(0, _waiting - 1)
            }
            synthesizing = false
            synthesizeNextIfIdle()
            return
        }

        let utterance = AVSpeechUtterance(string: text)
        if let id = voiceIdentifier, id != PiperVoice.identifier,
           let v = AVSpeechSynthesisVoice(identifier: id), !SpanishSpeaker.isNovelty(v) {
            utterance.voice = v
        } else {
            utterance.voice = SpanishSpeaker.spanishVoices().first ?? AVSpeechSynthesisVoice(language: "es-MX")
        }
        // Speed up when phrases are piling up, like the Python version
        let catchUp = fast || _waiting > 2
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (catchUp ? 1.15 : 1.0)

        var lastScheduled: AVAudioPCMBuffer?
        synth.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                // End of this phrase: when its last buffer finishes playing, count it done
                self.queue.async {
                    if let last = lastScheduled {
                        self.player.scheduleBuffer(last) {
                            self.queue.async { self._waiting = max(0, self._waiting - 1) }
                        }
                    } else {
                        self._waiting = max(0, self._waiting - 1)
                    }
                    self.synthesizing = false
                    self.synthesizeNextIfIdle()
                }
                return
            }
            guard let converted = self.convert(pcm) else { return }
            // Hold back one buffer so the final one can carry the completion handler
            if let prev = lastScheduled, self.started { self.player.scheduleBuffer(prev) }
            lastScheduled = converted
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
