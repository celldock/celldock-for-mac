import AppKit
import SwiftUI

struct PhoneWindowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @ObservedObject var messagesModel: MessagesWindowModel
    @ObservedObject var contacts: SystemContactStore
    @AppStorage("CommunicationSidebarWidth.v1") private var storedSidebarWidth = Double(CommunicationUI.sidebarWidth)

    var body: some View {
        HStack(spacing: 0) {
            CommunicationRailView(model: model)

            Group {
                if appState.call.hasCall && model.prefersFullCallPresentation {
                    ActiveCallView(contacts: contacts)
                        .environmentObject(appState)
                } else {
                    sectionContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            if contacts.authorizationState == .notDetermined {
                contacts.requestAccess()
            } else {
                contacts.reload()
            }
            acknowledgeMissedCallsIfNeeded()
            CommunicationWindowController.shared.refreshCommunicationWindowTitle()
        }
        .onChange(of: model.selection) { _, _ in
            acknowledgeMissedCallsIfNeeded()
            CommunicationWindowController.shared.refreshCommunicationWindowTitle()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            contacts.reload()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.selection {
        case .messages:
            MessagesWindowView(
                model: messagesModel,
                contacts: contacts,
                sidebarWidth: sidebarWidthBinding,
                focusFirstItemRequest: model.pendingListFocusSection == .messages,
                didHandleFocusFirstItemRequest: {
                    model.consumeListFocusRequest(for: .messages)
                }
            )
                .environmentObject(appState)
        case .dialer:
            DialerView(model: model, contacts: contacts)
                .environmentObject(appState)
        case .recents:
            ResizableCommunicationSplit(sidebarWidth: sidebarWidthBinding) {
                RecentCallsView(
                    model: model,
                    history: appState.callHistory,
                    recordings: appState.callRecordings,
                    contacts: contacts,
                    selectedRecordID: $model.selectedCallRecordID,
                    focusFirstItemRequest: model.pendingListFocusSection == .recents,
                    didHandleFocusFirstItemRequest: {
                        model.consumeListFocusRequest(for: .recents)
                    }
                )
                    .environmentObject(appState)
                    .communicationSidebarColumnStyle()
                    .communicationModuleFloatingSidebar()
            } detail: {
                RecentCallDetailView(
                    model: model,
                    history: appState.callHistory,
                    recordings: appState.callRecordings,
                    contacts: contacts,
                    selectedRecordID: model.selectedCallRecordID
                )
                    .environmentObject(appState)
                    .communicationDetailColumnStyle()
            }
        case .contacts:
            ContactsManagementView(contacts: contacts) { number in
                model.present(number: number, section: .dialer)
            }
            .environmentObject(appState)
        case .recordings:
            RecordingsLibraryView(
                recordings: appState.callRecordings,
                contacts: contacts,
                selectedRecordingID: $model.selectedRecordingID,
                sidebarWidth: sidebarWidthBinding,
                focusFirstItemRequest: model.pendingListFocusSection == .recordings,
                didHandleFocusFirstItemRequest: {
                    model.consumeListFocusRequest(for: .recordings)
                }
            )
        case .proxy:
            NetworkToolsView(
                proxyController: appState.socksProxyController,
                voWiFiController: appState.voWiFiController,
                sidebarWidth: sidebarWidthBinding
            )
            .environmentObject(appState)
        case .sim:
            SIMManagementView(
                sidebarWidth: sidebarWidthBinding,
                requestedModuleID: model.requestedSIMModuleID,
                moduleRequestSerial: model.simModuleRequestSerial,
                focusFirstItemRequest: model.pendingListFocusSection == .sim,
                didHandleFocusFirstItemRequest: {
                    model.consumeListFocusRequest(for: .sim)
                }
            )
                .environmentObject(appState)
        case .settings:
            CellDockSettingsView(
                sidebarWidth: sidebarWidthBinding,
                focusFirstItemRequest: model.pendingListFocusSection == .settings,
                didHandleFocusFirstItemRequest: {
                    model.consumeListFocusRequest(for: .settings)
                }
            )
                .environmentObject(appState)
        }
    }

    private var sidebarWidthBinding: Binding<CGFloat> {
        Binding(
            get: {
                min(
                    CommunicationUI.sidebarMaximumWidth,
                    max(CommunicationUI.sidebarMinimumWidth, CGFloat(storedSidebarWidth))
                )
            },
            set: { storedSidebarWidth = Double($0) }
        )
    }

    private func acknowledgeMissedCallsIfNeeded() {
        guard model.selection == .recents else { return }
        appState.callHistory.acknowledgeMissedCalls()
    }
}

struct CommunicationModuleStatusMenu: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPopoverPresented = false
    @State private var showsOfflineLines = false
    @State private var renamingLine: CommunicationLine?
    @State private var renameText = ""
    @State private var removingLine: CommunicationLine?

    let openSIMManagement: () -> Void

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                CommunicationModuleSignalBars(
                    bars: isViewingOffline ? 0 : (selectedModule?.modem.signalBars ?? 0),
                    hasSignal: !isViewingOffline && selectedModuleHasSignal,
                    tint: selectedModuleHasSignal ? .green : .secondary,
                    barWidth: 2.5,
                    spacing: 1.5
                )
                .frame(width: 14, height: 18)
                .accessibilityHidden(true)

                Text(pickerTitle)
                    .foregroundStyle(isViewingOffline ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if hasAttentionElsewhere {
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
            .frame(width: 210, height: 36)
            .contentShape(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .adaptiveGlassSurface(
            cornerRadius: 15,
            treatment: .regular,
            isInteractive: true
        )
        .popover(
            isPresented: $isPopoverPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            popoverContent
        }
        .onChange(of: isPopoverPresented) { _, presented in
            guard presented else { return }
            // History may name modules this Mac has not catalogued yet.
            appState.refreshModuleAppearanceRegistry()
            showsOfflineLines = isViewingOffline
        }
        // Both dialogs belong to the window, not the popover: the popover
        // closes as soon as a dialog takes focus and would take them with it.
        .alert(
            L10n.tr("重命名线路"),
            isPresented: Binding(
                get: { renamingLine != nil },
                set: { if !$0 { renamingLine = nil } }
            )
        ) {
            TextField(L10n.tr("线路名称"), text: $renameText)
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("保存")) {
                if let renamingLine {
                    appState.renameLine(renamingLine, to: renameText)
                }
            }
        } message: {
            Text(L10n.tr("留空将恢复默认名称。"))
        }
        .confirmationDialog(
            L10n.tr(
                "移除“%@”的记录？",
                removingLine.map { appState.lineAppearanceResolver.appearance(for: $0).title } ?? ""
            ),
            isPresented: Binding(
                get: { removingLine != nil },
                set: { if !$0 { removingLine = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("移除记录"), role: .destructive) {
                if let removingLine {
                    appState.removeRecords(ofOfflineLine: removingLine)
                }
            }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(L10n.tr(
                "将删除这条线路的 %lld 条短信和 %lld 条通话记录，无法恢复。通话录音不会被删除。",
                Int64(removingLine.map { line in
                    appState.messages.filter { $0.line == line }.count
                } ?? 0),
                Int64(removingLine.map { line in
                    appState.callHistory.records.filter { $0.line == line }.count
                } ?? 0)
            ))
        }
        .help(statusDescription)
        .accessibilityLabel(L10n.tr("蜂窝设备：%@", statusDescription))
        .accessibilityValue(isPopoverPresented ? L10n.tr("已展开") : L10n.tr("已收起"))
        .accessibilityHint(L10n.tr("显示并选择当前通信模组"))
    }

    private var popoverContent: some View {
        let scope = appState.lineScope
        let offline = offlineLines
        let showsTabs = appState.cellularModules.count > 1 || !offline.isEmpty

        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                if showsTabs {
                    CommunicationGlassTabs(
                        items: [(false, "在线"), (true, "离线")],
                        selection: $showsOfflineLines
                    )
                } else {
                    Text(L10n.tr("当前模组"))
                        .font(.appCalloutStrong)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                }

                Button {
                    isPopoverPresented = false
                    openSIMManagement()
                } label: {
                    Image(systemName: "simcard")
                        .font(.appSymbol(.small))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .adaptiveGlassSurface(cornerRadius: 9, treatment: .clear, isInteractive: true)
                .help(L10n.tr("管理 SIM 卡"))
                .accessibilityLabel(L10n.tr("管理 SIM 卡"))
            }

            if showsTabs && showsOfflineLines {
                offlineList(offline, scope: scope)
            } else {
                onlineList(scope: scope)
            }
        }
        .padding(8)
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func onlineList(scope: LineScope) -> some View {
        if appState.cellularModules.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.appSymbol(.rail, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("没有可用模组"))
                    .font(.appCalloutStrong)
                Text(L10n.tr("连接设备后将自动显示在这里"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(appState.cellularModules) { module in
                        moduleSelectionRow(module, scope: scope)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    @ViewBuilder
    private func offlineList(_ lines: [CommunicationLine], scope: LineScope) -> some View {
        if lines.isEmpty {
            Text(L10n.tr("没有离线线路的记录"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(lines, id: \.self) { line in
                        offlineLineRow(line, scope: scope)
                    }
                }
            }
            .frame(maxHeight: 280)

            Text(L10n.tr("离线线路只能查看已有的短信和通话记录。"))
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
    }

    private func lineRow(
        appearance: LineAppearance,
        title: String,
        detail: String,
        secondDetail: String? = nil,
        attention: Int,
        isSelected: Bool,
        trailingStatus: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
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

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.appSymbol(.inline, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if let trailingStatus {
                    Text(verbatim: trailingStatus)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
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

    private func moduleSelectionRow(_ module: CellularModuleSummary, scope: LineScope) -> some View {
        let resolver = scope.resolver
        let line = resolver.currentLine(of: module)
        let rowScope = LineScope(resolver: resolver, line: line, isOnline: true)
        return lineRow(
            appearance: resolver.appearance(for: line),
            title: "\(module.displayName) · \(module.carrierName)",
            detail: moduleSelectionDetail(module),
            attention: appState.attentionCount(in: rowScope),
            isSelected: scope.isOnline && scope.line == line,
            trailingStatus: module.isCommunicationEligible ? nil : module.statusText
        ) {
            guard module.isCommunicationEligible else { return }
            appState.selectCommunicationModule(module.id)
            isPopoverPresented = false
        }
        .disabled(!module.isCommunicationEligible)
        .accessibilityLabel(module.accessibilitySummary)
    }

    private func offlineLineRow(_ line: CommunicationLine, scope: LineScope) -> some View {
        let appearance = scope.resolver.appearance(for: line)
        let rowScope = LineScope(resolver: scope.resolver, line: line, isOnline: false)
        let status = appearance.isAttached ? L10n.tr("卡槽未启用") : L10n.tr("模组已拔出")
        return lineRow(
            appearance: appearance,
            title: appearance.title,
            detail: [status, appearance.carrier, appearance.identityDetail]
                .compactMap { $0 }
                .joined(separator: " · "),
            secondDetail: usageSummary(of: line),
            attention: appState.attentionCount(in: rowScope),
            isSelected: !scope.isOnline && scope.line == line
        ) {
            appState.viewOfflineLine(line)
            isPopoverPresented = false
        }
        .contextMenu {
            Button(L10n.tr("重命名…"), systemImage: "pencil") {
                beginRename(line)
            }
            Divider()
            Button(L10n.tr("移除…"), systemImage: "trash", role: .destructive) {
                beginRemoval(line)
            }
        }
        .accessibilityLabel(appearance.title)
    }

    /// What an offline line was used for, so lines that share a default name
    /// can still be told apart: who it last reached, when, and how much.
    private func usageSummary(of line: CommunicationLine) -> String? {
        let messages = appState.messages.filter { $0.line == line }
        let calls = appState.callHistory.records.filter { $0.line == line }
        let latestMessage = messages.max { $0.timestamp < $1.timestamp }
        let latestCall = calls.max { $0.startedAt < $1.startedAt }
        var latest: (date: Date, address: String)?
        if let latestMessage {
            latest = (latestMessage.timestamp, latestMessage.peerAddress)
        }
        if let latestCall, latestCall.startedAt > (latest?.date ?? .distantPast) {
            latest = (latestCall.startedAt, latestCall.number)
        }
        var parts: [String] = []
        if let latest {
            let name = appState.privacyPresentation.identity(
                contactName: SystemContactStore.shared.displayName(for: latest.address),
                number: latest.address
            )
            parts.append(L10n.tr("最近：%@", name))
            parts.append(CommunicationUI.listTimestamp(latest.date))
        }
        if !messages.isEmpty {
            parts.append(L10n.tr("%lld 条短信", Int64(messages.count)))
        }
        if !calls.isEmpty {
            parts.append(L10n.tr("%lld 通电话", Int64(calls.count)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func beginRename(_ line: CommunicationLine) {
        renameText = appState.moduleAppearanceRegistry.slotInfo(for: line)?.customName ?? ""
        isPopoverPresented = false
        DispatchQueue.main.async { renamingLine = line }
    }

    private func beginRemoval(_ line: CommunicationLine) {
        isPopoverPresented = false
        DispatchQueue.main.async { removingLine = line }
    }

    private var offlineLines: [CommunicationLine] {
        appState.lineAppearanceResolver.offlineLines(among: appState.recordedLines)
    }

    private var isViewingOffline: Bool {
        let scope = appState.lineScope
        return !scope.isOnline && scope.line != nil
    }

    /// True when a line other than the one on screen has unread messages or
    /// missed calls, so nothing arrives unnoticed.
    private var hasAttentionElsewhere: Bool {
        let scope = appState.lineScope
        let total = appState.messages.lazy.filter { !$0.isOutgoing && !$0.isRead }.count +
            appState.callHistory.records.lazy.filter(\.isUnacknowledgedMissed).count
        return total > appState.attentionCount(in: scope)
    }

    private var pickerTitle: String {
        if isViewingOffline {
            return L10n.tr("%@ · 离线，仅查看", appState.lineScope.appearance.title)
        }
        return appState.currentCommunicationModule?.selectorTitle ??
            (appState.cellularModules.isEmpty ? L10n.tr("没有可用模组") : L10n.tr("选择通信模组"))
    }

    private var selectedModule: CellularModuleSummary? {
        appState.currentCommunicationModule
    }

    private var selectedModuleHasSignal: Bool {
        guard let selectedModule else { return false }
        return moduleHasSignal(selectedModule)
    }

    private var statusDescription: String {
        appState.currentCommunicationModule?.accessibilitySummary ?? pickerTitle
    }

    private func moduleHasSignal(_ module: CellularModuleSummary) -> Bool {
        module.modem.isConnected && module.modem.signalDBm != nil
    }

    private func moduleSelectionDetail(_ module: CellularModuleSummary) -> String {
        var parts: [String] = []
        if let technology = module.technologyName { parts.append(technology) }
        if let signal = module.modem.signalDBm { parts.append("\(signal) dBm") }
        if let suffix = module.simSuffix { parts.append(L10n.tr("尾号 %@", suffix)) }
        if parts.isEmpty { parts.append(module.statusText) }
        return parts.joined(separator: " · ")
    }
}

private struct CommunicationModuleSignalBars: View {
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

private struct CommunicationRailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(spacing: 12) {
            railButton(.messages, icon: .messages)
            railButton(.recents, icon: .recents)
            railButton(.recordings, icon: .recordings)
            railButton(.proxy, icon: .proxy)
            Spacer()
            if appState.isPresentationPrivacyEnabled {
                Image(systemName: "checkmark.shield.fill")
                    .font(.appSymbol(.button, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 28)
                    .help(L10n.tr("演示隐私保护已开启"))
                    .accessibilityLabel(L10n.tr("演示隐私保护已开启"))
            }
            railButton(.sim, icon: .sim)
            railButton(.settings, icon: .settings)
        }
        .padding(.horizontal, 10)
        .padding(.top, 46)
        .padding(.bottom, 18)
        .frame(width: CommunicationUI.railWidth)
        .frame(maxHeight: .infinity)
        .communicationSidebarMaterial()
    }

    private func railButton(
        _ section: PhoneWindowSection,
        icon: CommunicationRailIconKind
    ) -> some View {
        let isSelected = normalizedSelection == section
        return AnimatedCommunicationRailButton(
            section: section,
            icon: icon,
            isSelected: isSelected,
            selectionNamespace: selectionNamespace,
            selectionGroup: selectionGroup(for: section)
        ) {
            withAnimation(.smooth(duration: 0.28)) {
                model.activateFromRail(section)
            }
        }
    }

    private func selectionGroup(for section: PhoneWindowSection) -> String {
        switch section {
        case .messages, .recents, .recordings, .proxy:
            return "primary"
        case .sim, .settings:
            return "secondary"
        case .dialer, .contacts:
            return "primary"
        }
    }

    private var normalizedSelection: PhoneWindowSection {
        switch model.selection {
        case .dialer, .contacts: return .recents
        default: return model.selection
        }
    }
}

private struct RecentCallsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @ObservedObject var history: CallHistoryStore
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore
    @Binding var selectedRecordID: CallHistoryRecord.ID?
    var focusFirstItemRequest = false
    var didHandleFocusFirstItemRequest: () -> Void = {}
    @State private var missedOnly = false
    @State private var searchText = ""
    @State private var deletingAll = false
    @FocusState private var listFocused: Bool

    var body: some View {
        let resolver = appState.lineAppearanceResolver
        let visible = filteredRecords

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索联系人或号码", text: $searchText)
                    .font(.appCallout)
                    .communicationSearchField()

                CommunicationIconActionButton(
                    systemImage: "phone",
                    accessibilityLabel: L10n.tr("拨打新号码"),
                    tint: .green
                ) {
                    guard !appState.blocksActionWhileViewingOfflineLine() else { return }
                    model.dialNumber = ""
                    model.activateFromRail(.dialer)
                }
            }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            CommunicationGlassTabs(
                items: [(false, "全部"), (true, "未接来电")],
                selection: $missedOnly
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            if visible.isEmpty {
                PhoneEmptyState(
                    title: missedOnly ? "没有未接来电" : "暂无最近通话",
                    detail: "完成或错过的蜂窝电话会保存在此 Mac。",
                    systemImage: missedOnly ? "phone.badge.checkmark" : "clock.arrow.circlepath"
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(visible) { record in
                            CallRowContent(
                                title: presentedIdentity(record),
                                address: record.number,
                                status: RecentCallText.status(record),
                                isMissed: record.isMissed,
                                direction: record.direction,
                                timestamp: CommunicationUI.listTimestamp(record.startedAt),
                                hasRecording: matchingRecording(for: record) != nil,
                                line: resolver.appearance(for: record.line)
                            )
                            .contentShape(Rectangle())
                            .communicationSelectionHighlight(selectedRecordID == record.id)
                            .onTapGesture { selectedRecordID = record.id }
                            .accessibilityAddTraits(selectedRecordID == record.id ? .isSelected : [])
                            .tag(record.id)
                            .contextMenu {
                                Button("回拨", systemImage: "phone") {
                                    call(record, resolver: resolver)
                                }
                                Button("发短信", systemImage: "message") {
                                    appState.showMessagesWindow(destination: record.number)
                                }
                                Divider()
                                Button("删除记录", systemImage: "trash", role: .destructive) {
                                    history.delete(record)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .communicationEmphasizedSelection()
                    .communicationInitialListFocus($listFocused)
                    .scrollContentBackground(.hidden)
                    .communicationSidebarScrollEdgeEffect()
                    .onAppear {
                        selectRequestedCall(using: proxy)
                    }
                    .onChange(of: model.callRecordRequestSerial) { _, _ in
                        selectRequestedCall(using: proxy)
                    }
                }
            }
        }
        .onAppear {
            selectRequestedCall()
            selectInitialRecordIfNeeded()
            handleFocusFirstItemRequest()
        }
        .onChange(of: focusFirstItemRequest) { _, requested in
            if requested { handleFocusFirstItemRequest() }
        }
        .onChange(of: missedOnly) { _, _ in ensureSelectionIsVisible() }
        .onChange(of: searchText) { _, _ in ensureSelectionIsVisible() }
        .onChange(of: appState.lineScope.line) { _, _ in ensureSelectionIsVisible() }
        .onChange(of: history.records) { _, _ in ensureSelectionIsVisible() }
        .confirmationDialog(
            "清除所有最近通话？",
            isPresented: $deletingAll,
            titleVisibility: .visible
        ) {
            Button("全部清除", role: .destructive) { history.deleteAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("通话录音不会被删除。")
        }
    }

    /// The calls of the line picked in the module selector.
    private var filteredRecords: [CallHistoryRecord] {
        let scope = appState.lineScope
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return history.records.filter { record in
            guard scope.contains(record.line) else { return false }
            if missedOnly, !record.isMissed { return false }
            guard !query.isEmpty else { return true }
            return record.number.localizedCaseInsensitiveContains(query) ||
                (contacts.displayName(for: record.number) ?? "")
                    .localizedCaseInsensitiveContains(query)
        }
    }

    private func selectInitialRecordIfNeeded() {
        guard selectedRecordID == nil else { return }
        if !model.dialNumber.isEmpty,
           let matchingRecord = filteredRecords.first(where: { $0.number == model.dialNumber }) {
            selectedRecordID = matchingRecord.id
        } else if let firstRecord = filteredRecords.first {
            selectedRecordID = firstRecord.id
        }
    }

    private func selectRequestedCall(using proxy: ScrollViewProxy? = nil) {
        guard let recordID = model.requestedCallRecordID,
              history.records.contains(where: { $0.id == recordID }) else {
            return
        }
        searchText = ""
        missedOnly = true
        selectedRecordID = recordID
        guard let proxy else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(recordID, anchor: .center)
            }
        }
    }

    private func ensureSelectionIsVisible() {
        let visible = filteredRecords
        if let selectedRecordID,
           visible.contains(where: { $0.id == selectedRecordID }) {
            return
        }
        selectedRecordID = visible.first?.id
    }

    private func handleFocusFirstItemRequest() {
        guard focusFirstItemRequest else { return }
        selectedRecordID = filteredRecords.first?.id
        didHandleFocusFirstItemRequest()
        listFocused = false
        DispatchQueue.main.async {
            listFocused = true
        }
    }

    private func matchingRecording(
        for record: CallHistoryRecord
    ) -> CallRecordingRecord? {
        guard let recordingID = record.recordingID else { return nil }
        return recordings.records.first { $0.id == recordingID }
    }

    /// A callback goes out on the line picked in the module selector.
    private func call(_ record: CallHistoryRecord, resolver: LineAppearanceResolver) {
        guard !appState.blocksActionWhileViewingOfflineLine(),
              let moduleID = appState.lineScope.moduleID,
              appState.moduleCanDial(moduleID),
              !appState.isChangingCall,
              CallATParser.normalizedDialNumber(record.number) != nil else { return }
        model.dialNumber = record.number
        appState.dial(record.number, via: moduleID)
    }

    private func presentedIdentity(_ record: CallHistoryRecord) -> String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: record.number),
            number: record.number
        )
    }
}

/// Texts shared by the Recents list and its detail pane.
enum RecentCallText {
    /// "呼入 · 2:35" for an answered call, the reason it ended otherwise.
    static func status(_ record: CallHistoryRecord) -> String {
        if record.isMissed { return L10n.tr("未接来电") }
        let direction = record.direction == .incoming ? L10n.tr("呼入") : L10n.tr("呼出")
        if record.duration > 0 {
            return "\(direction) · \(duration(record.duration))"
        }
        guard let reason = record.endReason else { return direction }
        return "\(direction) · \(reason.localizedDescription)"
    }

    static func duration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        if total >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3_600,
                (total / 60) % 60,
                total % 60
            )
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RecentCallDetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @ObservedObject var history: CallHistoryStore
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore
    let selectedRecordID: CallHistoryRecord.ID?

    private static let historyLimit = 50

    var body: some View {
        Group {
            if let record = selectedRecord {
                let resolver = appState.lineAppearanceResolver
                ScrollView {
                    AdaptiveGlassContainer(spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) {
                            identityHeader(record, line: resolver.appearance(for: record.line))
                            actionBar(record, resolver: resolver)

                            DetailSectionCaption(title: L10n.tr("本次通话"))
                                .padding(.top, 8)
                            callCard(record, line: resolver.appearance(for: record.line))

                            let related = relatedRecords(to: record)
                            if related.count > 1 {
                                DetailSectionCaption(title: L10n.tr(
                                    "与此号码的全部通话（%lld 次）",
                                    Int64(related.count)
                                ))
                                .padding(.top, 8)
                                historyCard(related, selected: record, resolver: resolver)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 560, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollContentBackground(.hidden)
            } else {
                PhoneEmptyState(
                    title: "选择一条通话记录",
                    detail: "选择左侧最近通话，查看联系人、通话信息和可用操作。",
                    systemImage: "phone.badge.clock"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func identityHeader(
        _ record: CallHistoryRecord,
        line: LineAppearance
    ) -> some View {
        HStack(spacing: 18) {
            ContactFaceAvatar(
                address: record.number,
                size: AppMetrics.Avatar.hero
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(record))
                    .font(.appTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(appState.privacyPresentation.phoneNumber(record.number))
                    .font(.appBody)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.tr("%@，%@", directionLabel(record), displayName(record)))
    }

    private func actionBar(
        _ record: CallHistoryRecord,
        resolver: LineAppearanceResolver
    ) -> some View {
        let scope = appState.lineScope
        let line = scope.appearance

        return HStack(spacing: 8) {
            Button {
                call(record)
            } label: {
                Label {
                    Text(verbatim: scope.isOnline
                        ? L10n.tr("用 %@ 回拨", line.title)
                        : L10n.tr("回拨"))
                } icon: {
                    Image(systemName: "phone.fill")
                }
                .font(.appBody.weight(.medium))
            }
            .adaptiveGlassButton(.prominent)
            .tint(scope.isOnline ? line.tint.solid : Color.secondary)
            .disabled(scope.isOnline && !canDial(record))
            .help(line.fullTitle)

            Button {
                guard !appState.blocksActionWhileViewingOfflineLine() else { return }
                appState.showMessagesWindow(destination: record.number)
            } label: {
                Label("发信息", systemImage: "message")
                    .font(.appBody.weight(.medium))
            }
            .adaptiveGlassButton()

            if let recording = matchingRecording(record) {
                Button {
                    model.selectedRecordingID = recording.id
                    model.activateFromRail(.recordings)
                } label: {
                    Label("查看录音", systemImage: "waveform")
                        .font(.appBody.weight(.medium))
                }
                .adaptiveGlassButton()
            }

            Spacer(minLength: 0)
        }
    }

    private func callCard(
        _ record: CallHistoryRecord,
        line: LineAppearance
    ) -> some View {
        VStack(spacing: 0) {
            DetailFieldRow(title: L10n.tr("类型")) {
                Text(directionLabel(record))
                    .foregroundStyle(record.isMissed ? Color.red : Color.primary)
            }
            Divider()
            DetailFieldRow(title: L10n.tr("通话时间")) {
                Text(Self.detailDateFormatter.string(from: record.startedAt))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            Divider()
            DetailFieldRow(title: L10n.tr("通话时长")) {
                Text(durationText(record))
                    .monospacedDigit()
            }
            Divider()
            DetailFieldRow(title: L10n.tr("线路")) {
                LineFieldValue(appearance: line)
            }
        }
        .padding(.horizontal, 14)
        .adaptiveGlassSurface(
            cornerRadius: AppMetrics.Radius.card,
            padding: 0,
            treatment: .regular
        )
        .accessibilityElement(children: .contain)
    }

    private func historyCard(
        _ related: [CallHistoryRecord],
        selected: CallHistoryRecord,
        resolver: LineAppearanceResolver
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(related.prefix(Self.historyLimit).enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 14) }
                let line = resolver.appearance(for: item.line)
                Button {
                    model.selectedCallRecordID = item.id
                } label: {
                    HStack(spacing: 6) {
                        CallDirectionGlyph(direction: item.direction, isMissed: item.isMissed)
                        Text(verbatim: RecentCallText.status(item))
                            .font(.appBody)
                            .monospacedDigit()
                            .foregroundStyle(item.isMissed ? Color.red : Color.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let badgeText = line.badgeText {
                            LineBadge(text: badgeText, color: line.tint.solid)
                                .help(line.fullTitle)
                        }
                        Text(verbatim: Self.historyDateFormatter.string(from: item.startedAt))
                            .font(.appCaption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 96, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: AppMetrics.Row.single)
                    .contentShape(Rectangle())
                    .background {
                        if item.id == selected.id {
                            Color.accentColor.opacity(0.12)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.id == selected.id ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppMetrics.Radius.card, style: .continuous))
        .adaptiveGlassSurface(
            cornerRadius: AppMetrics.Radius.card,
            padding: 0,
            treatment: .regular
        )
    }

    private var selectedRecord: CallHistoryRecord? {
        guard let selectedRecordID else { return nil }
        return history.records.first { $0.id == selectedRecordID }
    }

    /// Every call with the same number, on any line, newest first.
    private func relatedRecords(to record: CallHistoryRecord) -> [CallHistoryRecord] {
        let key = PhoneNumberNormalizer.conversationID(for: record.number)
        guard !key.isEmpty else { return [record] }
        return history.records
            .filter { PhoneNumberNormalizer.conversationID(for: $0.number) == key }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func matchingRecording(
        _ record: CallHistoryRecord
    ) -> CallRecordingRecord? {
        guard let recordingID = record.recordingID else { return nil }
        return recordings.records.first { $0.id == recordingID }
    }

    private func displayName(_ record: CallHistoryRecord) -> String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: record.number),
            number: record.number,
            fallback: L10n.tr("未知联系人")
        )
    }

    private func directionLabel(_ record: CallHistoryRecord) -> String {
        if record.isMissed { return L10n.tr("未接来电") }
        return record.direction == .incoming
            ? L10n.tr("呼入通话")
            : L10n.tr("呼出通话")
    }

    private func durationText(_ record: CallHistoryRecord) -> String {
        guard record.duration > 0 else { return L10n.tr("未接通") }
        return RecentCallText.duration(record.duration)
    }

    private func canDial(_ record: CallHistoryRecord) -> Bool {
        guard let moduleID = appState.lineScope.moduleID else { return false }
        return appState.moduleCanDial(moduleID) &&
            !appState.isChangingCall &&
            CallATParser.normalizedDialNumber(record.number) != nil
    }

    /// A callback goes out on the line picked in the module selector. On an
    /// offline line it explains why it cannot.
    private func call(_ record: CallHistoryRecord) {
        guard !appState.blocksActionWhileViewingOfflineLine(),
              canDial(record), let moduleID = appState.lineScope.moduleID else { return }
        model.dialNumber = record.number
        appState.dial(record.number, via: moduleID)
    }

    private static var detailDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.storedPreference.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return formatter
    }

    private static var historyDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.storedPreference.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter
    }
}

private struct RecordingsManagementView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore
    @Binding var selectedRecordingID: CallRecordingRecord.ID?
    @Binding var sidebarWidth: CGFloat
    @State private var renameText = ""
    @State private var deletingRecording: CallRecordingRecord?
    @State private var searchText = ""
    @State private var directionFilter = 0

    var body: some View {
        Group {
            if recordings.records.isEmpty {
                PhoneEmptyState(
                    title: "暂无通话录音",
                    detail: "在通话中手动开始录音，结束后会保存在此 Mac。",
                    systemImage: "waveform"
                )
            } else {
                ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
                    recordingList
                } detail: {
                    recordingDetail
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: selectFirstRecordingIfNeeded)
        .onChange(of: recordings.records.map(\.id)) { _, _ in
            selectFirstRecordingIfNeeded()
        }
        .onChange(of: selectedRecordingID) { _, _ in
            renameText = appState.isPresentationPrivacyEnabled
                ? ""
                : (selectedRecording?.title ?? "")
        }
        .onChange(of: appState.isPresentationPrivacyEnabled) { _, enabled in
            if enabled { renameText = "" }
        }
        .confirmationDialog(
            "删除这段通话录音？",
            isPresented: Binding(
                get: { deletingRecording != nil },
                set: { if !$0 { deletingRecording = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除录音", role: .destructive) {
                guard let deletingRecording else { return }
                recordings.delete(deletingRecording)
                self.deletingRecording = nil
            }
            Button("取消", role: .cancel) { deletingRecording = nil }
        } message: {
            Text("音频文件将从这台 Mac 永久删除；最近通话记录仍会保留。")
        }
    }

    private var recordingList: some View {
        VStack(spacing: 0) {
            TextField("搜索录音、联系人或号码", text: $searchText)
                .communicationSearchField()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            CommunicationGlassTabs(
                items: [(0, "全部"), (1, "呼入"), (2, "呼出")],
                selection: $directionFilter
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

        List(filteredRecordingRecords) { record in
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(recordings.playingRecordingID == record.id
                            ? Color.accentColor.opacity(0.14)
                            : Color.secondary.opacity(0.10))
                    Image(systemName: recordings.playingRecordingID == record.id
                        ? "waveform.circle.fill"
                        : "waveform")
                        .foregroundStyle(recordings.playingRecordingID == record.id
                            ? Color.accentColor
                            : Color.secondary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentedRecordingTitle(record))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(CommunicationUI.listTimestamp(record.startedAt))
                            .fixedSize(horizontal: true, vertical: false)
                        Text("·")
                        Text(recordingDuration(record.duration))
                        if record.isIncomplete {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(L10n.tr("录音过程中部分音频未能写入"))
                        }
                    }
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .communicationSelectionHighlight(selectedRecordingID == record.id)
            .contentShape(Rectangle())
            .onTapGesture { selectedRecordingID = record.id }
            .accessibilityAddTraits(selectedRecordingID == record.id ? .isSelected : [])
            .tag(record.id)
            .contextMenu {
                Button("播放或暂停", systemImage: "playpause") { recordings.play(record) }
                Button("导出…", systemImage: "square.and.arrow.up") { recordings.export(record) }
                    .disabled(appState.isPresentationPrivacyEnabled)
                Button("在访达中显示", systemImage: "folder") { recordings.reveal(record) }
                    .disabled(appState.isPresentationPrivacyEnabled)
                Divider()
                Button("删除", systemImage: "trash", role: .destructive) {
                    deletingRecording = record
                }
            }
        }
        .listStyle(.inset)
        }
        .communicationSidebarColumnStyle()
    }

    private var filteredRecordingRecords: [CallRecordingRecord] {
        let directional = recordings.records.filter { record in
            directionFilter == 0 ||
                (directionFilter == 1 && record.direction == .incoming) ||
                (directionFilter == 2 && record.direction == .outgoing)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return directional }
        return directional.filter { record in
            record.number.localizedCaseInsensitiveContains(query) ||
                (record.title ?? "").localizedCaseInsensitiveContains(query) ||
                (contacts.displayName(for: record.number) ?? "")
                    .localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var recordingDetail: some View {
        if let record = selectedRecording {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 18) {
                        ZStack {
                            Circle()
                                .fill(.tint.opacity(0.13))
                            Image(systemName: "waveform")
                                .font(.appSymbol(.hero))
                                .foregroundStyle(.tint)
                        }
                        .frame(width: 76, height: 76)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(presentedRecordingTitle(record))
                                .font(.appTitle)
                            Text(appState.privacyPresentation.phoneNumber(record.number))
                                .font(.appBody.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Label(
                                record.direction == .incoming ? L10n.tr("来电录音") : L10n.tr("去电录音"),
                                systemImage: record.direction == .incoming
                                    ? "phone.arrow.down.left"
                                    : "phone.arrow.up.right"
                            )
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 14) {
                        Button {
                            recordings.play(record)
                        } label: {
                            Label(
                                recordings.playingRecordingID == record.id ? L10n.tr("暂停") : L10n.tr("播放"),
                                systemImage: recordings.playingRecordingID == record.id
                                    ? "pause.fill"
                                    : "play.fill"
                            )
                            .frame(minWidth: 86)
                        }
                        .adaptiveGlassButton(.prominent)

                        Button("回拨", systemImage: "phone") {
                            appState.showPhoneWindow(number: record.number)
                        }
                        .adaptiveGlassButton()

                        Button("发短信", systemImage: "message") {
                            appState.showMessagesWindow(destination: record.number)
                        }
                        .adaptiveGlassButton()
                    }

                    recordingInformation(record)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("名称")
                            .font(.appBodyStrong)
                        HStack {
                            TextField(
                                appState.isPresentationPrivacyEnabled
                                    ? L10n.tr("录音名称已隐藏")
                                    : L10n.tr("可选的录音名称"),
                                text: $renameText
                            )
                            .disabled(appState.isPresentationPrivacyEnabled)
                            Button("保存") {
                                recordings.rename(record, title: renameText)
                            }
                            .disabled(
                                appState.isPresentationPrivacyEnabled ||
                                    renameText.trimmingCharacters(in: .whitespacesAndNewlines) ==
                                    (record.title ?? "")
                            )
                        }
                    }
                    .padding(16)
                    .adaptiveGlassSurface(cornerRadius: 18, treatment: .clear)

                    HStack {
                        Button("导出录音…", systemImage: "square.and.arrow.up") {
                            recordings.export(record)
                        }
                        .disabled(appState.isPresentationPrivacyEnabled)
                        Button("在访达中显示", systemImage: "folder") {
                            recordings.reveal(record)
                        }
                        .disabled(appState.isPresentationPrivacyEnabled)
                        Spacer()
                        Button("删除录音", systemImage: "trash", role: .destructive) {
                            deletingRecording = record
                        }
                    }
                    .buttonStyle(.borderless)

                    if let error = recordings.lastError {
                        Label(L10n.tr(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.appCaption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
            }
        } else {
            PhoneEmptyState(
                title: "选择一段录音",
                detail: "可播放、重命名、导出或删除通话录音。",
                systemImage: "waveform"
            )
        }
    }

    private func recordingInformation(_ record: CallRecordingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("录制时间") {
                Text(record.startedAt, format: .dateTime.year().month().day().hour().minute().second())
            }
            LabeledContent("时长", value: recordingDuration(record.duration))
            LabeledContent("声道", value: L10n.tr("左声道：对方 · 右声道：本机"))
            LabeledContent("存储", value: L10n.tr("仅保存在这台 Mac"))
            if record.isIncomplete {
                Label("部分音频因写入队列过载而缺失，通话本身未受影响。", systemImage: "exclamationmark.triangle.fill")
                    .font(.appCaption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .adaptiveGlassSurface(cornerRadius: 18, treatment: .clear)
    }

    private var selectedRecording: CallRecordingRecord? {
        guard let selectedRecordingID else { return nil }
        return recordings.records.first { $0.id == selectedRecordingID }
    }

    private func selectFirstRecordingIfNeeded() {
        if let selectedRecordingID,
           recordings.records.contains(where: { $0.id == selectedRecordingID }) {
            return
        }
        self.selectedRecordingID = recordings.records.first?.id
    }

    private func contactName(for record: CallRecordingRecord) -> String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: record.number),
            number: record.number
        )
    }

    private func presentedRecordingTitle(_ record: CallRecordingRecord) -> String {
        appState.privacyPresentation.recordingTitle(
            customTitle: record.title,
            contactName: contacts.displayName(for: record.number),
            number: record.number
        )
    }

    private func recordingDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ContactsManagementView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var contacts: SystemContactStore
    let dial: (String) -> Void

    @State private var searchText = ""
    @State private var selectedContactID: SystemContactRecord.ID?
    @State private var selectedGroupID: SystemContactGroup.ID?
    @State private var editingDraft: SystemContactDraft?
    @State private var deletingContact: SystemContactRecord?
    @State private var isCreatingGroup = false
    @State private var newGroupName = ""

    var body: some View {
        Group {
            switch contacts.authorizationState {
            case .authorized:
                authorizedContent
            case .notDetermined:
                permissionView(
                    title: "允许访问系统通讯录",
                    detail: "CellDock 使用联系人姓名匹配来电和短信，并允许在电话窗口中新增、编辑和删除系统联系人。",
                    actionTitle: "继续",
                    action: contacts.requestAccess
                )
            case .denied, .restricted:
                permissionView(
                    title: "通讯录访问已关闭",
                    detail: "仍可手动输入号码。若要浏览或管理系统联系人，请在系统设置中允许 CellDock 访问通讯录。",
                    actionTitle: "打开系统设置",
                    action: contacts.openPrivacySettings
                )
            }
        }
        .searchable(text: $searchText, prompt: "搜索姓名、号码或公司")
        .sheet(
            isPresented: Binding(
                get: { editingDraft != nil },
                set: { if !$0 { editingDraft = nil } }
            )
        ) {
            if let editingDraft {
                ContactEditorView(
                    initialDraft: editingDraft,
                    contacts: contacts
                ) {
                    self.editingDraft = nil
                }
            }
        }
        .confirmationDialog(
            "删除联系人？",
            isPresented: Binding(
                get: { deletingContact != nil },
                set: { if !$0 { deletingContact = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除联系人", role: .destructive) {
                guard let contact = deletingContact else { return }
                contacts.delete(contact) { _ in
                    if selectedContactID == contact.id { selectedContactID = nil }
                    deletingContact = nil
                }
            }
            Button("取消", role: .cancel) { deletingContact = nil }
        } message: {
            Text("只会从 macOS 系统通讯录删除联系人；已有短信、通话记录和录音会保留号码。")
        }
        .alert("新建分组", isPresented: $isCreatingGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") {
                contacts.createGroup(named: newGroupName) { _ in newGroupName = "" }
            }
        }
        .onChange(of: appState.isPresentationPrivacyEnabled) { _, enabled in
            if enabled {
                editingDraft = nil
                isCreatingGroup = false
            }
        }
    }

    private var authorizedContent: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("分组", selection: $selectedGroupID) {
                    Text("所有联系人").tag(SystemContactGroup.ID?.none)
                    ForEach(contacts.groups) { group in
                        Text(appState.privacyPresentation.groupName(
                            group.name,
                            identifier: group.id
                        ))
                        .tag(Optional(group.id))
                    }
                }
                .labelsHidden()
                .padding(12)

                List(filteredContacts, selection: $selectedContactID) { contact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentedContactName(contact))
                            .font(.appBody.weight(.medium))
                        Text(presentedContactDetail(contact))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(contact.id)
                    .contextMenu {
                        if let number = contact.primaryPhoneNumber {
                            Button("拨打", systemImage: "phone") { dial(number) }
                            Button("发短信", systemImage: "message") {
                                CommunicationWindowController.shared.showMessages(destination: number)
                            }
                        }
                        Divider()
                        Button("编辑", systemImage: "pencil") {
                            editingDraft = SystemContactDraft(contact: contact)
                        }
                        .disabled(appState.isPresentationPrivacyEnabled)
                        Button("删除", systemImage: "trash", role: .destructive) {
                            deletingContact = contact
                        }
                    }
                }
                .listStyle(.inset)

                HStack {
                    Button {
                        isCreatingGroup = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help(L10n.tr("新建联系人分组"))

                    Spacer()

                    Button {
                        editingDraft = SystemContactDraft()
                    } label: {
                        Label("新建联系人", systemImage: "person.badge.plus")
                    }
                    .disabled(appState.isPresentationPrivacyEnabled)
                    .help(appState.isPresentationPrivacyEnabled
                        ? L10n.tr("关闭演示隐私保护后可新建联系人")
                        : L10n.tr("新建联系人"))
                }
                .padding(10)
            }
            .frame(minWidth: 170, idealWidth: 195)

            contactDetail
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedContactID == nil { selectedContactID = filteredContacts.first?.id }
        }
        .onChange(of: filteredContacts.map(\.id)) { _, ids in
            if let selectedContactID, !ids.contains(selectedContactID) {
                self.selectedContactID = ids.first
            } else if selectedContactID == nil {
                selectedContactID = ids.first
            }
        }
    }

    @ViewBuilder
    private var contactDetail: some View {
        if let contact = selectedContact {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(.quaternary)
                            Image(systemName: "person.fill")
                                .font(.appSymbol(.hero))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 78, height: 78)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentedContactName(contact))
                                .font(.appDisplay)
                            if !contact.organizationName.isEmpty {
                                Text(appState.privacyPresentation.privateDetail(
                                    contact.organizationName
                                ))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        if let number = contact.primaryPhoneNumber {
                            Button {
                                dial(number)
                            } label: {
                                Label("呼叫", systemImage: "phone.fill")
                            }
                            .adaptiveGlassButton(.prominent)
                            .tint(.green)

                            Button {
                                CommunicationWindowController.shared.showMessages(destination: number)
                            } label: {
                                Label("发短信", systemImage: "message.fill")
                            }
                            .adaptiveGlassButton()
                        }

                        Button {
                            editingDraft = SystemContactDraft(contact: contact)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .adaptiveGlassButton()
                        .disabled(appState.isPresentationPrivacyEnabled)
                    }

                    if !contact.phoneNumbers.isEmpty {
                        ContactDetailSection(title: "电话号码") {
                            ForEach(contact.phoneNumbers) { phone in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(phone.label)
                                            .font(.appCaption)
                                            .foregroundStyle(.secondary)
                                        Text(appState.privacyPresentation.phoneNumber(phone.value))
                                            .font(.appBody.monospacedDigit())
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button {
                                        dial(phone.value)
                                    } label: {
                                        Image(systemName: "phone")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L10n.tr("拨打 %@", presentedContactName(contact)))
                                    Button {
                                        CommunicationWindowController.shared.showMessages(
                                            destination: phone.value
                                        )
                                    } label: {
                                        Image(systemName: "message")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L10n.tr("发送短信"))
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    if !contact.emailAddresses.isEmpty {
                        ContactDetailSection(title: "电子邮件") {
                            ForEach(contact.emailAddresses) { email in
                                HStack {
                                    Text(email.label)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(appState.privacyPresentation.privateDetail(email.value))
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }

                    Button("删除联系人", role: .destructive) {
                        deletingContact = contact
                    }
                    .buttonStyle(.borderless)
                }
                .padding(28)
                .frame(maxWidth: 620, alignment: .leading)
            }
        } else if contacts.isLoading {
            ProgressView("正在读取系统通讯录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhoneEmptyState(
                title: filteredContacts.isEmpty ? "没有联系人" : "选择一个联系人",
                detail: filteredContacts.isEmpty
                    ? "新建联系人后可直接拨打或发送短信。"
                    : "联系人详情会显示在这里。",
                systemImage: "person.crop.circle"
            )
        }
    }

    private var selectedContact: SystemContactRecord? {
        guard let selectedContactID else { return nil }
        return contacts.contacts.first { $0.id == selectedContactID }
    }

    private var filteredContacts: [SystemContactRecord] {
        contacts.contacts.filter { contact in
            let inGroup = selectedGroupID.map { contact.groupIDs.contains($0) } ?? true
            guard inGroup else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            let haystack = ([contact.displayName, contact.organizationName] +
                contact.phoneNumbers.map(\.value) + contact.emailAddresses.map(\.value))
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private func presentedContactName(_ contact: SystemContactRecord) -> String {
        appState.privacyPresentation.contactIdentity(
            name: contact.displayName,
            identifier: contact.id,
            fallbackNumber: contact.primaryPhoneNumber
        )
    }

    private func presentedContactDetail(_ contact: SystemContactRecord) -> String {
        if let number = contact.primaryPhoneNumber {
            return appState.privacyPresentation.phoneNumber(number)
        }
        return appState.privacyPresentation.privateDetail(contact.organizationName)
    }

    private func permissionView(
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(L10n.tr(title), systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text(L10n.tr(detail))
        } actions: {
            Button(L10n.tr(actionTitle), action: action)
                .adaptiveGlassButton(.prominent)
        }
    }
}

private struct ContactDetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr(title))
                .font(.appBodyStrong)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .adaptiveGlassSurface(cornerRadius: 18, treatment: .clear)
    }
}

private struct ContactEditorView: View {
    @State private var draft: SystemContactDraft
    @ObservedObject var contacts: SystemContactStore
    let close: () -> Void

    init(
        initialDraft: SystemContactDraft,
        contacts: SystemContactStore,
        close: @escaping () -> Void
    ) {
        _draft = State(initialValue: initialDraft)
        self.contacts = contacts
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.id == nil ? L10n.tr("新建联系人") : L10n.tr("编辑联系人"))
                        .font(.appTitle)
                    Text("更改将保存到 macOS 系统通讯录")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                Section("姓名") {
                    TextField("姓", text: $draft.familyName)
                    TextField("名", text: $draft.givenName)
                    TextField("公司", text: $draft.organizationName)
                }

                Section("电话号码") {
                    ForEach($draft.phoneNumbers) { $phone in
                        HStack {
                            Picker("类型", selection: $phone.label) {
                                ForEach(["手机", "工作", "住宅", "主要", "其他"], id: \.self) {
                                    Text(L10n.tr($0)).tag($0)
                                }
                            }
                            .frame(width: 110)
                            TextField("电话号码", text: $phone.value)
                            Button(role: .destructive) {
                                draft.phoneNumbers.removeAll { $0.id == phone.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.tr("删除电话号码"))
                        }
                    }
                    Button("添加电话号码", systemImage: "plus") {
                        draft.phoneNumbers.append(ContactPhoneNumber(label: "手机", value: ""))
                    }
                }

                Section("电子邮件") {
                    ForEach($draft.emailAddresses) { $email in
                        HStack {
                            Picker("类型", selection: $email.label) {
                                ForEach(["工作", "住宅", "其他"], id: \.self) {
                                    Text(L10n.tr($0)).tag($0)
                                }
                            }
                            .frame(width: 110)
                            TextField("电子邮件", text: $email.value)
                            Button(role: .destructive) {
                                draft.emailAddresses.removeAll { $0.id == email.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.tr("删除电子邮件"))
                        }
                    }
                    Button("添加电子邮件", systemImage: "plus") {
                        draft.emailAddresses.append(ContactEmailAddress(label: "工作", value: ""))
                    }
                }

                if !contacts.groups.isEmpty {
                    Section("分组") {
                        ForEach(contacts.groups) { group in
                            Toggle(
                                group.name,
                                isOn: Binding(
                                    get: { draft.groupIDs.contains(group.id) },
                                    set: { selected in
                                        if selected {
                                            draft.groupIDs.insert(group.id)
                                        } else {
                                            draft.groupIDs.remove(group.id)
                                        }
                                    }
                                )
                            )
                            .toggleStyle(.adaptiveGlass)
                        }
                    }
                }

            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let error = contacts.lastError {
                    Label(L10n.tr(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.appCaption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("取消", role: .cancel, action: close)
                    .adaptiveGlassButton()
                Button {
                    contacts.save(draft) { success in
                        if success { close() }
                    }
                } label: {
                    if contacts.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("保存")
                    }
                }
                .adaptiveGlassButton(.prominent)
                .disabled(!draft.hasIdentity || contacts.isLoading)
            }
            .padding(18)
        }
        .frame(width: 560, height: 680)
    }
}

struct PhoneEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            L10n.tr(title),
            systemImage: systemImage,
            description: Text(L10n.tr(detail))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
