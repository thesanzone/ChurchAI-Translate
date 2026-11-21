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

/// Thread-safe input gain, plus the Auto-level measurement (raw speech loudness samples).
final class GainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _linear: Float = 1
    private var autoUntil = Date.distantPast
    private var samples: [Float] = []
    /// Sound quieter than this (before gain) isn't counted as speech for Auto level.
    var speechFloor: Float = 0.0015

    var linear: Float { lock.lock(); defer { lock.unlock() }; return _linear }
    func set(db: Double) { lock.lock(); _linear = Float(pow(10, db / 20)); lock.unlock() }

    var autoActive: Bool { lock.lock(); defer { lock.unlock() }; return Date() < autoUntil }
    func startAuto(seconds: Double) {
        lock.lock(); samples = []; autoUntil = Date().addingTimeInterval(seconds); lock.unlock()
    }
    func addAutoSample(_ rms: Float) {
        lock.lock(); if rms >= speechFloor { samples.append(rms) }; lock.unlock()
    }
    /// 90th-percentile speech loudness from the last measurement, or nil if too little speech.
    func autoSpeechLevel(minimumSamples: Int) -> Float? {
        lock.lock(); let s = samples.sorted(); lock.unlock()
        guard s.count >= minimumSamples else { return nil }
        return s[Int(Double(s.count) * 0.9)]
    }
}

/// Captures audio (from the microphone, or from a recording for testing),
/// measures its level for the meter, and converts it into the format the
/// speech recogniser wants.
final class AudioCapture: @unchecked Sendable {
    let level = LevelBox()
    /// Input volume fader (applied before the meter and the speech recogniser).
    let gain = GainBox()
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var fileTask: Task<Void, Never>?
    #if os(macOS)
    // Mac: AVCaptureSession opens the chosen microphone directly. Pointing AVAudioEngine's
    // input at a specific device (kAudioOutputUnitProperty_CurrentDevice) stopped working on
    // macOS 27: its input and output share one audio unit, and the engine got no audio.
    private var session: AVCaptureSession?
    private var sink: CaptureSink?
    private let captureQueue = DispatchQueue(label: "org.churchai.translate.capture")
    #else
    private let engine = AVAudioEngine()
    #endif

    /// Start the microphone. Returns the stream of audio for the speech recogniser.
    func startMicrophone(deviceUID: String?, analyzerFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        #if os(macOS)
        let device = deviceUID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw CaptureError.noMicrophone }
        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw CaptureError.cantSelect }
        let output = AVCaptureAudioDataOutput()
        // 32-bit float, one buffer per channel: the format the meter and converter expect
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.cantSelect }
        session.addInput(input)
        session.addOutput(output)
        let stream = prepare(analyzerFormat: analyzerFormat)
        let sink = CaptureSink { [weak self] buffer in self?.process(buffer) }
        output.setSampleBufferDelegate(sink, queue: captureQueue)
        self.sink = sink
        self.session = session
        session.startRunning()
        print("[mic] \(device.localizedName) (\(device.uniqueID))")
        return stream
        #else
        try AudioDevices.configureSession()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw CaptureError.noMicrophone
        }
        let stream = prepare(analyzerFormat: analyzerFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        return stream
        #endif
    }

    /// Feed a recording through the same path in real time (for comparing with the Python app).
    func startFile(url: URL, analyzerFormat: AVAudioFormat, onFinished: @escaping @Sendable () -> Void) throws -> AsyncStream<AnalyzerInput> {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let stream = prepare(analyzerFormat: analyzerFormat)
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
        #if os(macOS)
        session?.stopRunning()
        session = nil
        sink = nil
        #else
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        #endif
        continuation?.finish()
        continuation = nil
        level.set(rms: 0, peak: 0)
    }

    // MARK: - Internals

    private func prepare(analyzerFormat: AVAudioFormat) -> AsyncStream<AnalyzerInput> {
        self.analyzerFormat = analyzerFormat
        converter = nil   // made from the first buffer's format (a microphone's isn't known until it starts)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }

    private func process(_ input: AVAudioPCMBuffer) {
        if gain.autoActive { gain.addAutoSample(rms(input)) }   // measured before any gain
        let buffer = applyGain(input, gain.linear)
        measure(buffer)
        guard let analyzerFormat, let continuation else { return }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { return }
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

    /// Scaled copy of the buffer (clipped to ±1), or the buffer itself at 0 dB.
    private func applyGain(_ buffer: AVAudioPCMBuffer, _ g: Float) -> AVAudioPCMBuffer {
        guard g != 1, let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return buffer }
        out.frameLength = buffer.frameLength
        let n = Int(buffer.frameLength)
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samplesPerChannel = buffer.format.isInterleaved ? n * Int(buffer.format.channelCount) : n
        for c in 0..<channels {
            for i in 0..<samplesPerChannel {
                dst[c][i] = max(-1, min(1, src[c][i] * g))
            }
        }
        return out
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0, let ch = buffer.floatChannelData?[0] else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(n)).squareRoot()
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
        case noMicrophone, cantSelect
        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone was found. Check the audio interface is plugged in."
            case .cantSelect: "Couldn't open the chosen microphone. Unplug it and plug it back in, press Refresh Devices and Voices, then try again."
            }
        }
    }
}

#if os(macOS)
/// Receives microphone audio from AVCaptureSession and hands it on as PCM buffers.
private final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let handler: (AVAudioPCMBuffer) -> Void
    init(handler: @escaping (AVAudioPCMBuffer) -> Void) { self.handler = handler }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: [asbd]) else { return }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        handler(buffer)
    }
}
#endif
