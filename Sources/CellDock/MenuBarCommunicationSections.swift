import SwiftUI

struct MenuBarCommunicationSections: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var contacts = SystemContactStore.shared
    @ObservedObject var history: CallHistoryStore

    let onOpenMessage: (SMSMessage) -> Void
    let onOpenMissedCall: (CallHistoryRecord) -> Void

    var body: some View {
        if hasVisibleContent {
            VStack(spacing: 8) {
                Divider()
                    .padding(.vertical, 8)

                ForEach(moduleAlertGroups) { group in
                    moduleAlertCard(group)
                        .transition(.opacity)
                }

                if appState.call.phase == .incoming {
                    CompactCallContent()
                        .adaptiveConcentricGlassSurface(
                            minimumCornerRadius: 22,
                            padding: 10,
                            treatment: .regular,
                            isInteractive: true
                        )
                }
            }
            .animation(.smooth(duration: 0.18), value: animationKeys)
        }
    }

    private var hasVisibleContent: Bool {
        !moduleAlertGroups.isEmpty || appState.call.phase == .incoming
    }

    private func moduleAlertCard(_ group: MenuBarModuleAlertGroup) -> some View {
        VStack(spacing: 0) {
            moduleHeader(group)

            if !group.unreadConversations.isEmpty {
                Divider().padding(.vertical, 8)
                unreadMessagesSection(group)
            }

            if !group.missedCalls.isEmpty {
                Divider().padding(.vertical, 8)
                missedCallsSection(group)
            }
        }
        .adaptiveConcentricGlassSurface(
            minimumCornerRadius: 22,
            padding: 10,
            treatment: .regular,
            isInteractive: true
        )
    }

    private func moduleHeader(_ group: MenuBarModuleAlertGroup) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "simcard.fill")
                .font(.appSymbol(.small, weight: .semibold))
                .foregroundStyle(group.isConnected ? Color.green : Color.secondary)
                .frame(width: 25, height: 25)
                .background(
                    (group.isConnected ? Color.green : Color.secondary).opacity(0.10),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: group.title)
                    .font(.appCaption.weight(.semibold))
                    .lineLimit(1)
                if let detail = group.detail {
                    Text(verbatim: detail)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if group.totalAttentionCount > 0 {
                Text(group.totalAttentionCount > 99 ? "99+" : "\(group.totalAttentionCount)")
                    .font(.appCaption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .accessibilityLabel(L10n.tr("%lld 项提醒", Int64(group.totalAttentionCount)))
            }
        }
    }

    private func unreadMessagesSection(_ group: MenuBarModuleAlertGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Label(L10n.tr("未读短信"), systemImage: "message.fill")
                    .font(.appCaption.weight(.semibold))

                Text(group.unreadMessageCount > 99 ? "99+" : "\(group.unreadMessageCount)")
                    .font(.appCaption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())

                Spacer()

                Button(L10n.tr("全部已读")) {
                    appState.markRead(group.unreadConversations.flatMap { conversation in
                        conversation.messages.filter { !$0.isOutgoing && !$0.isRead }
                    })
                }
                .buttonStyle(.plain)
                .font(.appCaption)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            ForEach(group.unreadConversations) { conversation in
                unreadConversationRow(conversation)

                if conversation.id != group.unreadConversations.last?.id {
                    Divider().padding(.leading, 35)
                }
            }
        }
    }

    @ViewBuilder
    private func unreadConversationRow(_ conversation: MessageConversation) -> some View {
        if let message = latestUnreadMessage(in: conversation) {
            Button {
                appState.markRead(
                    conversation.messages.filter { !$0.isOutgoing && !$0.isRead }
                )
                onOpenMessage(message)
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    directionIcon(
                        systemName: "arrow.down.left",
                        tint: .accentColor
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)

                            Text(verbatim: displayName(for: conversation.address))
                                .font(.appCaption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 6)

                            Text(message.timestamp, style: .relative)
                                .font(.appCaption)
                                .foregroundStyle(.tertiary)
                        }

                        Text(verbatim: appState.privacyPresentation.messagePreview(message.preview))
                            .font(.appCaption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr(
                "%lld 条未读短信，来自%@，%@",
                Int64(conversation.unreadCount),
                displayName(for: conversation.address),
                appState.privacyPresentation.messagePreview(message.preview)
            ))
        }
    }

    private func missedCallsSection(_ group: MenuBarModuleAlertGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Label(L10n.tr("未接来电"), systemImage: "phone.down.fill")
                    .font(.appCaption.weight(.semibold))

                Text(group.missedCalls.count > 99 ? "99+" : "\(group.missedCalls.count)")
                    .font(.appCaption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: Capsule())

                Spacer()
            }
            .padding(.bottom, 4)

            ForEach(group.missedCalls) { record in
                missedCallRow(record)

                if record.id != group.missedCalls.last?.id {
                    Divider().padding(.leading, 35)
                }
            }
        }
    }

    private func missedCallRow(_ record: CallHistoryRecord) -> some View {
        Button {
            onOpenMissedCall(record)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                directionIcon(
                    systemName: "phone.arrow.down.left.fill",
                    tint: .red
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)

                        Text(verbatim: displayName(for: record.number))
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        Text(record.startedAt, style: .relative)
                            .font(.appCaption)
                            .foregroundStyle(.tertiary)
                    }

                    Text(L10n.tr("未接来电"))
                        .font(.appCaption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr(
            "未接来电，来自%@，%@",
            displayName(for: record.number),
            record.startedAt.formatted(date: .abbreviated, time: .shortened)
        ))
    }

    private func directionIcon(systemName: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 26, height: 26)

            Image(systemName: systemName)
                .font(.appSymbol(.indicator, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private var moduleAlertGroups: [MenuBarModuleAlertGroup] {
        let conversations = MessageConversation.grouped(from: appState.messages)
            .filter(\.hasUnread)
        let missedCalls = history.records.filter(\.isUnacknowledgedMissed)
        let fallbackID = appState.currentCommunicationModuleID ?? appState.cellularModules.first?.id
        let knownIDs = Set(appState.cellularModules.map(\.id))
        var groups: [MenuBarModuleAlertGroup] = appState.cellularModules.compactMap { module -> MenuBarModuleAlertGroup? in
            let moduleConversations = conversations.filter {
                ($0.moduleID ?? fallbackID) == module.id
            }
            let moduleMissedCalls = missedCalls.filter {
                ($0.moduleID ?? fallbackID) == module.id
            }
            let hasAttention = !moduleConversations.isEmpty || !moduleMissedCalls.isEmpty
            guard hasAttention else { return nil }
            return MenuBarModuleAlertGroup(
                id: module.id.rawValue,
                title: module.displayName,
                detail: moduleDetail(module),
                isConnected: module.modem.isConnected,
                unreadConversations: moduleConversations,
                missedCalls: moduleMissedCalls
            )
        }

        let orphanConversations = conversations.filter {
            guard let id = $0.moduleID ?? fallbackID else { return true }
            return !knownIDs.contains(id)
        }
        let orphanMissedCalls = missedCalls.filter {
            guard let id = $0.moduleID ?? fallbackID else { return true }
            return !knownIDs.contains(id)
        }
        if !orphanConversations.isEmpty || !orphanMissedCalls.isEmpty {
            groups.append(MenuBarModuleAlertGroup(
                id: "unavailable-module",
                title: L10n.tr("未连接模组"),
                detail: nil,
                isConnected: false,
                unreadConversations: orphanConversations,
                missedCalls: orphanMissedCalls
            ))
        }
        return groups
    }

    private func moduleDetail(_ module: CellularModuleSummary) -> String {
        var parts: [String] = [module.statusText]
        if module.modem.simReady {
            parts.append(module.carrierName)
        }
        if let technology = module.technologyName {
            parts.append(technology)
        }
        if let signal = module.modem.signalDBm {
            parts.append("\(signal) dBm")
        }
        return parts.joined(separator: " · ")
    }

    private var animationKeys: [String] {
        moduleAlertGroups.map { group in
            "\(group.id):\(group.unreadMessageCount):\(group.missedCalls.count)"
        }
    }

    private func latestUnreadMessage(in conversation: MessageConversation) -> SMSMessage? {
        conversation.messages.last { !$0.isOutgoing && !$0.isRead }
    }

    private func displayName(for number: String) -> String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: number),
            number: number
        )
    }
}

private struct MenuBarModuleAlertGroup: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let isConnected: Bool
    let unreadConversations: [MessageConversation]
    let missedCalls: [CallHistoryRecord]

    var unreadMessageCount: Int {
        unreadConversations.reduce(0) { $0 + $1.unreadCount }
    }

    var totalAttentionCount: Int {
        unreadMessageCount + missedCalls.count
    }
}
