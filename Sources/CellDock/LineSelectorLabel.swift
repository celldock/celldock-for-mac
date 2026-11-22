import SwiftUI

/// What the line selector at the bottom of the sidebar shows: signal, the
/// line's title and a mark when another line needs attention.
///
/// It is as wide as the sidebar lets it be. When the full title still does
/// not fit, it shows a shorter one instead of cutting the text off.
struct LineSelectorLabel: View {
    /// The title from the most to the least detailed.
    let titles: [String]
    let signalBars: Int
    let hasSignal: Bool
    /// An offline line is only being looked at: grey title, no signal.
    var isOffline = false
    /// Another line has unread messages or missed calls.
    var showsAttention = false

    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 15

    var body: some View {
        HStack(spacing: 8) {
            CommunicationModuleSignalBars(
                bars: isOffline ? 0 : signalBars,
                hasSignal: !isOffline && hasSignal,
                tint: hasSignal ? .green : .secondary,
                barWidth: 2.5,
                spacing: 1.5
            )
            .frame(width: 14, height: 18)
            .accessibilityHidden(true)

            ViewThatFits(in: .horizontal) {
                ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                    Text(verbatim: title)
                        .lineLimit(1)
                }
                // Not even the shortest fits: show it cut off.
                Text(verbatim: titles.last ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0)
            }
            .foregroundStyle(isOffline ? Color.secondary : Color.primary)
            .layoutPriority(1)

            Spacer(minLength: 4)

            if showsAttention {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .help(L10n.tr("其他线路有未读短信或未接来电"))
                    .accessibilityLabel(L10n.tr("其他线路有未读短信或未接来电"))
            }

            Image(systemName: "chevron.up.chevron.down")
                .font(.appSymbol(.indicator, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
        }
        .font(.appCallout)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }
}

struct CommunicationModuleSignalBars: View {
    let bars: Int
    let hasSignal: Bool
    let tint: Color
    let barWidth: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0 ..< 4, id: \.self) { index in
                Capsule()
                    .fill(barColor(at: index))
                    .frame(
                        width: barWidth,
                        height: CGFloat(5 + index * 3)
                    )
            }
        }
    }

    private func barColor(at index: Int) -> Color {
        guard hasSignal else { return Color.secondary.opacity(0.20) }
        return index < min(max(bars, 0), 4)
            ? tint
            : tint.opacity(0.20)
    }
}
