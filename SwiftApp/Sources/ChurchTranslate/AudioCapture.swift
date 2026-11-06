import AVFoundation
import Speech

/// Thread-safe live level values, written by the audio thread and read by the UI.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _rms: Float = 0
    private var _peak: Float = 0
    func set(rms: Float, peak: Float) { lock.lock(); _rms = rms; _peak = peak; lock.unlock() }
    var value: (rms: Float, peak: Float) { lock.lock(); defer { lock.unlock() }; return (_rms, _peak) }
}

/// Captures audio (from the microphone, or from a recording for testing),
/// measures its level for the meter, and converts it into the format the
/// speech recogniser wants.
final class AudioCapture: @unchecked Sendable {
    let level = LevelBox()
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var fileTask: Task<Void, Never>?

    /// Start the microphone. Returns the stream of audio for the speech recogniser.
    func startMicrophone(deviceUID: String?, analyzerFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        #if os(macOS)
        if let deviceUID { AudioDevices.assign(uid: deviceUID, to: engine.inputNode) }
        #else
        try AudioDevices.configureSession()
        #endif
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw CaptureError.noMicrophone
        }
        let stream = prepare(inputFormat: inFormat, analyzerFormat: analyzerFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        return stream
    }

    /// Feed a recording through the same path in real time (for comparing with the Python app).
    func startFile(url: URL, analyzerFormat: AVAudioFormat, onFinished: @escaping @Sendable () -> Void) throws -> AsyncStream<AnalyzerInput> {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let stream = prepare(inputFormat: fmt, analyzerFormat: analyzerFormat)
        let chunk = AVAudioFrameCount(fmt.sampleRate / 10) // 100 ms
        fileTask = Task.detached { [weak self] in
            let start = Date()
            var framesSent: Double = 0
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                if buf.frameLength == 0 { break }
                self?.process(buf)
                framesSent += Double(buf.frameLength)
                // Pace to real time so the meter, delay and voice behave like a live service
                let ahead = framesSent / fmt.sampleRate - Date().timeIntervalSince(start)
                if ahead > 0 { try? await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000_000)) }
            }
            // A little trailing silence helps the recogniser finish the last sentence
            if let silence = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate)) {
                silence.frameLength = silence.frameCapacity
                self?.process(silence)
            }
            self?.level.set(rms: 0, peak: 0)
            onFinished()
        }
        return stream
    }

    /// Tell the speech recogniser no more audio is coming (end of a recording).
    func finishInput() {
        continuation?.finish()
        continuation = nil
    }

    func stop() {
        fileTask?.cancel()
        fileTask = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        continuation?.finish()
        continuation = nil
        level.set(rms: 0, peak: 0)
    }

    // MARK: - Internals

    private func prepare(inputFormat: AVAudioFormat, analyzerFormat: AVAudioFormat) -> AsyncStream<AnalyzerInput> {
        self.analyzerFormat = analyzerFormat
        converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        measure(buffer)
        guard let converter, let analyzerFormat, let continuation else { return }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ch = buffer.floatChannelData?[0] else { return }
        var sum: Float = 0
        var peak: Float = 0
        for i in 0..<n {
            let v = ch[i]
            sum += v * v
            peak = max(peak, abs(v))
        }
        level.set(rms: (sum / Float(n)).squareRoot(), peak: peak)
    }

    enum CaptureError: LocalizedError {
        case noMicrophone
        var errorDescription: String? {
            "No microphone was found. Check the audio interface is plugged in."
        }
    }
}
