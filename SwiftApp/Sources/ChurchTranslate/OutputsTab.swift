import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One row per language: on/off, language, voice, output device, volume, meter, test, remove.
struct OutputsTab: View {
    @Environment(TranslatorModel.self) private var model
    @ObservedObject var ui: ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(headerText)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Voices", systemImage: "arrow.clockwise") { model.refreshAll() }
                    .help("Reloads devices and voices after you plug something in or download a voice")
                Button("Add language", systemImage: "plus") { model.addLanguage() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            OutputsHeader()
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            List {
                ForEach(model.channels) { c in
                    OutputRow(channel: c, ui: ui)
                }
                .onMove { model.moveChannels(from: $0, to: $1) }
            }
            .listStyle(.inset)
            if model.channels.isEmpty {
                Text("No languages yet. Click Add language.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .alert(removeTitle, isPresented: Binding(
            get: { ui.removeCandidate != nil },
            set: { if !$0 { ui.removeCandidate = nil } })) {
            Button("Cancel", role: .cancel) { ui.removeCandidate = nil }
            Button("Remove \(removeName)", role: .destructive) {
                if let c = model.channel(ui.removeCandidate) { model.removeChannel(c) }
                ui.removeCandidate = nil
            }
        } message: {
            Text("\(removeName) is speaking right now. Its voice, device and volume settings will be deleted. To mute \(removeName) instead and keep its settings, untick On.")
        }
    }

    private var headerText: String {
        #if os(macOS)
        "Changes are saved automatically and restored next time the app opens. Drag rows to reorder."
        #else
        "Changes are saved automatically. On iPad, one language at a time."
        #endif
    }

    private var removeName: String { model.channel(ui.removeCandidate)?.name ?? "this language" }
    private var removeTitle: String { "Stop \(removeName) and remove it?" }
}

/// Column widths shared by the header and the rows.
private enum Col {
    static let on: CGFloat = 34
    static let language: CGFloat = 190
    static let voice: CGFloat = 210
    static let device: CGFloat = 200
    static let volume: CGFloat = 150
    static let meter: CGFloat = 60
}

private struct OutputsHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("On").frame(width: Col.on, alignment: .leading)
            Text("Language").frame(width: Col.language, alignment: .leading)
            Text("Voice").frame(width: Col.voice, alignment: .leading)
            #if os(macOS)
            Text("Output device").frame(width: Col.device, alignment: .leading)
            #endif
            Text("Volume").frame(width: Col.volume, alignment: .leading)
            Text("Meter").frame(width: Col.meter, alignment: .leading)
            Text("Test")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct OutputRow: View {
    @Environment(TranslatorModel.self) private var model
    let channel: LanguageChannel
    @ObservedObject var ui: ContentState

    var body: some View {
        @Bindable var c = channel
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("On", isOn: $c.config.isOn)
                    .labelsHidden()
                    #if os(macOS)
                    .toggleStyle(.checkbox)
                    #endif
                    .frame(width: Col.on, alignment: .leading)
                    .help(c.config.isOn ? "Untick to mute this language (its settings are kept)" : "Tick to translate into this language")
                languagePicker
                voicePicker
                #if os(macOS)
                devicePicker
                #endif
                HStack(spacing: 6) {
                    Slider(value: $c.config.gainDB, in: TranslatorModel.outputGainRange, step: 1)
                    Text(c.config.gainDB == 0 ? "0 dB" : String(format: "%+.0f dB", c.config.gainDB))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                        .onTapGesture(count: 2) { c.config.gainDB = 0 }
                        .help("Double-click to reset to 0 dB")
                }
                .frame(width: Col.volume)
                HorizontalMeter(level: meterFraction(c.outputLevel))
                    .frame(width: Col.meter, height: 8)
                Button { model.testSpeaker(c) } label: { Image(systemName: "play.fill") }
                    .disabled(model.isListening || c.status != .ready)
                    .help("Plays a short test sentence in \(c.name) on its output")
                Spacer(minLength: 0)
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                    .help("Remove \(c.name)")
            }
            .opacity(c.config.isOn ? 1 : 0.55)
            messages
                .padding(.leading, Col.on + 10)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Remove \(c.name)", role: .destructive) { remove() }
        }
    }

    private func remove() {
        if model.isListening && channel.config.isOn {
            ui.removeCandidate = channel.id   // asks first: this language is speaking right now
        } else {
            model.removeChannel(channel)
        }
    }

    // MARK: Pickers

    private var languagePicker: some View {
        @Bindable var c = channel
        return Picker("Language", selection: $c.config.language) {
            if !model.languageOptions.contains(where: { $0.id == c.config.language }) {
                Text(c.name).tag(c.config.language)
            }
            ForEach(model.languageOptions) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(width: Col.language)
        .disabled(model.isListening)
        .help(model.isListening ? "Stop translating to change the language" : "Language to translate into")
        .onChange(of: c.config.language) { _, _ in
            // A new language starts with its best installed voice
            c.config.voiceID = nil
            c.config.voiceChosenByUser = false
        }
    }

    private var voicePicker: some View {
        let c = channel
        let voices = c.voices
        return Picker("Voice", selection: Binding(
            get: { c.effectiveVoice?.identifier ?? "" },
            set: { c.chooseVoice($0.isEmpty ? nil : $0) })) {
            if voices.isEmpty { Text("No voice installed").tag("") }
            ForEach(voices, id: \.identifier) { v in
                Text(Languages.describe(v)).tag(v.identifier)
            }
        }
        .labelsHidden()
        .frame(width: Col.voice)
        .help("Apple voices installed on this device for \(c.name). Best first.")
    }

    #if os(macOS)
    private var devicePicker: some View {
        @Bindable var c = channel
        let devices = model.outputDevices
        return Picker("Output device", selection: Binding(
            get: { c.config.deviceUID },
            set: { uid in
                c.config.deviceUID = uid
                c.config.deviceName = devices.first { $0.id == uid }?.name
            })) {
            Text("Mac default output").tag(String?.none)
            ForEach(devices) { Text($0.name).tag(Optional($0.id)) }
            if let uid = c.config.deviceUID, !devices.contains(where: { $0.id == uid }) {
                Text("\(c.config.deviceName ?? "Device") (not connected)").tag(Optional(uid))
            }
        }
        .labelsHidden()
        .frame(width: Col.device)
        .disabled(model.isListening)
        .help(model.isListening ? "Stop translating to change the output" : "Where this language's voice plays")
    }
    #endif

    // MARK: Status messages under the row

    @ViewBuilder
    private var messages: some View {
        let c = channel
        switch c.status {
        case .checking:
            note("Checking \(c.name) translation…", color: .secondary, icon: "hourglass")
        case .unsupported:
            note("\(c.name) can't be translated on this device. Pick another language.", color: .orange)
        case .needsDownload:
            HStack(spacing: 8) {
                note("\(c.name) translation needs a one-time download.", color: .orange)
                Button("Download \(c.name)") { ui.download(c) }.controlSize(.small)
            }
        case .ready:
            EmptyView()
        }
        #if os(macOS)
        if let uid = c.config.deviceUID, !model.outputDevices.contains(where: { $0.id == uid }) {
            note("\(c.config.deviceName ?? "The output device") isn't connected."
                 + (c.config.isOn ? " Plug it in and \(c.name) starts again by itself." : ""), color: .orange)
        }
        if c.outputNotResponding {
            note("\(c.config.deviceName ?? "The output device") isn't responding. Unplug it and plug it back in.", color: .orange)
        }
        if c.config.isOn, let other = model.onChannels.first(where: { $0 !== c && $0.config.deviceUID == c.config.deviceUID }) {
            note("\(other.name) also plays on this output, so the voices will overlap.", color: .orange)
        }
        #endif
        if c.voices.isEmpty {
            HStack(spacing: 8) {
                note("No \(c.name) voice is installed. Download one (free).", color: .orange)
                voiceSettingsButton
            }
        } else if c.usesBasicVoice {
            HStack(spacing: 8) {
                note(c.betterVoiceInstalled ? "This is a basic voice and sounds robotic. A better one is installed: pick it in the Voice menu."
                     : "This is a basic voice and sounds robotic. Download an Enhanced or Premium \(c.name) voice (free).",
                     color: .orange)
                if !c.betterVoiceInstalled { voiceSettingsButton }
            }
        }
        if !c.config.isOn {
            note("Off: not translated or spoken. Settings kept.", color: .secondary, icon: "speaker.slash")
        }
    }

    @ViewBuilder
    private var voiceSettingsButton: some View {
        #if os(macOS)
        Button("Open Voice Settings…") { SettingsTab.openVoiceSettings() }.controlSize(.small)
        #else
        EmptyView()
        #endif
    }

    private func note(_ text: String, color: Color, icon: String = "exclamationmark.triangle.fill") -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
