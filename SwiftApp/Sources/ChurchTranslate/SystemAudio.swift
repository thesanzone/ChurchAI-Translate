import AVFoundation
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

/// "Mac's sound" as an input: translate whatever is playing on this Mac (a YouTube video in a
/// browser, a livestream, a Zoom call) instead of a microphone. Mac only.
enum SystemAudio {
    /// Stands in for a microphone's device UID in the Microphone menu.
    static let deviceUID = "org.churchai.translate.system-audio"
    static let displayName = "Mac's sound (videos, browser, other apps)"

    static var isSupported: Bool {
        #if os(macOS)
        if #available(macOS 14.2, *) { return true }
        #endif
        return false
    }
}

#if os(macOS)
/// Captures the sound of every other app on the Mac with a Core Audio process tap.
/// Church Translate's own process is always excluded, so its translated voices never feed
/// back into the translator. The first time, macOS asks for permission to capture audio.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "org.churchai.translate.system-audio")

    enum TapError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .failed(let step, let status):
                "Couldn't listen to the Mac's sound (\(step), error \(status)). Check Church Translate is allowed in System Settings → Privacy & Security → Screen & System Audio Recording."
            }
        }
    }

    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // Exclude this app (its voices) by its Core Audio process object. Without that, the
        // translated voices would be translated again, so refuse rather than risk a loop.
        guard let me = Self.processObject(pid: getpid()) else { throw TapError.failed("own process", -1) }
        let excluded = [me]
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Church Translate - Mac's sound"
        description.isPrivate = true
        description.muteBehavior = .unmuted   // the volunteer still hears the video
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("tap", status) }
        tapID = tap

        do {
            var format = try Self.tapFormat(tap)
            let outputUID = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Church Translate Mac Sound",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
            guard status == noErr else { throw TapError.failed("aggregate device", status) }
            aggregateID = agg
            // The tap reports a sample rate, but the sound actually runs at the aggregate device's
            // rate (that of the Mac's output, e.g. 44.1 kHz for the MacBook speakers). Labelling it
            // wrongly makes speech sound too fast and the delay drift, so use the device's rate.
            if let rate = Self.nominalSampleRate(agg), rate > 0, rate != format.mSampleRate {
                print("[input] Mac's sound: tap says \(Int(format.mSampleRate)) Hz, device runs at \(Int(rate)) Hz")
                format.mSampleRate = rate
            }
            guard let avFormat = AVAudioFormat(streamDescription: &format) else {
                throw TapError.failed("format", -1)
            }

            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { _, input, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil),
                      buffer.frameLength > 0 else { return }
                handler(buffer)   // used synchronously (copied/converted before returning)
            }
            guard status == noErr, let proc else { throw TapError.failed("audio callback", status) }
            procID = proc
            status = AudioDeviceStart(agg, proc)
            guard status == noErr else { throw TapError.failed("start", status) }
            print("[input] Mac's sound: \(Int(avFormat.sampleRate)) Hz, \(avFormat.channelCount) ch; own voices excluded: \(!excluded.isEmpty)")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    // MARK: Core Audio helpers

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.failed("format", status) }
        return format
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw TapError.failed("default output", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else { throw TapError.failed("default output", status) }
        return value as String
    }
}
#endif
