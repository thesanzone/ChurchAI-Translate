import SwiftUI

final class PreviewState: ObservableObject {
    @Published var channelID: UUID?
    @Published var showEdgeGuide = true
}

/// A scaled-down captions screen in the current style, to check font, size and colours.
/// Shows sample sentences before a service and the live captions while translating.
struct CaptionPreview: View {
    @Environment(TranslatorModel.self) private var model
    @StateObject private var state = PreviewState()
    var onClose: (() -> Void)? = nil

    /// The preview is drawn as a 1920×1080 screen scaled to fit.
    private let screenWidth: CGFloat = 1920

    var body: some View {
        let channels = model.channels
        let selected = state.channelID ?? channels.first(where: { $0.config.isOn })?.id ?? channels.first?.id
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if channels.count > 1 {
                    Picker("Language", selection: Binding(get: { selected }, set: { state.channelID = $0 })) {
                        ForEach(channels) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Spacer()
                Toggle("Show TV edge guide", isOn: $state.showEdgeGuide)
            }
            GeometryReader { geo in
                let scale = geo.size.width / screenWidth
                ZStack {
                    CaptionView(channelID: selected, sample: !model.isListening, scale: scale)
                    if state.showEdgeGuide {
                        // Some TVs and projectors cut off about 5% at each edge
                        Rectangle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(geo.size.width * 0.05)
                            .allowsHitTesting(false)
                    }
                    if !model.isListening {
                        Text("Sample text")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(6)
                            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(geo.size.width * 0.06)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            HStack {
                Text(model.captionStyle.summary)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if let onClose { Button("Close", action: onClose).keyboardShortcut(.cancelAction) }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }
}
