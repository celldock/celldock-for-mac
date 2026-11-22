import SwiftUI

/// The words on the line selector: which line, and what is known about it.
struct LineSelectorTitle: Equatable {
    /// Everything on one line: "模组 1 · 卡槽 1 · 中国电信 · LTE".
    let full: String
    /// What identifies the line: "模组 1 · 卡槽 1".
    let line: String
    /// The rest: "中国电信 · LTE". nil when the line's name is all there is.
    let detail: String?

    init(full: String, line: String, detail: String?) {
        self.full = full
        self.line = line
        self.detail = detail
    }

    /// A title with nothing to split off, such as "没有可用模组".
    init(_ text: String) {
        self.init(full: text, line: text, detail: nil)
    }
}

/// What the line selector at the bottom of the sidebar shows: signal, the
/// line's title and a mark when another line needs attention.
///
/// It is as wide as the sidebar. The title stays on one line while it fits;
/// in a narrower sidebar it takes two lines, the line's name over its
/// carrier and network, rather than being cut off.
struct LineSelectorLabel: View {
    let title: LineSelectorTitle
    let signalBars: Int
    let hasSignal: Bool
    /// An offline line is only being looked at: grey title, no signal.
    var isOffline = false
    /// Another line has unread messages or missed calls.
    var showsAttention = false

    static let minimumHeight: CGFloat = 36
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
                Text(verbatim: title.full)
                    .foregroundStyle(isOffline ? Color.secondary : Color.primary)
                    .lineLimit(1)

                if title.detail != nil {
                    twoLines
                }

                // Not even two lines fit: cut them off.
                twoLines
                    .frame(minWidth: 0, alignment: .leading)
            }
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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.minimumHeight)
    }

    private var twoLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title.line)
                .foregroundStyle(isOffline ? Color.secondary : Color.primary)
                .lineLimit(1)
            if let detail = title.detail {
                Text(verbatim: detail)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
