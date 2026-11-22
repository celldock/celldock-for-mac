import SwiftUI

// Presentational building blocks shared by Messages, Recents and Recordings.
// They take plain values and never read app state, so the three lists stay
// visually identical and can be rendered in isolation.

/// Incoming, outgoing or missed, as a small arrow in front of a status line.
struct CallDirectionGlyph: View {
    let direction: CallDirection
    var isMissed = false

    var body: some View {
        Image(systemName: direction == .incoming ? "arrow.down.left" : "arrow.up.right")
            .font(.appSymbol(.indicator, weight: .semibold))
            .foregroundStyle(isMissed ? Color.red : Color.secondary)
            .accessibilityHidden(true)
    }
}

struct UnreadCountPill: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(.appMicro)
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18)
            .frame(height: 16)
            .background(Color.accentColor, in: Capsule())
            .fixedSize()
            .accessibilityLabel(L10n.tr("%lld 条未读", Int64(count)))
    }
}

/// One conversation in the Messages list.
struct ConversationRowContent: View {
    let title: String
    let address: String
    let preview: String
    let timestamp: String?
    let unreadCount: Int
    let latestIsOutgoing: Bool
    let line: LineAppearance

    var body: some View {
        HStack(spacing: AppMetrics.Spacing.medium) {
            ContactFaceAvatar(address: address)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: AppMetrics.Spacing.small) {
                    Text(verbatim: title)
                        .font(unreadCount > 0 ? .appBodyStrong : .appBody)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let timestamp {
                        Text(verbatim: timestamp)
                            .font(.appCaption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
                HStack(spacing: 4) {
                    if latestIsOutgoing {
                        Image(systemName: "arrow.up.right")
                            .font(.appSymbol(.indicator, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.tr("已发送"))
                    }
                    Text(verbatim: preview)
                        .font(.appCallout)
                        .foregroundStyle(unreadCount > 0 ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if unreadCount > 0 {
                        UnreadCountPill(count: unreadCount)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .help(line.fullTitle)
    }
}

/// One call in the Recents list.
struct CallRowContent: View {
    let title: String
    let address: String
    let status: String
    let isMissed: Bool
    let direction: CallDirection
    let timestamp: String
    let hasRecording: Bool
    let line: LineAppearance

    var body: some View {
        HStack(spacing: AppMetrics.Spacing.medium) {
            ContactFaceAvatar(address: address)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: AppMetrics.Spacing.small) {
                    Text(verbatim: title)
                        .font(isMissed ? .appBodyStrong : .appBody)
                        .foregroundStyle(isMissed ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: timestamp)
                        .font(.appCaption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                HStack(spacing: 4) {
                    CallDirectionGlyph(direction: direction, isMissed: isMissed)
                    Text(verbatim: status)
                        .font(.appCallout)
                        .monospacedDigit()
                        .foregroundStyle(isMissed ? Color.red : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hasRecording {
                        Image(systemName: "waveform")
                            .font(.appSymbol(.inline))
                            .foregroundStyle(.secondary)
                            .help(L10n.tr("包含通话录音"))
                            .accessibilityLabel(L10n.tr("包含通话录音"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .help(line.fullTitle)
    }
}

/// One recording in the Recordings list.
struct RecordingRowContent: View {
    let title: String
    let address: String
    let detail: String
    let direction: CallDirection
    let timestamp: String
    let isIncomplete: Bool
    /// "waveform" while playing, "play.fill" while paused, nil otherwise.
    var playbackSymbol: String? = nil
    let line: LineAppearance

    var body: some View {
        HStack(spacing: AppMetrics.Spacing.medium) {
            ContactFaceAvatar(address: address)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: AppMetrics.Spacing.small) {
                    Text(verbatim: title)
                        .font(.appBody)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: timestamp)
                        .font(.appCaption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                HStack(spacing: 4) {
                    if let playbackSymbol {
                        Image(systemName: playbackSymbol)
                            .font(.appSymbol(.indicator, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    } else {
                        CallDirectionGlyph(direction: direction)
                    }
                    Text(verbatim: detail)
                        .font(.appCallout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isIncomplete {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.appSymbol(.inline))
                            .foregroundStyle(.orange)
                            .help(L10n.tr("录音过程中部分音频未能写入"))
                            .accessibilityLabel(L10n.tr("录音过程中部分音频未能写入"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .help(line.fullTitle)
    }
}

/// Marks where a merged conversation moves to another line.
struct LineChangeNotice: View {
    let appearance: LineAppearance
    /// True for the first stretch of the thread, which has nothing to switch from.
    let isFirst: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let badgeText = appearance.badgeText {
                LineBadge(text: badgeText, color: appearance.tint.solid)
            }
            Text(verbatim: L10n.tr(
                isFirst ? "通过 %@ 收发" : "切换到 %@ 收发",
                appearance.fullTitle
            ))
            .font(.appCaption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.leading, appearance.badgeText == nil ? 10 : 3)
        .padding(.trailing, 10)
        .frame(height: AppMetrics.Control.chip)
        .adaptiveGlassSurface(
            cornerRadius: AppMetrics.Control.chip / 2,
            treatment: .clear
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The message input: line picker, text field and send button in one glass
/// bar, with the character count and the sending line underneath.
struct MessageComposerBar: View {
    @Binding var draft: String
    let options: [SendLineOption]
    let selectedModuleID: CellularModuleID?
    let onSelectModule: (CellularModuleID) -> Void
    let canSend: Bool
    let isSending: Bool
    let sendHelp: String
    /// Shown above the bar when the line last used with this peer is unavailable.
    var note: String? = nil
    let statusLeading: String
    let statusTrailing: String
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let note {
                Label {
                    Text(verbatim: note)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.appCaption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
            }

            HStack(alignment: .bottom, spacing: 6) {
                linePicker

                TextField(L10n.tr("输入短信"), text: $draft, axis: .vertical)
                    .font(.appBody)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 5)
                    .focused(focus)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(minHeight: AppMetrics.Control.regular)

                Button(action: onSend) {
                    Group {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.appSymbol(.small, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: AppMetrics.Control.regular, height: AppMetrics.Control.regular)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .adaptiveGlassSurface(
                    cornerRadius: AppMetrics.Control.regular / 2,
                    treatment: .regular,
                    tint: selectedTint.solid.opacity(canSend ? 0.92 : 0.36),
                    isInteractive: canSend
                )
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSend)
                .help(sendHelp)
                .accessibilityLabel(L10n.tr("发送"))
            }
            .padding(4)
            .adaptiveGlassSurface(
                cornerRadius: 18,
                treatment: .clear,
                isInteractive: true
            )

            HStack {
                Text(verbatim: statusLeading)
                    .monospacedDigit()
                Spacer()
                Text(verbatim: statusTrailing)
            }
            .font(.appCaption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
    }

    private var selectedOption: SendLineOption? {
        options.first { $0.moduleID == selectedModuleID }
    }

    private var selectedTint: ModuleTint {
        selectedOption?.appearance.tint ?? .detached
    }

    private var linePicker: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelectModule(option.moduleID)
                } label: {
                    if option.moduleID == selectedModuleID {
                        Label(option.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.menuTitle)
                    }
                }
                .disabled(!option.isEligible)
            }
        } label: {
            HStack(spacing: 6) {
                if let badgeText = selectedOption?.appearance.badgeText {
                    LineBadge(text: badgeText, color: selectedTint.solid)
                }
                Text(verbatim: selectedOption?.appearance.title ?? L10n.tr("选择线路"))
                    .font(.appCalloutStrong)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.appSymbol(.indicator, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(height: AppMetrics.Control.regular)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Color.primary.opacity(0.07), in: Capsule())
        .disabled(options.isEmpty)
        .help(L10n.tr("选择发送线路"))
        .accessibilityLabel(L10n.tr("选择发送线路"))
        .accessibilityValue(selectedOption?.appearance.fullTitle ?? "")
    }
}

/// A label and a value on one line inside a detail card.
struct DetailFieldRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: AppMetrics.Spacing.large) {
            Text(verbatim: title)
                .font(.appCallout)
                .foregroundStyle(.secondary)
            Spacer(minLength: AppMetrics.Spacing.medium)
            value
                .font(.appBody)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
        .frame(minHeight: AppMetrics.Row.single)
    }
}

/// A line shown as a field value: badge followed by "模组 1 · 中国移动".
struct LineFieldValue: View {
    let appearance: LineAppearance

    var body: some View {
        HStack(spacing: 7) {
            if let badgeText = appearance.badgeText {
                LineBadge(text: badgeText, color: appearance.tint.solid)
            }
            Text(verbatim: appearance.fullTitle)
                .font(.appBody)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appearance.fullTitle)
    }
}

/// The small caption above a card in a detail pane.
struct DetailSectionCaption: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(.appCaptionStrong)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }
}
