import SwiftUI

@main
struct ChurchTranslateApp: App {
    // The App struct is created once, so a plain constant holds the single shared model.
    private let model = TranslatorModel()

    var body: some Scene {
        WindowGroup("Church Translate") {
            ContentView()
                .environment(model)
                .task { await launch() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 660)
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
    }
}
