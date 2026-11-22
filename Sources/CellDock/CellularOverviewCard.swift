import CellDockNetworkIPC
import SwiftUI

enum CellularOverviewCardDensity: Equatable {
    case regular
    case compact
}

struct CellularOverviewCard: View {
    @EnvironmentObject private var appState: AppState

    let moduleID: CellularModuleID?
    let treatment: AdaptiveGlassTreatment
    let density: CellularOverviewCardDensity
    private let onSelectModule: (() -> Void)?
    private let onOpenMainWindow: (() -> Void)?
    private let onOpenATConsole: (() -> Void)?
    private let onRefresh: (() -> Void)?
    private let onOpenSettings: (() -> Void)?

    private var displayedModule: CellularModuleSummary? {
        guard let moduleID else { return nil }
        return appState.cellularModules.first { $0.id == moduleID }
    }

    private var displayedModem: ModemSnapshot {
        displayedModule?.modem ?? appState.primaryDataModem
    }

    private var resolvedModuleID: CellularModuleID? {
        moduleID ?? appState.primaryDataModuleID
    }

    private var displayedNetwork: CellularNetworkStatus {
        resolvedModuleID.map(appState.networkStatus(for:)) ?? appState.network
    }

    private var displayedNetworkMode: CellularNetworkMode {
        resolvedModuleID.map(appState.networkMode(for:)) ?? appState.presentedCellularNetworkMode
    }

    private var displayedNetworkIsChanging: Bool {
        resolvedModuleID.map(appState.isChangingNetworkMode(for:)) ?? appState.isChangingNetwork
    }

    private var displayedConnectionState: CellularDataConnectionState {
        CellularDataConnectionPolicy.state(
            modem: displayedModem,
            network: displayedNetwork,
            isPresentedEnabled: displayedNetworkMode.isEnabled,
            isChangingNetwork: displayedNetworkIsChanging,
            isRecovering: resolvedModuleID
                .map(appState.isRecoveringNetworkLink(for:)) ?? false,
            isRetryingLink: resolvedModuleID
                .map(appState.isRetryingCellularLink(for:)) ?? true
        )
    }

    private var showsNetworkControls: Bool {
        resolvedModuleID != nil
    }

    init(
        moduleID: CellularModuleID? = nil,
        treatment: AdaptiveGlassTreatment = .regular,
        density: CellularOverviewCardDensity = .regular,
        onSelectModule: (() -> Void)? = nil,
        onOpenMainWindow: (() -> Void)? = nil,
        onOpenATConsole: (() -> Void)? = nil,
        onRefresh: (() -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.moduleID = moduleID
        self.treatment = treatment
        self.density = density
        self.onSelectModule = onSelectModule
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenATConsole = onOpenATConsole
        self.onRefresh = onRefresh
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryPanel

            ExpandableCardSection(
                isExpanded: showsNetworkControls && displayedNetworkMode.isEnabled,
                topSpacing: cardSpacing
            ) {
                networkDetailPanel
            }

            ExpandableCardSection(
                isExpanded: showsNetworkControls && needsECMConfiguration,
                topSpacing: cardSpacing
            ) {
                ecmConfigurationNotice
            }

            if hasFooterActions {
                Divider().padding(.top, cardSpacing)
                actionFooter
                    .padding(.top, cardSpacing)
            }
        }
        .adaptiveGlassSurface(
            cornerRadius: 22,
            padding: cardPadding,
            treatment: treatment
        )
    }

    private var summaryPanel: some View {
        VStack(spacing: summarySpacing) {
            HStack(spacing: 12) {
                CellularSignalBars(
                    bars: displayedModem.signalBars,
                    active: displayedModem.isConnected
                )
                .frame(width: 46, height: 38)
                .contentShape(Rectangle())
                .onTapGesture { onSelectModule?() }
                .help(
                    displayedModem.signalDetail
                        ?? displayedModem.endpointDescription
                        ?? L10n.tr("暂无信号详情")
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        cardTitleView
                            .layoutPriority(2)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectModule?() }
                        Spacer(minLength: 0)
                        statusBadge
                            .fixedSize()
                    }

                    HStack(spacing: 8) {
                        Text(signalSummary)
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        networkModeMenu
                    }
                }
                .layoutPriority(2)
            }

            Divider().opacity(0.55)

            HStack(alignment: .center, spacing: 9) {
                Image(systemName: simStateIcon)
                    .font(.appSymbol(.small))
                    .foregroundStyle(simStateColor)
                    .frame(width: 22, height: 22)
                    .background(simStateColor.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(simStatusText)
                        .font(.appCaptionStrong)
                    Text(simDetailText)
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if showsNetworkControls && displayedNetworkMode.isEnabled {
                    Label(networkStateLabel, systemImage: networkStateIcon)
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(networkStateColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(networkStateColor.opacity(0.10), in: Capsule())
                }
            }
        }
        .padding(summaryPadding)
    }

    @ViewBuilder
    private var cardTitleView: some View {
        if let displayedModule {
            Text("\(displayedModule.displayName) · \(operatorName)")
                .font(.appBodyStrong)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(operatorName)
                .font(.appBodyStrong)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.appCaption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.09), in: Capsule())
    }

    @ViewBuilder
    private var networkModeMenu: some View {
        if let resolvedModuleID {
            HStack(spacing: 6) {
                Text("蜂窝网络")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)

                CellularNetworkModeMenu(
                    moduleID: resolvedModuleID,
                    mode: displayedNetworkMode,
                    isChanging: displayedNetworkIsChanging,
                    isEnabled: canChangeNetworkMode,
                    compact: true
                )
                .accessibilityIdentifier("CellularNetworkModeMenu")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var networkDetailPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("蜂窝数据详情", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.appCaption.weight(.semibold))
                Spacer()
                Text(networkStateLabel)
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(networkStateColor)
            }

            Divider()
                .opacity(0.6)
                .padding(.top, 10)

            HStack(alignment: .top, spacing: 12) {
                networkMetric(
                    icon: networkConnectionIcon,
                    tint: networkStateColor,
                    title: networkConnectionTitle,
                    detail: networkConnectionDetail
                )

                Divider().frame(minHeight: 38)

                networkMetric(
                    icon: networkPriorityIcon,
                    tint: isEnablingCellularNetworking
                        ? .blue
                        : networkPriorityColor,
                    title: networkPriorityTitle,
                    detail: networkPriorityDetail
                )
            }
            .padding(.top, 10)

            ExpandableCardSection(
                isExpanded: resolvedModuleID
                    .map(appState.isRecoveringNetworkLink(for:)) ?? false,
                topSpacing: 10
            ) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在重新协商 ECM 链路与 DHCP 地址")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            ExpandableCardSection(
                isExpanded: displayedNetwork.issue?.isWarning == true,
                topSpacing: 10
            ) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: displayedNetwork.issue?.localizedTitle ?? "")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(verbatim: displayedNetwork.issue?.localizedDetail ?? "")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                }
            }

            ExpandableCardSection(
                isExpanded: showsPriorityWarning,
                topSpacing: 10
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundStyle(.orange)
                    Text(L10n.tr("蜂窝网络已开启，但%@目前仍然优先", higherPriorityNetworkName))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("让蜂窝优先") {
                        appState.reapplyCellularNetworkPriorities()
                    }
                    .adaptiveGlassButton()
                    .controlSize(.small)
                    .disabled(displayedNetworkIsChanging)
                }
            }
        }
        .padding(12)
    }

    private var ecmConfigurationNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("当前 usbnet=%@", displayedModem.usbNetMode.map(String.init) ?? L10n.tr("未知")))
                    .font(.appCaption.weight(.semibold))
                Text("macOS 联网需要 CDC‑ECM（usbnet=1）")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                if case .needsECMSwitch = displayedModem.initialSetupState {
                    // The setup window asks for confirmation before it
                    // restarts an RM520N-GL.
                    appState.showInitialSetupWindow()
                } else {
                    appState.configureECM()
                }
            } label: {
                if appState.isConfiguringECM {
                    ProgressView().controlSize(.small)
                } else {
                    Text("切换为 ECM")
                }
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .disabled(appState.isConfiguringECM)
        }
        .adaptiveGlassSurface(
            cornerRadius: 14,
            padding: 10,
            treatment: .clear,
            tint: Color.orange.opacity(0.06)
        )
    }

    private var actionFooter: some View {
        HStack(spacing: 8) {
            if let onOpenMainWindow {
                CellularOverviewActionButton(
                    title: L10n.tr("打开主窗口"),
                    systemImage: "arrow.up.forward.square",
                    accessibilityIdentifier: "OpenMainWindowButton",
                    action: onOpenMainWindow
                )
            }

            if let onOpenATConsole {
                CellularOverviewActionButton(
                    title: L10n.tr("AT 控制台"),
                    systemImage: "terminal",
                    accessibilityIdentifier: "OpenATConsoleButton",
                    action: onOpenATConsole
                )
            }

            if let onRefresh {
                CellularOverviewActionButton(
                    title: L10n.tr("刷新"),
                    systemImage: "arrow.clockwise",
                    accessibilityIdentifier: "RefreshModemButton",
                    action: onRefresh
                )
            }

            if let onOpenSettings {
                CellularOverviewActionButton(
                    title: L10n.tr("设置"),
                    systemImage: "gearshape",
                    accessibilityIdentifier: "OpenSettingsButton",
                    action: onOpenSettings
                )
            }
        }
    }

    private func networkMetric(
        icon: String,
        tint: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appCaptionStrong)
                    .lineLimit(1)
                Text(detail)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var operatorName: String {
        switch displayedModem.operationalState {
        case .ready, .configurationRequired:
            return displayedModem.operatorName ?? L10n.tr("等待运营商")
        case .initializing:
            return L10n.tr("正在识别模组")
        case .restarting:
            return L10n.tr("模组正在重启")
        case .reconnecting:
            return L10n.tr("正在重新连接")
        case .enumerating:
            return L10n.tr("正在等待 USB 接口")
        case .failed:
            return L10n.tr("蜂窝模组异常")
        case .absent:
            return L10n.tr("蜂窝模组")
        }
    }

    private var signalSummary: String {
        switch displayedModem.operationalState {
        case .absent: return L10n.tr("等待插入 QDC507")
        case .enumerating: return L10n.tr("正在等待 USB/AT 接口")
        case .initializing: return L10n.tr("正在初始化模组")
        case .restarting: return L10n.tr("正在等待模组断开并重启")
        case .reconnecting: return L10n.tr("正在恢复 USB/AT 接口")
        case .failed: return L10n.tr("AT 接口异常")
        case .configurationRequired, .ready:
            break
        }
        let parts = [
            displayedModem.accessTechnology,
            displayedModem.signalDBm.map { "\($0) dBm" }
        ].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return displayedModem.operationalState == .configurationRequired
            ? L10n.tr("需要完成模组配置")
            : L10n.tr("正在读取信号")
    }

    private var statusText: String {
        switch displayedModem.operationalState {
        case .absent: return L10n.tr("未连接")
        case .enumerating: return L10n.tr("USB 枚举中")
        case .initializing: return L10n.tr("初始化中")
        case .configurationRequired: return L10n.tr("需要配置")
        case .ready: return L10n.tr("已就绪")
        case .restarting: return L10n.tr("正在重启")
        case .reconnecting: return L10n.tr("重新连接中")
        case .failed: return L10n.tr("异常")
        }
    }

    private var statusColor: Color {
        switch displayedModem.operationalState {
        case .absent: return .gray
        case .enumerating, .initializing, .restarting, .reconnecting: return .blue
        case .configurationRequired: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }

    private var simStatusText: String {
        switch displayedModem.simState {
        case .unavailable: return L10n.tr("等待模组")
        case .initializing: return L10n.tr("SIM 初始化中")
        case .absent: return L10n.tr("未插入 SIM 卡")
        case .pinRequired: return L10n.tr("需要 SIM PIN")
        case .pukRequired: return L10n.tr("需要 SIM PUK")
        case .ready: return L10n.tr("SIM 已就绪")
        case .queryFailed: return L10n.tr("SIM 查询异常")
        }
    }

    private var simDetailText: String {
        switch displayedModem.simState {
        case .unavailable:
            return L10n.tr("连接并初始化模组后读取")
        case .initializing:
            return L10n.tr("正在读取 AT+CPIN?")
        case .absent:
            return L10n.tr("请检查 SIM 卡是否正确插入")
        case .pinRequired:
            return L10n.tr("解锁后才能注册运营商")
        case .pukRequired:
            return L10n.tr("请使用运营商提供的 PUK 解锁")
        case .queryFailed:
            return displayedModem.simLastError ?? L10n.tr("稍后将自动重新查询")
        case .ready:
            break
        }
        if let number = displayedModem.simPhoneNumber {
            if appState.isPresentationPrivacyEnabled {
                return L10n.tr("本机号码已隐藏")
            }
            return L10n.tr("本机号码 %@", formattedPhoneNumber(number))
        }
        if let iccid = displayedModem.simICCID, iccid.count >= 4 {
            if appState.isPresentationPrivacyEnabled {
                return L10n.tr("未提供手机号 · SIM 标识已隐藏")
            }
            return L10n.tr("未提供手机号 · ICCID 尾号 %@", String(iccid.suffix(4)))
        }
        return L10n.tr("SIM 未提供本机号码")
    }

    private var simStateIcon: String {
        switch displayedModem.simState {
        case .ready: return "simcard.fill"
        case .pinRequired, .pukRequired: return "lock.fill"
        case .queryFailed: return "exclamationmark.triangle.fill"
        case .initializing: return "ellipsis"
        case .unavailable, .absent: return "simcard"
        }
    }

    private var simStateColor: Color {
        switch displayedModem.simState {
        case .ready: return .green
        case .initializing: return .blue
        case .pinRequired, .pukRequired: return .orange
        case .queryFailed: return .red
        case .unavailable, .absent: return .secondary
        }
    }

    private func formattedPhoneNumber(_ number: String) -> String {
        let hasChinaPrefix = number.hasPrefix("+86")
        let localNumber = hasChinaPrefix ? String(number.dropFirst(3)) : number
        guard localNumber.count == 11,
              localNumber.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return number
        }
        let first = localNumber.prefix(3)
        let middle = localNumber.dropFirst(3).prefix(4)
        let last = localNumber.suffix(4)
        return (hasChinaPrefix ? "+86 " : "") + "\(first) \(middle) \(last)"
    }

    private var canChangeNetworkMode: Bool {
        displayedNetwork.isEnabled || (
            displayedModem.isConnected
                && displayedModem.usbNetMode == 1
                && displayedNetwork.isHardwarePresent
        )
    }

    private var needsECMConfiguration: Bool {
        displayedModem.isConnected && displayedModem.usbNetMode != 1
    }

    private var showsPriorityWarning: Bool {
        displayedNetworkMode == .preferred
            && displayedNetwork.isEnabled
            && displayedNetwork.isHardwarePresent
            && !displayedNetwork.isPrioritized
    }

    private var networkStateLabel: String {
        switch displayedConnectionState {
        case .disabled: return L10n.tr("已关闭")
        case .waitingForModem: return L10n.tr("等待模组")
        case .starting: return L10n.tr("连接中")
        case .linkDown: return L10n.tr("链路中断")
        case .interfaceReady: return L10n.tr("接口已连接")
        case .available: return L10n.tr("数据可用")
        case .recovering: return L10n.tr("恢复中")
        case .failed: return L10n.tr("连接异常")
        }
    }

    private var networkStateIcon: String {
        switch displayedConnectionState {
        case .disabled: return "power"
        case .waitingForModem, .starting: return "clock.fill"
        case .linkDown: return "exclamationmark.triangle.fill"
        case .interfaceReady: return "network"
        case .available: return "checkmark.circle.fill"
        case .recovering: return "arrow.clockwise.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var networkStateColor: Color {
        switch displayedConnectionState {
        case .disabled: return .secondary
        case .waitingForModem, .starting, .recovering: return .blue
        case .linkDown: return .orange
        case .interfaceReady: return .orange
        case .available: return .green
        case .failed: return .red
        }
    }

    private var networkConnectionIcon: String {
        networkStateIcon
    }

    private var networkConnectionTitle: String {
        switch displayedConnectionState {
        case .disabled: return L10n.tr("蜂窝数据已关闭")
        case .waitingForModem: return L10n.tr("正在等待模组")
        case .starting: return L10n.tr("正在建立数据连接")
        case .linkDown: return L10n.tr("ECM 链路中断")
        case .interfaceReady: return L10n.tr("ECM 接口已连接")
        case .available: return L10n.tr("蜂窝数据可用")
        case .recovering: return L10n.tr("正在恢复蜂窝数据")
        case .failed: return L10n.tr("蜂窝数据连接异常")
        }
    }

    private var networkConnectionDetail: String {
        switch displayedConnectionState {
        case .disabled:
            return L10n.tr("开启后建立 CDC‑ECM 数据连接")
        case .waitingForModem:
            return L10n.tr("模组就绪后自动检查网络接口")
        case .starting:
            return L10n.tr("正在等待 ECM 链路与 DHCP 地址")
        case let .linkDown(isRetrying):
            return isRetrying
                ? L10n.tr("ECM 载波未建立，正在自动重试")
                : L10n.tr("ECM 载波未建立，已停止自动重试；请拔下模组后重新插入")
        case .recovering:
            return L10n.tr("正在重新协商 ECM 链路与 DHCP 地址")
        case .failed:
            return displayedNetwork.lastError ?? L10n.tr("网络恢复后仍未获得有效地址")
        case .available:
            if let address = displayedNetwork.ipv4Address {
                let operatorName = displayedModem.operatorName ?? L10n.tr("蜂窝网络")
                return "\(operatorName) · \(address)"
            }
            return displayedModem.operatorName ?? L10n.tr("蜂窝数据链路可用")
        case .interfaceReady:
            switch displayedModem.simState {
            case .absent: return L10n.tr("ECM 已连接，等待插入 SIM 卡")
            case .pinRequired: return L10n.tr("ECM 已连接，需要 SIM PIN")
            case .pukRequired: return L10n.tr("ECM 已连接，需要 SIM PUK")
            case .initializing, .unavailable, .queryFailed: return L10n.tr("ECM 已连接，正在确认 SIM 状态")
            case .ready:
                return registrationDetailText
            }
        }
    }

    private var registrationDetailText: String {
        switch displayedModem.registrationState {
        case .unavailable: return L10n.tr("ECM 已连接，等待蜂窝注册状态")
        case .notRegistered: return L10n.tr("ECM 已连接，尚未注册运营商")
        case .registered: return L10n.tr("ECM 已连接，正在确认数据链路")
        case .searching: return L10n.tr("ECM 已连接，正在搜索运营商")
        case .denied: return L10n.tr("ECM 已连接，蜂窝注册被拒绝")
        case .unknown: return L10n.tr("ECM 已连接，注册状态未知")
        case .roaming: return L10n.tr("ECM 已连接，正在漫游网络中")
        case .queryFailed: return L10n.tr("ECM 已连接，注册状态查询异常")
        }
    }

    private var networkPriorityTitle: String {
        if isEnablingCellularNetworking { return L10n.tr("正在检查网络优先级") }
        if displayedNetworkMode == .standby {
            if displayedNetwork.isSystemPrimary || displayedNetwork.isPrioritized {
                return L10n.tr("当前没有其他可用网络")
            }
            return L10n.tr("%@保持优先", higherPriorityNetworkName)
        }
        return displayedNetwork.isPrioritized
            ? L10n.tr("蜂窝网络优先")
            : L10n.tr("%@保持优先", higherPriorityNetworkName)
    }

    private var networkPriorityDetail: String {
        if isEnablingCellularNetworking { return L10n.tr("连接建立后自动检查") }
        if displayedNetworkMode == .standby {
            if displayedNetwork.isSystemPrimary || displayedNetwork.isPrioritized {
                return L10n.tr("蜂窝网络可能暂时承载流量")
            }
            return L10n.tr("蜂窝接口保持连接")
        }
        return displayedNetwork.isPrioritized
            ? L10n.tr("已排在其他网络之前")
            : L10n.tr("可切换为蜂窝优先")
    }

    private var higherPriorityNetworkName: String {
        displayedNetwork.higherPriorityServiceName ?? L10n.tr("其他网络")
    }

    private var networkPriorityIcon: String {
        if isEnablingCellularNetworking {
            return "arrow.triangle.swap"
        }
        if displayedNetworkMode == .standby {
            if displayedNetwork.isSystemPrimary || displayedNetwork.isPrioritized {
                return "exclamationmark.triangle.fill"
            }
            return higherPriorityNetworkName == "Wi‑Fi" ? "wifi" : "network"
        }
        if displayedNetwork.isPrioritized {
            return "antenna.radiowaves.left.and.right"
        }
        return higherPriorityNetworkName == "Wi‑Fi" ? "wifi" : "network"
    }

    private var networkPriorityColor: Color {
        if displayedNetworkMode == .standby {
            return displayedNetwork.isSystemPrimary || displayedNetwork.isPrioritized
                ? .orange
                : .blue
        }
        return displayedNetwork.isPrioritized ? .green : .orange
    }

    private var isEnablingCellularNetworking: Bool {
        displayedNetworkMode.isEnabled
            && displayedNetworkIsChanging
            && !displayedNetwork.isEnabled
    }

    private var hasFooterActions: Bool {
        onOpenMainWindow != nil
            || onOpenATConsole != nil
            || onRefresh != nil
            || onOpenSettings != nil
    }

    private var cardSpacing: CGFloat {
        density == .compact ? 10 : 12
    }

    private var cardPadding: CGFloat {
        density == .compact ? 9 : 13
    }

    private var summarySpacing: CGFloat {
        density == .compact ? 8 : 10
    }

    private var summaryPadding: CGFloat {
        density == .compact ? 9 : 12
    }
}

private struct ExpandableCardSection<Content: View>: View {
    let isExpanded: Bool
    let topSpacing: CGFloat
    let content: Content

    init(
        isExpanded: Bool,
        topSpacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.isExpanded = isExpanded
        self.topSpacing = topSpacing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topSpacing)
            content
        }
        .modifier(CurtainRevealModifier(isExpanded: isExpanded))
    }
}

private struct CurtainRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    @State private var naturalHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                if reduceMotion {
                    naturalHeight = newHeight
                } else {
                    withAnimation(.maVoPanelResize) {
                        naturalHeight = newHeight
                    }
                }
            }
            .frame(height: isExpanded ? naturalHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(reduceMotion ? nil : .maVoPanelResize, value: isExpanded)
    }
}

private struct CellularOverviewActionButton: View {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.appCaptionStrong)
                .frame(maxWidth: .infinity)
        }
        .adaptiveGlassButton()
        .controlSize(.small)
        .help(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct CellularSignalBars: View {
    let bars: Int
    let active: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(1 ... 4, id: \.self) { index in
                Capsule()
                    .fill(index <= bars && active ? Color.green : Color.secondary.opacity(0.18))
                    .frame(width: 7, height: CGFloat(8 + index * 6))
            }
        }
        .accessibilityLabel(L10n.tr("信号 %lld 格", Int64(bars)))
    }
}
