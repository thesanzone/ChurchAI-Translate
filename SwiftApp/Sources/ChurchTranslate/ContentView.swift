import SwiftUI
import Translation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum MainTab: Hashable { case translate, outputs, settings }

/// Window-only state (tab, sheets, dialogs). Uses ObservableObject/@StateObject so it
/// also builds with Apple's Command Line Tools, which lack the @State macro plugin.
final class ContentState: ObservableObject {
    @Published var tab: MainTab = .translate
    @Published var showCaptions = false     // iPad full-screen captions
    @Published var showPreview = false      // iPad captions preview
    @Published var pickRecording = false
    @Published var translationConfig: TranslationSession.Configuration?
    var downloadLanguage: String?
    /// The language waiting for "Stop … and remove it?" during a service.
    @Published var removeCandidate: UUID?

    /// Show Apple's one-time download sheet for a language's translation.
    @MainActor func download(_ c: LanguageChannel) {
        downloadLanguage = c.config.language
        translationConfig = .init(source: Languages.english, target: c.target)
    }
}

struct ContentView: View {
    @Environment(TranslatorModel.self) private var model
    @StateObject private var ui = ContentState()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(ui: ui)
            Divider()
            TabView(selection: $ui.tab) {
                TranslateTab(ui: ui)
                    .tabItem { Label("Translate", systemImage: "captions.bubble") }
                    .tag(MainTab.translate)
                OutputsTab(ui: ui)
                    .tabItem { Label("Outputs", systemImage: "speaker.wave.2") }
                    .tag(MainTab.outputs)
                SettingsTab(ui: ui)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(MainTab.settings)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        #if os(macOS)
        // While translating, grey out the red close button so a stray click can't stop a service.
        // (Press Stop first. Quitting with ⌘Q still asks: see AppDelegate.)
        .windowDismissBehavior(model.isListening ? .disabled : .automatic)
        #endif
        .alert("Auto level", isPresented: Binding(
            get: { model.autoLevelMessage != nil },
            set: { if !$0 { model.autoLevelMessage = nil } })) {
            Button("OK") { model.autoLevelMessage = nil }
        } message: {
            Text(model.autoLevelMessage ?? "")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $ui.showCaptions) {
            CaptionView(channelID: model.onChannels.first?.id, onClose: { ui.showCaptions = false })
        }
        .sheet(isPresented: $ui.showPreview) { CaptionPreview(onClose: { ui.showPreview = false }) }
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
            // Shows Apple's download sheet for the language's translation model if needed
            try? await session.prepareTranslation()
            if let language = ui.downloadLanguage { await model.translationDownloaded(language) }
        }
    }
}

// MARK: - Top bar (all tabs)

private struct TopBar: View {
    @Environment(TranslatorModel.self) private var model
    @ObservedObject var ui: ContentState

    var body: some View {
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
            .disabled(!(model.isListening || model.canStart))
            .keyboardShortcut(.space, modifiers: [])

            statusPill

            Spacer()
            Text(languageSummary).foregroundStyle(.secondary).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(at: ctx.date))
                    .font(.body.monospacedDigit())
                    .help("Time since Start was pressed")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var languageSummary: String {
        let names = model.onChannels.map(\.name)
        return names.isEmpty ? "English → (no language on)" : "English → " + names.joined(separator: ", ")
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
                if model.state == .ready, let c = model.languageNeedingDownload, model.activeChannels.isEmpty {
                    Button("Download \(c.name)") { ui.download(c) }
                }
                if model.state == .ready, model.onChannels.isEmpty {
                    Button("Open Outputs") { ui.tab = .outputs }
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
        case .ready where model.isStarting: return (.gray, "Starting…")
        case .ready:
            if let problem = model.startProblem { return (.orange, problem) }
            return (.blue, "Ready. Press Start when the service begins.")
        case .error(let msg): return (.red, msg)
        case .listening:
            let since = model.lastSpeech ?? model.startedAt ?? now
            if model.playingFile == nil, !model.heardAnySignal,
               let start = model.startedAt, now.timeIntervalSince(start) > 3 {
                if model.usingSystemAudio {
                    return (.red, "No sound from the Mac yet. Play the video, and check Church Translate is allowed in System Settings → Privacy & Security → Screen & System Audio Recording.")
                }
                return (.red, "No sound at all from the microphone. Check it's plugged in and not muted. (The MacBook's built-in mic is off while the lid is closed.)")
            }
            if now.timeIntervalSince(since) > 20 {
                return (.orange, model.usingSystemAudio ? "Listening to the Mac's sound, but nothing is playing."
                        : "Listening, but no sound from the microphone. Check it's on and unmuted.")
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
}

// MARK: - Translate tab

struct TranslateTab: View {
    @Environment(TranslatorModel.self) private var model
    @ObservedObject var ui: ContentState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftPanel.frame(width: 330)
                Divider()
                TranscriptView()
            }
            Divider()
            bottomBar
        }
    }

    // MARK: Left panel

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
            .help("Pick \"Mac's sound\" to translate a video or livestream playing on this Mac")
            Button("Refresh Devices and Voices") { model.refreshAll() }
                .help("Re-reads the microphones, speakers and installed voices")
                .disabled(model.isListening)
                .frame(maxWidth: .infinity)
            #else
            caption("Microphone (English in)")
            Text(model.inputDevices.first?.name ?? "Built-in microphone")
            Text("Plug in the audio interface before opening the app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Refresh") { model.refreshAll() }
            #endif

            HStack(alignment: .bottom, spacing: 8) {
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
                    GainFader(db: $model.inputGainDB, range: TranslatorModel.inputGainRange,
                              help: "Microphone level going to the translator.")
                    Button(model.autoLevelSecondsLeft.map { "\($0)s" } ?? "Auto") { model.startAutoLevel() }
                        .controlSize(.small)
                        .disabled(model.autoLevelSecondsLeft != nil)
                        .help("While the pastor is speaking, listens for 10 seconds and sets the microphone level automatically.")
                }
                .frame(width: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    Text("- - -  quiet line. Sound below it is treated as silence.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    caption("Speech heard")
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        Text(heard(at: ctx.date)).font(.title3)
                    }
                    Spacer().frame(height: 18)
                }
                .padding(.leading, 6)
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 8)

            languagesList

            Button("Test all outputs", systemImage: "speaker.wave.2") { model.testAllOutputs() }
                .frame(maxWidth: .infinity)
                .disabled(model.isListening || model.onChannels.isEmpty)
                .help("Each language that's on says a short test sentence on its own output")

            if let basic = model.onChannels.first(where: { $0.usesBasicVoice }) {
                // Easy to miss in the Outputs tab, so also warn here before a service starts.
                VStack(alignment: .leading, spacing: 6) {
                    Label("The \(basic.name) voice is a basic Apple voice and sounds robotic.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose a better voice…") { ui.tab = .outputs }
                        .controlSize(.small)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
    }

    /// Each language's status and voice level, with a link to the Outputs tab.
    private var languagesList: some View {
        VStack(alignment: .leading, spacing: 5) {
            caption("Languages")
            if model.channels.isEmpty {
                Text("None yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.channels) { c in
                HStack(spacing: 8) {
                    Dot(color: statusColor(c), size: 9)
                    Text(c.name + (c.config.isOn ? "" : " (off)"))
                        .foregroundStyle(c.config.isOn ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer()
                    if model.isListening, c.config.isOn, let d = c.lastDelay {
                        Text(String(format: "%.1fs", d))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(d < 3 ? .green : d < 6 ? .orange : .red)
                            .help("Delay for \(c.name): from the English being spoken to its translation")
                    }
                    HorizontalMeter(level: meterFraction(c.outputLevel))
                        .frame(width: 70, height: 8)
                        .opacity(c.config.isOn ? 1 : 0.3)
                }
                .font(.callout)
                .help(statusHelp(c))
            }
            Button("Change in Outputs tab") { ui.tab = .outputs }
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ c: LanguageChannel) -> Color {
        guard c.config.isOn else { return .gray.opacity(0.4) }
        switch c.status {
        case .checking: return .gray
        case .needsDownload, .unsupported: return .orange
        case .ready: return c.deviceMissing || c.outputNotResponding ? .orange : .green
        }
    }

    private func statusHelp(_ c: LanguageChannel) -> String {
        guard c.config.isOn else { return "\(c.name) is turned off" }
        switch c.status {
        case .checking: return "Checking \(c.name) translation…"
        case .needsDownload: return "\(c.name) translation needs a one-time download (Outputs tab)"
        case .unsupported: return "\(c.name) can't be translated on this device"
        case .ready:
            if c.deviceMissing { return "\(c.config.deviceName ?? "Its output") isn't connected" }
            if c.outputNotResponding { return "\(c.config.deviceName ?? "Its output") isn't responding" }
            return "\(c.name) is ready"
        }
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

    // MARK: Bottom bar

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
                if let notice = model.transcriptProblem ?? model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(notice)
                }
            }
            .foregroundStyle(.secondary)
            .font(.callout)
            Spacer()
            captionsButton
            Button("Play recording…", systemImage: "waveform") { ui.pickRecording = true }
                .disabled(!model.canStart)
                .help("Translate a sermon recording (MP3, M4A, WAV or MP4 video) instead of the microphone")
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

    @ViewBuilder
    private var captionsButton: some View {
        #if os(macOS)
        let assigned = model.onChannels.filter { $0.config.captionScreenID != nil }
        if assigned.isEmpty {
            Button("Set up captions…", systemImage: "rectangle.on.rectangle") { ui.tab = .settings }
                .help("Choose a projector or TV for each language in Settings → Captions")
        } else if model.captionsShowing {
            Button("Hide captions", systemImage: "rectangle.on.rectangle.slash") { model.captionsShowing = false }
        } else {
            Button("Show captions", systemImage: "rectangle.on.rectangle") { model.captionsShowing = true }
                .help(assigned.map { "\($0.name) → \($0.config.captionScreenName ?? "screen")" }.joined(separator: ", "))
        }
        #else
        Button("Show captions", systemImage: "rectangle.on.rectangle") { ui.showCaptions = true }
            .disabled(model.onChannels.isEmpty)
        #endif
    }
}

/// Small horizontal level bar for a language's voice.
struct HorizontalMeter: View {
    var level: Double   // 0...1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.88 ? Color.red : level > 0.7 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * min(1, max(0, level)))
            }
        }
        .accessibilityLabel("Voice level")
    }
}

/// The scrolling English + translations table. A separate view, so it's only redrawn when the
/// text changes, not every time a level meter moves.
struct TranscriptView: View {
    @Environment(TranslatorModel.self) private var model

    var body: some View {
        let columns = model.channels.filter { $0.config.isOn }
        return ScrollViewReader { proxy in
            ScrollView {
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Time")
                        Text("English")
                        ForEach(columns) { Text($0.name) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(model.rows) { row in
                        GridRow {
                            Text(row.time.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary).font(.callout.monospacedDigit())
                            Text(row.english).frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(columns) { c in
                                Text(row.translations[c.id] ?? "")
                                    .frame(maxWidth: .infinity, alignment: c.isRightToLeft ? .trailing : .leading)
                                    .multilineTextAlignment(c.isRightToLeft ? .trailing : .leading)
                            }
                        }
                        .textSelection(.enabled)
                        .id(row.id)
                    }
                    if !model.liveEnglish.isEmpty {
                        GridRow {
                            Text("hearing").foregroundStyle(.secondary).font(.callout)
                            Text(model.liveEnglish).italic().foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(columns) { _ in Text("") }
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

}
