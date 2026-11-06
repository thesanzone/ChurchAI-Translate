import AVFoundation
import Foundation

/// The Python app's Piper voice (es_MX "ald"), built into the Mac app via sherpa-onnx.
/// Compiled only when ./fetch_piper.sh has been run; otherwise Apple voices are used.
/// The voice files live in the app bundle at Contents/Resources/piper/.
#if canImport(CSherpaOnnx)
import CSherpaOnnx

final class PiperVoice: @unchecked Sendable {
    static let identifier = "piper.es_MX-ald-medium"
    static let displayName = "Piper — Mexican Spanish (built in, same as the Python app)"

    private let tts: OpaquePointer
    let sampleRate: Double
    private let lock = NSLock()

    /// Folder containing es_MX-ald-medium.onnx, tokens.txt and espeak-ng-data.
    static var voiceFolder: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("piper", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path) ? dir : nil
    }

    static var isAvailable: Bool { voiceFolder != nil }

    init?() {
        guard let dir = Self.voiceFolder else { return nil }
        let model = strdup(dir.appendingPathComponent("es_MX-ald-medium.onnx").path)
        let tokens = strdup(dir.appendingPathComponent("tokens.txt").path)
        let data = strdup(dir.appendingPathComponent("espeak-ng-data").path)
        let provider = strdup("cpu")
        defer { free(model); free(tokens); free(data); free(provider) }

        var config = SherpaOnnxOfflineTtsConfig()
        config.model.vits.model = UnsafePointer(model)
        config.model.vits.tokens = UnsafePointer(tokens)
        config.model.vits.data_dir = UnsafePointer(data)
        // Same voice settings as the Python app (Piper defaults)
        config.model.vits.noise_scale = 0.667
        config.model.vits.noise_scale_w = 0.8
        config.model.vits.length_scale = 1.0
        config.model.num_threads = 2
        config.model.provider = UnsafePointer(provider)
        config.max_num_sentences = 1

        guard let created = SherpaOnnxCreateOfflineTts(&config) else { return nil }
        tts = created
        sampleRate = Double(SherpaOnnxOfflineTtsSampleRate(created))
    }

    deinit { SherpaOnnxDestroyOfflineTts(tts) }

    /// Speak `text` into a mono float buffer. `speed` 1.11 matches the Python app's normal pace.
    func synthesize(_ text: String, speed: Float) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let audio = SherpaOnnxOfflineTtsGenerate(tts, text, 0, speed) else { return nil }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let n = Int(audio.pointee.n)
        guard n > 0, let samples = audio.pointee.samples,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        buf.floatChannelData![0].update(from: samples, count: n)
        return buf
    }
}
#else
/// Stand-in when the Piper engine isn't built in (iPad / App Store builds, or fetch_piper.sh not run).
final class PiperVoice: @unchecked Sendable {
    static let identifier = "piper.es_MX-ald-medium"
    static let displayName = "Piper (not included in this build)"
    static var isAvailable: Bool { false }
    let sampleRate: Double = 22050
    init?() { return nil }
    func synthesize(_ text: String, speed: Float) -> AVAudioPCMBuffer? { nil }
}
#endif
