import SwiftUI

/// Large Spanish captions for a projector or TV: the newest line big, the previous one dimmed.
struct CaptionView: View {
    @Environment(TranslatorModel.self) private var model
    var onClose: (() -> Void)? = nil

    var body: some View {
        let lines = model.rows.suffix(2).map(\.spanish)
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.07).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Spacer()
                if lines.count == 2 {
                    Text(lines[0])
                        .font(.system(size: model.captionSize * 0.65))
                        .foregroundStyle(Color(white: 0.55))
                }
                Text(lines.last ?? "Esperando la traducción…")
                    .font(.system(size: model.captionSize, weight: .semibold))
                    .foregroundStyle(Color(white: 0.96))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.bottom, 60)
            .animation(.easeOut(duration: 0.25), value: model.rows.count)
        }
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button("Close", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .foregroundStyle(Color(white: 0.4))
                    .buttonStyle(.plain)
                    .padding()
            }
        }
    }
}
