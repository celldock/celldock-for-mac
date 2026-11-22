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
/// line's title, a tag while the lists show every line's records, and a mark
/// when another line needs attention.
///
/// It is as wide as the sidebar. The title stays on one line while it fits;
/// in a narrower sidebar it takes two lines, the line's name over its
/// carrier and network, rather than being cut off. The tag gives way before
/// the title does: it shrinks to a symbol, and goes when even that would cut
/// the title off.
struct LineSelectorLabel: View {
    let title: LineSelectorTitle
    let signalBars: Int
    let hasSignal: Bool
    /// An offline line is only being looked at: grey title, no signal.
    var isOffline = false
    /// Another line has unread messages or missed calls.
    var showsAttention = false
    /// The lists show every line's records; this line only sends and dials.
    var showsAllRecords = false

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
                titled(oneLine, tag: .words)

                if title.detail != nil {
                    titled(twoLines, tag: .words)
                }

                if showsAllRecords {
                    titled(twoLines, tag: .symbol)
                    // The title matters more than the tag: the rows of the
                    // lists carry line badges that say the same.
                    titled(twoLines, tag: nil)
                }

                // Not even that fits: cut the title off.
                titled(twoLines.frame(minWidth: 0, alignment: .leading), tag: nil)
            }
            .layoutPriority(1)

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

    /// The title at the leading edge and, while the lists show every line,
    /// the tag at the trailing edge.
    private func titled(_ title: some View, tag: AllRecordsTag.Size?) -> some View {
        let shownTag = showsAllRecords ? tag : nil
        return HStack(spacing: 0) {
            title
            Spacer(minLength: shownTag == nil ? 12 : 6)
            if let shownTag {
                AllRecordsTag(size: shownTag)
            }
        }
    }

    private var oneLine: some View {
        Text(verbatim: title.full)
            .foregroundStyle(isOffline ? Color.secondary : Color.primary)
            .lineLimit(1)
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

/// Says that Messages, Recents and Recordings are listing every line's
/// records, not only those of the line the selector names.
struct AllRecordsTag: View {
    enum Size {
        /// "全部记录"
        case words
        /// A symbol, for where the words would crowd the title out.
        case symbol
    }

    var size: Size = .words

    var body: some View {
        Group {
            switch size {
            case .words:
                Text(verbatim: L10n.tr("全部记录"))
                    .font(.appMicro)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
            case .symbol:
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.appSymbol(.indicator, weight: .semibold))
                    .frame(width: 20)
            }
        }
        .foregroundStyle(Color.accentColor)
        .frame(height: 16)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
        .help(L10n.tr("正在显示全部线路的记录"))
        .accessibilityLabel(L10n.tr("正在显示全部线路的记录"))
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
