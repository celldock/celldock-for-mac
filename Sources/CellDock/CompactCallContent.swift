import OSLog
import SwiftUI

private let compactCallLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.celldock.mac",
    category: "MenuBarDialer"
)

struct CompactCallContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var contacts = SystemContactStore.shared
    @ObservedObject private var recordings = CallRecordingStore.shared
    @AppStorage("CallRecordingConsentAcknowledged.v1") private var recordingConsent = false

    @State private var dialNumber = ""
    @State private var isDTMFKeypadVisible = false
    @State private var dtmfDigits = ""
    @State private var showingRecordingConsent = false
    @FocusState private var dtmfKeypadFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header

            phaseContent
                .id(appState.call.phase.rawValue)
                .transition(.opacity)
        }
        .animation(phaseAnimation, value: appState.call.phase)
        .onChange(of: appState.call.phase) { _, phase in
            if phase != .active {
                showingRecordingConsent = false
            }
            guard phase != .active else { return }
            isDTMFKeypadVisible = false
            dtmfDigits = ""
            dtmfKeypadFocused = false
        }
        .alert(L10n.tr("开始通话录音？"), isPresented: $showingRecordingConsent) {
            Button(L10n.tr("取消"), role: .cancel) {}
            Button(L10n.tr("同意并开始")) {
                recordingConsent = true
                appState.startCallRecording()
            }
        } message: {
            Text(L10n.tr("录音会保存本次通话双方的声音。请先确认已取得通话参与者同意，并遵守所在地法律法规。录音仅保存在这台 Mac。"))
        }
    }

    private var header: some View {
        HStack {
            Label(L10n.tr("电话"), systemImage: "phone.fill")
                .font(.appCaption.weight(.semibold))

            Spacer()

            if appState.isChangingCall {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(verbatim: callPhaseText)
                    .font(.appCaptionStrong)
                    .foregroundStyle(callPhaseColor)
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch appState.call.phase {
        case .idle:
            idleContent
        case .incoming:
            incomingContent
        case .dialing, .alerting:
            outgoingCallContent
        case .active:
            activeCallContent
        case .ending, .recovering:
            finishingCallContent
        case .unavailable, .error:
            unavailableContent
        }
    }

    private var idleContent: some View {
        VStack(spacing: 10) {
            VStack(spacing: 3) {
                Group {
                    if appState.isPresentationPrivacyEnabled {
                        SecureField(L10n.tr("输入电话号码"), text: $dialNumber)
                    } else {
                        TextField(L10n.tr("输入电话号码"), text: $dialNumber)
                    }
                }
                    .textFieldStyle(.plain)
                    .font(.appTitle)
                    .multilineTextAlignment(.center)
                    .onSubmit(dialIfPossible)
                    .padding(.horizontal, 32)
                    .overlay(alignment: .trailing) {
                        if !dialNumber.isEmpty {
                            Button(action: deleteLastDialCharacter) {
                                Image(systemName: "delete.left")
                                    .font(.appSymbol(.small))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.tr("删除最后一位"))
                            .accessibilityLabel(L10n.tr("删除最后一位"))
                        }
                    }
                    .accessibilityIdentifier("MenuBarDialNumberField")

                Text(verbatim: presentedMatchedContact ?? callAvailabilityDetail)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 14)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .adaptiveGlassSurface(
                cornerRadius: 16,
                treatment: .regular,
                tint: Color.accentColor.opacity(0.035),
                isInteractive: true
            )

            CompactCallKeypad(isEnabled: true) {
                appendDialCharacter($0)
            }

            HStack {
                Spacer()

                CompactCallControlButton(
                    title: L10n.tr("拨打"),
                    systemImage: "phone.fill",
                    tint: .green,
                    isSelected: true,
                    isEnabled: canDial
                ) {
                    dialIfPossible()
                }
                .accessibilityIdentifier("MenuBarDialButton")

                Spacer()
            }

            if let reason = appState.call.lastEndReason {
                Text(verbatim: reason.localizedDescription)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var incomingContent: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: currentCallDisplayName(fallback: L10n.tr("未知号码")))
                    .font(.appBodyStrong)
                Text(L10n.tr("蜂窝来电"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.tr("拒接"), role: .destructive) {
                appState.hangUp()
            }
            .adaptiveGlassButton()
            .tint(.red)
            .disabled(appState.isChangingCall)

            Button(L10n.tr("接听")) {
                appState.answerCall()
            }
            .adaptiveGlassButton(.prominent)
            .tint(.green)
            .disabled(
                !appState.call.voiceOverUSBSupported ||
                    appState.isChangingCall
            )
        }
    }

    private var outgoingCallContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: currentCallDisplayName(fallback: L10n.tr("正在拨号")))
                    .font(.appBodyStrong)
                Text(appState.call.phase == .alerting ? L10n.tr("对方正在响铃") : L10n.tr("正在建立通话"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(L10n.tr("挂断"), role: .destructive) {
                appState.hangUp()
            }
            .adaptiveGlassButton()
            .tint(.red)
            .disabled(appState.isChangingCall)
        }
    }

    private var activeCallContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 3) {
                Text(verbatim: currentCallDisplayName(fallback: L10n.tr("通话中")))
                    .font(.appHeadline)
                if let startedAt = appState.call.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 16) {
                CompactCallControlButton(
                    title: appState.call.muted ? L10n.tr("取消静音") : L10n.tr("静音"),
                    systemImage: appState.call.muted ? "mic.slash.fill" : "mic.fill",
                    isSelected: appState.call.muted
                ) {
                    appState.setCallMuted(!appState.call.muted)
                }

                CompactCallControlButton(
                    title: L10n.tr("拨号盘"),
                    systemImage: "circle.grid.3x3.fill",
                    isSelected: isDTMFKeypadVisible
                ) {
                    let willShow = !isDTMFKeypadVisible
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isDTMFKeypadVisible.toggle()
                    }
                    if willShow {
                        DispatchQueue.main.async {
                            dtmfKeypadFocused = true
                        }
                    } else {
                        dtmfKeypadFocused = false
                    }
                }

                CompactCallControlButton(
                    title: recordings.isRecording ? L10n.tr("停止录音") : L10n.tr("录音"),
                    systemImage: recordings.isRecording ? "stop.circle.fill" : "record.circle",
                    tint: .red,
                    isSelected: recordings.isRecording,
                    isEnabled: canToggleRecording
                ) {
                    toggleRecording()
                }
                .help(recordings.isRecording ? L10n.tr("停止并保存本次录音") : L10n.tr("录制通话双方声音"))
                .accessibilityIdentifier("MenuBarCallRecordingButton")

                CompactCallControlButton(
                    title: L10n.tr("挂断"),
                    systemImage: "phone.down.fill",
                    tint: .red,
                    isEnabled: !appState.isChangingCall
                ) {
                    appState.hangUp()
                }
            }

            recordingStatus

            if isDTMFKeypadVisible {
                CompactDTMFReadout(digits: dtmfDigits) {
                    dtmfDigits = ""
                }

                CompactCallKeypad(isEnabled: appState.call.canSendDTMF) {
                    sendDTMFTone($0)
                }
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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                Text(L10n.tr("正在录音"))
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
            .font(.appCaptionStrong)
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("MenuBarCallRecordingStatus")
        } else if recordings.phase == .finalizing {
            ProgressView(L10n.tr("正在保存录音…"))
                .controlSize(.small)
                .accessibilityIdentifier("MenuBarCallRecordingStatus")
        }

        if let recordingError = recordings.lastError {
            Label {
                Text(verbatim: recordingError)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .font(.appCaption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finishingCallContent: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text(appState.call.phase == .recovering
                ? L10n.tr("正在核对通话状态…")
                : L10n.tr("正在结束通话…"))
                .font(.appCaption)
                .foregroundStyle(.secondary)

            Spacer()

            if appState.call.phase == .recovering {
                Button(L10n.tr("重试挂断"), role: .destructive) {
                    appState.hangUp()
                }
                .adaptiveGlassButton()
                .tint(.red)
                .disabled(appState.isChangingCall)
            }
        }
    }

    private var unavailableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(.secondary)
                Text(verbatim: appState.call.lastError ?? (appState.activeCallModemSnapshot.isConnected
                    ? L10n.tr("模块未报告 USB 语音能力")
                    : L10n.tr("插入模块后可使用蜂窝电话")))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            if appState.activeCallModemSnapshot.isConnected {
                HStack {
                    Spacer()

                    if appState.call.controlInterfaceBusy {
                        Button(role: .destructive) {
                            appState.forceReleaseCallControlInterface()
                        } label: {
                            Label(L10n.tr("结束占用并重试"), systemImage: "xmark.app.fill")
                        }
                        .help(L10n.tr("只结束当前占用模块 ADB 接口的应用，然后重试电话初始化"))
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .disabled(appState.isChangingCall)
                    } else {
                        Button(L10n.tr("重试初始化")) {
                            appState.retryCallInitialization()
                        }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .disabled(appState.isChangingCall)
                    }
                }
            }
        }
    }

    private var canDial: Bool {
        appState.currentCommunicationModemSnapshot.simReady &&
            appState.call.canDial &&
            CallATParser.normalizedDialNumber(dialNumber) != nil &&
            !appState.isChangingCall
    }

    private var callAvailabilityDetail: String {
        let modem = appState.currentCommunicationModemSnapshot
        switch modem.simState {
        case .ready:
            return modem.voiceServiceAvailability == .likelyDataOnly
                ? L10n.tr("该 SIM 可能仅支持数据，未检测到可用语音服务。")
                : L10n.tr("通过当前 SIM 卡呼叫")
        case .pinRequired: return L10n.tr("需要 SIM PIN 后才能拨号")
        case .pukRequired: return L10n.tr("需要 SIM PUK 后才能拨号")
        case .absent: return L10n.tr("插入 SIM 卡后才能拨号")
        case .queryFailed: return L10n.tr("确认 SIM 状态后才能拨号")
        case .unavailable, .initializing: return L10n.tr("正在等待 SIM 卡就绪")
        }
    }

    private var matchedContact: String? {
        contacts.displayName(for: dialNumber)
    }

    private var presentedMatchedContact: String? {
        guard let matchedContact else { return nil }
        return appState.privacyPresentation.identity(
            contactName: matchedContact,
            number: dialNumber
        )
    }

    private func currentCallDisplayName(fallback: String) -> String {
        guard let number = appState.call.number, !number.isEmpty else {
            return fallback
        }
        return appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: number),
            number: number,
            fallback: fallback
        )
    }

    private var callPhaseText: String {
        switch appState.call.phase {
        case .unavailable: return L10n.tr("不可用")
        case .idle: return appState.modem.simReady ? L10n.tr("可拨号") : L10n.tr("等待 SIM")
        case .incoming: return L10n.tr("来电")
        case .dialing: return L10n.tr("拨号中")
        case .alerting: return L10n.tr("响铃中")
        case .active: return L10n.tr("通话中")
        case .ending: return L10n.tr("结束中")
        case .recovering: return L10n.tr("恢复中")
        case .error: return L10n.tr("异常")
        }
    }

    private var callPhaseColor: Color {
        switch appState.call.phase {
        case .incoming: return .orange
        case .active: return .green
        case .dialing, .alerting, .ending, .recovering: return .blue
        case .error: return .red
        case .unavailable, .idle: return .secondary
        }
    }

    private var phaseAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .smooth(duration: Animation.maVoPanelResizeDuration)
    }

    private func dialIfPossible() {
        guard canDial else { return }
        appState.dial(dialNumber)
    }

    private func appendDialCharacter(_ character: String) {
        guard dialNumber.count < 32 else { return }
        compactCallLogger.info("Menu bar dial key accepted")
        dialNumber.append(character)
    }

    private func deleteLastDialCharacter() {
        guard !dialNumber.isEmpty else { return }
        dialNumber.removeLast()
    }

    private var canToggleRecording: Bool {
        if recordings.isRecording { return true }
        return recordings.phase == .idle &&
            appState.call.phase == .active &&
            appState.call.audioActive
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
}

private struct CompactDTMFReadout: View {
    let digits: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if digits.isEmpty {
                        Text(L10n.tr("点击按键，或直接使用 Mac 键盘"))
                    } else {
                        Text(verbatim: digits)
                    }
                }
                    .font(digits.isEmpty ? .appCaption : .appHeadline.monospaced().weight(.medium))
                    .foregroundStyle(digits.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .defaultScrollAnchor(.trailing)
            .frame(maxWidth: .infinity, minHeight: 26)

            if !digits.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清空按键显示（不会撤回已发送的按键）"))
                .accessibilityLabel(L10n.tr("清空按键显示"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlassSurface(cornerRadius: 12, treatment: .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(digits.isEmpty ? L10n.tr("尚未输入通话按键") : L10n.tr("已输入 %@", digits))
    }
}

private struct CompactCallKeypad: View {
    let isEnabled: Bool
    let send: (String) -> Void

    private let tones: [(tone: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(tones, id: \.tone) { key in
                Button {
                    send(key.tone)
                } label: {
                    VStack(spacing: 0) {
                        Text(verbatim: key.tone)
                            .font(.appHeadline.monospaced())
                        Text(verbatim: key.letters.isEmpty ? " " : key.letters)
                            .font(.appMicro)
                            .tracking(1)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(CompactDTMFKeyButtonStyle())
                .disabled(!isEnabled)
                .accessibilityLabel(accessibilityLabel(for: key.tone))
                .accessibilityIdentifier("MenuBarDialKey-\(key.tone)")
            }
        }
        .padding(.top, 2)
    }

    private func accessibilityLabel(for tone: String) -> String {
        switch tone {
        case "*": return L10n.tr("星号")
        case "#": return L10n.tr("井号")
        default: return tone
        }
    }
}

private struct CompactDTMFKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .adaptiveGlassSurface(
                cornerRadius: 12,
                treatment: .clear,
                tint: configuration.isPressed ? Color.blue.opacity(0.16) : nil,
                isInteractive: true
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        configuration.isPressed
                            ? Color.blue.opacity(0.55)
                            : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct CompactCallControlButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .blue
    var isSelected = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                controlIcon
                Text(verbatim: title)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var controlIcon: some View {
        let icon = Image(systemName: systemImage)
            .font(.appSymbol(.button, weight: .semibold))
            .frame(width: 38, height: 38)

        if #available(macOS 26.0, *) {
            if isSelected || tint == .red {
                icon
                    .foregroundStyle(Color.white)
                    .glassEffect(.regular.tint(tint).interactive(), in: Circle())
            } else {
                icon
                    .foregroundStyle(tint)
                    .glassEffect(.clear.tint(tint.opacity(0.10)).interactive(), in: Circle())
            }
        } else {
            icon
                .foregroundStyle(isSelected || tint == .red ? Color.white : tint)
                .background(
                    isSelected || tint == .red ? tint : tint.opacity(0.13),
                    in: Circle()
                )
        }
    }
}
