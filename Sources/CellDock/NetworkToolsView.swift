import SwiftUI

enum NetworkToolsTab: String {
    case proxy
    case voWiFi = "wifiCalling"
}

struct NetworkToolsTabBar: View {
    @Binding var selection: NetworkToolsTab

    var body: some View {
        CommunicationGlassTabs(
            items: [
                (NetworkToolsTab.proxy, "代理"),
                (NetworkToolsTab.voWiFi, "VoWiFi")
            ],
            selection: $selection
        )
        .accessibilityIdentifier("NetworkToolsTabs")
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

struct NetworkToolsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var proxyController: SOCKSProxyController
    @ObservedObject var voWiFiController: VoWiFiController
    @Binding var sidebarWidth: CGFloat
    @AppStorage("NetworkToolsSelectedTab.v1") private var storedTab = NetworkToolsTab.proxy.rawValue

    @ViewBuilder
    var body: some View {
        switch selection.wrappedValue {
        case .proxy:
            ProxyManagementView(
                controller: proxyController,
                sidebarWidth: $sidebarWidth,
                networkToolsTab: selection
            )
            .environmentObject(appState)
        case .voWiFi:
            VoWiFiView(
                controller: voWiFiController,
                sidebarWidth: $sidebarWidth,
                networkToolsTab: selection
            )
            .environmentObject(appState)
        }
    }

    private var selection: Binding<NetworkToolsTab> {
        Binding(
            get: { NetworkToolsTab(rawValue: storedTab) ?? .proxy },
            set: { storedTab = $0.rawValue }
        )
    }
}

private struct VoWiFiView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: VoWiFiController
    @Binding var sidebarWidth: CGFloat
    @Binding var networkToolsTab: NetworkToolsTab
    @State private var selectedModuleID: CellularModuleID?

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            sidebar
                .communicationSidebarColumnStyle()
                .communicationModuleFloatingSidebar()
        } detail: {
            detail
                .communicationDetailColumnStyle()
        }
        .onAppear {
            reconcileSelection()
            controller.refreshAll()
        }
        .onChange(of: availableModules.map(\.id)) { _, _ in reconcileSelection() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            NetworkToolsTabBar(selection: $networkToolsTab)

            HStack {
                Text(verbatim: L10n.tr("VoWiFi"))
                    .font(.appTitle)
                Spacer()
                CommunicationIconActionButton(
                    systemImage: "arrow.clockwise",
                    accessibilityLabel: L10n.tr("重新检测 VoWiFi"),
                    action: controller.refreshAll
                )
                .disabled(availableModules.isEmpty)
            }
            .padding(16)

            if availableModules.isEmpty {
                ContentUnavailableView(
                    L10n.tr("没有可用模组"),
                    systemImage: "wifi.slash",
                    description: Text(verbatim: L10n.tr("连接并识别蜂窝模组后即可检测 VoWiFi 运行时。"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(availableModules) { module in
                        VoWiFiModuleRow(
                            module: module,
                            state: controller.states[module.id] ?? .checking
                        )
                        .communicationSelectionHighlight(selectedModuleID == module.id)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedModuleID = module.id }
                        .accessibilityAddTraits(
                            selectedModuleID == module.id ? .isSelected : []
                        )
                    }
                }
                .listStyle(.sidebar)
                .communicationEmphasizedSelection()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let module = selectedModule {
            VoWiFiDetailView(
                module: module,
                state: controller.states[module.id] ?? .checking,
                controller: controller
            )
            .environmentObject(appState)
        } else {
            ContentUnavailableView(
                L10n.tr("选择模组"),
                systemImage: "wifi",
                description: Text(verbatim: L10n.tr("选择一个模组以查看 VoWiFi 运行时和注册状态。"))
            )
        }
    }

    private var availableModules: [CellularModuleSummary] {
        controller.availableModules
    }

    private var selectedModule: CellularModuleSummary? {
        guard let selectedModuleID else { return nil }
        return availableModules.first(where: { $0.id == selectedModuleID })
    }

    private func reconcileSelection() {
        let ids = availableModules.map(\.id)
        selectedModuleID = CellularModuleSelectionPolicy.reconciledManagementSelection(
            current: selectedModuleID,
            available: ids
        )
    }
}

private struct VoWiFiModuleRow: View {
    let module: CellularModuleSummary
    let state: VoWiFiSessionState

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(VoWiFiStatusStyle.color(for: state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: module.localizedDisplayName).lineLimit(1)
                Text(verbatim: state.localizedShortTitle)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 5)
    }
}

private enum VoWiFiStatusStyle {
    static func color(for state: VoWiFiSessionState) -> Color {
        switch state {
        case .registered: return .green
        case .starting, .authenticatingSIM, .establishingTunnel, .registeringIMS: return .orange
        case .failed, .desynchronized, .egressUnavailable: return .red
        case .checking, .unsupported, .stopped: return .secondary
        }
    }

    static func icon(for state: VoWiFiSessionState) -> String {
        switch state {
        case .registered: return "wifi"
        case .starting, .authenticatingSIM, .establishingTunnel, .registeringIMS: return "hourglass"
        case .failed, .unsupported, .desynchronized, .egressUnavailable:
            return "wifi.exclamationmark"
        case .checking: return "arrow.triangle.2.circlepath"
        case .stopped: return "wifi.slash"
        }
    }
}

private struct VoWiFiDetailView: View {
    @EnvironmentObject private var appState: AppState
    let module: CellularModuleSummary
    let state: VoWiFiSessionState
    @ObservedObject var controller: VoWiFiController
    @ObservedObject private var upstreamStore = VoWiFiUpstreamProxyStore.shared
    @State private var showingUpstreamManager = false
    @State private var routeError: String?

    var body: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusCard
                    upstreamCard
                    if let problem = state.localizedProblem {
                        messageCard(problem)
                    }
                    explanationCard
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .sheet(isPresented: $showingUpstreamManager) {
            VoWiFiUpstreamProxyManagerView(controller: controller)
        }
        .alert(L10n.tr("无法更新 VoWiFi 路由"), isPresented: Binding(
            get: { routeError != nil },
            set: { if !$0 { routeError = nil } }
        )) {
            Button(L10n.tr("好"), role: .cancel) {}
        } message: {
            Text(verbatim: routeError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: L10n.tr("软件 VoWiFi 运行时"))
                    .font(.appTitle)
                Text(verbatim: module.selectorTitle)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.refresh(module.id)
            } label: {
                Label(L10n.tr("重新检测"), systemImage: "arrow.clockwise")
            }
            .adaptiveGlassButton(.regular)
            .disabled(state == .checking)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(state.localizedTitle, systemImage: VoWiFiStatusStyle.icon(for: state))
                    .font(.appBodyStrong)
                    .foregroundStyle(VoWiFiStatusStyle.color(for: state))
                Spacer()
                Toggle(L10n.tr("启用"), isOn: runningBinding)
                    .toggleStyle(.adaptiveGlass)
                    .controlSize(.small)
                    .disabled(!canToggle)
                    .accessibilityIdentifier("VoWiFiRuntimeToggle")
            }
            Divider()
            statusRow(L10n.tr("运行阶段"), status?.phase?.localizedName ?? L10n.tr("未知"))
            statusRow(
                L10n.tr("数据平面"),
                status?.dataplaneMode ?? VoWiFiControlProtocol.requiredDataplaneMode
            )
            statusRow(L10n.tr("Mac 网络出口"), egressDescription)
            Divider()
            statusRow(
                L10n.tr("SIM/ISIM 鉴权"),
                readinessText(status?.isSIMReady)
            )
            statusRow(
                L10n.tr("IKE/ESP 网络访问"),
                readinessText(status?.isAccessReady)
            )
            statusRow(
                L10n.tr("SWu/ePDG 隧道"),
                status?.isTunnelReady == true ? L10n.tr("已建立") : L10n.tr("未建立")
            )
            statusRow(
                L10n.tr("IMS 注册"),
                status?.isIMSReady == true
                    ? L10n.tr("已注册")
                    : L10n.tr("尚未注册")
            )
            if let registrationStatus = status?.registrationStatus {
                statusRow(L10n.tr("IMS 状态码"), String(registrationStatus))
            }
        }
        .adaptiveGlassSurface(cornerRadius: 20, padding: 18, treatment: .regular)
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.tr("工作方式"), systemImage: "checkmark.shield")
                .font(.appBodyStrong)
            Text(verbatim: L10n.tr("vowifi-go 在 Mac 的特权网络进程中运行，通过受限桥向模组请求 SIM/ISIM AKA，并在 Mac 上建立 utun、SWu/ePDG 隧道和 IMS 注册。可选的 SOCKS5 上游只承载 IKEv2 与 ESP；模组固件无需修改。此后端仍处于实验阶段，需要真实 SIM、运营商和 ePDG 联调验证。"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(cornerRadius: 16, padding: 14, treatment: .clear)
    }

    private var upstreamCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.tr("VoWiFi 上游网络"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.appBodyStrong)
                Spacer()
                Button(L10n.tr("管理代理")) { showingUpstreamManager = true }
                    .accessibilityIdentifier("VoWiFiManageUpstreamProxies")
            }
            Picker(L10n.tr("路由"), selection: routeBinding) {
                Text(verbatim: L10n.tr("直接使用 Mac 网络出口")).tag(VoWiFiUpstreamRoute.direct)
                ForEach(upstreamStore.configurations.filter(\.isEnabled)) { proxy in
                    Text(verbatim: proxy.name).tag(VoWiFiUpstreamRoute.proxy(proxy.id))
                }
            }
            .accessibilityIdentifier("VoWiFiUpstreamRoute")
            Text(verbatim: L10n.tr("上游必须是支持 UDP ASSOCIATE 的 SOCKS5 代理；IKEv2 与 ESP 共用同一个 UDP 关联，以保持 ePDG 看到的 NAT 映射稳定。"))
                .font(.appCaption)
                .foregroundStyle(.secondary)
            if controller.isRunningRequested(module.id) {
                Button {
                    controller.reapplyUpstreamRoute(for: module.id)
                } label: {
                    Label(L10n.tr("应用并重新连接"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(state == .checking)
                .accessibilityIdentifier("VoWiFiApplyUpstreamRoute")
            }
        }
        .adaptiveGlassSurface(cornerRadius: 18, padding: 16, treatment: .regular)
    }

    private func messageCard(_ text: String) -> some View {
        let color = VoWiFiStatusStyle.color(for: state)
        return Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.appCallout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlassSurface(
                cornerRadius: 14,
                padding: 12,
                treatment: .clear,
                tint: color.opacity(0.08)
            )
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).multilineTextAlignment(.trailing)
        }
        .font(.appCallout)
    }

    private func readinessText(_ value: Bool?) -> String {
        value == true ? L10n.tr("已就绪") : L10n.tr("未就绪")
    }

    private var status: VoWiFiRuntimeStatus? { state.status }

    private var egressDescription: String {
        controller.relayDescription(for: module.id) ?? L10n.tr("未建立")
    }

    private var moduleIdentity: String { module.modem.moduleIMEI ?? module.id.rawValue }

    private var routeBinding: Binding<VoWiFiUpstreamRoute> {
        Binding(
            get: { upstreamStore.route(for: moduleIdentity) },
            set: { route in
                do { try upstreamStore.setRoute(route, for: moduleIdentity) }
                catch { routeError = error.localizedDescription }
            }
        )
    }

    private var canToggle: Bool {
        guard state != .checking, !appState.call.hasCall else { return false }
        switch state {
        case .unsupported: return false
        default: return true
        }
    }

    private var runningBinding: Binding<Bool> {
        Binding(
            get: { controller.isRunningRequested(module.id) || state.isRunning },
            set: { controller.setRunning($0, for: module.id) }
        )
    }
}
