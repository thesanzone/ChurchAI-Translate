#if os(macOS)
import AppKit
import SwiftUI

/// Shows each language's captions full screen on the external screen chosen for it in
/// Settings → Captions. Checked every second, so plugging a screen in or out (or an AirPlay
/// display dropping) is handled without anyone pressing anything.
@MainActor
final class CaptionWindows {
    static let shared = CaptionWindows()

    /// Open caption windows, by screen.
    private var windows: [String: (window: NSWindow, channel: UUID)] = [:]
    /// Testing only (--captions-on-any-screen): also allow the screen with the menu bar.
    var allowMainScreen = false

    /// Stable identifier for a screen (the same monitor keeps it when it's unplugged and replugged).
    static func screenID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// External screens captions may use: never the screen with the menu bar (the volunteer's
    /// controls) or the Mac's built-in display.
    func eligibleScreens() -> [NSScreen] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            if allowMainScreen { return screen }
            let builtIn = CGDisplayIsBuiltin(number.uint32Value) != 0
            return index == 0 || builtIn ? nil : screen
        }
    }

    func reconcile(_ model: TranslatorModel) {
        let screens = eligibleScreens()
        let infos = screens.compactMap { s in Self.screenID(s).map { CaptionScreen(id: $0, name: s.localizedName) } }
        if model.captionScreens != infos { model.captionScreens = infos }
        for c in model.channels {
            if let id = c.config.captionScreenID, let info = infos.first(where: { $0.id == id }),
               c.config.captionScreenName != info.name {
                c.config.captionScreenName = info.name
            }
        }

        // Which language goes on which connected screen (one language per screen)
        var wanted: [String: UUID] = [:]
        if model.captionsShowing {
            for c in model.channels where c.config.isOn {
                if let sid = c.config.captionScreenID, infos.contains(where: { $0.id == sid }), wanted[sid] == nil {
                    wanted[sid] = c.id
                }
            }
        }
        for (sid, entry) in windows where wanted[sid] != entry.channel {
            entry.window.orderOut(nil)
            entry.window.close()
            windows[sid] = nil
        }
        for (sid, channelID) in wanted {
            guard let screen = screens.first(where: { Self.screenID($0) == sid }) else { continue }
            if let w = windows[sid]?.window {
                if w.frame != screen.frame { w.setFrame(screen.frame, display: true) }
                continue
            }
            windows[sid] = (makeWindow(on: screen, channel: channelID, model: model), channelID)
            print("[captions] \(model.channel(channelID)?.name ?? "?") on \(screen.localizedName)")
        }
    }

    var openCount: Int { windows.count }

    func closeAll() {
        for (_, entry) in windows { entry.window.orderOut(nil); entry.window.close() }
        windows = [:]
    }

    private func makeWindow(on screen: NSScreen, channel: UUID, model: TranslatorModel) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Above the menu bar and Dock on that screen, on every Space, never in the window cycle
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.title = "Captions"
        window.contentView = NSHostingView(rootView: CaptionView(channelID: channel).environment(model))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        return window
    }
}
#endif
