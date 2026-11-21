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

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isListening else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop translating and quit?"
        alert.informativeText = "Church Translate is translating right now. Quitting stops the Spanish voice and captions."
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
                .task { await launch() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 660)
        // Always open the control panel at launch. If macOS restored "no windows" instead,
        // the app would sit there without loading anything (launch() runs from the window).
        .restorationBehavior(.disabled)
        #endif

        #if os(macOS)
        // Separate window for a projector/TV. Drag it to the second screen and press ⌃⌘F for full screen.
        Window("Spanish captions", id: "captions") {
            CaptionView()
                .environment(model)
                .frame(minWidth: 600, minHeight: 300)
        }
        .defaultSize(width: 1100, height: 450)
        #endif
    }

    /// Loads models. For testing: `--test-file <audio>` translates a recording on launch,
    /// and `--quit-when-done` exits when it finishes (output is printed to the console).
    @MainActor
    private func launch() async {
        #if os(macOS)
        appDelegate.model = model
        #endif
        setvbuf(stdout, nil, _IOLBF, 0)   // print each line immediately (useful when logging to a file)
        print("[launch] preparing models")
        await model.prepare()
        print("[voice] \(model.currentVoiceName) — \(model.voiceID ?? "none")")
        let args = ProcessInfo.processInfo.arguments
        // Test-only fader settings (not saved): --input-gain-db N, --output-gain-db N, --auto-level
        func number(after flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        if args.contains("--test-file") {
            model.saveGainsEnabled = false
            if let db = number(after: "--input-gain-db") { model.inputGainDB = db }
            if let db = number(after: "--output-gain-db") { model.outputGainDB = db }
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
                model.appendRow(TranscriptRow(time: Date(), english: "Sentence \(n)", spanish: "Frase \(n)", delay: 0))
            }
            print("[rows-selftest] added 450, on screen: \(model.rows.count), first: \(model.rows.first?.english ?? "-"), last: \(model.rows.last?.english ?? "-")")
            exit(model.rows.count == TranslatorModel.maxRowsOnScreen ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--test-file"), i + 1 < args.count, model.state == .ready {
            if args.contains("--auto-level") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    model.startAutoLevel()
                }
            }
            if args.contains("--quit-when-done") {
                NotificationCenter.default.addObserver(forName: .recordingFinished, object: nil, queue: .main) { _ in
                    exit(0)
                }
            }
            await model.startFile(URL(fileURLWithPath: args[i + 1]))
        }
        // `--test-mic <seconds>`: listen on the saved microphone, report whether sound arrived, then quit.
        if let i = args.firstIndex(of: "--test-mic"), model.state == .ready {
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
                exit(model.heardAnySignal ? 0 : 1)
            }
            await model.startMicrophone()
        }
    }
}
