import AppKit
import AVFoundation
import SwiftUI

struct CellDockSettingsView: View {
    private enum Category: String, CaseIterable {
        case general = "通用"
        case sounds = "声音"
        case communications = "蜂窝与通信"
        case permissions = "通知与权限"
        case updates = "软件更新"

        var title: String { L10n.tr(rawValue) }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .sounds: return "speaker.wave.2.fill"
            case .communications: return "antenna.radiowaves.left.and.right"
            case .permissions: return "bell.badge"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }

        var detail: String {
            switch self {
            case .general: return L10n.tr("启动、外观与菜单栏行为")
            case .sounds: return L10n.tr("选择短信与来电使用的提示音")
            case .communications: return L10n.tr("查看模块状态并管理通话与短信处理")
            case .permissions: return L10n.tr("检查 CellDock 的系统访问权限")
            case .updates: return L10n.tr("检查版本并选择更新频道")
            }
        }

        var sidebarDetail: String {
            switch self {
            case .general: return L10n.tr("外观、语言与启动")
            case .sounds: return L10n.tr("短信提示音与来电铃声")
            case .communications: return L10n.tr("通话、短信与转发")
            case .permissions: return L10n.tr("通知与系统访问权限")
            case .updates: return L10n.tr("版本与更新频道")
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var contacts = SystemContactStore.shared
    @ObservedObject private var languageController = AppLanguageController.shared
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @ObservedObject private var smsForwarding = SMSForwardingStore.shared
    @Binding private var sidebarWidth: CGFloat
    private let focusFirstItemRequest: Bool
    private let didHandleFocusFirstItemRequest: () -> Void
    @AppStorage(AppAppearanceMode.defaultsKey) private var appearanceModeRawValue =
        AppAppearanceMode.system.rawValue
    @AppStorage("CallRecordingConsentAcknowledged.v1") private var recordingConsent = false
    @State private var selectedCategory: Category = .general
    @State private var didResolveInitialCategory = false
    @State private var isConfirmingVerificationAutoDelete = false
    @State private var isConfirmingAutomaticRecording = false
    @State private var microphoneAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var presentedForwardingChannel: SMSForwardChannel?
    @FocusState private var listFocused: Bool

    init(
        sidebarWidth: Binding<CGFloat> = .constant(CommunicationUI.sidebarWidth),
        focusFirstItemRequest: Bool = false,
        didHandleFocusFirstItemRequest: @escaping () -> Void = {}
    ) {
        _sidebarWidth = sidebarWidth
        self.focusFirstItemRequest = focusFirstItemRequest
        self.didHandleFocusFirstItemRequest = didHandleFocusFirstItemRequest
    }

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            settingsSidebar
        } detail: {
            settingsContent
        }
        .frame(
            minWidth: 560,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .onAppear {
            refreshSettingsState()
            resolveInitialSettingsCategoryIfNeeded()
            handleFocusFirstItemRequest()
        }
        .onChange(of: focusFirstItemRequest) { _, requested in
            if requested { handleFocusFirstItemRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshSystemPermissionState()
        }
        .alert("开启验证码自动删除？", isPresented: $isConfirmingVerificationAutoDelete) {
            Button("取消", role: .cancel) { }
            Button("开启", role: .destructive) {
                appState.setAutoDeleteReadVerificationMessages(true)
            }
        } message: {
            Text("验证码短信被标记已读 30 分钟后，将从模块/SIM 和本地永久删除，无法撤销。")
        }
        .alert("开启通话自动录音？", isPresented: $isConfirmingAutomaticRecording) {
            Button("取消", role: .cancel) { }
            Button("同意并开启") {
                recordingConsent = true
                appState.setAutomaticallyRecordCalls(true)
            }
        } message: {
            Text("通话接通后会自动录制双方的声音。请先确认已取得通话参与者同意，并遵守所在地法律法规。录音仅保存在这台 Mac。")
        }
        .sheet(item: $presentedForwardingChannel) { channel in
            smsForwardingConfigSheet(for: channel)
        }
    }

    @ViewBuilder
    private func smsForwardingConfigSheet(for channel: SMSForwardChannel) -> some View {
        switch channel {
        case .bark:
            BarkForwardingConfigSheet(store: smsForwarding)
        case .feishu:
            FeishuForwardingConfigSheet(store: smsForwarding)
        case .dingtalk:
            DingTalkForwardingConfigSheet(store: smsForwarding)
        }
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.tr("设置"))
                        .font(.title2.bold())
                        .padding(.horizontal, 14)

                    settingsSidebarGroup(
                        L10n.tr("偏好设置"),
                        categories: [.general, .sounds, .communications]
                    )
                    settingsSidebarGroup(
                        L10n.tr("系统"),
                        categories: [.permissions, .updates]
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .communicationSidebarScrollEdgeEffect()

            Text(verbatim: "CellDock · \(updaterManager.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .accessibilityLabel("CellDock \(updaterManager.currentVersion)")
        }
        .communicationInitialListFocus($listFocused)
        .communicationSidebarColumnStyle()
    }

    private func settingsSidebarGroup(
        _ title: String,
        categories: [Category]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(spacing: 2) {
                ForEach(categories, id: \.self) { category in
                    settingsSidebarRow(category)
                }
            }
        }
    }

    private func settingsSidebarRow(_ category: Category) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            selectSettingsCategory(category)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    Text(category.sidebarDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if category == .permissions, allSettingsPermissionsAllowed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.7)
                    }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectSettingsCategory(_ category: Category) {
        didResolveInitialCategory = true
        selectedCategory = category
        if category == .communications {
            appState.refresh()
        } else if category == .permissions {
            refreshSystemPermissionState()
        }
    }

    private func handleFocusFirstItemRequest() {
        guard focusFirstItemRequest else { return }
        resolveInitialSettingsCategoryIfNeeded()
        didHandleFocusFirstItemRequest()
        listFocused = false
        DispatchQueue.main.async {
            listFocused = true
        }
    }

    private func resolveInitialSettingsCategoryIfNeeded() {
        guard !didResolveInitialCategory else { return }
        selectedCategory = .general
        didResolveInitialCategory = true
    }

    private var settingsContent: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 20) {
                    settingsHeader
                    settingsCards
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .communicationDetailColumnStyle()
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedCategory.title)
                .font(.largeTitle.bold())
            Text(selectedCategory.detail)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var settingsCards: some View {
        switch selectedCategory {
        case .general:
            generalSettings
        case .sounds:
            SoundSettingsView()
        case .communications:
            communicationSettings
        case .permissions:
            permissionSettings
        case .updates:
            updateSettings
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 16) {
            settingsSection(title: L10n.tr("隐私保护")) {
                VStack(spacing: 12) {
                    settingRow(
                        title: L10n.tr("演示隐私保护"),
                        status: appState.isPresentationPrivacyEnabled ? L10n.tr("已开启") : nil,
                        statusColor: .green,
                        detail: L10n.tr("在界面与系统通知中隐藏联系人、电话号码、短信内容和验证码")
                    ) {
                        Toggle("演示隐私保护", isOn: Binding(
                            get: { appState.isPresentationPrivacyEnabled },
                            set: { appState.setPresentationPrivacyEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }

                    if appState.isPresentationPrivacyEnabled {
                        inlineCallout(
                            L10n.tr("原始数据不会被修改；复制、导出、在访达中显示和编辑联系人暂不可用。"),
                            systemImage: "checkmark.shield.fill",
                            color: .green
                        )
                    }
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("外观与语言")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("主题模式")
                    ) {
                        Picker("主题模式", selection: appearanceModeBinding) {
                            ForEach(AppAppearanceMode.allCases) { mode in
                                Text(mode.title)
                                    .lineLimit(1)
                                    .tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 276)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("应用语言"),
                        detail: L10n.tr("切换后立即应用，无需重新启动")
                    ) {
                        Picker("应用语言", selection: languageBinding) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(verbatim: language.nativeName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 142)
                    }
                    .padding(16)
                }
            }

            settingsSection(title: L10n.tr("启动与菜单栏")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("登录时启动"),
                        detail: launchAtLoginDetail
                    ) {
                        if appState.isChangingLaunchAtLogin {
                            ProgressView().controlSize(.small)
                        } else {
                            Toggle("登录时启动", isOn: Binding(
                                get: { appState.launchAtLoginStatus.isRegistered },
                                set: { appState.setLaunchAtLogin($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.adaptiveGlass)
                            .disabled(appState.launchAtLoginStatus == .unavailable)
                        }
                    }
                    .padding(16)

                    if let error = appState.launchAtLoginError {
                        inlineMessage(
                            error,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .red
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                    }

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("未连接模块时隐藏菜单栏图标"),
                        detail: appState.hideMenuBarIconWhenDisconnected
                            ? L10n.tr("重新连接模块后自动显示")
                            : L10n.tr("模块断开后继续显示状态图标")
                    ) {
                        Toggle("未连接模块时隐藏菜单栏图标", isOn: Binding(
                            get: { appState.hideMenuBarIconWhenDisconnected },
                            set: { appState.setHideMenuBarIconWhenDisconnected($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }
                    .padding(16)
                }
            }

            settingsSection(title: L10n.tr("应用操作")) {
                settingRow(
                    title: L10n.tr("完全退出 CellDock"),
                    detail: L10n.tr("关闭窗口不会停止短信、来电和模块监测")
                ) {
                    Button(role: .destructive) {
                        appState.quit()
                    } label: {
                        Label("完全退出 CellDock", systemImage: "power")
                    }
                    .adaptiveGlassButton()
                    .tint(.red)
                    .help("完全退出 CellDock，并停止后台短信、来电和模块监测")
                }
                .padding(16)
            }
        }
    }

    private var updateSettings: some View {
        VStack(spacing: 16) {
            settingsSection(title: L10n.tr("软件更新")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("自动检查更新"),
                        detail: updaterManager.currentVersion
                    ) {
                        Toggle("自动检查更新", isOn: Binding(
                            get: { updaterManager.automaticallyChecksForUpdates },
                            set: { updaterManager.automaticallyChecksForUpdates = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("更新频道"),
                        detail: updaterManager.channel == .stable
                            ? L10n.tr("仅接收经过验证的正式版本")
                            : L10n.tr("提前体验新功能，可能不够稳定")
                    ) {
                        Picker("更新频道", selection: $updaterManager.channel) {
                            ForEach(UpdateChannel.allCases) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("立即检查"),
                        detail: L10n.tr("从 CellDock 官方服务器检查并验证更新")
                    ) {
                        Button("检查更新…") {
                            updaterManager.checkForUpdates()
                        }
                        .adaptiveGlassButton()
                        .disabled(!updaterManager.canCheckForUpdates)
                    }
                    .padding(16)
                }
            }
        }
    }

    private var communicationSettings: some View {
        VStack(spacing: 16) {
            moduleStatusStrip

            settingsSection(title: L10n.tr("本地通话 API")) {
                LocalCallAPISettingsView(controller: appState.localCallAPIController)
                    .padding(16)
            }

            settingsSection(title: L10n.tr("通话录音")) {
                settingRow(
                    title: L10n.tr("通话时自动录音"),
                    detail: L10n.tr("通话接通且音频就绪后自动开始，录音仅保存在这台 Mac")
                ) {
                    Toggle("通话时自动录音", isOn: Binding(
                        get: { appState.automaticallyRecordCalls },
                        set: { enabled in
                            if enabled, !recordingConsent {
                                isConfirmingAutomaticRecording = true
                            } else {
                                appState.setAutomaticallyRecordCalls(enabled)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.adaptiveGlass)
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("短信处理")) {
                VStack(spacing: 12) {
                    settingRow(
                        title: L10n.tr("已读验证码自动删除"),
                        detail: L10n.tr("标记已读 30 分钟后，从模块/SIM 与本地永久删除")
                    ) {
                        Toggle("已读验证码自动删除", isOn: Binding(
                            get: { appState.autoDeleteReadVerificationMessages },
                            set: { enabled in
                                if enabled {
                                    isConfirmingVerificationAutoDelete = true
                                } else {
                                    appState.setAutoDeleteReadVerificationMessages(false)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }

                    inlineCallout(
                        L10n.tr("删除后无法恢复，开启时需要确认。"),
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("短信转发")) {
                VStack(spacing: 0) {
                    ForEach(Array(SMSForwardChannel.allCases.enumerated()), id: \.element) { index, channel in
                        if index > 0 {
                            Divider().padding(.horizontal, 16)
                        }
                        smsForwardingChannelRow(channel)
                            .padding(16)
                    }
                }
            }
        }
    }

    private func smsForwardingChannelRow(_ channel: SMSForwardChannel) -> some View {
        settingRow(
            title: channel.title,
            status: smsForwardingStatusText(for: channel),
            statusColor: smsForwardingStatusColor(for: channel),
            detail: channel.detail
        ) {
            HStack(spacing: 8) {
                Toggle(channel.title, isOn: Binding(
                    get: { smsForwarding.isEnabled(channel) },
                    set: { smsForwarding.setEnabled($0, for: channel) }
                ))
                .labelsHidden()
                .toggleStyle(.adaptiveGlass)

                Button(L10n.tr("配置…")) {
                    presentedForwardingChannel = channel
                }
                .adaptiveGlassButton()
                .controlSize(.small)
            }
        }
    }

    private func smsForwardingStatusText(for channel: SMSForwardChannel) -> String? {
        guard let result = smsForwarding.lastResults[channel] else { return nil }
        return result.isSuccess ? L10n.tr("上次转发成功") : L10n.tr("上次转发失败")
    }

    private func smsForwardingStatusColor(for channel: SMSForwardChannel) -> Color {
        guard let result = smsForwarding.lastResults[channel] else { return .secondary }
        return result.isSuccess ? .green : .red
    }

    private var moduleStatusStrip: some View {
        HStack(spacing: 14) {
            Text(cellularSummary)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Circle()
                    .fill(moduleStatusColor)
                    .frame(width: 8, height: 8)
                Text(moduleStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(moduleStatusColor)
            }
        }
        .adaptiveGlassSurface(
            cornerRadius: 18,
            padding: 16,
            treatment: .clear,
            tint: moduleStatusColor.opacity(0.045)
        )
        .accessibilityElement(children: .combine)
    }

    private var permissionSettings: some View {
        VStack(spacing: 16) {
            settingsSection(title: L10n.tr("通知")) {
                settingRow(
                    title: L10n.tr("系统通知"),
                    status: notificationPermissionStatus.text,
                    statusColor: notificationPermissionStatus.color,
                    detail: L10n.tr("用于来电、新短信和未接来电提醒")
                ) {
                    notificationPermissionAccessory
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("隐私权限")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("麦克风"),
                        status: microphonePermissionStatus.text,
                        statusColor: microphonePermissionStatus.color,
                        detail: L10n.tr("用于通话时传输本机音频")
                    ) {
                        Button(microphonePermissionButtonTitle) {
                            handleMicrophonePermissionAction()
                        }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .frame(width: 112)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("通讯录"),
                        status: contactPermissionStatus.text,
                        statusColor: contactPermissionStatus.color,
                        detail: L10n.tr("用于识别来电、短信联系人和拨号")
                    ) {
                        Button(contactPermissionButtonTitle) {
                            handleContactPermissionAction()
                        }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .frame(width: 112)
                    }
                    .padding(16)
                }
            }

            inlineMessage(
                L10n.tr("权限由 macOS 管理，可随时在系统设置中更改。"),
                systemImage: "checkmark.shield",
                color: .secondary
            )
            .padding(4)
            .adaptiveGlassSurface(
                cornerRadius: 18,
                padding: 13,
                treatment: .clear
            )
        }
    }

    @ViewBuilder
    private var notificationPermissionAccessory: some View {
        if appState.isRequestingNotificationAuthorization ||
            appState.notificationAuthorizationStatus == .unknown {
            ProgressView()
                .controlSize(.small)
                .frame(width: 112)
        } else {
            Button(notificationPermissionButtonTitle) {
                if appState.notificationAuthorizationStatus == .notDetermined {
                    appState.requestNotificationAuthorization()
                } else {
                    appState.openNotificationSettings()
                }
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .frame(width: 112)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 16)
            content()
        }
        .adaptiveGlassSurface(
            cornerRadius: 18,
            treatment: .regular
        )
    }

    private func settingRow<Accessory: View>(
        title: String,
        status: String? = nil,
        statusColor: Color = .secondary,
        detail: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let status {
                        Text(status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            accessory()
        }
    }

    private func inlineMessage(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(color)
    }

    private func inlineCallout(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        inlineMessage(text, systemImage: systemImage, color: color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .adaptiveGlassSurface(
                cornerRadius: 10,
                treatment: .clear,
                tint: color.opacity(0.08)
            )
    }

    private var selectedAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var appearanceModeBinding: Binding<AppAppearanceMode> {
        Binding(
            get: { selectedAppearanceMode },
            set: { mode in
                appearanceModeRawValue = mode.rawValue
                mode.apply()
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { languageController.selectedLanguage },
            set: { languageController.select($0) }
        )
    }

    private var launchAtLoginDetail: String {
        switch appState.launchAtLoginStatus {
        case .disabled: return L10n.tr("登录 Mac 后可在后台自动运行 CellDock")
        case .enabled: return L10n.tr("登录 Mac 后在后台运行 CellDock")
        case .unavailable: return L10n.tr("当前应用位置或用户会话不支持登录启动")
        }
    }

    private var cellularSummary: String {
        guard appState.modem.isConnected else { return L10n.tr("SIM 1 · 模块未连接") }
        return (["SIM 1", appState.modem.operatorName, appState.modem.accessTechnology]
            .compactMap { $0 })
            .joined(separator: " · ")
    }

    private var moduleStatusText: String {
        switch appState.modem.operationalState {
        case .absent: return L10n.tr("模块未连接")
        case .enumerating: return L10n.tr("USB 枚举中")
        case .initializing: return L10n.tr("模块初始化中")
        case .configurationRequired: return L10n.tr("模块需要配置")
        case .ready: return L10n.tr("模块已连接")
        case .restarting: return L10n.tr("模块正在重启")
        case .reconnecting: return L10n.tr("模块重新连接中")
        case .failed: return L10n.tr("模块异常")
        }
    }

    private var moduleStatusColor: Color {
        switch appState.modem.operationalState {
        case .ready: return .green
        case .configurationRequired: return .orange
        case .failed: return .red
        case .enumerating, .initializing, .restarting, .reconnecting: return .blue
        case .absent: return .secondary
        }
    }

    private var notificationPermissionStatus: (text: String, color: Color) {
        switch appState.notificationAuthorizationStatus {
        case .unknown: return (L10n.tr("读取中"), .secondary)
        case .notDetermined: return (L10n.tr("未请求"), .secondary)
        case .denied: return (L10n.tr("未允许"), .orange)
        case .authorized: return (L10n.tr("已允许"), .green)
        }
    }

    private var allSettingsPermissionsAllowed: Bool {
        appState.notificationAuthorizationStatus == .authorized &&
            microphoneAuthorizationStatus == .authorized &&
            contacts.authorizationState == .authorized
    }

    private var notificationPermissionButtonTitle: String {
        appState.notificationAuthorizationStatus == .notDetermined
            ? L10n.tr("允许通知")
            : L10n.tr("通知设置…")
    }

    private var microphonePermissionStatus: (text: String, color: Color) {
        switch microphoneAuthorizationStatus {
        case .notDetermined: return (L10n.tr("未请求"), .secondary)
        case .restricted: return (L10n.tr("受限制"), .orange)
        case .denied: return (L10n.tr("未允许"), .orange)
        case .authorized: return (L10n.tr("已允许"), .green)
        @unknown default: return (L10n.tr("未知"), .secondary)
        }
    }

    private var microphonePermissionButtonTitle: String {
        microphoneAuthorizationStatus == .notDetermined
            ? L10n.tr("请求权限")
            : L10n.tr("系统设置…")
    }

    private var contactPermissionStatus: (text: String, color: Color) {
        switch contacts.authorizationState {
        case .notDetermined: return (L10n.tr("未请求"), .secondary)
        case .authorized: return (L10n.tr("已允许"), .green)
        case .denied: return (L10n.tr("未允许"), .orange)
        case .restricted: return (L10n.tr("受限制"), .orange)
        }
    }

    private var contactPermissionButtonTitle: String {
        contacts.authorizationState == .notDetermined
            ? L10n.tr("请求权限")
            : L10n.tr("系统设置…")
    }

    private func handleMicrophonePermissionAction() {
        if microphoneAuthorizationStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    microphoneAuthorizationStatus =
                        AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else {
            openPrivacySettings(anchor: "Privacy_Microphone")
        }
    }

    private func handleContactPermissionAction() {
        if contacts.authorizationState == .notDetermined {
            contacts.requestAccess()
        } else {
            contacts.openPrivacySettings()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshSettingsState() {
        appState.refresh()
        refreshSystemPermissionState()
    }

    private func refreshSystemPermissionState() {
        appState.refreshSystemSettingsStatus()
        contacts.reload()
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

private struct LocalCallAPISettingsView: View {
    @ObservedObject var controller: LocalCallAPIController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.tr("启用本地通话 API"), isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.adaptiveGlass)
            Text(L10n.tr("允许持有令牌的本机程序拨号、接听、挂断和查询状态。通话仍使用 Mac 的麦克风与扬声器。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if controller.isEnabled {
                HStack {
                    Text(verbatim: LocalCallAPIController.endpoint)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button(L10n.tr("复制 API 令牌")) { controller.copyToken() }
                        .adaptiveGlassButton()
                        .disabled(!controller.isRunning)
                }
                if let error = controller.error {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                } else if !controller.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}
