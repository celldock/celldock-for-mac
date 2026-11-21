import AppKit
import SwiftUI

struct ProxyManagementView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: SOCKSProxyController
    /// Observed directly: the controller only publishes runtime states, so a
    /// rename or an enable toggle would otherwise not refresh the list.
    @ObservedObject private var store: SOCKSProxyStore
    @Binding var sidebarWidth: CGFloat
    @Binding var networkToolsTab: NetworkToolsTab
    @State private var selectedID: UUID?

    init(
        controller: SOCKSProxyController,
        sidebarWidth: Binding<CGFloat>,
        networkToolsTab: Binding<NetworkToolsTab>
    ) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.store)
        _sidebarWidth = sidebarWidth
        _networkToolsTab = networkToolsTab
    }

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            sidebar
                .communicationSidebarColumnStyle()
                .communicationModuleFloatingSidebar()
        } detail: {
            detail
                .communicationDetailColumnStyle()
        }
        .onAppear { reconcileSelection() }
        .onChange(of: store.configurations.map(\.id)) { _, _ in reconcileSelection() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            NetworkToolsTabBar(selection: $networkToolsTab)

            HStack {
                Text(verbatim: L10n.tr("代理")).font(.title2.weight(.semibold))
                Spacer()
                CommunicationIconActionButton(
                    systemImage: "plus",
                    accessibilityLabel: L10n.tr("新建代理"),
                    action: createProxy
                )
                .disabled(availableModules.isEmpty)
            }
            .padding(16)

            if availableModules.isEmpty && store.configurations.isEmpty {
                ContentUnavailableView(
                    L10n.tr("没有可用模组"),
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text(verbatim: L10n.tr("连接并识别蜂窝模组后即可创建代理。"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(availableModules) { module in
                        if let imei = module.modem.moduleIMEI {
                            Section(module.selectorTitle) {
                                ForEach(configurations(for: imei)) { config in
                                    row(config, fallbackState: .disabled)
                                }
                            }
                        }
                    }
                    if !orphanedConfigurations.isEmpty {
                        Section(L10n.tr("离线模组")) {
                            ForEach(orphanedConfigurations) { config in
                                row(config, fallbackState: .stoppedModuleOffline)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .communicationEmphasizedSelection()
            }
        }
    }

    private func row(
        _ config: SOCKSProxyConfiguration,
        fallbackState: SOCKSProxyRuntimeState
    ) -> some View {
        ProxyRow(
            configuration: config,
            state: controller.runtimeStates[config.id] ?? fallbackState
        )
        .communicationSelectionHighlight(selectedID == config.id)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = config.id }
        .accessibilityAddTraits(selectedID == config.id ? .isSelected : [])
        .tag(config.id)
    }

    @ViewBuilder private var detail: some View {
        if let selectedID,
           let configuration = store.configurations.first(where: { $0.id == selectedID }) {
            ProxyEditorView(
                configuration: configuration,
                controller: controller,
                modules: availableModules,
                onDelete: { self.selectedID = nil }
            )
            // ProxyEditorView keeps an editable draft in local state. Give each
            // configuration its own identity so selecting another row replaces
            // that draft (and hides any revealed password) instead of
            // continuing to edit the previous proxy.
            .id(configuration.id)
        } else {
            ContentUnavailableView(
                L10n.tr("选择代理"),
                systemImage: "point.forward.to.point.capsulepath",
                description: Text(verbatim: L10n.tr("选择现有代理或新建代理以编辑设置。"))
            )
        }
    }

    private var availableModules: [CellularModuleSummary] {
        appState.cellularModules.filter { $0.modem.moduleIMEI?.isEmpty == false }
    }

    private func configurations(for imei: String) -> [SOCKSProxyConfiguration] {
        store.configurations.filter { $0.moduleIMEI == imei }
    }

    private var orphanedConfigurations: [SOCKSProxyConfiguration] {
        let presentIMEIs = Set(availableModules.compactMap(\.modem.moduleIMEI))
        return store.configurations.filter { !presentIMEIs.contains($0.moduleIMEI) }
    }

    private func createProxy() {
        guard let module = availableModules.first, let imei = module.modem.moduleIMEI,
              let port = SOCKSProxyPortAllocator.nextAvailable(
                used: Set(store.configurations.map(\.port))
              ) else { return }
        // A newly-created proxy remains unnamed and disabled until the user
        // reviews the draft, gives it a name, and explicitly enables it.
        let config = SOCKSProxyConfiguration.newDraft(moduleIMEI: imei, port: port)
        try? store.save(config)
        selectedID = config.id
    }

    private func reconcileSelection() {
        let ids = store.configurations.map(\.id)
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.first
    }
}

// MARK: - Shared presentation

private extension SOCKSProxyConfiguration.ListenScope {
    var title: String {
        switch self {
        case .loopback: return L10n.tr("仅本机")
        case .lan: return L10n.tr("局域网")
        }
    }
}

private extension SOCKSProxyConfiguration {
    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension SOCKSProxyRuntimeState {
    var statusText: String {
        switch self {
        case let .running(connections): return L10n.tr("运行中 · %lld 个连接", Int64(connections))
        case .stoppedModuleOffline: return L10n.tr("已停止 · 模组离线")
        case .stoppedCellularDisabled: return L10n.tr("已停止 · 蜂窝网络关闭")
        case .stoppedLinkDown: return L10n.tr("已停止 · ECM 链路中断")
        case let .failedPortInUse(port): return L10n.tr("启动失败 · 端口 %lld 被占用", Int64(port))
        case let .failedToStart(reason): return L10n.tr("启动失败 · %@", reason)
        case .stoppedMissingCredentials: return L10n.tr("已停止 · 缺少认证密码")
        case .disabled: return L10n.tr("已停用")
        }
    }

    /// `nil` means the neutral secondary style (disabled or offline).
    var tint: Color? {
        switch self {
        case .running: return .green
        case .failedPortInUse, .failedToStart: return .red
        case .stoppedLinkDown, .stoppedMissingCredentials: return .orange
        case .stoppedModuleOffline, .stoppedCellularDisabled, .disabled: return nil
        }
    }

    /// States the user has to act on; these replace the address line in the
    /// sidebar so the problem is visible without opening the proxy.
    var isAttentionNeeded: Bool {
        switch self {
        case .failedPortInUse, .failedToStart, .stoppedLinkDown, .stoppedMissingCredentials:
            return true
        default:
            return false
        }
    }

    var isOffline: Bool {
        switch self {
        case .stoppedModuleOffline, .stoppedCellularDisabled: return true
        default: return false
        }
    }
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

// MARK: - Sidebar row

private struct ProxyRow: View {
    let configuration: SOCKSProxyConfiguration
    let state: SOCKSProxyRuntimeState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(isDraft ? Color.secondary : (state.tint ?? Color.secondary))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                nameText.lineLimit(1)
                detailText
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if case let .running(connections) = state {
                Text(verbatim: "\(connections)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
                    .accessibilityLabel(L10n.tr("%lld 个连接", Int64(connections)))
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var isDraft: Bool {
        configuration.trimmedName.isEmpty && !configuration.isEnabled
    }

    @ViewBuilder private var nameText: some View {
        if configuration.trimmedName.isEmpty {
            Text(verbatim: L10n.tr("未命名代理"))
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: configuration.name)
        }
    }

    @ViewBuilder private var detailText: some View {
        if isDraft {
            Text(verbatim: L10n.tr("草稿 · 已停用"))
                .foregroundStyle(.secondary)
        } else if state.isAttentionNeeded, let tint = state.tint {
            Text(verbatim: state.statusText)
                .foregroundStyle(tint)
        } else if state.isOffline {
            Text(verbatim: state.statusText)
                .foregroundStyle(.secondary)
        } else {
            (Text(verbatim: "\(configuration.listenScope.title) · ") +
                Text(verbatim: ":\(configuration.port)")
                .font(.system(.caption, design: .monospaced)))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

private struct ProxyEditorView: View {
    /// The configuration as currently saved in the store.
    let configuration: SOCKSProxyConfiguration
    @ObservedObject var controller: SOCKSProxyController
    let modules: [CellularModuleSummary]
    let onDelete: () -> Void

    @State private var draft: SOCKSProxyConfiguration
    @State private var password: String
    @State private var savedPassword: String
    @State private var isPasswordRevealed = false
    @State private var snippetFormat: SOCKSProxyClientSnippetFormat = .surge
    @State private var lanAddress: String?
    @State private var didCopySnippet = false
    @State private var copyFeedbackToken = UUID()
    @State private var errorMessage: String?
    @State private var enableHint: String?
    @State private var attemptedSave = false
    @State private var isConfirmingDelete = false

    init(
        configuration: SOCKSProxyConfiguration,
        controller: SOCKSProxyController,
        modules: [CellularModuleSummary],
        onDelete: @escaping () -> Void
    ) {
        let storedPassword = controller.store.password(for: configuration.id) ?? ""
        self.configuration = configuration
        _draft = State(initialValue: configuration)
        _password = State(initialValue: storedPassword)
        _savedPassword = State(initialValue: storedPassword)
        _lanAddress = State(initialValue: LocalNetworkAddress.currentLANIPv4())
        self.controller = controller
        self.modules = modules
        self.onDelete = onDelete
    }

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectionCard
                    basicInfoCard
                    listenCard
                    authenticationCard

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .adaptiveGlassSurface(
                                cornerRadius: 14,
                                padding: 12,
                                treatment: .clear,
                                tint: Color.red.opacity(0.08)
                            )
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
        .onChange(of: draft.listenScope) { _, scope in
            if scope == .lan {
                lanAddress = LocalNetworkAddress.currentLANIPv4()
                if case .none = draft.authentication {
                    draft.authentication = .usernamePassword(username: "")
                }
            }
        }
        .onChange(of: draft.name) { _, _ in enableHint = nil }
        .confirmationDialog(
            L10n.tr("删除代理“%@”？", displayName),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("删除"), role: .destructive) { delete() }
            Button(L10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(verbatim: L10n.tr("代理设置和钥匙串中保存的密码将被移除。"))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: draft.trimmedName.isEmpty ? L10n.tr("新建代理") : draft.name)
                        .font(.title.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        statusCapsule
                        Text(verbatim: moduleTitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                // Native switch: on macOS 26+ it renders with the system's
                // Liquid Glass appearance, and as a regular switch before that.
                Toggle(L10n.tr("启用"), isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    .fixedSize()
                    .padding(.top, 6)
            }
            if let enableHint {
                Label(enableHint, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runtimeState: SOCKSProxyRuntimeState {
        controller.runtimeStates[configuration.id] ?? .disabled
    }

    private var statusCapsule: some View {
        let state = runtimeState
        let foreground = state.tint ?? Color.secondary
        return HStack(spacing: 6) {
            Circle().fill(foreground).frame(width: 7, height: 7)
            Text(verbatim: state.statusText)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill((state.tint ?? Color.primary).opacity(0.1)))
        .fixedSize()
    }

    private var moduleTitle: String {
        modules.first(where: { $0.modem.moduleIMEI == draft.moduleIMEI })?.selectorTitle
            ?? L10n.tr("离线模组")
    }

    private var displayName: String {
        draft.trimmedName.isEmpty ? L10n.tr("未命名代理") : draft.trimmedName
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { configuration.isEnabled },
            set: { setEnabled($0) }
        )
    }

    /// The enable switch applies immediately to the saved configuration,
    /// independent of any unsaved edits in the draft.
    private func setEnabled(_ enabled: Bool) {
        enableHint = nil
        if enabled && configuration.trimmedName.isEmpty {
            enableHint = L10n.tr("请先填写名称并保存，然后再启用。")
            return
        }
        var updated = configuration
        updated.isEnabled = enabled
        do {
            try controller.store.save(updated)
            controller.reconcile()
            draft.isEnabled = enabled
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Connection

    private var clientConfig: SOCKSProxyClientConfig {
        SOCKSProxyClientConfig(
            configuration: draft,
            host: SOCKSProxyClientConfig.host(for: draft.listenScope, lanAddress: lanAddress),
            password: password
        )
    }

    private var connectionCard: some View {
        ProxyEditorCard(title: L10n.tr("连接地址")) {
            Picker(L10n.tr("连接地址"), selection: $snippetFormat) {
                Text(verbatim: L10n.tr("地址")).tag(SOCKSProxyClientSnippetFormat.address)
                Text(verbatim: "Surge").tag(SOCKSProxyClientSnippetFormat.surge)
                Text(verbatim: "Clash").tag(SOCKSProxyClientSnippetFormat.clash)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: clientConfig.snippet(
                        snippetFormat,
                        revealPassword: isPasswordRevealed
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: copySnippet) {
                        Label(
                            didCopySnippet ? L10n.tr("已复制") : copyButtonTitle,
                            systemImage: didCopySnippet ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.small)
                    .fixedSize()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

                Text(verbatim: snippetCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draft.listenScope == .lan && lanAddress == nil {
                    Label(
                        L10n.tr("未找到局域网 IPv4 地址，暂以 0.0.0.0 显示。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Divider().padding(.vertical, 2)

                HStack(alignment: .top, spacing: 16) {
                    summaryItem(
                        title: L10n.tr("监听"),
                        value: draft.listenScope.title,
                        detail: "\(clientConfig.host):\(draft.port)",
                        monospacedDetail: true
                    )
                    summaryItem(
                        title: L10n.tr("出口"),
                        value: moduleTitle,
                        detail: nil
                    )
                    summaryItem(
                        title: L10n.tr("认证"),
                        value: isAuthenticationEnabled ? L10n.tr("用户名密码") : L10n.tr("无认证"),
                        detail: authenticatedUsername
                    )
                }
            }
        }
    }

    private var copyButtonTitle: String {
        snippetFormat == .address ? L10n.tr("复制") : L10n.tr("复制配置")
    }

    private var snippetCaption: String {
        let hasCredentials = isAuthenticationEnabled
        switch snippetFormat {
        case .address:
            return L10n.tr("不含密码")
        case .surge:
            return hasCredentials
                ? L10n.tr("粘贴到 Surge 配置的 [Proxy] 段，复制内容含完整密码")
                : L10n.tr("粘贴到 Surge 配置的 [Proxy] 段")
        case .clash:
            return hasCredentials
                ? L10n.tr("粘贴到 Clash 配置的 proxies: 下，复制内容含完整密码")
                : L10n.tr("粘贴到 Clash 配置的 proxies: 下")
        }
    }

    private func summaryItem(
        title: String,
        value: String,
        detail: String?,
        monospacedDetail: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(monospacedDetail
                        ? .system(.caption, design: .monospaced)
                        : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copySnippet() {
        copyToPasteboard(clientConfig.snippet(snippetFormat, revealPassword: true))
        let token = UUID()
        copyFeedbackToken = token
        didCopySnippet = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copyFeedbackToken == token { didCopySnippet = false }
        }
    }

    // MARK: Basic info

    private var basicInfoCard: some View {
        ProxyEditorCard(title: L10n.tr("基本信息")) {
            Form {
                TextField(L10n.tr("名称"), text: $draft.name)
                Picker(L10n.tr("绑定模组"), selection: $draft.moduleIMEI) {
                    ForEach(modules) { module in
                        if let imei = module.modem.moduleIMEI {
                            Text(verbatim: module.selectorTitle).tag(imei)
                        }
                    }
                    if !modules.contains(where: { $0.modem.moduleIMEI == draft.moduleIMEI }) {
                        Text(verbatim: L10n.tr("离线模组")).tag(draft.moduleIMEI)
                    }
                }
            }
            .formStyle(.columns)
        }
    }

    // MARK: Listen

    private var listenCard: some View {
        ProxyEditorCard(title: L10n.tr("监听")) {
            VStack(alignment: .leading, spacing: 10) {
                Form {
                    Picker(L10n.tr("监听范围"), selection: $draft.listenScope) {
                        Text(verbatim: L10n.tr("仅本机"))
                            .tag(SOCKSProxyConfiguration.ListenScope.loopback)
                        Text(verbatim: L10n.tr("局域网"))
                            .tag(SOCKSProxyConfiguration.ListenScope.lan)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    LabeledContent(L10n.tr("端口")) {
                        HStack(spacing: 8) {
                            TextField(
                                L10n.tr("端口"),
                                value: $draft.port,
                                format: .number.grouping(.never)
                            )
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 90)
                            Button(L10n.tr("自动分配"), action: assignPort)
                                .adaptiveGlassButton(.regular)
                                .controlSize(.small)
                        }
                    }
                }
                .formStyle(.columns)

                if draft.listenScope == .lan {
                    Label(
                        L10n.tr(
                            "同一网络的设备可通过 %@ 访问，必须开启用户名密码认证。",
                            lanAddress ?? "0.0.0.0"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                } else {
                    Text(verbatim: L10n.tr("只接受这台 Mac 上的连接（127.0.0.1）。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func assignPort() {
        let used = Set(
            controller.store.configurations
                .filter { $0.id != draft.id }
                .map(\.port)
        )
        if let port = SOCKSProxyPortAllocator.nextAvailable(used: used) {
            draft.port = port
        }
    }

    // MARK: Authentication

    private var isAuthenticationEnabled: Bool {
        if case .usernamePassword = draft.authentication { return true }
        return false
    }

    private var authenticatedUsername: String? {
        if case let .usernamePassword(username) = draft.authentication { return username }
        return nil
    }

    private var authenticationEnabled: Binding<Bool> {
        Binding(
            get: { isAuthenticationEnabled },
            set: { enabled in
                draft.authentication = enabled ? .usernamePassword(username: "") : .none
                if !enabled { password = "" }
            }
        )
    }

    private var credentialsInvalid: Bool {
        guard let username = authenticatedUsername else { return false }
        let tooLong = username.utf8.count > 255 || password.utf8.count > 255
        let empty = username.utf8.isEmpty || password.utf8.isEmpty
        return tooLong || (attemptedSave && empty)
    }

    private var authenticationCard: some View {
        ProxyEditorCard(title: L10n.tr("认证")) {
            VStack(alignment: .leading, spacing: 10) {
                Form {
                    Toggle(isOn: authenticationEnabled) {
                        Text(verbatim: L10n.tr("需要用户名和密码"))
                        if draft.listenScope == .lan {
                            Text(verbatim: L10n.tr("局域网模式下必须开启"))
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(draft.listenScope == .lan)

                    if let username = authenticatedUsername {
                        TextField(L10n.tr("用户名"), text: Binding(
                            get: { username },
                            set: { draft.authentication = .usernamePassword(username: $0) }
                        ))
                        LabeledContent(L10n.tr("密码")) {
                            HStack(spacing: 8) {
                                ProxyPasswordField(
                                    text: $password,
                                    isRevealed: $isPasswordRevealed
                                )
                                Button(L10n.tr("生成")) {
                                    password = SOCKSProxyPasswordGenerator.generate()
                                    isPasswordRevealed = true
                                }
                                .adaptiveGlassButton(.regular)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .formStyle(.columns)

                if isAuthenticationEnabled {
                    if credentialsInvalid {
                        Text(verbatim: L10n.tr("用户名和密码必须为 1–255 字节。"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(verbatim: L10n.tr("保存在钥匙串中 · 1–255 字节"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Action bar

    private var isDirty: Bool {
        draft != configuration || password != savedPassword
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(L10n.tr("删除代理"), role: .destructive) { isConfirmingDelete = true }
                .adaptiveGlassButton(.regular)
            Spacer(minLength: 16)
            if isDirty {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                    Text(verbatim: L10n.tr("有未保存的更改"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Button(L10n.tr("还原"), action: revert)
                    .adaptiveGlassButton(.regular)
            }
            Button(L10n.tr("保存")) { save() }
                .adaptiveGlassButton(.prominent)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!isDirty)
        }
        .adaptiveGlassSurface(
            cornerRadius: 16,
            padding: 12,
            treatment: .clear
        )
    }

    private func revert() {
        let stored = controller.store.password(for: configuration.id) ?? ""
        draft = configuration
        password = stored
        savedPassword = stored
        errorMessage = nil
        attemptedSave = false
    }

    private func delete() {
        do {
            try controller.store.delete(draft.id)
            controller.reconcile()
            onDelete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        errorMessage = nil
        attemptedSave = true
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, draft.port > 0 else { errorMessage = L10n.tr("名称和端口不能为空。"); return }
        if draft.listenScope == .lan, case .none = draft.authentication {
            errorMessage = L10n.tr("局域网监听必须启用用户名密码认证。"); return
        }
        if case let .usernamePassword(username) = draft.authentication,
           username.utf8.isEmpty || username.utf8.count > 255 ||
            password.utf8.isEmpty || password.utf8.count > 255 {
            errorMessage = L10n.tr("用户名和密码必须为 1–255 字节。"); return
        }
        draft.name = name
        do {
            try controller.store.save(draft, password: password)
            controller.reconcile()
            savedPassword = isAuthenticationEnabled ? password : ""
            attemptedSave = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Building blocks

private struct ProxyEditorCard<Accessory: View, Content: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(
        title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(verbatim: title).font(.headline)
                Spacer(minLength: 12)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(
            cornerRadius: 20,
            padding: 18,
            treatment: .regular
        )
    }
}

private extension ProxyEditorCard where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// A password field that can switch between hidden and visible text without
/// losing keyboard focus, with inline copy and reveal buttons.
private struct ProxyPasswordField: View {
    @Binding var text: String
    @Binding var isRevealed: Bool
    @FocusState private var focusedField: Field?
    @State private var didCopy = false
    @State private var copyFeedbackToken = UUID()

    private enum Field: Hashable {
        case secure
        case plain
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isRevealed {
                    TextField(L10n.tr("密码"), text: $text)
                        .focused($focusedField, equals: .plain)
                } else {
                    SecureField(L10n.tr("密码"), text: $text)
                        .focused($focusedField, equals: .secure)
                }
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 160)

            iconButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                label: L10n.tr("复制密码"),
                action: copy
            )
            .disabled(text.isEmpty)

            iconButton(
                systemImage: isRevealed ? "eye.slash" : "eye",
                label: isRevealed ? L10n.tr("隐藏密码") : L10n.tr("显示密码"),
                action: toggleReveal
            )
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    focusedField != nil ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: focusedField != nil ? 1.5 : 1
                )
        )
    }

    private func iconButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }

    private func toggleReveal() {
        let hadFocus = focusedField != nil
        isRevealed.toggle()
        guard hadFocus else { return }
        // The other field only exists after this update, so move focus on the
        // next run loop turn.
        let target: Field = isRevealed ? .plain : .secure
        DispatchQueue.main.async { focusedField = target }
    }

    private func copy() {
        copyToPasteboard(text)
        let token = UUID()
        copyFeedbackToken = token
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copyFeedbackToken == token { didCopy = false }
        }
    }
}
