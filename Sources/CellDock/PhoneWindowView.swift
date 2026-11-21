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

    let openSIMManagement: () -> Void

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                CommunicationModuleSignalBars(
                    bars: selectedModule?.modem.signalBars ?? 0,
                    hasSignal: selectedModuleHasSignal,
                    tint: selectedModuleHasSignal ? .green : .secondary,
                    barWidth: 2.5,
                    spacing: 1.5
                )
                .frame(width: 14, height: 18)
                .accessibilityHidden(true)

                Text(pickerTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .font(.callout)
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
        .help(statusDescription)
        .accessibilityLabel(L10n.tr("蜂窝设备：%@", statusDescription))
        .accessibilityValue(isPopoverPresented ? L10n.tr("已展开") : L10n.tr("已收起"))
        .accessibilityHint(L10n.tr("显示并选择当前通信模组"))
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("当前通信模组"))
                    .font(.headline)
                Text(L10n.tr("短信和拨号使用所选模组"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            Divider()

            Group {
                if appState.cellularModules.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("没有可用模组"))
                            .font(.callout.weight(.medium))
                        Text(L10n.tr("连接设备后将自动显示在这里"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(appState.cellularModules) { module in
                                moduleSelectionRow(module)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 280)
                }
            }

            Divider()

            VStack(spacing: 2) {
                CommunicationModulePopoverAction(
                    title: L10n.tr("管理 SIM 卡"),
                    systemImage: "simcard",
                    isEnabled: true,
                    showsProgress: false,
                    trailingSystemImage: "chevron.right"
                ) {
                    isPopoverPresented = false
                    openSIMManagement()
                }
            }
            .padding(6)
        }
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func moduleSelectionRow(_ module: CellularModuleSummary) -> some View {
        let isSelected = appState.currentCommunicationModuleID == module.id
        return Button {
            guard module.isCommunicationEligible else { return }
            appState.selectCommunicationModule(module.id)
            isPopoverPresented = false
        } label: {
            HStack(spacing: 10) {
                CommunicationModuleSignalBars(
                    bars: module.modem.signalBars,
                    hasSignal: moduleHasSignal(module),
                    tint: moduleHasSignal(module) ? .green : .secondary,
                    barWidth: 3,
                    spacing: 2
                )
                .frame(width: 20, height: 24)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(module.displayName) · \(module.carrierName)")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    Text(moduleSelectionDetail(module))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if !module.isCommunicationEligible {
                    Text(module.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!module.isCommunicationEligible)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        }
        .accessibilityLabel(module.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var pickerTitle: String {
        appState.currentCommunicationModule?.selectorTitle ??
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

private struct CommunicationModulePopoverAction: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let showsProgress: Bool
    let trailingSystemImage: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(L10n.tr(title))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isHovered && isEnabled
                        ? Color.primary.opacity(0.075)
                        : Color.clear
                )
        }
        .onHover { isHovered = $0 }
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
                    .font(.system(size: 15, weight: .semibold))
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

private struct ActiveCallView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @ObservedObject var contacts: SystemContactStore
    @ObservedObject private var recordings = CallRecordingStore.shared
    @AppStorage("CallRecordingConsentAcknowledged.v1") private var recordingConsent = false
    @State private var keypadVisible = false
    @State private var dtmfDigits = ""
    @State private var showingRecordingConsent = false
    @FocusState private var dtmfKeypadFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 560

            ScrollView(.vertical) {
                HStack(spacing: compact ? 14 : 20) {
                    callStage(compact: compact)
                        .frame(
                            minWidth: keypadVisible ? 350 : 400,
                            maxWidth: keypadVisible ? 520 : 610
                        )

                    if keypadVisible, appState.call.phase == .active {
                        dtmfPanel(compact: compact)
                            .frame(width: compact ? 246 : 272)
                            .transition(keypadTransition)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, proxy.size.height - 94))
                .padding(.horizontal, compact ? 14 : 22)
                .padding(.top, 66)
                .padding(.bottom, compact ? 14 : 22)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(callAnimation, value: keypadVisible)
        .onChange(of: appState.call.phase) { _, phase in
            guard phase != .active else { return }
            keypadVisible = false
            dtmfDigits = ""
            dtmfKeypadFocused = false
        }
        .alert("开始通话录音？", isPresented: $showingRecordingConsent) {
            Button("取消", role: .cancel) {}
            Button("同意并开始") {
                recordingConsent = true
                appState.startCallRecording()
            }
        } message: {
            Text("录音会保存本次通话双方的声音。请先确认已取得通话参与者同意，并遵守所在地法律法规。录音仅保存在这台 Mac。")
        }
    }

    private func callStage(compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 17) {
            callStateBadge

            CallAvatar(
                title: avatarTitle,
                fallbackSystemImage: callDirectionSystemImage,
                tint: callAvatarTint,
                size: compact ? 74 : 94
            )

            VStack(spacing: 5) {
                Text(displayName)
                    .font(.system(size: compact ? 25 : 30, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if contacts.displayName(for: callNumber) != nil {
                    Text(appState.privacyPresentation.phoneNumber(callNumber))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if appState.call.phase == .active, let startedAt = appState.call.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.title3.monospacedDigit().weight(.medium))
                }

                Text(callRouteSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .accessibilityElement(children: .combine)

            phaseActions(compact: compact)

            recordingStatus

            if let error = appState.call.lastError, appState.call.phase == .recovering {
                Label(L10n.tr(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 460)
            }
        }
        .padding(.horizontal, compact ? 18 : 26)
        .padding(.vertical, compact ? 17 : 24)
        .adaptiveGlassSurface(
            cornerRadius: compact ? 26 : 32,
            treatment: .clear
        )
    }

    @ViewBuilder
    private func phaseActions(compact: Bool) -> some View {
        switch appState.call.phase {
        case .incoming:
            VStack(spacing: 9) {
                AdaptiveGlassContainer(spacing: compact ? 28 : 40) {
                    HStack(spacing: compact ? 28 : 40) {
                        CircularLiquidCallButton(
                            title: L10n.tr("拒接"),
                            systemImage: "phone.down.fill",
                            tint: .red,
                            prominent: true,
                            role: .destructive,
                            isEnabled: !appState.isChangingCall,
                            diameter: compact ? 58 : 66
                        ) {
                            appState.hangUp()
                        }

                        CircularLiquidCallButton(
                            title: L10n.tr("接听"),
                            systemImage: "phone.fill",
                            tint: .green,
                            prominent: true,
                            isEnabled: canAnswer,
                            diameter: compact ? 58 : 66
                        ) {
                            appState.answerCall()
                        }
                    }
                }

                Text(canAnswer ? L10n.tr("使用 Mac 接听") : L10n.tr("USB 语音通道尚未就绪"))
                    .font(.caption)
                    .foregroundStyle(canAnswer ? Color.secondary : Color.orange)
            }
            .frame(maxWidth: 390)

        case .active:
            AdaptiveGlassContainer(spacing: compact ? 10 : 16) {
                HStack(spacing: compact ? 10 : 16) {
                    CircularLiquidCallButton(
                        title: appState.call.muted ? L10n.tr("取消静音") : L10n.tr("静音"),
                        systemImage: appState.call.muted ? "mic.slash.fill" : "mic.fill",
                        selected: appState.call.muted,
                        diameter: compact ? 58 : 66
                    ) {
                        appState.setCallMuted(!appState.call.muted)
                    }

                    CircularLiquidCallButton(
                        title: L10n.tr("拨号盘"),
                        systemImage: "circle.grid.3x3.fill",
                        selected: keypadVisible,
                        diameter: compact ? 58 : 66
                    ) {
                        toggleKeypad()
                    }

                    CircularLiquidCallButton(
                        title: recordings.isRecording ? L10n.tr("停止录音") : L10n.tr("录音"),
                        systemImage: recordings.isRecording ? "stop.circle.fill" : "record.circle",
                        tint: .red,
                        selected: recordings.isRecording,
                        isEnabled: canToggleRecording,
                        diameter: compact ? 58 : 66
                    ) {
                        toggleRecording()
                    }
                    .help(recordings.isRecording ? L10n.tr("停止并保存本次录音") : L10n.tr("录制通话双方声音"))

                    CircularLiquidCallButton(
                        title: L10n.tr("挂断"),
                        systemImage: "phone.down.fill",
                        tint: .red,
                        prominent: true,
                        role: .destructive,
                        isEnabled: !appState.isChangingCall,
                        diameter: compact ? 58 : 66
                    ) {
                        appState.hangUp()
                    }
                }
            }

        case .dialing, .alerting, .ending, .recovering:
            CircularLiquidCallButton(
                title: L10n.tr("挂断"),
                systemImage: "phone.down.fill",
                tint: .red,
                prominent: true,
                role: .destructive,
                isEnabled: !appState.isChangingCall || appState.call.phase == .recovering,
                diameter: compact ? 58 : 66
            ) {
                appState.hangUp()
            }

        case .idle, .unavailable, .error:
            EmptyView()
        }
    }

    private func dtmfPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            HStack {
                Text("通话按键")
                    .font(.headline)

                Spacer()

                Button("清除") {
                    dtmfDigits = ""
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .disabled(dtmfDigits.isEmpty)
                .help(L10n.tr("清空按键显示，不会撤回已发送的按键"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(dtmfDigits.isEmpty ? L10n.tr("直接点击或使用 Mac 键盘") : dtmfDigits)
                    .font(dtmfDigits.isEmpty
                        ? .callout
                        : .title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(dtmfDigits.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity, minHeight: compact ? 28 : 36)
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 7 : 10)
            .adaptiveGlassSurface(cornerRadius: 14, treatment: .clear)

            DTMFPad(keySize: compact ? 46 : 52) { tone in
                sendDTMFTone(tone)
            }
        }
        .padding(compact ? 15 : 20)
        .adaptiveGlassSurface(
            cornerRadius: compact ? 24 : 30,
            treatment: .clear
        )
        .focusable()
        .focused($dtmfKeypadFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleDTMFKeyPress(press)
        }
        .onAppear {
            DispatchQueue.main.async {
                dtmfKeypadFocused = true
            }
        }
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if recordings.isRecording, let startedAt = recordings.activeRecordingStartedAt {
            HStack(spacing: 7) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                Text("正在录音")
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
        } else if recordings.phase == .finalizing {
            ProgressView("正在保存录音…")
                .controlSize(.small)
        }

        if let recordingError = recordings.lastError {
            Label(L10n.tr(recordingError), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var canToggleRecording: Bool {
        if recordings.isRecording { return true }
        return recordings.phase == .idle &&
            appState.call.phase == .active &&
            appState.call.audioActive
    }

    private var canAnswer: Bool {
        appState.call.voiceOverUSBSupported &&
            !appState.isChangingCall
    }

    private func toggleRecording() {
        if recordings.isRecording {
            appState.stopCallRecording()
        } else if recordingConsent {
            appState.startCallRecording()
        } else {
            showingRecordingConsent = true
        }
    }

    private func toggleKeypad() {
        withAnimation(callAnimation) {
            keypadVisible.toggle()
        }
        if keypadVisible {
            DispatchQueue.main.async {
                dtmfKeypadFocused = true
            }
        } else {
            dtmfKeypadFocused = false
        }
    }

    private func sendDTMFTone(_ tone: String) {
        guard appState.call.canSendDTMF else { return }
        dtmfDigits.append(tone)
        if dtmfDigits.count > 48 {
            dtmfDigits.removeFirst(dtmfDigits.count - 48)
        }
        appState.sendDTMF(tone)
    }

    private func handleDTMFKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty,
              let tone = CallATParser.normalizedDTMFTone(press.characters) else {
            return .ignored
        }
        sendDTMFTone(tone)
        return .handled
    }

    private var callNumber: String {
        appState.call.number ?? L10n.tr("未知号码")
    }

    private var displayName: String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: callNumber),
            number: callNumber
        )
    }

    private var avatarTitle: String? {
        contacts.displayName(for: callNumber) == nil ? nil : String(displayName.prefix(1))
    }

    private var callDirectionSystemImage: String {
        appState.call.direction == .incoming
            ? "phone.arrow.down.left.fill"
            : "phone.arrow.up.right.fill"
    }

    private var callAvatarTint: Color {
        appState.call.phase == .incoming ? .orange : .blue
    }

    private var callRouteSummary: String {
        var parts: [String] = []
        let callModule = appState.call.moduleID.flatMap { moduleID in
            appState.cellularModules.first(where: { $0.id == moduleID })
        }
        if let displayName = callModule?.displayName {
            parts.append(displayName)
        }
        if let operatorName = callModule?.modem.operatorName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !operatorName.isEmpty {
            parts.append(CarrierNameFormatter.localized(operatorName))
        }
        if appState.call.phase == .active, appState.call.audioActive {
            parts.append(L10n.tr("Mac 麦克风与扬声器"))
        } else if appState.call.voiceOverUSBSupported {
            parts.append(L10n.tr("使用 Mac 接听"))
        }
        return parts.isEmpty ? L10n.tr("蜂窝语音通话") : parts.joined(separator: " · ")
    }

    private var callTint: Color {
        switch appState.call.phase {
        case .incoming: return .orange
        case .active: return .green
        case .dialing, .alerting, .ending, .recovering: return .blue
        case .unavailable, .idle, .error: return .secondary
        }
    }

    private var callStateBadge: some View {
        Label(callStateText, systemImage: callStateSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(callTint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .adaptiveGlassSurface(
                cornerRadius: 16,
                treatment: .clear,
                tint: callTint.opacity(0.08)
            )
    }

    private var callStateSystemImage: String {
        switch appState.call.phase {
        case .incoming: return "phone.arrow.down.left.fill"
        case .active: return "waveform"
        case .dialing, .alerting: return "phone.arrow.up.right.fill"
        case .ending, .recovering: return "arrow.triangle.2.circlepath"
        case .idle, .unavailable, .error: return "phone.fill"
        }
    }

    private var callStateText: String {
        switch appState.call.phase {
        case .incoming: return L10n.tr("蜂窝来电")
        case .dialing: return L10n.tr("正在拨号")
        case .alerting: return L10n.tr("对方正在响铃")
        case .active: return L10n.tr("通话中")
        case .ending: return L10n.tr("正在结束通话")
        case .recovering: return L10n.tr("正在恢复通话状态")
        case .unavailable: return L10n.tr("电话不可用")
        case .idle: return L10n.tr("可拨号")
        case .error: return L10n.tr("通话异常")
        }
    }

    private var callAnimation: Animation {
        reduceMotion ? .linear(duration: 0.14) : .smooth(duration: 0.30)
    }

    private var keypadTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .trailing))
    }
}

private struct CallAvatar: View {
    let title: String?
    let fallbackSystemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.gradient)
            if let title {
                Text(title)
                    .font(.system(size: size * 0.40, weight: .semibold))
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: size * 0.34, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.22), radius: 11, y: 4)
        .accessibilityHidden(true)
    }
}

private struct CallControlPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }
}

private struct DTMFPad: View {
    let keySize: CGFloat
    let send: (String) -> Void
    private let tones: [(digit: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(keySize), spacing: 10), count: 3),
            spacing: 10
        ) {
            ForEach(tones, id: \.digit) { tone in
                Button {
                    send(tone.digit)
                } label: {
                    VStack(spacing: 0) {
                        Text(tone.digit)
                            .font(.system(size: keySize * 0.38, weight: .medium, design: .rounded))
                        Text(tone.letters.isEmpty ? " " : tone.letters)
                            .font(.system(size: max(7, keySize * 0.12), weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(.secondary)
                            .frame(height: max(8, keySize * 0.16))
                    }
                    .frame(width: keySize, height: keySize)
                    .adaptiveGlassSurface(
                        cornerRadius: keySize / 2,
                        treatment: .clear,
                        isInteractive: true
                    )
                }
                .buttonStyle(CallControlPressStyle())
                .accessibilityLabel(
                    tone.letters.isEmpty ? tone.digit : L10n.tr("%@，%@", tone.digit, tone.letters)
                )
            }
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("搜索联系人或号码", text: $searchText)
                    .communicationSearchField()

                CommunicationIconActionButton(
                    systemImage: "phone",
                    accessibilityLabel: L10n.tr("拨打新号码"),
                    tint: .green
                ) {
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

            if filteredRecords.isEmpty {
                PhoneEmptyState(
                    title: missedOnly ? "没有未接来电" : "暂无最近通话",
                    detail: "完成或错过的蜂窝电话会保存在此 Mac。",
                    systemImage: missedOnly ? "phone.badge.checkmark" : "clock.arrow.circlepath"
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(filteredRecords) { record in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(iconTint(record).opacity(0.12))
                                Image(systemName: iconName(record))
                                    .foregroundStyle(iconTint(record))
                            }
                            .frame(width: 38, height: 38)
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(presentedIdentity(record))
                                    .font(.body.weight(record.isMissed ? .semibold : .regular))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                HStack(spacing: 5) {
                                    if let moduleName = moduleName(record) {
                                        Text(moduleName)
                                    }
                                    if record.duration > 0 {
                                        Text(formattedDuration(record.duration))
                                    } else if let reason = record.endReason {
                                        Text(callEndReasonText(record, reason: reason))
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(record.isMissed ? Color.red : Color.secondary)
                            }

                            Spacer()

                            Text(CommunicationUI.listTimestamp(record.startedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)

                            if matchingRecording(for: record) != nil {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.secondary)
                                    .help(L10n.tr("包含通话录音"))
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .communicationSelectionHighlight(selectedRecordID == record.id)
                        .onTapGesture { selectedRecordID = record.id }
                        .accessibilityAddTraits(selectedRecordID == record.id ? .isSelected : [])
                        .tag(record.id)
                        .contextMenu {
                            Button("回拨", systemImage: "phone") {
                                call(record)
                            }
                            .disabled(!canDial(record))
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

    private var filteredRecords: [CallHistoryRecord] {
        let base = missedOnly ? history.records.filter(\.isMissed) : history.records
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { record in
            record.number.localizedCaseInsensitiveContains(query) ||
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
        if let selectedRecordID,
           filteredRecords.contains(where: { $0.id == selectedRecordID }) {
            return
        }
        selectedRecordID = filteredRecords.first?.id
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

    private func iconName(_ record: CallHistoryRecord) -> String {
        if record.isMissed { return "phone.arrow.down.left.fill" }
        return record.direction == .incoming
            ? "phone.arrow.down.left.fill"
            : "phone.arrow.up.right.fill"
    }

    private func callEndReasonText(
        _ record: CallHistoryRecord,
        reason: CallEndReason
    ) -> String {
        if record.isMissed, reason == .remoteHangup {
            return L10n.tr("已挂断")
        }
        return reason.localizedDescription
    }

    private func iconTint(_ record: CallHistoryRecord) -> Color {
        if record.isMissed { return .red }
        return record.direction == .incoming ? .blue : .green
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func matchingRecording(
        for record: CallHistoryRecord
    ) -> CallRecordingRecord? {
        guard let recordingID = record.recordingID else { return nil }
        return recordings.records.first { $0.id == recordingID }
    }

    private func canDial(_ record: CallHistoryRecord) -> Bool {
        appState.moduleCanDial(nil) &&
            !appState.isChangingCall &&
            CallATParser.normalizedDialNumber(record.number) != nil
    }

    private func call(_ record: CallHistoryRecord) {
        guard canDial(record) else { return }
        model.dialNumber = record.number
        appState.dial(record.number)
    }

    private func moduleName(_ record: CallHistoryRecord) -> String? {
        guard let moduleID = record.moduleID,
              let name = appState.cellularModules.first(where: { $0.id == moduleID })?.localizedDisplayName else {
            return nil
        }
        guard let simSlot = record.simSlot else { return name }
        return name + L10n.tr(" · 卡 %lld", Int64(simSlot))
    }

    private func presentedIdentity(_ record: CallHistoryRecord) -> String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: record.number),
            number: record.number
        )
    }
}

private struct RecentCallDetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @ObservedObject var history: CallHistoryStore
    @ObservedObject var recordings: CallRecordingStore
    @ObservedObject var contacts: SystemContactStore
    let selectedRecordID: CallHistoryRecord.ID?

    var body: some View {
        Group {
            if let record = selectedRecord {
                GeometryReader { proxy in
                    let compact = proxy.size.height < 560

                    ScrollView {
                        VStack {
                            Spacer(minLength: compact ? 14 : 24)

                            AdaptiveGlassContainer(spacing: compact ? 8 : 12) {
                                detailCard(record, compact: compact)
                                    .frame(maxWidth: 380)
                            }

                            Spacer(minLength: compact ? 14 : 24)
                        }
                        .padding(.horizontal, compact ? 14 : 24)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(0, proxy.size.height)
                        )
                    }
                    .scrollIndicators(.never)
                }
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

    private func detailCard(
        _ record: CallHistoryRecord,
        compact: Bool
    ) -> some View {
        VStack(spacing: compact ? 12 : 16) {
            identityHeader(record, compact: compact)

            Divider()

            VStack(spacing: 0) {
                informationRow(
                    title: "手机号码",
                    value: appState.privacyPresentation.phoneNumber(record.number),
                    systemImage: "phone"
                )
                Divider()
                informationRow(
                    title: "通话时间",
                    value: Self.detailDateFormatter.string(from: record.startedAt),
                    systemImage: "calendar"
                )
                Divider()
                informationRow(
                    title: "通话时长",
                    value: durationText(record),
                    systemImage: "clock"
                )
                if let moduleName = moduleName(record) {
                    Divider()
                    informationRow(
                        title: "SIM 路由",
                        value: moduleName,
                        systemImage: "simcard"
                    )
                }
            }

            actionBar(record, compact: compact)
        }
        .adaptiveGlassSurface(
            cornerRadius: compact ? 22 : 26,
            padding: compact ? 20 : 26,
            treatment: .regular
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("%@，%@", directionLabel(record), displayName(record)))
    }

    private func identityHeader(
        _ record: CallHistoryRecord,
        compact: Bool
    ) -> some View {
        let tint = directionTint(record)
        let iconSize: CGFloat = compact ? 68 : 82

        return VStack(spacing: compact ? 5 : 7) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10))

                Image(systemName: directionIcon(record))
                    .font(.system(
                        size: iconSize * 0.38,
                        weight: .semibold
                    ))
                    .foregroundStyle(tint)
            }
            .frame(width: iconSize, height: iconSize)
            .adaptiveGlassSurface(
                cornerRadius: iconSize / 2,
                treatment: .clear,
                tint: tint.opacity(0.06)
            )
            .accessibilityHidden(true)

            Text(displayName(record))
                .font(.system(
                    size: compact ? 24 : 27,
                    weight: .semibold
                ))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(appState.privacyPresentation.phoneNumber(record.number))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
    }

    private func informationRow(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(L10n.tr(title))
                .foregroundStyle(.secondary)

            Spacer(minLength: 14)

            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .textSelection(.enabled)
        }
        .font(.callout)
        .frame(height: 44)
    }

    @ViewBuilder
    private func actionBar(
        _ record: CallHistoryRecord,
        compact: Bool
    ) -> some View {
        let recording = matchingRecording(record)

        HStack(spacing: compact ? 10 : 12) {
            RecentCallDetailAction(
                title: "回拨",
                systemImage: "phone",
                isEnabled: canDial(record),
                compact: compact
            ) {
                call(record)
            }

            RecentCallDetailAction(
                title: "发信息",
                systemImage: "message",
                compact: compact
            ) {
                appState.showMessagesWindow(destination: record.number)
            }

            if let recording {
                RecentCallDetailAction(
                    title: "查看录音",
                    systemImage: "waveform",
                    compact: compact
                ) {
                    model.selectedRecordingID = recording.id
                    model.activateFromRail(.recordings)
                }
            }
        }
    }

    private var selectedRecord: CallHistoryRecord? {
        guard let selectedRecordID else { return nil }
        return history.records.first { $0.id == selectedRecordID }
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

    private func directionIcon(_ record: CallHistoryRecord) -> String {
        if record.isMissed { return "phone.down.fill" }
        return record.direction == .incoming
            ? "phone.arrow.down.left.fill"
            : "phone.arrow.up.right.fill"
    }

    private func directionTint(_ record: CallHistoryRecord) -> Color {
        if record.isMissed { return .red }
        return record.direction == .incoming ? .blue : .green
    }

    private func directionLabel(_ record: CallHistoryRecord) -> String {
        if record.isMissed { return L10n.tr("未接来电") }
        return record.direction == .incoming
            ? L10n.tr("呼入通话")
            : L10n.tr("呼出通话")
    }

    private func durationText(_ record: CallHistoryRecord) -> String {
        guard record.duration > 0 else { return L10n.tr("未接通") }
        let total = max(0, Int(record.duration.rounded()))
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

    private func canDial(_ record: CallHistoryRecord) -> Bool {
        appState.moduleCanDial(nil) &&
            !appState.isChangingCall &&
            CallATParser.normalizedDialNumber(record.number) != nil
    }

    private func call(_ record: CallHistoryRecord) {
        guard canDial(record) else { return }
        model.dialNumber = record.number
        appState.dial(record.number)
    }

    private func moduleName(_ record: CallHistoryRecord) -> String? {
        guard let moduleID = record.moduleID,
              let name = appState.cellularModules.first(where: { $0.id == moduleID })?.displayName else {
            return nil
        }
        guard let simSlot = record.simSlot else { return name }
        return name + L10n.tr(" · 卡 %lld", Int64(simSlot))
    }

    private static var detailDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.storedPreference.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmm")
        return formatter
    }
}

private struct RecentCallDetailAction: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 4 : 5) {
                Image(systemName: systemImage)
                    .font(.system(
                        size: compact ? 17 : 19,
                        weight: .semibold
                    ))
                    .foregroundStyle(.primary)
                    .frame(
                        width: compact ? 28 : 32,
                        height: compact ? 28 : 32
                    )

                Text(L10n.tr(title))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 58 : 64)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: compact ? 14 : 16,
                    style: .continuous
                )
            )
        }
        .buttonStyle(CallControlPressStyle())
        .adaptiveGlassSurface(
            cornerRadius: compact ? 14 : 16,
            treatment: .clear,
            isInteractive: isEnabled
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.46)
        .help(L10n.tr(title))
        .accessibilityLabel(L10n.tr(title))
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
                    .font(.caption)
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
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(.tint)
                        }
                        .frame(width: 76, height: 76)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(presentedRecordingTitle(record))
                                .font(.title2.weight(.semibold))
                            Text(appState.privacyPresentation.phoneNumber(record.number))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Label(
                                record.direction == .incoming ? L10n.tr("来电录音") : L10n.tr("去电录音"),
                                systemImage: record.direction == .incoming
                                    ? "phone.arrow.down.left"
                                    : "phone.arrow.up.right"
                            )
                            .font(.caption)
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
                            .font(.headline)
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
                            .font(.caption)
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
                    .font(.caption)
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
                            .font(.body.weight(.medium))
                        Text(presentedContactDetail(contact))
                            .font(.caption)
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
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 78, height: 78)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentedContactName(contact))
                                .font(.largeTitle.weight(.semibold))
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
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(appState.privacyPresentation.phoneNumber(phone.value))
                                            .font(.body.monospacedDigit())
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
                .font(.headline)
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
                        .font(.title2.weight(.semibold))
                    Text("更改将保存到 macOS 系统通讯录")
                        .font(.caption)
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
                        .font(.caption)
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
