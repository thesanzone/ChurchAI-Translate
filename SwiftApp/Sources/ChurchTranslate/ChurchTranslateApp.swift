import SwiftUI
#if os(macOS)
import AppKit

/// Quits the app when its last window is closed (normally a Mac app keeps running in the Dock),
/// and asks before quitting (⌘Q) while a service is being translated. The window's close button
/// is disabled while translating (ContentView), so the question never appears after the window
/// is gone, and closing the alert can't count as "last window closed" and re-trigger it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: TranslatorModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Runs the app's start-up (loading models, test options) once.
    var onLaunch: (() -> Void)?

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.releaseAudioNow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start loading models straight away, not when the window first appears (macOS doesn't
        // open windows while the screen is locked, for example).
        onLaunch?()
        onLaunch = nil
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isListening else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop translating and quit?"
        alert.informativeText = "Church Translate is translating right now. Quitting stops the voices and captions."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Translating")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await model.stop()   // closes the transcript file and lets the Mac sleep again
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

@main
struct ChurchTranslateApp: App {
    // The App struct is created once, so a plain constant holds the single shared model.
    private let model = TranslatorModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(macOS)
        let model = self.model
        let app = self
        appDelegate.onLaunch = { Task { @MainActor in await app.launch(model: model) } }
        #endif
        // `--filter-check <text> [<text>…]`: show what the swear-word filter does, then quit.
        // Runs before any window opens: plain-text arguments would otherwise be treated by
        // macOS as documents to open, and the main window would never appear.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--filter-check"), i + 1 < args.count {
            setvbuf(stdout, nil, _IOLBF, 0)
            for text in args[(i + 1)...] {
                let shown = model.filterEnglish(text, mask: "•••")
                let voice = model.filterEnglish(text, mask: "")
                print("[filter-check] \(text)\n   shown: \(shown.text)\n   voice: \(voice.text)   [\(shown.changed) changed]")
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Church Translate") {
            ContentView()
                .environment(model)
                #if os(iOS)
                .task { await launch() }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 660)
        // Always open the control panel at launch. If macOS restored "no windows" instead,
        // the app would sit there without loading anything (launch() runs from the window).
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        #endif

        #if os(macOS)
        // Settings → Captions → Preview. (Live captions windows are placed on their screens by
        // CaptionWindows, not opened as scenes.)
        Window("Captions preview", id: "captionPreview") {
            CaptionPreview().environment(model)
        }
        .defaultSize(width: 760, height: 520)
        // Only opened from Settings; never reopened at launch (that could replace the control panel)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }

    /// Loads models. For testing: `--test-file <audio>` translates a recording on launch,
    /// and `--quit-when-done` exits when it finishes (output is printed to the console).
    @MainActor
    private func launch() async { await launch(model: model) }

    @MainActor
    private func launch(model: TranslatorModel) async {
        #if os(macOS)
        appDelegate.model = model
        #endif
        setvbuf(stdout, nil, _IOLBF, 0)   // print each line immediately (useful when logging to a file)
        let args = ProcessInfo.processInfo.arguments
        func number(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        func list(after flag: String) -> [String]? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1].split(separator: ",").map(String.init)
        }
        // Command-line tests never change the volunteer's saved settings
        let testing = args.contains { $0.hasPrefix("--test-file") } || ["--test-mic", "--test-languages", "--rows-selftest", "--test-captions", "--render-captions"].contains { args.contains($0) }
        if testing {
            model.persistEnabled = false
            model.saveGainsEnabled = false
        }
        // --test-languages es,ko[,…]: translate into these languages for this run (Mac default
        // output unless --test-device-uids "uid1|uid2|…" gives one per language; "none" = default)
        if let codes = list(after: "--test-languages") {
            // Device UIDs can contain commas (e.g. "…:1,2"), so they're separated by "|"
            let uids = args.firstIndex(of: "--test-device-uids").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                .map { $0.split(separator: "|").map(String.init) } ?? []
            model.useTestLanguages(codes, deviceUIDs: uids.map { $0 == "none" ? nil : $0 })
        }
        #if os(macOS)
        if args.contains("--system-audio") { model.inputUID = SystemAudio.deviceUID }
        if args.contains("--captions-on-any-screen") { CaptionWindows.shared.allowMainScreen = true }
        // Keep captions windows matched to their screens (and to screens being plugged in or out)
        Task { @MainActor in
            while true {
                CaptionWindows.shared.reconcile(model)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #endif
        print("[launch] preparing models")
        await model.prepare()
        for c in model.channels {
            print("[language] \(c.name) (\(c.config.language)) on=\(c.config.isOn) status=\(c.status) voice=\(c.voiceName) output=\(model.deviceName(c.config.deviceUID, in: model.outputDevices))")
        }
        if args.contains(where: { $0.hasPrefix("--test-file") }) {
            if let db = number(after: "--input-gain-db") { model.inputGainDB = db }
            if let db = number(after: "--output-gain-db") { for c in model.channels { c.config.gainDB = db } }
        }
        #if os(macOS)
        // --test-captions: show the first language's captions on the first external screen
        if args.contains("--test-captions") {
            CaptionWindows.shared.reconcile(model)
            if let screen = model.captionScreens.first, let c = model.channels.first {
                c.config.captionScreenID = screen.id
                c.config.captionScreenName = screen.name
                model.captionsShowing = true
                print("[test] captions for \(c.name) on \(screen.name)")
            } else {
                print("[test] no external screen for captions")
            }
        }
        #endif
        #if os(macOS)
        // --render-captions <folder>: draw sample captions screens in a few styles to PNG files, then quit
        if let i = args.firstIndex(of: "--render-captions"), i + 1 < args.count {
            let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var green = CaptionStyle()
            green.background = "#00B140"; green.outline = true; green.showPreviousLine = false; green.atTop = true
            var yellow = CaptionStyle()
            yellow.text = "#FFD60A"; yellow.fontFamily = "Georgia"; yellow.size = 72
            for (styleName, style) in [("default", CaptionStyle()), ("green-overlay", green), ("yellow-georgia", yellow)] {
                model.captionStyle = style
                for c in model.channels {
                    let view = CaptionView(channelID: c.id, sample: true, scale: 0.5)
                        .environment(model)
                        .frame(width: 960, height: 540)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1
                    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let file = folder.appendingPathComponent("\(styleName)-\(c.config.language).png")
                        try? png.write(to: file)
                        print("[render] \(file.lastPathComponent)")
                    }
                }
            }
            exit(0)
        }
        #endif
        // --test-mute-second N: turn the second language off N seconds after start, on again N seconds later
        if let n = number(after: "--test-mute-second"), model.channels.count > 1 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(n))
                print("[test] turning \(model.channels[1].name) off")
                model.channels[1].config.isOn = false
                try? await Task.sleep(for: .seconds(n))
                print("[test] turning \(model.channels[1].name) on")
                model.channels[1].config.isOn = true
            }
        }
        // Failure simulations for testing recovery (see README)
        if args.contains("--simulate-recognizer-error") { model.simulateRecognizerError = true }
        if args.contains("--simulate-voice-stall") { model.simulateVoiceStall() }
        if args.contains("--simulate-output-dropout") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                print("[test] simulating a speaker output dropout")
                model.simulateOutputDropout()
            }
        }
        if args.contains("--rows-selftest") {
            for n in 1...450 {
                model.appendRow(TranscriptRow(time: Date(), english: "Sentence \(n)", translations: [UUID(): "Frase \(n)"], delay: 0))
            }
            print("[rows-selftest] added 450, on screen: \(model.rows.count), first: \(model.rows.first?.english ?? "-"), last: \(model.rows.last?.english ?? "-")")
            exit(model.rows.count == TranslatorModel.maxRowsOnScreen ? 0 : 1)
        }
        // `--test-file=/path` (one argument): a separate path argument makes macOS treat it as a
        // document to open, and the control panel window then doesn't appear.
        let testFile = args.first { $0.hasPrefix("--test-file=") }.map { String($0.dropFirst("--test-file=".count)) }
            ?? args.firstIndex(of: "--test-file").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        if let testFile, model.canStart {
            if args.contains("--auto-level") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    model.startAutoLevel()
                }
            }
            if args.contains("--quit-when-done") {
                NotificationCenter.default.addObserver(forName: .recordingFinished, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { model.releaseAudioNow() }
                    exit(0)
                }
            }
            await model.startFile(URL(fileURLWithPath: testFile))
        }
        // `--test-mic <seconds>`: listen on the saved microphone, report whether sound arrived, then quit.
        if let i = args.firstIndex(of: "--test-mic"), model.canStart {
            let seconds = i + 1 < args.count ? Double(args[i + 1]) ?? 5 : 5
            if args.contains("--simulate-mic-dropout") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    print("[test] simulating a microphone dropout")
                    model.simulateMicDropout()
                }
            }
            Task { @MainActor in
                var loudest: Float = 0
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    try? await Task.sleep(for: .milliseconds(50))
                    loudest = max(loudest, model.inputPeak)
                }
                print("[mic test] state: \(model.state), sound arrived: \(model.heardAnySignal), loudest peak: \(loudest), "
                      + String(format: "last audio %.1fs ago", model.micSecondsSinceAudio))
                model.releaseAudioNow()
                exit(model.heardAnySignal ? 0 : 1)
            }
            await model.startMicrophone()
        }
    }
}
