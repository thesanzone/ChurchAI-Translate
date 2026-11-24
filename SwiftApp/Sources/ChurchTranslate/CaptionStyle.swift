import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How captions look on every captions screen. Saved between launches.
struct CaptionStyle: Codable, Equatable {
    /// Font family name; empty means the system font (SF Pro).
    var fontFamily = ""
    var size: Double = 56
    var background = "#000000"
    var text = "#FFFFFF"
    var outline = false
    var atTop = false
    var showPreviousLine = true

    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let backgrounds = [
        Swatch(name: "Black (standard)", hex: "#000000"),
        Swatch(name: "Green (for green-screen overlay)", hex: "#00B140"),
        Swatch(name: "Blue (for blue-screen overlay)", hex: "#0047BB"),
        Swatch(name: "Magenta", hex: "#FF00FF"),
    ]
    static let textColors = [
        Swatch(name: "White (standard)", hex: "#FFFFFF"),
        Swatch(name: "Yellow", hex: "#FFD60A"),
    ]

    static func name(of hex: String, in list: [Swatch]) -> String {
        list.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name
            .replacingOccurrences(of: " (standard)", with: "") ?? "Custom (\(hex.uppercased()))"
    }

    /// Readable fonts listed first in the Font menu (only those installed are shown).
    static let suggestedFonts = ["Helvetica Neue", "Arial", "Verdana", "Avenir Next", "Georgia", "Gill Sans"]

    static var installedFonts: [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }.sorted()
        #else
        UIFont.familyNames.sorted()
        #endif
    }

    var fontName: String { fontFamily.isEmpty ? "SF Pro (System)" : fontFamily }

    var summary: String {
        [fontName, "\(Int(size)) pt",
         "\(Self.name(of: background, in: Self.backgrounds)) background",
         "\(Self.name(of: text, in: Self.textColors)) text" + (outline ? " with outline" : ""),
         atTop ? "Top" : "Bottom",
         showPreviousLine ? "2 lines" : "1 line"].joined(separator: " · ")
    }
}

extension Color {
    /// "#RRGGBB" → Color (black if the text can't be read).
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt32(s, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    /// Color → "#RRGGBB".
    var hexString: String {
        #if os(macOS)
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    /// Rough brightness 0…1, used to pick an outline colour that contrasts with the text.
    static func brightness(_ hex: String) -> Double {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let v = UInt32(s, radix: 16) ?? 0
        return (0.299 * Double((v >> 16) & 0xFF) + 0.587 * Double((v >> 8) & 0xFF) + 0.114 * Double(v & 0xFF)) / 255
    }
}
