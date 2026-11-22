import SwiftUI

// The rows of the line menu, the popover the line selector opens. They take
// plain values and never read app state, so the menu can be rendered in
// isolation.

/// One line in the line menu. The lines are a choice of one, so each row
/// ends in a radio mark.
struct LineMenuRow: View {
    let appearance: LineAppearance
    let title: String
    let detail: String
    var secondDetail: String? = nil
    /// Unread messages plus missed calls on this line.
    var attention = 0
    let isSelected: Bool
    var isEnabled = true
    /// Why the line cannot be picked, shown while it is not the selected one.
    var trailingStatus: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let badgeText = appearance.badgeText {
                    LineBadge(text: badgeText, color: appearance.tint.solid)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.appBodyStrong)
                        .lineLimit(1)

                    Text(verbatim: detail)
                        .font(.appCaption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let secondDetail {
                        Text(verbatim: secondDetail)
                            .font(.appCaption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 6)

                Spacer(minLength: 8)

                if attention > 0 {
                    UnreadCountPill(count: attention)
                }

                if !isSelected, let trailingStatus {
                    Text(verbatim: trailingStatus)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }

                RadioMark(isOn: isSelected, isEnabled: isEnabled)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The mark at the end of a row that is one choice among several: filled for
/// the chosen row, an empty ring for the others.
struct RadioMark: View {
    let isOn: Bool
    var isEnabled = true

    static let diameter: CGFloat = 16

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.05))
            Circle()
                .strokeBorder(
                    isOn ? Color.accentColor : Color.secondary.opacity(0.6),
                    lineWidth: 1.2
                )
            if isOn {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityHidden(true)
    }
}

/// The switch under the lines of the line menu. While it is on, Messages,
/// Recents and Recordings list every line's records, and the rows above only
/// choose the line that sends and dials.
struct AllRecordsSwitchRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: L10n.tr("显示全部线路的记录"))
                    .font(.appBody.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: L10n.tr("短信、最近通话和录音不再按线路筛选"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
