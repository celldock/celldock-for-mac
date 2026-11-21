import AppKit
import SwiftUI

struct CellDockInitialSetupView: View {
    private enum Confirmation: Equatable {
        case identityConversion
        case ecmInitialization
    }

    @EnvironmentObject private var appState: AppState
    @State private var confirmation: Confirmation?
    @State private var isConversionInfoPresented = false

    let onDismiss: () -> Void
    let onPreferredHeightChange: (CGFloat) -> Void

    var body: some View {
        AdaptiveGlassContainer(spacing: 12) {
            VStack(spacing: 14) {
                draggableHeader
                setupStatusCard

                if let confirmation {
                    confirmationCard(confirmation)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                actionBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(30)
        .frame(width: 520, height: preferredHeight)
        .background {
            if #available(macOS 15.0, *) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            } else {
                Color.clear
            }
        }
        .animation(.smooth(duration: 0.22), value: confirmation)
        .onAppear {
            onPreferredHeightChange(preferredHeight)
        }
        .onChange(of: confirmation) { _, _ in
            onPreferredHeightChange(preferredHeight)
        }
        .onChange(of: appState.modem.initialSetupState) { _, state in
            if state != .needsIdentityConversion && confirmation == .identityConversion {
                confirmation = nil
            }
            if state != .needsECM && confirmation == .ecmInitialization {
                confirmation = nil
            }
            if state != .needsIdentityConversion {
                isConversionInfoPresented = false
            }
        }
        .onExitCommand(perform: dismissIfAllowed)
    }

    private var preferredHeight: CGFloat {
        confirmation == nil ? 330 : 400
    }

    @ViewBuilder
    private var draggableHeader: some View {
        let header = HStack(alignment: .center, spacing: 13) {
            ZStack {
                Circle()
                    .fill(setupColor.opacity(0.14))
                Image(systemName: setupIcon)
                    .font(.appSymbol(.large, weight: .semibold))
                    .foregroundStyle(setupColor)
                    .symbolEffect(.pulse, isActive: isBusy)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(setupTitle)
                    .font(.appHeadline)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if appState.modem.initialSetupState == .needsIdentityConversion {
                        Button {
                            isConversionInfoPresented.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.appSymbol(.indicator, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("查看转换配置"))
                        .accessibilityLabel(L10n.tr("查看转换配置"))
                        .popover(
                            isPresented: $isConversionInfoPresented,
                            arrowEdge: .bottom
                        ) {
                            identityConversionPopover
                        }
                    }

                    Text(setupDetail)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if isSafeDJISource {
                Label("安全已验证", systemImage: "checkmark.shield.fill")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.1), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())

        if #available(macOS 15.0, *) {
            header
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
        } else {
            header
        }
    }

    private var identityConversionPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("转换配置", systemImage: "arrow.triangle.2.circlepath")
                .font(.appBodyStrong)

            Text("CellDock 会先完成 QADBKEY 解锁；仅当当前值精确匹配已验证配置时才写入，并在逐项回读成功后重启模块。")
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            configurationLine(
                title: L10n.tr("当前"),
                value: configurationValue(appState.modem.usbConfiguration),
                color: .secondary
            )
            configurationLine(
                title: L10n.tr("转换后"),
                value: configurationValue(.maVoTarget),
                color: Color.accentColor
            )

            Text("顺序：VID:PID, DIAG, NMEA, AT, MODEM, NET, ADB, AUDIO")
                .font(.appMicro.monospaced().weight(.regular))
                .minimumScaleFactor(0.85)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Divider()

            HStack(spacing: 18) {
                conversionChange(
                    systemImage: "network",
                    title: L10n.tr("联网模式"),
                    from: appState.modem.usbNetMode.map(String.init) ?? "?",
                    to: "1"
                )
                conversionChange(
                    systemImage: "waveform",
                    title: L10n.tr("通话音频"),
                    from: appState.modem.usbConfiguration?.audioEnabled == true ? "1" : "0",
                    to: "1"
                )
                conversionChange(
                    systemImage: "terminal",
                    title: "ADB",
                    from: appState.modem.usbConfiguration?.adbEnabled == true ? "1" : "0",
                    to: "1"
                )
            }
        }
        .padding(16)
        .frame(width: 430)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("模块转换配置预览"))
    }

    private func configurationLine(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .leading)
            Text(value)
                .font(.appCaptionStrong.monospaced())
                .foregroundStyle(color)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func conversionChange(
        systemImage: String,
        title: String,
        from: String,
        to: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .foregroundStyle(.secondary)
            Text("\(from) → \(to)")
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.appCaption)
    }

    private func configurationValue(_ configuration: ModemUSBConfiguration?) -> String {
        guard let configuration else { return L10n.tr("等待读取") }
        return configuration.usbcfgValueDescription
    }

    private var setupStatusCard: some View {
        VStack(spacing: 8) {
            setupRow(
                title: L10n.tr("USB 模块"),
                value: appState.modem.usbIdentity ?? usbStatusText,
                systemImage: "cable.connector"
            )
            Divider()
            setupRow(
                title: L10n.tr("联网模式"),
                value: appState.modem.usbNetMode.map { "usbnet=\($0)" } ?? L10n.tr("等待检测"),
                systemImage: "network"
            )
            Divider()
            setupRow(
                title: L10n.tr("设备配置"),
                value: usbConfigurationStatusText,
                systemImage: "slider.horizontal.3"
            )
            Divider()
            setupRow(
                title: L10n.tr("SIM 卡"),
                value: setupSIMStatusText,
                systemImage: setupSIMStatusIcon
            )
        }
        .adaptiveGlassSurface(
            cornerRadius: 19,
            padding: 12,
            treatment: .clear
        )
    }

    private func setupRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 19)
            Text(title)
                .font(.appCaptionStrong)
            Spacer(minLength: 10)
            Text(value)
                .font(.appCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minHeight: 21)
    }

    private func confirmationCard(_ confirmation: Confirmation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(confirmationTitle(confirmation))
                    .font(.appCaption.weight(.semibold))
                Text(confirmationDetail(confirmation))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveGlassSurface(
            cornerRadius: 17,
            padding: 11,
            treatment: .clear,
            tint: Color.orange.opacity(0.055)
        )
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if confirmation != nil {
                Button {
                    confirmation = nil
                } label: {
                    actionButtonLabel(L10n.tr("返回"))
                }
                .adaptiveGlassButton()
            } else {
                Button(action: dismissIfAllowed) {
                    actionButtonLabel(L10n.tr("稍后"))
                }
                .adaptiveGlassButton()
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            }

            Spacer()

            if let confirmation {
                Button {
                    performConfirmedAction(confirmation)
                } label: {
                    actionButtonLabel(
                        confirmationActionTitle(confirmation),
                        systemImage: confirmationActionIcon(confirmation)
                    )
                }
                .adaptiveGlassButton(.accented)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || appState.call.hasCall)
            } else if isBusy {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(busyActionTitle)
                        .font(.appCaptionStrong)
                        .foregroundStyle(.secondary)
                }
            } else if appState.modem.initialSetupState == .needsIdentityConversion {
                Button {
                    confirmation = .identityConversion
                } label: {
                    actionButtonLabel(
                        L10n.tr("转换配置"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .adaptiveGlassButton(.accented)
                .keyboardShortcut(.defaultAction)
                .disabled(appState.call.hasCall)
            } else if appState.modem.initialSetupState == .needsECM {
                Button {
                    confirmation = .ecmInitialization
                } label: {
                    actionButtonLabel(L10n.tr("初始化模块"), systemImage: "wand.and.stars")
                }
                .adaptiveGlassButton(.accented)
                .keyboardShortcut(.defaultAction)
                .disabled(appState.call.hasCall)
            } else if appState.modem.initialSetupState == .ready {
                Button {
                    appState.completeInitialSetup()
                    onDismiss()
                } label: {
                    actionButtonLabel(L10n.tr("开始使用"))
                }
                .adaptiveGlassButton(.accented)
                .keyboardShortcut(.defaultAction)
            } else if appState.modem.isConnected {
                Button {
                    appState.refresh()
                } label: {
                    actionButtonLabel(L10n.tr("重新检测"))
                }
                .adaptiveGlassButton(.accented)
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.regular)
        .frame(minHeight: 30)
    }

    private func actionButtonLabel(
        _ title: String,
        systemImage: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
                .lineLimit(1)
        }
        .frame(height: 18)
    }

    private func performConfirmedAction(_ confirmation: Confirmation) {
        self.confirmation = nil
        switch confirmation {
        case .identityConversion:
            appState.convertDJIModuleIdentity()
        case .ecmInitialization:
            appState.configureECM()
        }
    }

    private func dismissIfAllowed() {
        guard !isBusy else {
            NSSound.beep()
            return
        }
        confirmation = nil
        onDismiss()
    }

    private func confirmationTitle(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .identityConversion: return L10n.tr("转换并重启 DJI 模块？")
        case .ecmInitialization: return L10n.tr("初始化并重启模块？")
        }
    }

    private func confirmationDetail(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .identityConversion:
            return L10n.tr("仅当原值精确匹配已验证配置时执行。CellDock 会先解锁模组，再转换 USB 身份并开启 ADB、CDC‑ECM 与通话音频，逐项回读成功后才重启。")
        case .ecmInitialization:
            if appState.modem.hardwareFamily == .quectelNativeVoice,
               appState.modem.usbConfiguration?.isCellDockTarget != true {
                return L10n.tr("CellDock 将写入 usbnet=1 和完整 USBCFG。逐项回读成功后模块会重启一次；Quectel 设备不会注入语音内核模块。")
            }
            return L10n.tr("CellDock 将确认完整 USBCFG 并把 usbnet 切换为 1。写入回读成功后模块会重启一次。")
        }
    }

    private func confirmationActionTitle(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .identityConversion: return L10n.tr("转换并重启")
        case .ecmInitialization: return L10n.tr("确认初始化")
        }
    }

    private func confirmationActionIcon(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .identityConversion: return "arrow.triangle.2.circlepath"
        case .ecmInitialization: return "wand.and.stars"
        }
    }

    private var setupTitle: String {
        switch appState.modem.initialSetupState {
        case .insertModule: return L10n.tr("请插入蜂窝模块")
        case .inspecting: return L10n.tr("正在识别模块")
        case .needsIdentityConversion: return L10n.tr("识别到 DJI 原始配置")
        case .needsECM: return L10n.tr("模块尚未初始化")
        case .ready: return L10n.tr("模块已准备好")
        case .unsupportedIdentity: return L10n.tr("识别到不兼容的 USB 身份")
        case .unsupportedUSBConfiguration: return L10n.tr("DJI 配置未通过校验")
        case .unsupportedUSBNetMode: return L10n.tr("联网模式不受支持")
        case .failed: return L10n.tr("模块检测失败")
        }
    }

    private var setupDetail: String {
        switch appState.modem.initialSetupState {
        case .insertModule:
            return L10n.tr("连接 QDC507 后，CellDock 会自动检查 USB 身份、联网模式和 SIM 状态。")
        case .inspecting:
            return L10n.tr("请保持模块连接，检测完成后会自动显示下一步。")
        case .needsIdentityConversion:
            return L10n.tr("已确认安全原值，可一键转换为 CellDock 兼容配置。")
        case .needsECM:
            return L10n.tr("已识别模块，但 macOS 联网所需的 CDC‑ECM 尚未开启。")
        case .ready:
            return appState.modem.simReady
                ? L10n.tr("USB 身份和 CDC‑ECM 均已通过检查，可以开始使用。")
                : L10n.tr("USB 身份和 CDC‑ECM 已通过检查；请再确认 SIM 卡已正确插入。")
        case let .unsupportedIdentity(identity):
            return identity == "2CA3:4006"
                ? L10n.tr("识别到 DJI 身份，但无法读取精确 USBCFG，因此不会提供写入。")
                : L10n.tr("当前身份为 %@，CellDock 只处理已验证的 DJI/QDC507 模块。", identity)
        case let .unsupportedUSBConfiguration(configuration):
            return L10n.tr("当前值为 %@。它不等于已记录的 DJI 原值，CellDock 已拒绝一键转换。", configuration)
        case let .unsupportedUSBNetMode(mode):
            return L10n.tr("检测到 usbnet=%lld。一键初始化只处理已验证的 usbnet=0 → 1。", Int64(mode))
        case let .failed(error):
            return error
        }
    }

    private var setupSIMStatusText: String {
        switch appState.modem.simState {
        case .unavailable: return L10n.tr("等待模组")
        case .initializing: return L10n.tr("初始化中")
        case .absent: return L10n.tr("未插卡")
        case .pinRequired: return L10n.tr("需要 PIN")
        case .pukRequired: return L10n.tr("需要 PUK")
        case .ready: return L10n.tr("已就绪")
        case .queryFailed: return L10n.tr("查询异常")
        }
    }

    private var setupSIMStatusIcon: String {
        switch appState.modem.simState {
        case .ready: return "simcard.fill"
        case .pinRequired, .pukRequired: return "lock.fill"
        case .queryFailed: return "exclamationmark.triangle.fill"
        case .unavailable, .initializing, .absent: return "simcard"
        }
    }

    private var setupIcon: String {
        switch appState.modem.initialSetupState {
        case .insertModule: return "cable.connector.slash"
        case .inspecting: return "wave.3.right.circle"
        case .needsIdentityConversion: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsECM: return "wrench.and.screwdriver.fill"
        case .ready: return "checkmark.circle.fill"
        case .unsupportedIdentity, .unsupportedUSBConfiguration, .unsupportedUSBNetMode, .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var setupColor: Color {
        switch appState.modem.initialSetupState {
        case .ready: return .green
        case .needsIdentityConversion, .needsECM: return .orange
        case .unsupportedIdentity, .unsupportedUSBConfiguration, .unsupportedUSBNetMode, .failed: return .red
        case .insertModule, .inspecting: return Color.accentColor
        }
    }

    private var isBusy: Bool {
        appState.modem.initialSetupState == .inspecting ||
            appState.isConfiguringECM || appState.isConvertingModuleIdentity
    }

    private var busyActionTitle: String {
        if appState.isConvertingModuleIdentity { return L10n.tr("正在转换配置…") }
        if appState.isConfiguringECM { return L10n.tr("正在初始化…") }
        return L10n.tr("正在检测…")
    }

    private var isSafeDJISource: Bool {
        appState.modem.initialSetupState == .needsIdentityConversion &&
            appState.modem.usbConfiguration?.isSafeDJISource == true
    }

    private var usbStatusText: String {
        switch appState.modem.state {
        case .disconnected: return L10n.tr("未插入")
        case .connecting: return L10n.tr("连接中")
        case .connected: return L10n.tr("正在读取")
        case .error: return L10n.tr("异常")
        }
    }

    private var usbConfigurationStatusText: String {
        guard let configuration = appState.modem.usbConfiguration else { return L10n.tr("等待检测") }
        if configuration.isSafeDJISource { return L10n.tr("DJI 原值已确认") }
        if configuration.isCellDockTarget { return L10n.tr("CellDock 目标值") }
        return configuration.identity
    }
}
