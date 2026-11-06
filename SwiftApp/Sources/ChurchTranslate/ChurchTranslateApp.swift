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
        if let i = args.firstIndex(of: "--test-file"), i + 1 < args.count, model.state == .ready {
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
            Task { @MainActor in
                var loudest: Float = 0
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    try? await Task.sleep(for: .milliseconds(50))
                    loudest = max(loudest, model.inputPeak)
                }
                print("[mic test] state: \(model.state), sound arrived: \(model.heardAnySignal), loudest peak: \(loudest)")
                exit(model.heardAnySignal ? 0 : 1)
            }
            await model.startMicrophone()
        }
    }
}
