import SwiftUI

/// Map loudness to 0...1 on a decibel scale (like a mixing desk).
func meterFraction(_ rms: Float) -> Double {
    guard rms > 0 else { return 0 }
    let db = 20 * log10(Double(rms))
    return min(1, max(0, (db + 60) / 60))
}

/// Smoothing state for one meter (fast attack, slow release, peak hold).
final class MeterState: ObservableObject {
    @Published var shown: Double = 0
    @Published var peak: Double = 0
    var peakTime = Date.distantPast

    func update(_ new: Double) {
        shown = new > shown ? new : shown * 0.8 + new * 0.2
        if new >= peak || Date().timeIntervalSince(peakTime) > 1.5 {
            peak = new
            peakTime = Date()
        }
    }
}

/// Vertical green/amber/red segmented level meter with peak hold and an optional cutoff line.
struct LevelMeter: View {
    var level: Double            // 0...1
    var threshold: Double? = nil // 0...1, drawn as a dashed line
    @StateObject private var meter = MeterState()

    private var shown: Double { meter.shown }
    private var peak: Double { meter.peak }
    private let segments = 30

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - 4
            let segH = h / Double(segments)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.background.secondary)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                VStack(spacing: 1) {
                    ForEach((0..<segments).reversed(), id: \.self) { i in
                        let frac = Double(i + 1) / Double(segments)
                        let lit = Double(i) < shown * Double(segments)
                        Rectangle()
                            .fill(color(frac).opacity(lit ? 1 : 0.15))
                            .frame(height: max(1, segH - 1))
                    }
                }
                .padding(3)
                if peak > 0.02 {
                    Rectangle().fill(.primary)
                        .frame(height: 2)
                        .padding(.horizontal, 3)
                        .offset(y: -(peak * h) - 1)
                }
                if let threshold {
                    Path { p in
                        let y = geo.size.height - 2 - threshold * h
                        p.move(to: CGPoint(x: -2, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width + 2, y: y))
                    }
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
        }
        .frame(width: 30)
        .onChange(of: level) { _, new in meter.update(new) }
        .accessibilityLabel("Level meter")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(_ frac: Double) -> Color {
        frac <= 0.70 ? Color(red: 0.39, green: 0.60, blue: 0.13)
            : frac <= 0.88 ? Color(red: 0.94, green: 0.62, blue: 0.15)
            : Color(red: 0.89, green: 0.29, blue: 0.29)
    }
}

/// Small coloured status dot.
struct Dot: View {
    var color: Color
    var size: CGFloat = 12
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
