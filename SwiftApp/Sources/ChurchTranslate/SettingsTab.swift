import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Speech, captions, transcripts and version. Voices are chosen per language in the Outputs tab.
struct SettingsTab: View {
    @Environment(TranslatorModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @ObservedObject var ui: ContentState

    var body: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 0) {
            Form { speech; transcripts; about }
                .formStyle(.grouped)
                .frame(maxWidth: 430)
            Form { captions }
                .formStyle(.grouped)
        }
        #else
        Form { speech; captions; transcripts; about }
            .formStyle(.grouped)
        #endif
    }

    // MARK: Speech

    private var speech: some View {
        @Bindable var model = model
        return Section {
            Toggle("Faster speech (all languages)", isOn: $model.fastSpeech)
            LabeledContent("Swear-word filter") { Text("Always on").foregroundStyle(.secondary) }
            Text("English swears are removed before translating. Spanish translations are also checked against the Spanish word list.")
                .font(.caption).foregroundStyle(.secondary)
            #if os(macOS)
            LabeledContent("Voices") {
                Button("Open Voice Settings…") { Self.openVoiceSettings() }
            }
            #endif
            Text(voiceHelp)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Speech")
        }
    }

    private var voiceHelp: String {
        #if os(macOS)
        "Choose each language's voice in the Outputs tab. Better Apple voices are a free one-time download per Mac: Open Voice Settings… → System voice menu → Manage Voices… → find the language → tick an Enhanced or Premium voice. Then click Refresh Voices in the Outputs tab."
        #else
        "Choose each language's voice in the Outputs tab. Better voices: Settings → Accessibility → Spoken Content → Voices → the language → download an Enhanced or Premium voice."
        #endif
    }

    // MARK: Captions

    private var captions: some View {
        @Bindable var model = model
        let style = model.captionStyle
        return Section {
            LabeledContent("Preview") {
                Button("Preview", systemImage: "eye") {
                    #if os(macOS)
                    openWindow(id: "captionPreview")
                    #else
                    ui.showPreview = true
                    #endif
                }
            }
            LabeledContent("Font") { fontMenu }
            LabeledContent("Text size") {
                HStack {
                    Slider(value: $model.captionStyle.size, in: 28...120, step: 2).frame(width: 160)
                    Text("\(Int(style.size)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            colorRow("Background", hex: $model.captionStyle.background, swatches: CaptionStyle.backgrounds)
            colorRow("Text color", hex: $model.captionStyle.text, swatches: CaptionStyle.textColors)
            Toggle("Text outline", isOn: $model.captionStyle.outline)
            Picker("Position", selection: $model.captionStyle.atTop) {
                Text("Bottom").tag(false)
                Text("Top").tag(true)
            }
            .pickerStyle(.segmented)
            Toggle("Show previous line", isOn: $model.captionStyle.showPreviousLine)
            Text("For a video overlay (e.g. OBS Studio), choose a green background, one line and an outline, then key out the green.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            #if os(macOS)
            ForEach(model.channels) { c in
                LabeledContent("\(c.name) captions") { screenMenu(for: c) }
            }
            if model.captionScreens.isEmpty {
                Text("Connect a projector or TV, or an Apple TV with AirPlay (Control Center → Screen Mirroring → Use as Separate Display), to show captions.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Each screen shows one language, full screen. The screen with the menu bar keeps the controls. AirPlay screens work too, with a little more delay.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #else
            Text("Show captions (Translate tab) fills the iPad screen with the first language that's on. A connected TV mirrors it.")
                .font(.caption).foregroundStyle(.secondary)
            #endif
        } header: {
            Text("Captions")
        }
    }

    private var fontMenu: some View {
        let installed = CaptionStyle.installedFonts
        let suggested = CaptionStyle.suggestedFonts.filter { installed.contains($0) }
        return Menu(model.captionStyle.fontName) {
            Button { model.captionStyle.fontFamily = "" } label: {
                checkLabel("SF Pro (System)", model.captionStyle.fontFamily.isEmpty)
            }
            ForEach(suggested, id: \.self) { f in
                Button { model.captionStyle.fontFamily = f } label: { checkLabel(f, model.captionStyle.fontFamily == f) }
            }
            Divider()
            Menu("More fonts") {
                ForEach(installed.filter { !suggested.contains($0) }, id: \.self) { f in
                    Button { model.captionStyle.fontFamily = f } label: { checkLabel(f, model.captionStyle.fontFamily == f) }
                }
            }
        }
        .fixedSize()
        .help("If a font doesn't have a language's letters, the system fills them in automatically.")
    }

    private func colorRow(_ title: String, hex: Binding<String>, swatches: [CaptionStyle.Swatch]) -> some View {
        let isPreset = swatches.contains { $0.hex.caseInsensitiveCompare(hex.wrappedValue) == .orderedSame }
        return LabeledContent(title) {
            HStack(spacing: 8) {
                if !isPreset {
                    ColorPicker("Custom color", selection: Binding(
                        get: { Color(hex: hex.wrappedValue) },
                        set: { hex.wrappedValue = $0.hexString }), supportsOpacity: false)
                        .labelsHidden()
                }
                Menu {
                    ForEach(swatches) { s in
                        Button { hex.wrappedValue = s.hex } label: {
                            checkLabel(s.name, s.hex.caseInsensitiveCompare(hex.wrappedValue) == .orderedSame)
                        }
                    }
                    Divider()
                    Button("Custom color…") {
                        // Start from a nearby colour so the picker appears; then adjust it
                        if isPreset { hex.wrappedValue = title == "Background" ? "#202020" : "#E0E0E0" }
                    }
                } label: {
                    Text(CaptionStyle.name(of: hex.wrappedValue, in: swatches))
                }
                .fixedSize()
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: hex.wrappedValue))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                    .frame(width: 16, height: 16)
            }
        }
    }

    #if os(macOS)
    /// Off, or one of the connected external screens. A screen used by another language is
    /// shown but can't be picked (one language per screen); a remembered screen that isn't
    /// plugged in stays selected, marked "not connected".
    private func screenMenu(for c: LanguageChannel) -> some View {
        let current = c.config.captionScreenID
        let currentLabel: String
        if let current {
            let connected = model.captionScreens.contains { $0.id == current }
            currentLabel = (c.config.captionScreenName ?? "Screen") + (connected ? "" : " (not connected)")
        } else {
            currentLabel = "Off"
        }
        return Menu(currentLabel) {
            Button { setScreen(c, nil) } label: { checkLabel("Off", current == nil) }
            if !model.captionScreens.isEmpty { Divider() }
            ForEach(model.captionScreens) { s in
                let user = model.channels.first { $0 !== c && $0.config.captionScreenID == s.id }
                Button { setScreen(c, s) } label: {
                    checkLabel(s.name + (user.map { " (used by \($0.name))" } ?? ""), current == s.id)
                }
                .disabled(user != nil)
            }
            if let current, !model.captionScreens.contains(where: { $0.id == current }) {
                Button("\(c.config.captionScreenName ?? "Screen") (not connected)") {}.disabled(true)
            }
            if model.captionScreens.isEmpty {
                Text("Connect a projector or TV, or an Apple TV with AirPlay, to show captions.")
            }
        }
        .fixedSize()
    }

    private func setScreen(_ c: LanguageChannel, _ s: CaptionScreen?) {
        c.config.captionScreenID = s?.id
        c.config.captionScreenName = s?.name
    }
    #endif

    private func checkLabel(_ text: String, _ checked: Bool) -> some View {
        Group {
            if checked { Label(text, systemImage: "checkmark") } else { Text(text) }
        }
    }

    // MARK: Transcripts and About

    private var transcripts: some View {
        Section {
            #if os(macOS)
            LabeledContent("Saved to") {
                Button("Open transcripts folder") {
                    let url = TranslatorModel.transcriptsFolder
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
            #endif
            ForEach(model.channels) { c in
                LabeledContent("\(c.name) translation") {
                    switch c.status {
                    case .ready: Label("Ready", systemImage: "checkmark").foregroundStyle(.green)
                    case .checking: Text("Checking…").foregroundStyle(.secondary)
                    case .needsDownload: Button("Download") { ui.download(c) }
                    case .unsupported: Text("Not available").foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Transcripts and downloads")
        }
    }

    private var about: some View {
        Section {
            LabeledContent("Church Translate") {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0")")
                    .foregroundStyle(.secondary)
            }
            Text("Speech recognition, translation and voices are Apple's, and run on this device.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("About")
        }
    }

    #if os(macOS)
    /// System Settings → Accessibility → Spoken Content, at the "System voice" setting.
    /// AX_SPOKEN_VOICE is the anchor System Settings lists for that setting on macOS 27.
    /// If a macOS version doesn't know the anchor, System Settings still opens at Accessibility.
    static func openVoiceSettings() {
        let link = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_SPOKEN_VOICE"
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    #endif
}
