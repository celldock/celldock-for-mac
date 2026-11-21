import SwiftUI

private struct MenuBarContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuBarHubView: View {
    @EnvironmentObject private var appState: AppState
    @State private var contentHeight: CGFloat = 0

    private let maximumHeight: CGFloat
    private let onDismiss: () -> Void

    init(
        maximumHeight: CGFloat = MenuBarHubMetrics.defaultMaximumHeight,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.maximumHeight = maximumHeight
        self.onDismiss = onDismiss
    }

    var body: some View {
        ScrollView(.vertical) {
            menuContent
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MenuBarContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top)
        .frame(
            width: MenuBarHubMetrics.panelWidth,
            height: min(max(contentHeight, 1), maximumHeight)
        )
        .onPreferenceChange(MenuBarContentHeightKey.self) { height in
            guard height > 0 else { return }
            contentHeight = height
        }
    }

    private var menuContent: some View {
        AdaptiveGlassContainer(spacing: 6) {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    if appState.cellularModules.isEmpty {
                        CellularOverviewCard(
                            treatment: .regular,
                            density: .compact
                        )
                    } else {
                        ForEach(appState.cellularModules) { module in
                            CellularOverviewCard(
                                moduleID: module.id,
                                treatment: .regular,
                                density: .compact,
                                onSelectModule: {
                                    transition {
                                        appState.showPhoneWindow(
                                            section: .sim,
                                            simModuleID: module.id
                                        )
                                    }
                                }
                            )
                            .id(module.id)
                        }
                    }
                }

                if appState.isPresentationPrivacyEnabled {
                    Label(L10n.tr("演示隐私保护已开启"), systemImage: "checkmark.shield.fill")
                        .font(.appCaptionStrong)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                        .accessibilityLabel(L10n.tr("演示隐私保护已开启"))
                }

                if let transientMessage = appState.transientMessage {
                    Label {
                        Text(verbatim: transientMessage)
                    } icon: {
                        Image(systemName: appState.transientIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill")
                    }
                    .font(.appCaption)
                    .foregroundStyle(appState.transientIsError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }

                MenuBarCommunicationSections(
                    history: appState.callHistory,
                    onOpenMessage: { message in
                        transition {
                            appState.showMessagesWindow(messageID: message.id)
                        }
                    },
                    onOpenMissedCall: { record in
                        transition {
                            appState.showPhoneWindow(callRecordID: record.id)
                        }
                    }
                )

                Divider()
                    .padding(.vertical, MenuBarHubMetrics.sectionSpacing)

                menuDestinations
            }
        }
        .padding(.horizontal, MenuBarHubMetrics.horizontalInset)
        .padding(.vertical, MenuBarHubMetrics.verticalInset)
        .frame(width: MenuBarHubMetrics.panelWidth)
    }

    private var menuDestinations: some View {
        HStack(spacing: MenuBarHubMetrics.actionSpacing) {
            ForEach(menuDestinationSections) { section in
                destinationButton(section)
            }
            menuActionButton(
                L10n.tr("退出"),
                systemImage: "power",
                action: quitApplication
            )
            .help(L10n.tr("退出 CellDock"))
            .accessibilityLabel(L10n.tr("退出 CellDock"))
        }
    }

    private var menuDestinationSections: [PhoneWindowSection] {
        [.messages, .recents, .recordings, .proxy, .sim, .settings]
    }

    private func destinationButton(_ section: PhoneWindowSection) -> some View {
        menuActionButton(
            section.title,
            systemImage: section.systemImage
        ) {
            transition {
                appState.showPhoneWindow(section: section)
            }
        }
        .help(section.title)
        .accessibilityLabel(section.title)
    }

    private func menuActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.appSymbol(.button, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 31)
                .adaptiveConcentricGlassSurface(
                    minimumCornerRadius: 16,
                    padding: 8,
                    treatment: .regular,
                    isInteractive: true
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(title)
    }

    private func quitApplication() {
        appState.quit()
    }

    private func transition(_ action: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
    }
}

private struct MenuHubAction: View {
    let title: String
    let detail: String
    let systemImage: String
    let attentionCount: Int
    let highlightsDetail: Bool
    let attentionAccessibilityLabel: String?
    let action: () -> Void

    init(
        title: String,
        detail: String,
        systemImage: String,
        attentionCount: Int = 0,
        highlightsDetail: Bool = false,
        attentionAccessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.attentionCount = attentionCount
        self.highlightsDetail = highlightsDetail
        self.attentionAccessibilityLabel = attentionAccessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.appSymbol(.button, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.appBody.weight(.medium))
                    Text(verbatim: detail)
                        .font(.appCaption)
                        .foregroundStyle(highlightsDetail ? Color.red : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if attentionCount > 0 {
                    Text(attentionCount > 99 ? "99+" : "\(attentionCount)")
                        .font(.appCaption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .accessibilityLabel(
                            attentionAccessibilityLabel ?? L10n.tr("%lld 项提醒", Int64(attentionCount))
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .adaptiveConcentricGlassSurface(
            minimumCornerRadius: 22,
            padding: MenuBarHubMetrics.actionPadding,
            treatment: .regular,
            isInteractive: true
        )
        .frame(maxWidth: .infinity)
    }
}

private struct MissedCallMenuHubAction: View {
    @ObservedObject var history: CallHistoryStore

    let defaultDetail: String
    let prefersDefaultDetail: Bool
    let action: () -> Void

    private var missedCount: Int {
        history.unacknowledgedMissedCallCount
    }

    private var showsMissedSummary: Bool {
        missedCount > 0 && !prefersDefaultDetail
    }

    var body: some View {
        MenuHubAction(
            title: L10n.tr("电话"),
            detail: showsMissedSummary ? L10n.tr("%lld 个未接", Int64(missedCount)) : defaultDetail,
            systemImage: "phone.fill",
            attentionCount: missedCount,
            highlightsDetail: showsMissedSummary,
            attentionAccessibilityLabel: L10n.tr("%lld 个未接来电", Int64(missedCount)),
            action: action
        )
    }
}

private enum MenuBarHubMetrics {
    static let panelWidth: CGFloat = 370
    static let defaultMaximumHeight: CGFloat = 720
    static let horizontalInset: CGFloat = 10
    static let verticalInset: CGFloat = 8
    static let sectionSpacing: CGFloat = 8
    static let actionSpacing: CGFloat = 8
    static let actionPadding: CGFloat = 10
}
