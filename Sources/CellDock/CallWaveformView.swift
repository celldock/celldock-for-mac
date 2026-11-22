import AppKit
import SwiftUI

/// The colours of the two voices in a call. They are fixed rather than taken
/// from the module, whose own colour may be the same blue.
enum CallVoiceTint {
    static let remote = adaptive(light: 0x0B7F73, dark: 0x4FD1BE)
    static let local = adaptive(light: 0x2563EB, dark: 0x7AB0FF)

    /// A colour with one value for light and one for dark appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// One voice as a row of bars, newest on the right. Between two readings the
/// row slides left by one bar, so it moves steadily instead of jumping.
struct CallWaveformLane: View {
    /// Levels from 0 to 1, oldest first.
    let levels: [Float]
    let tint: Color
    let height: CGFloat
    /// When the newest level was taken. nil draws the bars at rest, for
    /// Reduce Motion and for a lane that is not live.
    var takenAt: Date?

    static let barWidth: CGFloat = 4
    static let barGap: CGFloat = 3
    private static let restingHeight: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: takenAt == nil)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, progress: progress(at: timeline.date))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// How far the row has slid towards the next reading, 0 to 1.
    private func progress(at date: Date) -> CGFloat {
        guard let takenAt else { return 1 }
        let elapsed = date.timeIntervalSince(takenAt) / CallAudioLevelMonitor.readingInterval
        return CGFloat(max(0, min(1, elapsed)))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress: CGFloat) {
        let pitch = Self.barWidth + Self.barGap
        let tallest = max(Self.restingHeight, size.height * 0.88)
        let quiet = Color.primary.opacity(0.2)
        // The newest bar enters from beyond the right edge.
        var x = size.width - Self.barWidth + (1 - progress) * pitch
        var index = levels.count - 1
        while x + Self.barWidth > 0 {
            let level = index >= 0 ? CGFloat(max(0, min(1, levels[index]))) : 0
            let barHeight = Self.restingHeight + level * (tallest - Self.restingHeight)
            let bar = CGRect(
                x: x,
                y: (size.height - barHeight) / 2,
                width: Self.barWidth,
                height: barHeight
            )
            context.fill(
                Path(roundedRect: bar, cornerRadius: Self.barWidth / 2),
                with: .color(Float(level) >= CallAudioLevel.voiced ? tint : quiet)
            )
            x -= pitch
            index -= 1
        }
    }
}

/// The recessed panel with both voices and the line that says who speaks.
struct CallWaveformPanel: View {
    let history: CallWaveformHistory
    /// nil keeps the bars at rest.
    var takenAt: Date?
    let laneHeight: CGFloat
    var paddingTop: CGFloat = 12
    var paddingBottom: CGFloat = 10
    var muted = false
    /// The line under the lanes. nil hides it, an empty string keeps its room.
    var hint: String?

    var body: some View {
        let labelWidth = Self.labelColumnWidth
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Self.labelGap) {
                label(L10n.tr("对方"), speaking: history.remoteSpeaking, tint: CallVoiceTint.remote)
                    .frame(width: labelWidth, alignment: .leading)
                CallWaveformLane(
                    levels: history.remote,
                    tint: CallVoiceTint.remote,
                    height: laneHeight,
                    takenAt: takenAt
                )
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 3)
                .padding(.leading, labelWidth + Self.labelGap)

            HStack(spacing: Self.labelGap) {
                label(
                    L10n.tr("我"),
                    speaking: history.localSpeaking && !muted,
                    tint: CallVoiceTint.local
                )
                .frame(width: labelWidth, alignment: .leading)
                CallWaveformLane(
                    levels: muted ? [] : history.local,
                    tint: CallVoiceTint.local,
                    height: laneHeight,
                    takenAt: muted ? nil : takenAt
                )
            }

            if let hint {
                Text(verbatim: hint.isEmpty ? " " : hint)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
                    .padding(.top, 6)
                    .padding(.leading, labelWidth + Self.labelGap)
                    .accessibilityHidden(hint.isEmpty)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, paddingTop)
        .padding(.bottom, paddingBottom)
        .inCallInsetSurface(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("通话声音"))
    }

    private static let labelGap: CGFloat = 12

    /// Both lanes start at the same x, whichever label is longer in the
    /// current language.
    private static var labelColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let widest = [L10n.tr("对方"), L10n.tr("我")]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(24, widest.rounded(.up) + 2)
    }

    private func label(_ text: String, speaking: Bool, tint: Color) -> some View {
        Text(verbatim: text)
            .font(.appCaptionStrong)
            .foregroundStyle(speaking ? tint : Color.secondary)
            .lineLimit(1)
            .fixedSize()
            .animation(.easeOut(duration: 0.15), value: speaking)
    }
}

/// A recessed area inside the glass card. Glass on glass looks muddy, so
/// wells are a soft fill with a hairline edge instead.
private struct InCallInsetSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .background {
                shape
                    .fill(Color.white.opacity(dark ? 0.06 : 0.36))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(dark ? 0.10 : 0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func inCallInsetSurface(cornerRadius: CGFloat) -> some View {
        modifier(InCallInsetSurface(cornerRadius: cornerRadius))
    }
}
