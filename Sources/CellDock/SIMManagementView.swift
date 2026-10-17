import AppKit
import CellDockNetworkIPC
import SwiftUI

struct SIMManagementView: View {
    private enum Pane: Hashable {
        case overview
        case sim
        case esim
        case module
        case terminal

        var title: String {
            switch self {
            case .overview: return L10n.tr("概览")
            case .sim: return L10n.tr("SIM 卡信息")
            case .esim: return "eSIM"
            case .module: return L10n.tr("模块信息")
            case .terminal: return L10n.tr("AT 终端")
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @Binding var sidebarWidth: CGFloat
    let requestedModuleID: CellularModuleID?
    let moduleRequestSerial: Int
    var focusFirstItemRequest = false
    var didHandleFocusFirstItemRequest: () -> Void = {}
    @State private var selectedModuleID: CellularModuleID?
    @State private var handledModuleRequestSerial = 0
    @State private var selection: Pane = .overview
    @State private var copiedField: String?
    @State private var pendingIncomingCallsEnabled: Bool?
    @State private var showingAddESIM = false
    @State private var renamingProfile: ESIMProfile?
    @State private var deletingProfile: ESIMProfile?
    @State private var isInternetModulePopoverPresented = false
    @State private var isConfirmingCloseAllCellularNetworks = false
    @State private var overviewThroughput = NetworkThroughput.zero
    @State private var previousOverviewCounters: NetworkInterfaceByteCounters?
    @FocusState private var listFocused: Bool

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            if !applyRequestedModuleSelection() {
                reconcileModuleSelection()
            }
            appState.refresh()
            handleFocusFirstItemRequest()
        }
        .onChange(of: moduleRequestSerial) { _, _ in
            _ = applyRequestedModuleSelection()
        }
        .onChange(of: focusFirstItemRequest) { _, requested in
            if requested { handleFocusFirstItemRequest() }
        }
        .onChange(of: appState.cellularModules.map(\.id)) { _, _ in
            if !applyRequestedModuleSelection() {
                reconcileModuleSelection()
            }
        }
        .onChange(of: selectedEUICC.cardKind) { _, cardKind in
            if cardKind != .eUICC, selection == .esim { selection = .sim }
        }
        .task(id: selectedModuleID) {
            previousOverviewCounters = nil
            overviewThroughput = .zero
            while !Task.isCancelled {
                refreshOverviewThroughput()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $showingAddESIM) {
            AddESIMProfileSheet { activationCode, confirmationCode in
                appState.downloadESIMProfile(
                    activationCode: activationCode,
                    confirmationCode: confirmationCode,
                    moduleID: selectedModuleID
                )
            }
        }
        .sheet(item: $renamingProfile) { profile in
            RenameESIMProfileSheet(profile: profile) { nickname in
                appState.renameESIMProfile(
                    profile,
                    nickname: nickname,
                    moduleID: selectedModuleID
                )
            }
        }
        .alert(
            "删除 eSIM 套餐？",
            isPresented: Binding(
                get: { deletingProfile != nil },
                set: { if !$0 { deletingProfile = nil } }
            ),
            presenting: deletingProfile
        ) { profile in
            Button("取消", role: .cancel) { deletingProfile = nil }
            Button("删除", role: .destructive) {
                deletingProfile = nil
                appState.deleteESIMProfile(profile, moduleID: selectedModuleID)
            }
        } message: { profile in
            Text(L10n.tr(
                "“%@”将从此 eUICC 永久移除，之后需要重新下载才能使用。",
                profile.displayName
            ))
        }
        .alert(
            pendingIncomingCallsEnabled == true ? L10n.tr("开启接收来电？") : L10n.tr("关闭接收来电？"),
            isPresented: Binding(
                get: { pendingIncomingCallsEnabled != nil },
                set: { if !$0 { pendingIncomingCallsEnabled = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingIncomingCallsEnabled = nil }
            Button(
                pendingIncomingCallsEnabled == true ? L10n.tr("重启并开启") : L10n.tr("重启并关闭"),
                role: pendingIncomingCallsEnabled == false ? .destructive : nil
            ) {
                guard let enabled = pendingIncomingCallsEnabled else { return }
                pendingIncomingCallsEnabled = nil
                appState.setIncomingCallsEnabled(enabled, moduleID: selectedModuleID)
            }
        } message: {
            Text(L10n.tr("CellDock 会在%@中写入并回读 IMS=%lld，校验成功后再重启模块。蜂窝网络将短暂中断。", selectedModule?.displayName ?? L10n.tr("当前模组"), Int64(pendingIncomingCallsEnabled == true ? 1 : 0)))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SIM 管理")
                        .font(.title2.weight(.bold))
                    Text(L10n.tr("%lld 个模组已连接", Int64(connectedModuleCount)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    appState.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .adaptiveGlassButton()
                .buttonBorderShape(.circle)
                .disabled(appState.isChangingNetwork || selectedEUICC.isBusy)
                .help(L10n.tr("重新扫描并刷新模组状态"))
                .accessibilityLabel(L10n.tr("刷新模组"))

                Button {
                    isInternetModulePopoverPresented.toggle()
                } label: {
                    if appState.isChangingNetwork {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "globe")
                            .frame(width: 16, height: 16)
                            .foregroundStyle(internetGlobeColor)
                    }
                }
                .adaptiveGlassButton()
                .buttonBorderShape(.circle)
                .disabled(appState.cellularModules.isEmpty || appState.isChangingNetwork)
                .popover(
                    isPresented: $isInternetModulePopoverPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    internetModulePopover
                }
                .help(L10n.tr("蜂窝网络选择"))
                .accessibilityLabel(L10n.tr("蜂窝网络选择"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider()

            if appState.cellularModules.isEmpty {
                ContentUnavailableView(
                    "未发现蜂窝模组",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("连接设备后，CellDock 会自动识别。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(appState.cellularModules) { module in
                            SIMModuleSidebarRow(
                                module: module,
                                hidesSensitiveIdentifiers: appState.isPresentationPrivacyEnabled,
                                showsCurrentInternetTag: module.isPrimaryData,
                                showsIncomingCallsTag: module.modem.imsMode.map { $0 != 0 } ?? false,
                                showsESIMTag: module.cardKind == .eUICC
                            )
                            .communicationSelectionHighlight(selectedModuleID == module.id)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedModuleID = module.id }
                            .accessibilityAddTraits(selectedModuleID == module.id ? .isSelected : [])
                            .id(module.id)
                            .tag(module.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .communicationEmphasizedSelection()
                    .communicationInitialListFocus($listFocused)
                    .scrollContentBackground(.hidden)
                    .communicationSidebarScrollEdgeEffect()
                    .onAppear { scrollToRequestedModule(using: proxy) }
                    .onChange(of: moduleRequestSerial) { _, _ in
                        scrollToRequestedModule(using: proxy)
                    }
                    .onChange(of: appState.cellularModules.map(\.id)) { _, _ in
                        scrollToRequestedModule(using: proxy)
                    }
                }
            }
        }
        .communicationSidebarColumnStyle()
    }

    private var detail: some View {
        Group {
            if selectedModule != nil {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            moduleDetailHeader
                            detailTabs
                            tabContent(availableHeight: proxy.size.height)
                        }
                        .frame(width: max(0, proxy.size.width - 44))
                        .padding(22)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            } else {
                ContentUnavailableView(
                    "连接一个蜂窝模组",
                    systemImage: "simcard",
                    description: Text("识别成功后，可在这里管理 SIM、网络和模组设置。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .communicationDetailColumnStyle()
    }

    private var internetModulePopover: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("蜂窝网络选择"))
                    .font(.headline)
                Text(verbatim: L10n.tr("一个模组可设为蜂窝优先，多个模组可以保持连接。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)

            Divider()

            VStack(spacing: 3) {
                ForEach(appState.cellularModules) { module in
                    internetModuleRow(module)
                }
            }
            .padding(6)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: L10n.tr("实时网速"))
                        .font(.callout.weight(.medium))
                    Text(verbatim: L10n.tr("蜂窝网络开启后在菜单栏显示下载与上传速度"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle(isOn: Binding(
                    get: { appState.showsMenuBarNetworkSpeed },
                    set: { appState.setShowsMenuBarNetworkSpeed($0) }
                )) {
                    Text(verbatim: L10n.tr("实时网速"))
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(6)

            Divider()

            Button {
                isConfirmingCloseAllCellularNetworks = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe.slash")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(verbatim: L10n.tr("完全关闭所有模组"))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.isChangingNetwork || !appState.hasEnabledCellularModule)
            .padding(6)
            .confirmationDialog(
                L10n.tr("完全关闭所有蜂窝模组？"),
                isPresented: $isConfirmingCloseAllCellularNetworks,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("完全关闭所有模组"), role: .destructive) {
                    isInternetModulePopoverPresented = false
                    appState.closeAllCellularNetworks()
                }
                Button(L10n.tr("取消"), role: .cancel) {}
            } message: {
                Text(verbatim: L10n.tr(
                    "将停用 %lld 个模组的蜂窝网络服务，并恢复原有的网络服务顺序。",
                    Int64(appState.enabledCellularModuleCount)
                ))
            }
        }
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func internetModuleRow(_ module: CellularModuleSummary) -> some View {
        let mode = appState.networkMode(for: module.id)
        return HStack(spacing: 11) {
            SIMSignalBars(
                bars: module.modem.signalBars,
                active: module.isDataEligible
            )
            .frame(width: 28, height: 32)
            .foregroundStyle(mode.isEnabled ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(module.displayName) · \(module.carrierName)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let issue = appState.networkStatus(for: module.id).issue, issue.isWarning {
                    Label(issue.localizedTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .help(issue.localizedDetail)
                } else {
                    Text(verbatim: internetModuleDetail(module))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            CellularNetworkModeMenu(
                moduleID: module.id,
                mode: mode,
                isChanging: appState.isChangingNetworkMode(for: module.id),
                isEnabled: module.isDataEligible || mode.isEnabled,
                compact: true
            )
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(mode.isEnabled ? Color.accentColor.opacity(0.07) : Color.clear)
        }
        .help(module.isDataEligible ? mode.localizedDetail : L10n.tr("SIM 或 ECM 接口尚未就绪"))
        .accessibilityLabel(L10n.tr("%@，%@", module.accessibilitySummary, mode.localizedTitle))
    }

    private func internetModuleDetail(_ module: CellularModuleSummary) -> String {
        var parts: [String] = []
        if let technology = module.technologyName { parts.append(technology) }
        if let signal = module.modem.signalDBm { parts.append("\(signal) dBm") }
        if !module.isDataEligible { parts.append(module.statusText) }
        return parts.isEmpty ? L10n.tr("正在读取网络状态") : parts.joined(separator: " · ")
    }

    private var internetGlobeColor: Color {
        if appState.isChangingNetwork { return .blue }
        if appState.hasCellularNetworkConfigurationIssue { return .orange }
        if appState.cellularModules.contains(where: {
            appState.networkMode(for: $0.id) == .preferred
        }) { return .green }
        if appState.cellularModules.contains(where: {
            appState.networkMode(for: $0.id) == .standby
        }) { return .blue }
        return .secondary
    }

    private var moduleDetailHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("%@ · %@", selectedModule?.displayName ?? L10n.tr("模组"), selectedModule?.carrierName ?? L10n.tr("运营商未识别")))
                    .font(.title2.weight(.bold))
                    .lineLimit(1)

                Text(moduleHeaderSubtitle)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 7) {
                Circle()
                    .fill(moduleStatusColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)

                if selectedModule?.isPrimaryData == true {
                    ModuleRoleBadge(title: "主上网", tint: .blue)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(selectedModule?.accessibilitySummary ?? L10n.tr("模组详情"))
    }

    private var detailTabs: some View {
        CommunicationGlassTabs(
            items: detailTabItems,
            selection: $selection
        )
        .accessibilityIdentifier("SIMManagementDetailTabs")
    }

    private var detailTabItems: [(Pane, String)] {
        var items: [(Pane, String)] = [
            (.overview, Pane.overview.title),
            (.sim, Pane.sim.title)
        ]
        if selectedEUICC.cardKind == .eUICC {
            items.append((.esim, Pane.esim.title))
        }
        items.append((.module, Pane.module.title))
        items.append((.terminal, Pane.terminal.title))
        return items
    }

    @ViewBuilder
    private func tabContent(availableHeight: CGFloat) -> some View {
        if selection == .terminal {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    L10n.tr("命令目标：%@", selectedModule?.displayName ?? L10n.tr("当前模组")),
                    systemImage: "scope"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                ATConsoleView(
                    embedded: true,
                    targetModuleID: selectedModuleID
                )
                    .frame(height: max(360, availableHeight - 140))
            }
            .transition(.opacity)
        } else {
            VStack(spacing: 12) {
                LazyVStack(spacing: 14) {
                    if selection == .overview {
                        overviewConnectionCard
                        overviewCommunicationCard
                        overviewSIMCard
                        overviewDeviceInformationCard
                    } else if selection == .sim {
                        simConnectionCard
                        basicInformationCard
                        identifierCard
                        serviceCard
                    } else if selection == .esim {
                        esimOverviewCard
                        esimProfilesCard
                    } else {
                        moduleInformationCard
                    }
                }
                .frame(maxWidth: .infinity)

                if appState.transientMessage != nil {
                    detailFooter
                }
            }
            .transition(.opacity)
        }
    }

    private var selectedModule: CellularModuleSummary? {
        if let selectedModuleID,
           let module = appState.cellularModules.first(where: { $0.id == selectedModuleID }) {
            return module
        }
        return appState.cellularModules.first
    }

    private var selectedModem: ModemSnapshot {
        selectedModule?.modem ?? appState.modem
    }

    private var selectedNetwork: CellularNetworkStatus {
        selectedModuleID.map(appState.networkStatus(for:)) ?? appState.network
    }

    private var selectedNetworkMode: CellularNetworkMode {
        selectedModuleID.map(appState.networkMode(for:)) ?? .off
    }

    private var selectedConnectionState: CellularDataConnectionState {
        CellularDataConnectionPolicy.state(
            modem: selectedModem,
            network: selectedNetwork,
            isPresentedEnabled: selectedNetworkMode.isEnabled,
            isChangingNetwork: selectedModuleID.map(appState.isChangingNetworkMode(for:)) ?? false,
            isRecovering: selectedModuleID
                .map(appState.isRecoveringNetworkLink(for:)) ?? false,
            isRetryingLink: selectedModuleID
                .map(appState.isRetryingCellularLink(for:)) ?? true
        )
    }

    private var selectedEUICC: EUICCSnapshot {
        appState.euiccSnapshot(for: selectedModuleID)
    }

    private var connectedModuleCount: Int {
        appState.cellularModules.lazy.filter { $0.modem.isConnected }.count
    }

    private var moduleHeaderSubtitle: String {
        guard let module = selectedModule else { return L10n.tr("未连接") }
        var parts = [module.statusText]
        if let technology = module.technologyName { parts.append(technology) }
        if let signal = module.modem.signalDBm { parts.append("\(signal) dBm") }
        return parts.joined(separator: " · ")
    }

    private func reconcileModuleSelection() {
        selectedModuleID = CellularModuleSelectionPolicy.reconciledManagementSelection(
            current: selectedModuleID,
            available: appState.cellularModules.map(\.id)
        )
    }

    @discardableResult
    private func applyRequestedModuleSelection() -> Bool {
        guard moduleRequestSerial > 0,
              moduleRequestSerial != handledModuleRequestSerial,
              let requestedModuleID,
              appState.cellularModules.contains(where: { $0.id == requestedModuleID }) else {
            return false
        }
        selectedModuleID = requestedModuleID
        selection = .overview
        handledModuleRequestSerial = moduleRequestSerial
        return true
    }

    private func scrollToRequestedModule(using proxy: ScrollViewProxy) {
        guard moduleRequestSerial > 0,
              let requestedModuleID,
              appState.cellularModules.contains(where: { $0.id == requestedModuleID }) else {
            return
        }
        DispatchQueue.main.async {
            proxy.scrollTo(requestedModuleID, anchor: .center)
        }
    }

    private func handleFocusFirstItemRequest() {
        guard focusFirstItemRequest else { return }
        selectedModuleID = appState.cellularModules.first?.id
        didHandleFocusFirstItemRequest()
        listFocused = false
        DispatchQueue.main.async {
            listFocused = true
        }
    }

    private var detailFooter: some View {
        HStack(spacing: 10) {
            if let message = appState.transientMessage {
                Label(
                    message,
                    systemImage: appState.transientIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(appState.transientIsError ? Color.red : Color.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var esimOverviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "simcard.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("板载 eUICC")
                            .font(.headline)
                        Text("已识别")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Text("通过 ISD-R 逻辑通道识别，可管理已安装的运营商套餐")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if selectedEUICC.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text("EID")
                    .font(.callout)
                Spacer()
                Text(maskedIdentifier(selectedEUICC.eid, prefixCount: 6, suffixCount: 6))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    if let eid = selectedEUICC.eid { copy(eid, field: "EID") }
                } label: {
                    Image(systemName: copiedField == "EID" ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedEUICC.eid == nil || appState.isPresentationPrivacyEnabled)
                .help(L10n.tr("复制完整 EID"))
            }
        }
        .adaptiveGlassCard()
    }

    private var esimProfilesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("eSIM 套餐")
                        .font(.headline)
                    Text(L10n.tr(
                        "已安装 %lld 个套餐",
                        Int64(selectedEUICC.profiles.count)
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingAddESIM = true
                } label: {
                    Label("添加 eSIM", systemImage: "plus")
                }
                .adaptiveGlassButton(.prominent)
                .disabled(selectedEUICC.isBusy || appState.moduleHasCall(selectedModuleID))
                .accessibilityIdentifier("SIMManagementAddESIMButton")
            }

            if selectedEUICC.profiles.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "simcard")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("尚未安装 eSIM 套餐")
                        .font(.callout.weight(.medium))
                    Text("使用运营商提供的二维码或激活码添加套餐")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selectedEUICC.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider() }
                        esimProfileRow(profile)
                    }
                }
            }
        }
        .adaptiveGlassCard()
    }

    private func esimProfileRow(_ profile: ESIMProfile) -> some View {
        HStack(spacing: 13) {
            Image(systemName: profile.isEnabled ? "antenna.radiowaves.left.and.right" : "simcard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(profile.isEnabled ? Color.green : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    (profile.isEnabled ? Color.green : Color.secondary).opacity(0.10),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.callout.weight(.semibold))
                Text(profile.serviceProviderName ?? L10n.tr("运营商信息未提供"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(maskedIdentifier(profile.iccid, prefixCount: 4, suffixCount: 4))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if let switchingLabel = switchingLabel(for: profile) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(switchingLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else if profile.isEnabled {
                Text("使用中")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.10), in: Capsule())
            } else {
                Text("已停用")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button(profile.isEnabled ? L10n.tr("停用套餐") : L10n.tr("启用套餐")) {
                    if profile.isEnabled {
                        appState.disableESIMProfile(profile, moduleID: selectedModuleID)
                    } else {
                        appState.enableESIMProfile(profile, moduleID: selectedModuleID)
                    }
                }
                Button("重命名") { renamingProfile = profile }
                Divider()
                Button("删除套餐", role: .destructive) { deletingProfile = profile }
                    .disabled(profile.isEnabled)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(selectedEUICC.isBusy || appState.moduleHasCall(selectedModuleID))
            .help(profile.isEnabled ? L10n.tr("管理套餐；使用中的套餐需先停用才能删除") : L10n.tr("管理套餐"))
        }
        .padding(.vertical, 11)
    }

    private func switchingLabel(for profile: ESIMProfile) -> String? {
        switch selectedEUICC.operation {
        case .enabling(profile.iccid): return L10n.tr("正在启用…")
        case .disabling(profile.iccid): return L10n.tr("正在停用…")
        default: return nil
        }
    }

    private var overviewConnectionCard: some View {
        ViewThatFits(in: .horizontal) {
            overviewConnectionRegularLayout
            overviewConnectionCompactLayout
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassCard()
    }

    private var overviewConnectionRegularLayout: some View {
        HStack(spacing: 18) {
            HStack(spacing: 18) {
                overviewModuleIcon
                    .frame(width: 36, height: 68)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 5) {
                    Text("蜂窝连接")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(networkStateText)
                        .font(.title2.weight(.bold))
                    Text(overviewConnectionDetail)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 66)

            VStack(spacing: 8) {
                overviewSpeedMetric(
                    title: NetworkSpeedFormatter.menuBarLines(overviewThroughput).download,
                    systemImage: "arrow.down",
                    tint: .blue
                )
                overviewSpeedMetric(
                    title: NetworkSpeedFormatter.menuBarLines(overviewThroughput).upload,
                    systemImage: "arrow.up",
                    tint: .green
                )
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .center)
            .layoutPriority(1)

            Divider().frame(height: 66)

            VStack(alignment: .leading, spacing: 5) {
                Text("蜂窝网络模式")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                CellularNetworkModeMenu(
                    moduleID: selectedModuleID ?? .compatibilityPrimary,
                    mode: overviewCellularNetworkMode,
                    isChanging: appState.isChangingNetwork,
                    isEnabled: canChangeOverviewCellularData
                )
                .accessibilityIdentifier("SIMManagementOverviewCellularNetworkModeMenu")

                Text(overviewCellularNetworkMode.localizedDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 190, alignment: .leading)
        }
        // Preserve the natural minimum width so ViewThatFits selects the
        // compact layout instead of letting this row overflow a narrow detail.
        .fixedSize(horizontal: true, vertical: false)
    }

    private var overviewConnectionCompactLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                overviewModuleIcon
                    .frame(width: 28, height: 52)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("蜂窝连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(overviewConnectionDetail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Text(networkStateText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(networkStateColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(networkStateColor.opacity(0.10), in: Capsule())
                    .fixedSize()
            }

            Divider()

            HStack(spacing: 8) {
                overviewSpeedMetric(
                    title: NetworkSpeedFormatter.menuBarLines(overviewThroughput).download,
                    systemImage: "arrow.down",
                    tint: .blue
                )
                overviewSpeedMetric(
                    title: NetworkSpeedFormatter.menuBarLines(overviewThroughput).upload,
                    systemImage: "arrow.up",
                    tint: .green
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text("蜂窝网络模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    CellularNetworkModeMenu(
                        moduleID: selectedModuleID ?? .compatibilityPrimary,
                        mode: overviewCellularNetworkMode,
                        isChanging: appState.isChangingNetwork,
                        isEnabled: canChangeOverviewCellularData
                    )
                    .accessibilityIdentifier("SIMManagementOverviewCellularNetworkModeMenu")
                }

                Text(overviewCellularNetworkMode.localizedDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var overviewModuleIcon: some View {
        if let url = Bundle.main.url(
            forResource: "celldock-module-vertical",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "externaldrive.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(networkStateColor)
                .padding(7)
                .accessibilityHidden(true)
        }
    }

    private func overviewSpeedMetric(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title.replacingOccurrences(of: systemImage == "arrow.down" ? "↓ " : "↑ ", with: ""))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 110, maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var overviewCommunicationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("通信服务", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 10)

            Divider()
            incomingCallsRow
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "message.fill")
                    .foregroundStyle(messageServiceColor)
                    .frame(width: 38, height: 38)
                    .background(messageServiceColor.opacity(0.10), in: Circle())
                Text("短信服务").font(.headline)
                Spacer()
                Text(messageServiceText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(messageServiceColor)
            }
            .padding(.vertical, 12)

            Label(
                L10n.tr("更改接收来电设置后将重启%@。", selectedModule?.displayName ?? L10n.tr("当前模组")),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .adaptiveGlassCard()
    }

    private var overviewSIMCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("SIM 卡", systemImage: "simcard.fill")
                    .font(.headline)
                Spacer()
                Button("查看详情") { selection = .sim }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            Divider()

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedModule?.carrierName ?? L10n.tr("运营商未识别"))
                        .font(.title3.weight(.semibold))
                    Text(displayedPhoneNumber)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)

                HStack(spacing: 8) {
                    overviewTag(selectedModule?.technologyName ?? L10n.tr("尚未读取"))
                    overviewTag("SIM 1")
                    overviewTag("ICCID \(quickICCIDValue)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassCard()
    }

    private func overviewTag(_ title: String) -> some View {
        Text(title)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var overviewDeviceInformationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("设备信息", systemImage: "info.circle")
                .font(.headline)

            HStack(spacing: 0) {
                overviewDeviceMetric(
                    icon: "cable.connector",
                    title: "USB",
                    value: selectedModem.usbIdentity ?? L10n.tr("尚未读取")
                )
                Divider().frame(height: 42)
                overviewDeviceMetric(
                    icon: "globe",
                    title: "联网模式",
                    value: selectedModem.usbNetMode == 1 ? "CDC‑ECM" : L10n.tr("需要配置")
                )
                Divider().frame(height: 42)
                overviewDeviceMetric(
                    icon: "terminal",
                    title: "AT 接口",
                    value: selectedModem.isConnected ? L10n.tr("已连接") : L10n.tr("未连接"),
                    valueColor: selectedModem.isConnected ? .green : .secondary
                )
                Divider().frame(height: 42)
                overviewDeviceMetric(
                    icon: "cpu",
                    title: "模块状态",
                    value: moduleStatusText,
                    valueColor: moduleStatusColor
                )
            }
        }
        .adaptiveGlassCard()
    }

    private func overviewDeviceMetric(
        icon: String,
        title: String,
        value: String,
        valueColor: Color = .secondary
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var overviewCellularNetworkMode: CellularNetworkMode {
        selectedNetworkMode
    }

    private var canChangeOverviewCellularData: Bool {
        selectedModule?.isDataEligible == true && !appState.isChangingNetwork
    }

    private var overviewConnectionDetail: String {
        [selectedModule?.technologyName, selectedNetwork.ipv4Address]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var messageServiceColor: Color {
        selectedModem.simReady && selectedModem.registrationState.hasService ? .green : .secondary
    }

    private func refreshOverviewThroughput() {
        guard let interfaceName = selectedNetwork.bsdName,
              let current = NetworkInterfaceCounterReader.read(interfaceName: interfaceName) else {
            previousOverviewCounters = nil
            overviewThroughput = .zero
            return
        }
        if let previousOverviewCounters,
           let rates = NetworkThroughputCalculator.rates(
               previous: previousOverviewCounters,
               current: current
           ) {
            overviewThroughput = rates
        }
        previousOverviewCounters = current
    }

    private var cellularServiceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("蜂窝服务")
                .font(.headline)
                .padding(.bottom, 12)

            Divider()
            networkStatusRow
            Divider()
            incomingCallsRow

            Label(
                L10n.tr("更改接收来电设置后将重启%@。", selectedModule?.displayName ?? L10n.tr("当前模组")),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        .adaptiveGlassCard()
    }

    private var simQuickInformationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SIM 卡")
                    .font(.headline)
                Spacer()
                Button("查看详情") { selection = .sim }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.bottom, 12)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                simQuickInformationColumn(title: "号码", value: displayedPhoneNumber)
                Divider().frame(height: 42)
                simQuickInformationColumn(
                    title: "运营商",
                    value: selectedModule?.carrierName ?? L10n.tr("尚未读取")
                )
                Divider().frame(height: 42)
                simQuickInformationColumn(
                    title: "网络",
                    value: selectedModule?.technologyName ?? L10n.tr("尚未读取")
                )
                Divider().frame(height: 42)
                simQuickInformationColumn(title: "ICCID", value: quickICCIDValue)
            }
            .padding(.top, 12)
        }
        .adaptiveGlassCard()
    }

    private func simQuickInformationColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var quickICCIDValue: String {
        guard !appState.isPresentationPrivacyEnabled else {
            return selectedModem.simICCID == nil ? L10n.tr("尚未读取") : L10n.tr("标识已隐藏")
        }
        guard let suffix = selectedModule?.simSuffix else { return L10n.tr("尚未读取") }
        return "•••• \(suffix)"
    }

    private var networkStatusRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(networkStateColor)
                .frame(width: 38, height: 38)
                .background(networkStateColor.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("蜂窝数据")
                        .font(.headline)
                    Text(networkStateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(networkStateColor)
                }
                Text(networkDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let issue = selectedNetwork.issue {
                    Label(
                        issue.localizedDetail,
                        systemImage: issue.isWarning
                            ? "exclamationmark.triangle.fill"
                            : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(issue.isWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            if selectedModuleID.map(appState.isChangingNetworkMode(for:)) == true {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 12)
    }

    private var incomingCallsRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "phone.arrow.down.left")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(incomingCallStateColor)
                .frame(width: 38, height: 38)
                .background(incomingCallStateColor.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("接收来电")
                        .font(.headline)

                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help(incomingCallsHelpText)
                        .accessibilityLabel(L10n.tr("接收来电设置说明"))
                        .accessibilityHint(incomingCallsHelpText)

                    Text(incomingCallStateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(incomingCallStateColor)
                }

                Text(incomingCallDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if appState.isChangingIncomingCallSetting {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("开启接收来电", isOn: incomingCallsBinding)
                .labelsHidden()
                .toggleStyle(.adaptiveGlass)
                .disabled(!canChangeIncomingCalls)
                .accessibilityIdentifier("SIMManagementIncomingCallsToggle")
                .help(L10n.tr("控制模块是否接收运营商来电"))
        }
        .padding(.vertical, 12)
    }

    private var incomingCallsBinding: Binding<Bool> {
        Binding(
            get: {
                pendingIncomingCallsEnabled ??
                    selectedModem.imsMode.map { $0 != 0 } ?? false
            },
            set: { pendingIncomingCallsEnabled = $0 }
        )
    }

    private var canChangeIncomingCalls: Bool {
        selectedModem.isConnected &&
            selectedModem.imsMode != nil &&
            !appState.moduleHasCall(selectedModuleID) &&
            !selectedEUICC.isBusy &&
            !appState.isChangingIncomingCallSetting
    }

    private var incomingCallDetail: String {
        guard selectedModem.isConnected else { return L10n.tr("模块就绪后可配置接收来电") }
        guard !appState.moduleHasCall(selectedModuleID) else { return L10n.tr("通话期间不可更改") }
        guard !selectedEUICC.isBusy else { return L10n.tr("eSIM 操作期间不可更改") }
        guard let mode = selectedModem.imsMode else { return L10n.tr("正在读取模块 IMS 状态") }
        return mode == 0 ? L10n.tr("模块不会接收运营商来电") : L10n.tr("允许模块接收运营商来电")
    }

    private var incomingCallStateText: String {
        if appState.isChangingIncomingCallSetting { return L10n.tr("更新中") }
        guard selectedModem.isConnected else { return L10n.tr("等待模块") }
        guard let mode = selectedModem.imsMode else { return L10n.tr("读取中") }
        return "IMS=\(mode)"
    }

    private var incomingCallStateColor: Color {
        if appState.isChangingIncomingCallSetting { return .blue }
        guard selectedModem.isConnected else { return .secondary }
        guard let mode = selectedModem.imsMode else { return .blue }
        return mode == 0 ? .secondary : .green
    }

    private var incomingCallsHelpText: String {
        L10n.tr("更改此设置时模块会重启，蜂窝网络将短暂中断。")
    }

    private var simConnectionCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(simStateColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(simStateText)
                    .font(.headline)
                Text(connectionDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SIMSignalBars(
                bars: selectedModem.signalBars,
                active: hasSelectedSignalInformation,
                tint: hasSelectedSignalInformation ? .green : .secondary
            )
            .frame(width: 52, height: 34)
            .help(selectedSignalDescription)
            .accessibilityLabel(selectedSignalDescription)
        }
        .adaptiveGlassCard()
    }

    private var basicInformationCard: some View {
        VStack(spacing: 0) {
            informationRow(title: "电话号码", value: displayedPhoneNumber)
            Divider()
            informationRow(title: "运营商", value: selectedModem.operatorName ?? L10n.tr("尚未读取"))
            Divider()
            informationRow(title: "卡槽", value: "SIM 1")
            Divider()
            informationRow(title: "网络类型", value: selectedModem.accessTechnology ?? L10n.tr("尚未读取"))
        }
        .adaptiveGlassCard()
    }

    private var identifierCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SIM 标识")
                .font(.headline)
                .padding(.bottom, 10)

            identifierRow(
                title: "ICCID",
                value: selectedModem.simICCID,
                maskedValue: maskedIdentifier(selectedModem.simICCID, prefixCount: 4, suffixCount: 4)
            )

            Divider()

            identifierRow(
                title: "IMSI",
                value: selectedModem.simIMSI,
                maskedValue: maskedIdentifier(selectedModem.simIMSI, prefixCount: 5, suffixCount: 4)
            )
        }
        .adaptiveGlassCard()
    }

    private var serviceCard: some View {
        VStack(spacing: 0) {
            informationRow(title: "SIM 状态", value: simStateText, valueColor: simStateColor)
            Divider()
            informationRow(title: "数据服务", value: dataServiceText, valueColor: dataServiceColor)
            Divider()
            informationRow(title: "运营商语音服务", value: voiceServiceText, valueColor: voiceServiceColor)
            Divider()
            informationRow(title: "短信服务", value: messageServiceText)
        }
        .adaptiveGlassCard()
    }

    private var moduleInformationCard: some View {
        VStack(spacing: 0) {
            informationRow(title: "模块状态", value: moduleStatusText, valueColor: moduleStatusColor)
            Divider()
            informationRow(title: "USB 标识", value: selectedModem.usbIdentity ?? L10n.tr("尚未读取"))
            Divider()
            informationRow(title: "USB 厂商", value: selectedModem.usbVendorName ?? L10n.tr("尚未读取"))
            Divider()
            informationRow(title: "USB 产品", value: selectedModem.usbProductName ?? L10n.tr("尚未读取"))
            Divider()
            informationRow(title: "设备类型", value: hardwareFamilyText)
            Divider()
            informationRow(title: "固件版本", value: selectedModem.firmwareVersion ?? L10n.tr("尚未读取"))
            Divider()
            informationRow(
                title: "语音硬件能力",
                value: voiceCapabilityText,
                valueColor: voiceCapabilityColor
            )
            Divider()
            informationRow(title: "语音实现", value: voiceBackendText)
            Divider()
            informationRow(
                title: "联网模式",
                value: selectedModem.usbNetMode == 1 ? "CDC‑ECM" : L10n.tr("需要配置")
            )
            Divider()
            informationRow(
                title: "网络接口",
                value: selectedNetwork.bsdName ?? L10n.tr("尚未创建")
            )
            Divider()
            informationRow(title: "AT 接口", value: selectedModem.endpointDescription ?? L10n.tr("尚未读取"))
        }
        .adaptiveGlassCard()
    }

    private func informationRow(
        title: String,
        value: String,
        valueColor: Color = .secondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(L10n.tr(title))
                .foregroundStyle(.primary)
            Spacer(minLength: 20)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 9)
    }

    private func identifierRow(
        title: String,
        value: String?,
        maskedValue: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(L10n.tr(title))
                .font(.callout)

            Spacer()

            Text(maskedValue)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Button {
                guard let value else { return }
                copy(value, field: title)
            } label: {
                Image(systemName: copiedField == title ? "checkmark" : "doc.on.doc")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(value == nil ? Color.secondary.opacity(0.45) : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(value == nil || appState.isPresentationPrivacyEnabled)
            .help(identifierCopyHelp(title: title, value: value))
            .accessibilityLabel(identifierCopyHelp(title: title, value: value))
        }
        .padding(.vertical, 9)
    }

    private func copy(_ value: String, field: String) {
        guard !appState.isPresentationPrivacyEnabled else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedField == field {
                copiedField = nil
            }
        }
    }

    private func maskedIdentifier(
        _ value: String?,
        prefixCount: Int,
        suffixCount: Int
    ) -> String {
        if appState.isPresentationPrivacyEnabled {
            return value == nil ? L10n.tr("尚未读取") : L10n.tr("标识已隐藏")
        }
        guard let value, value.count > prefixCount + suffixCount else {
            return L10n.tr("尚未读取")
        }
        return "\(value.prefix(prefixCount)) •••• •••• \(value.suffix(suffixCount))"
    }

    private var displayedPhoneNumber: String {
        guard let number = selectedModem.simPhoneNumber else {
            return selectedModem.simReady ? L10n.tr("SIM 未提供本机号码") : L10n.tr("尚未读取")
        }
        if appState.isPresentationPrivacyEnabled {
            return L10n.tr("本机号码已隐藏")
        }
        let digits = number.filter { $0 >= "0" && $0 <= "9" }
        guard digits.count >= 7 else { return number }
        return "\(digits.prefix(3)) •••• \(digits.suffix(4))"
    }

    private var sidebarSIMTitle: String {
        if selectedModem.simReady {
            return selectedModem.operatorName ?? L10n.tr("当前 SIM 卡")
        }
        return L10n.tr("SIM 卡")
    }

    private var sidebarSIMDetail: String {
        if appState.isPresentationPrivacyEnabled, selectedModem.simICCID != nil {
            return L10n.tr("SIM 标识已隐藏")
        }
        if let iccid = selectedModem.simICCID, iccid.count >= 4 {
            return L10n.tr("ICCID 尾号 %@", String(iccid.suffix(4)))
        }
        return selectedModem.isConnected ? L10n.tr("等待读取号码") : L10n.tr("模块未连接")
    }

    private func identifierCopyHelp(title: String, value: String?) -> String {
        let localizedTitle = L10n.tr(title)
        if value == nil { return L10n.tr("%@尚未读取", localizedTitle) }
        if appState.isPresentationPrivacyEnabled {
            return L10n.tr("关闭演示隐私保护后可复制完整%@", localizedTitle)
        }
        return L10n.tr("复制完整%@", localizedTitle)
    }

    private var simStateText: String {
        switch selectedModem.simState {
        case .unavailable: return L10n.tr("等待模块")
        case .initializing: return L10n.tr("正在读取")
        case .absent: return L10n.tr("未插入 SIM 卡")
        case .pinRequired: return L10n.tr("需要 SIM PIN")
        case .pukRequired: return L10n.tr("需要 SIM PUK")
        case .ready: return L10n.tr("已连接")
        case .queryFailed: return L10n.tr("查询异常")
        }
    }

    private var simStateIcon: String {
        switch selectedModem.simState {
        case .ready: return "simcard.fill"
        case .pinRequired, .pukRequired: return "lock.fill"
        case .queryFailed: return "exclamationmark.triangle.fill"
        case .initializing: return "ellipsis"
        case .unavailable, .absent: return "simcard"
        }
    }

    private var simStateColor: Color {
        switch selectedModem.simState {
        case .ready: return .green
        case .initializing: return .blue
        case .pinRequired, .pukRequired: return .orange
        case .queryFailed: return .red
        case .unavailable, .absent: return .secondary
        }
    }

    private var connectionDetailText: String {
        switch selectedModem.simState {
        case .ready:
            let parts = [selectedModem.accessTechnology, selectedModem.signalDBm.map { "\($0) dBm" }]
                .compactMap { $0 }
            return parts.isEmpty ? L10n.tr("正在读取蜂窝网络状态") : parts.joined(separator: " · ")
        case .queryFailed:
            return selectedModem.simLastError ?? L10n.tr("稍后将自动重新查询")
        case .pinRequired:
            return L10n.tr("请先使用运营商提供的 PIN 解锁")
        case .pukRequired:
            return L10n.tr("请联系运营商获取 PUK")
        case .absent:
            return L10n.tr("请检查 SIM 卡是否正确插入")
        case .unavailable, .initializing:
            return L10n.tr("连接模块后自动读取 SIM 卡信息")
        }
    }

    private var hasSelectedSignalInformation: Bool {
        selectedModem.simReady && selectedModem.signalDBm != nil
    }

    private var selectedSignalDescription: String {
        guard selectedModem.isConnected, selectedModem.simReady else {
            return L10n.tr("无蜂窝信号")
        }
        guard let signalDBm = selectedModem.signalDBm else {
            return L10n.tr("正在读取蜂窝网络状态")
        }
        var parts: [String] = []
        if let technology = selectedModem.accessTechnology {
            parts.append(technology)
        }
        parts.append(L10n.tr("信号 %lld dBm", Int64(signalDBm)))
        parts.append(L10n.tr("信号强度 %lld 格", Int64(selectedModem.signalBars)))
        return parts.joined(separator: " · ")
    }

    private var networkStateText: String {
        switch selectedConnectionState {
        case .disabled: return L10n.tr("已关闭")
        case .waitingForModem: return L10n.tr("等待模块")
        case .starting: return L10n.tr("连接中")
        case .linkDown: return L10n.tr("链路中断")
        case .interfaceReady: return L10n.tr("接口已连接")
        case .available: return L10n.tr("数据可用")
        case .recovering: return L10n.tr("恢复中")
        case .failed: return L10n.tr("连接异常")
        }
    }

    private var networkStateColor: Color {
        switch selectedConnectionState {
        case .disabled: return .secondary
        case .waitingForModem, .starting, .recovering: return .blue
        case .linkDown: return .orange
        case .interfaceReady: return .orange
        case .available: return .green
        case .failed: return .red
        }
    }

    private var networkDetailText: String {
        switch selectedConnectionState {
        case .disabled:
            return L10n.tr("当前没有启用蜂窝数据；请通过顶部地球按钮选择")
        case .waitingForModem:
            return L10n.tr("模块就绪后自动建立蜂窝数据连接")
        case .starting:
            return L10n.tr("正在等待 ECM 链路与网络地址")
        case let .linkDown(isRetrying):
            return isRetrying
                ? L10n.tr("ECM 载波未建立，正在自动重试")
                : L10n.tr("ECM 载波未建立，已停止自动重试；请拔下模组后重新插入")
        case .interfaceReady:
            return L10n.tr("ECM 已连接，正在等待运营商数据服务")
        case .available:
            if let address = selectedNetwork.ipv4Address {
                return L10n.tr("蜂窝数据已连接 · %@", address)
            }
            return L10n.tr("蜂窝数据已连接")
        case .recovering:
            return L10n.tr("正在重新协商 ECM 链路与网络地址")
        case .failed:
            return selectedNetwork.lastError ?? L10n.tr("蜂窝数据连接异常，请尝试刷新")
        }
    }

    private var voiceServiceText: String {
        switch selectedModem.voiceServiceAvailability {
        case .unavailable: return L10n.tr("不可用")
        case .available: return L10n.tr("可用")
        case .likelyDataOnly: return L10n.tr("可能仅数据")
        case .unknown: return L10n.tr("语音能力未知")
        }
    }

    private var voiceServiceColor: Color {
        switch selectedModem.voiceServiceAvailability {
        case .available: return .green
        case .likelyDataOnly: return .orange
        case .unavailable, .unknown: return .secondary
        }
    }

    private var hardwareFamilyText: String {
        switch selectedModem.hardwareFamily {
        case .quectelNativeVoice: return L10n.tr("Quectel 原生语音模块")
        case .baiwangInjectedVoice: return L10n.tr("Baiwang 动态语音模块")
        case .unknown: return L10n.tr("未识别")
        }
    }

    private var voiceCapabilityText: String {
        switch selectedModem.voiceCapability {
        case .unknown: return L10n.tr("尚未探测")
        case .probing: return L10n.tr("正在探测")
        case let .supported(_, verified):
            return verified ? L10n.tr("支持 · 已通话验证") : L10n.tr("支持 · 尚未通话验证")
        case let .unsupported(reason): return L10n.tr("不支持 · %@", reason)
        case let .probeFailed(reason): return L10n.tr("探测失败 · %@", reason)
        case let .initializationFailed(reason): return L10n.tr("初始化失败 · %@", reason)
        }
    }

    private var voiceCapabilityColor: Color {
        switch selectedModem.voiceCapability {
        case .supported: return .green
        case .probing: return .blue
        case .unsupported: return .secondary
        case .probeFailed, .initializationFailed: return .red
        case .unknown: return .secondary
        }
    }

    private var voiceBackendText: String {
        guard case let .supported(backend, _) = selectedModem.voiceCapability else {
            return L10n.tr("未选择")
        }
        switch backend {
        case .nativeQPCMV: return L10n.tr("原生 QPCMV")
        case .injectedQDC507: return L10n.tr("QDC507 动态注入")
        }
    }

    private var dataServiceText: String {
        guard selectedModem.simReady else { return L10n.tr("不可用") }
        return selectedModem.registrationState.hasService ? L10n.tr("可用") : L10n.tr("等待注册")
    }

    private var dataServiceColor: Color {
        selectedModem.registrationState.hasService ? .green : .secondary
    }

    private var messageServiceText: String {
        guard selectedModem.simReady else { return L10n.tr("不可用") }
        return selectedModem.registrationState.hasService ? L10n.tr("可用") : L10n.tr("等待注册")
    }

    private var moduleStatusText: String {
        switch selectedModem.operationalState {
        case .absent: return L10n.tr("未连接")
        case .enumerating: return L10n.tr("USB 枚举中")
        case .initializing: return L10n.tr("初始化中")
        case .configurationRequired: return L10n.tr("需要配置")
        case .ready: return L10n.tr("工作正常")
        case .restarting: return L10n.tr("正在重启")
        case .reconnecting: return L10n.tr("重新连接中")
        case .failed: return L10n.tr("异常")
        }
    }

    private var moduleStatusColor: Color {
        if selectedModule?.isActiveSession == false { return .blue }
        switch selectedModem.operationalState {
        case .ready: return .green
        case .configurationRequired: return .orange
        case .failed: return .red
        case .enumerating, .initializing, .restarting, .reconnecting: return .blue
        case .absent: return .secondary
        }
    }
}

private struct SIMModuleSidebarRow: View {
    let module: CellularModuleSummary
    let hidesSensitiveIdentifiers: Bool
    let showsCurrentInternetTag: Bool
    let showsIncomingCallsTag: Bool
    let showsESIMTag: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SIMSignalBars(
                bars: module.modem.signalBars,
                active: module.modem.simReady,
                tint: hasSignalInformation ? .green : .secondary
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(moduleTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                Text(simIdentifierText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if hasRoleTags {
                    HStack(spacing: 5) {
                        if showsCurrentInternetTag {
                            ModuleRoleBadge(title: "当前上网", tint: .blue)
                        }
                        if showsIncomingCallsTag {
                            ModuleRoleBadge(title: "接收来电", tint: .green)
                        }
                        if showsESIMTag {
                            ModuleRoleBadge(title: "eSIM", tint: .purple)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var hasSignalInformation: Bool {
        module.modem.simReady && module.modem.signalDBm != nil
    }

    private var moduleTitle: String {
        [module.localizedDisplayName, module.carrierName, module.technologyName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var hasRoleTags: Bool {
        showsCurrentInternetTag || showsIncomingCallsTag || showsESIMTag
    }

    private var accessibilitySummary: String {
        var parts = [module.accessibilitySummary]
        if showsCurrentInternetTag { parts.append(L10n.tr("当前上网")) }
        if showsIncomingCallsTag { parts.append(L10n.tr("接收来电已开启")) }
        if showsESIMTag { parts.append("eSIM") }
        return parts.joined(separator: "，")
    }

    private var simIdentifierText: String {
        guard let suffix = module.simSuffix else {
            return module.modem.simReady ? L10n.tr("ICCID 尚未读取") : module.statusText
        }
        return hidesSensitiveIdentifiers
            ? L10n.tr("SIM 标识已隐藏")
            : L10n.tr("ICCID 尾号 %@", suffix)
    }

    private var statusColor: Color {
        switch module.modem.simState {
        case .ready: return .green
        case .initializing, .unavailable: return .blue
        case .pinRequired, .pukRequired: return .orange
        case .queryFailed: return .red
        case .absent: return .secondary
        }
    }
}

private struct ModuleRoleBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(L10n.tr(title))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.09), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.7)
            }
            .fixedSize()
    }
}

private struct SIMSignalBars: View {
    let bars: Int
    let active: Bool
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0 ..< 4, id: \.self) { index in
                Capsule()
                    .fill(barColor(index: index))
                    .frame(width: 6, height: CGFloat(9 + index * 6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active ? L10n.tr("信号强度 %lld 格", Int64(bars)) : L10n.tr("无蜂窝信号"))
    }

    private func barColor(index: Int) -> Color {
        guard active else { return Color.secondary.opacity(0.22) }
        return index < bars ? tint : tint.opacity(0.22)
    }
}
