import AVFoundation
#if os(macOS)
import CoreAudio
import AudioToolbox
#endif

/// An audio device the volunteer can pick. On iPad the system routes audio
/// (a plugged-in USB interface is used automatically), so only Mac shows pickers.
struct AudioDevice: Identifiable, Hashable {
    let id: String          // CoreAudio UID (stable across reboots/replugging)
    let name: String
}

enum AudioDevices {
#if os(macOS)
    static func inputs() -> [AudioDevice] { devices(scope: kAudioDevicePropertyScopeInput) }
    static func outputs() -> [AudioDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channelCount(id, scope: scope) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Point an AVAudioEngine input or output node at a specific device.
    @discardableResult
    static func assign(uid: String?, to node: AVAudioIONode) -> Bool {
        guard let uid, var devID = deviceID(forUID: uid), let unit = node.audioUnit else { return false }
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() else { return nil }
        return str as String
    }
#else
    static func inputs() -> [AudioDevice] {
        let s = AVAudioSession.sharedInstance()
        return (s.currentRoute.inputs).map { AudioDevice(id: $0.uid, name: $0.portName) }
    }
    static func outputs() -> [AudioDevice] {
        let s = AVAudioSession.sharedInstance()
        return (s.currentRoute.outputs).map { AudioDevice(id: $0.uid, name: $0.portName) }
    }

    static func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        // .default mode keeps the audio clean (no voice-call processing) for a mixer feed
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
    }
#endif
}
