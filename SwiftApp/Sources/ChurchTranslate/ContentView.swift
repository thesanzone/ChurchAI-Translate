import SwiftUI
import Translation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Window-only state (which sheets are open). Uses ObservableObject/@StateObject so it
/// also builds with Apple's Command Line Tools, which lack the @State macro plugin.
final class ContentState: ObservableObject {
    @Published var showSettings = false
    @Published var showCaptions = false     // iPad full-screen captions
    @Published var pickRecording = false
    @Published var translationConfig: TranslationSession.Configuration?
}

struct ContentView: View {
    @Environment(TranslatorModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @StateObject private var ui = ContentState()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                leftPanel
                    .frame(width: 250)
                Divider()
                transcript
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $ui.showSettings) { SettingsView() }
        #if os(iOS)
        .fullScreenCover(isPresented: $ui.showCaptions) {
            CaptionView(onClose: { ui.showCaptions = false })
        }
        #endif
        .fileImporter(isPresented: $ui.pickRecording,
                      allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let ok = url.startAccessingSecurityScopedResource()
                await model.startFile(url)
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
        .translationTask(ui.translationConfig) { session in
            // Shows Apple's download sheet for the Spanish translation model if needed
            try? await session.prepareTranslation()
            await model.translationDownloaded()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    if model.isListening { await model.stop() } else { await model.startMicrophone() }
                }
            } label: {
                Text(model.isListening ? "Stop" : "Start")
                    .font(.title3.weight(.semibold))
                    .frame(width: 110, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isListening ? Color(red: 0.89, green: 0.29, blue: 0.29) : Color(red: 0.23, green: 0.43, blue: 0.07))
            .disabled(!model.isReady)
            .keyboardShortcut(.space, modifiers: [])

            statusPill

            Spacer()
            Text("English → Spanish").foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(at: ctx.date))
                    .font(.body.monospacedDigit())
                    .help("Time since Start was pressed")
            }
            Button("Settings", systemImage: "gearshape") { ui.showSettings = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (color, text) = status(at: ctx.date)
            HStack(spacing: 8) {
                if case .preparing = model.state {
                    ProgressView().controlSize(.small)
                } else {
                    Dot(color: color)
                }
                Text(text).lineLimit(2)
                if case .needsTranslationDownload = model.state {
                    Button("Download Spanish") { ui.translationConfig = .init(source: model.source, target: model.target) }
                }
                if case .error = model.state {
                    Button("Try again") { model.resetError() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func status(at now: Date) -> (Color, String) {
        switch model.state {
        case .preparing(let msg): return (.gray, msg)
        case .needsTranslationDownload: return (.blue, "Spanish translation needs a one-time download.")
        case .ready: return (.blue, "Ready. Press Start when the service begins.")
        case .error(let msg): return (.red, msg)
        case .listening:
            let since = model.lastSpeech ?? model.startedAt ?? now
            if model.playingFile == nil, !model.heardAnySignal,
               let start = model.startedAt, now.timeIntervalSince(start) > 3 {
                return (.red, "No sound at all from the microphone. Check it's plugged in and not muted. (The MacBook's built-in mic is off while the lid is closed.)")
            }
            if now.timeIntervalSince(since) > 20 {
                return (.orange, "Listening, but no sound from the microphone. Check it's on and unmuted.")
            }
            if let file = model.playingFile { return (.green, "Playing recording: \(file)") }
            return (.green, "Listening on \(model.deviceName(model.inputUID, in: model.inputDevices))")
        }
    }

    private func elapsed(at now: Date) -> String {
        guard let start = model.startedAt else { return "00:00:00" }
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    // MARK: - Left panel

    private var leftPanel: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            caption("Microphone (English in)")
            Picker("Microphone", selection: $model.inputUID) {
                ForEach(model.inputDevices) { Text($0.name).tag(Optional($0.id)) }
                if let uid = model.inputUID, !model.inputDevices.contains(where: { $0.id == uid }) {
                    Text("Not connected").tag(Optional(uid))
                }
            }
            .labelsHidden()
            .disabled(model.isListening)
            caption("Speakers / headsets (Spanish out)")
            Picker("Speakers", selection: $model.outputUID) {
                ForEach(model.outputDevices) { Text($0.name).tag(Optional($0.id)) }
                if let uid = model.outputUID, !model.outputDevices.contains(where: { $0.id == uid }) {
                    Text("Not connected").tag(Optional(uid))
                }
            }
            .labelsHidden()
            .disabled(model.isListening)
            Button("Refresh device list") { model.refreshDevices() }
                .disabled(model.isListening)
                .frame(maxWidth: .infinity)
            #else
            caption("Microphone (English in)")
            Text(model.inputDevices.first?.name ?? "Built-in microphone")
            caption("Speakers / headsets (Spanish out)")
            Text(model.outputDevices.first?.name ?? "iPad speaker")
            Text("Plug in the audio interface before opening the app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Refresh") { model.refreshDevices() }
            #endif

            HStack(alignment: .bottom, spacing: 16) {
                VStack(spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                        let clipping = model.lastClip.map { ctx.date.timeIntervalSince($0) < 1 } ?? false
                        Dot(color: clipping ? .red : .gray.opacity(0.4), size: 10)
                            .help("Turns red if the microphone is too loud")
                    }
                    LevelMeter(level: meterFraction(model.inputLevel),
                               threshold: meterFraction(model.silenceThreshold))
                    Text("In").font(.caption)
                }
                VStack(spacing: 4) {
                    Spacer().frame(height: 14)
                    LevelMeter(level: meterFraction(model.outputLevel))
                    Text("Out").font(.caption)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    Text("- - -  quiet line\nSound below it is\ntreated as silence.")
                        .font(.caption2).foregroundStyle(.secondary)
                    caption("Speech heard")
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        Text(heard(at: ctx.date)).font(.title3)
                    }
                    Spacer().frame(height: 18)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 8)

            Button("Test speakers", systemImage: "speaker.wave.2") { model.testSpeakers() }
                .frame(maxWidth: .infinity)
                .disabled(model.isListening)
        }
        .padding(16)
    }

    private func heard(at now: Date) -> String {
        guard model.isListening else { return "—" }
        guard let last = model.lastSpeech else { return "Not yet" }
        let ago = now.timeIntervalSince(last)
        return ago < 1.5 ? "Now" : "\(Int(ago))s ago"
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Time"); Text("English"); Text("Spanish")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(model.rows) { row in
                        GridRow {
                            Text(row.time.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                            Text(row.english).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.spanish).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .textSelection(.enabled)
                        .id(row.id)
                    }
                    if !model.liveEnglish.isEmpty {
                        GridRow {
                            Text("hearing").foregroundStyle(.secondary).font(.callout)
                            Text(model.liveEnglish).italic().foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("")
                        }
                        .id("live")
                    }
                }
                .padding(16)
            }
            .onChange(of: model.rows.count) { _, _ in
                withAnimation { proxy.scrollTo(model.rows.last?.id, anchor: .bottom) }
            }
            .onChange(of: model.liveEnglish) { _, _ in
                proxy.scrollTo("live", anchor: .bottom)
            }
        }
        .font(.system(size: 15))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Group {
                if let d = model.lastDelay {
                    HStack(spacing: 0) {
                        Text("Delay: ")
                        Text(String(format: "%.1fs", d)).foregroundStyle(d < 3 ? .green : d < 6 ? .orange : .red)
                    }
                } else {
                    Text("Delay: —")
                }
                Text("Waiting: \(model.waiting)")
                Text("Speech: \(model.fastSpeech ? "fast" : "normal")")
            }
            .foregroundStyle(.secondary)
            .font(.callout)
            Spacer()
            Button("Show captions", systemImage: "rectangle.on.rectangle") {
                #if os(macOS)
                openWindow(id: "captions")
                #else
                ui.showCaptions = true
                #endif
            }
            Button("Play recording…", systemImage: "waveform") { ui.pickRecording = true }
                .disabled(model.state != .ready)
                .help("Translate a sermon recording instead of the microphone, to compare quality")
            Button("Clear") { model.rows.removeAll() }
            #if os(macOS)
            Button("Open transcripts") {
                let url = TranslatorModel.transcriptsFolder
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            }
            #endif
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(TranslatorModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.weight(.semibold))
            Form {
                HStack {
                    Picker("Spanish voice", selection: Binding(
                        get: { model.voiceID },
                        set: { model.chooseVoice($0) })) {
                        ForEach(model.voiceOptions, id: \.id) { v in
                            Text(v.name).tag(Optional(v.id))
                        }
                    }
                    Button("Preview") { model.testSpeakers() }
                        .disabled(model.isListening)
                }
                Toggle("Faster Spanish speech", isOn: $model.fastSpeech)
                HStack {
                    Text("Caption text size")
                    Slider(value: $model.captionSize, in: 28...120, step: 2)
                    Text("\(Int(model.captionSize)) pt").monospacedDigit().frame(width: 52)
                }
            }
            if model.voiceID != PiperVoice.identifier, SpanishSpeaker.onlyBasicVoices {
                Label {
                    Text("Only the basic Spanish voice is installed, which sounds robotic. "
                         + "Download a natural-sounding one (free, one time):")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout.weight(.medium))
            }
            Text("Mac: System Settings → Accessibility → Read & Speak (or Spoken Content) → System Voice → "
                 + "Manage Voices → Spanish (Mexico) → Paulina (Enhanced or Premium).\n"
                 + "iPad: Settings → Accessibility → Read & Speak (or Spoken Content) → Voices → Spanish.\n"
                 + "Then come back here; the new voice appears in the list.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { model.refreshDevices() }   // picks up newly downloaded voices
    }
}
