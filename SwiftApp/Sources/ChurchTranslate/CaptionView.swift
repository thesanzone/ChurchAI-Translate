import SwiftUI

/// Large captions for one language on a projector or TV: the newest line big, the previous
/// one dimmed (optional). Colours, font, size and position come from Settings → Captions.
struct CaptionView: View {
    @Environment(TranslatorModel.self) private var model
    let channelID: UUID?
    /// Show sample sentences instead of the live translation (Preview).
    var sample = false
    /// Font sizes are multiplied by this (the Preview draws a scaled-down screen).
    var scale: CGFloat = 1
    var onClose: (() -> Void)? = nil

    var body: some View {
        let style = model.captionStyle
        let channel = model.channels.first { $0.id == channelID }
        let lines = currentLines(channel)
        let textColor = Color(hex: style.text)
        let rtl = channel?.isRightToLeft ?? false
        ZStack(alignment: style.atTop ? .topLeading : .bottomLeading) {
            Color(hex: style.background).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16 * scale) {
                if !style.atTop { Spacer(minLength: 0) }
                if style.showPreviousLine, let previous = lines.previous {
                    CaptionText(text: previous, size: style.size * 0.65 * scale, weight: .regular,
                                family: style.fontFamily, color: textColor.opacity(0.6),
                                outline: style.outline, textHex: style.text, lineLimit: 2)
                }
                CaptionText(text: lines.current, size: style.size * scale, weight: .semibold,
                            family: style.fontFamily, color: textColor,
                            outline: style.outline, textHex: style.text, lineLimit: 4)
                if style.atTop { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 60 * scale)
            .padding(.vertical, 60 * scale)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .animation(sample ? nil : .easeOut(duration: 0.25), value: model.rows.count)
        }
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .foregroundStyle(Color(white: 0.5))
                    .buttonStyle(.plain)
                    .padding()
            }
        }
    }

    private func currentLines(_ channel: LanguageChannel?) -> (previous: String?, current: String) {
        let phrases = channel?.phrases ?? .english
        if sample { return (phrases.samplePrevious, phrases.sample) }
        guard let channelID else { return (nil, phrases.waiting) }
        // The last two phrases translated into this language (rows from while it was off are skipped)
        var found: [String] = []
        for row in model.rows.reversed() {
            if let t = row.translations[channelID], !t.isEmpty, t != TranscriptRow.filtered {
                found.append(t)
                if found.count == 2 { break }
            }
        }
        guard let current = found.first else { return (nil, phrases.waiting) }
        return (found.count > 1 ? found[1] : nil, current)
    }
}

/// One caption line, with an optional outline so it stays readable over video.
private struct CaptionText: View {
    let text: String
    let size: Double
    let weight: Font.Weight
    let family: String
    let color: Color
    let outline: Bool
    let textHex: String
    let lineLimit: Int

    var body: some View {
        let font = family.isEmpty ? Font.system(size: size, weight: weight)
            : Font.custom(family, size: size).weight(weight)
        let base = Text(text).font(font).lineLimit(lineLimit).minimumScaleFactor(0.5)
            .multilineTextAlignment(.leading)
        if outline {
            // Dark outline around light text, light outline around dark text
            let outlineColor: Color = Color.brightness(textHex) > 0.5 ? .black : .white
            let w = max(1, size * 0.045)
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let angle = Double(i) * .pi / 4
                    base.foregroundStyle(outlineColor)
                        .offset(x: cos(angle) * w, y: sin(angle) * w)
                }
                base.foregroundStyle(color)
            }
        } else {
            base.foregroundStyle(color)
        }
    }
}
