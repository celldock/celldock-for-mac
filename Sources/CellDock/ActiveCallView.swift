import SwiftUI

/// The full-window call page: the in-call card, centred, over a soft glow
/// that follows whoever is speaking.
struct ActiveCallView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @ObservedObject var contacts: SystemContactStore
    @ObservedObject private var recordings = CallRecordingStore.shared
    @AppStorage("CallRecordingConsentAcknowledged.v1") private var recordingConsent = false
    @State private var keypadVisible = false
    @State private var dtmfDigits = ""
    @State private var flashedTone: String?
    @State private var flashGeneration = 0
    @State private var showingRecordingConsent = false
    @FocusState private var keypadFocused: Bool

    private let levels = CallAudioLevelMonitor.shared

    var body: some View {
        GeometryReader { proxy in
            let isActive = appState.call.phase == .active
            let model = cardModel
            let availableHeight = proxy.size.height - InCallLayout.topMargin - InCallLayout.bottomMargin
            let layout = InCallLayout(
                availableHeight: availableHeight,
                keypadOpen: keypadVisible && isActive,
                isConnected: model.isConnected
            )

            ScrollView(.vertical) {
                InCallCard(
                    model: model,
                    layout: layout,
                    maximumWidth: max(360, proxy.size.width - 28),
                    digits: dtmfDigits,
                    flashedTone: flashedTone,
                    monitor: levels,
                    actions: cardActions
                )
                .focusable(keypadVisible && isActive)
                .focused($keypadFocused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    handleKeyPress(press)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, availableHeight))
                .padding(.top, InCallLayout.topMargin)
                .padding(.bottom, InCallLayout.bottomMargin)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .background {
                InCallAmbientGlow(
                    monitor: levels,
                    address: appState.call.number ?? "",
                    isLive: isActive
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(callAnimation, value: keypadVisible)
        .animation(phaseAnimation, value: appState.call.phase)
        .onAppear { levels.beginWatching() }
        .onDisappear { levels.endWatching() }
        .onExitCommand {
            if keypadVisible { setKeypadVisible(false) }
        }
        .onChange(of: appState.call.phase) { _, phase in
            guard phase != .active else { return }
            keypadVisible = false
            dtmfDigits = ""
            keypadFocused = false
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

    // MARK: - What the card shows

    private var cardModel: InCallCardModel {
        let call = appState.call
        let hasContactName = contacts.displayName(for: callNumber) != nil
        return InCallCardModel(
            phase: call.phase,
            title: displayName,
            subtitle: hasContactName ? appState.privacyPresentation.phoneNumber(callNumber) : nil,
            address: call.number ?? "",
            startedAt: call.startedAt,
            line: callLine,
            lineDetail: callModule?.technologyName,
            routeSummary: callRouteSummary,
            muted: call.muted,
            audioActive: call.audioActive,
            canAnswer: call.voiceOverUSBSupported && !appState.isChangingCall,
            canHangUp: !appState.isChangingCall || call.phase == .recovering,
            canToggleRecording: canToggleRecording,
            isRecording: recordings.isRecording,
            recordingStartedAt: recordings.activeRecordingStartedAt,
            isSavingRecording: recordings.phase == .finalizing,
            recordingError: recordings.lastError,
            error: call.lastError
        )
    }

    private var cardActions: InCallCardActions {
        InCallCardActions(
            toggleMute: { appState.setCallMuted(!appState.call.muted) },
            toggleKeypad: { setKeypadVisible(!keypadVisible) },
            toggleRecording: toggleRecording,
            hangUp: {
                setKeypadVisible(false)
                appState.hangUp()
            },
            answer: { appState.answerCall() },
            sendTone: sendDTMFTone,
            clearDigits: { dtmfDigits = "" }
        )
    }

    private var canToggleRecording: Bool {
        if recordings.isRecording { return true }
        return recordings.phase == .idle &&
            appState.call.phase == .active &&
            appState.call.audioActive
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

    private var callModule: CellularModuleSummary? {
        appState.call.moduleID.flatMap { moduleID in
            appState.cellularModules.first(where: { $0.id == moduleID })
        }
    }

    private var callLine: LineAppearance {
        appState.lineAppearanceResolver.currentAppearance(moduleID: appState.call.moduleID)
    }

    /// Shown under the name while the call is being set up: which module
    /// carries it and where the sound will go.
    private var callRouteSummary: String {
        var parts: [String] = []
        if let displayName = callModule?.displayName {
            parts.append(displayName)
        }
        if appState.call.voiceOverUSBSupported {
            parts.append(L10n.tr("使用 Mac 接听"))
        }
        return parts.isEmpty ? L10n.tr("蜂窝语音通话") : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func toggleRecording() {
        if recordings.isRecording {
            appState.stopCallRecording()
        } else if recordingConsent {
            appState.startCallRecording()
        } else {
            showingRecordingConsent = true
        }
    }

    private func setKeypadVisible(_ visible: Bool) {
        guard keypadVisible != visible else { return }
        withAnimation(callAnimation) {
            keypadVisible = visible
        }
        if visible {
            // Focus once the card has become focusable, so the Mac keyboard
            // types tones straight away.
            DispatchQueue.main.async {
                keypadFocused = true
            }
        } else {
            keypadFocused = false
        }
    }

    private func sendDTMFTone(_ tone: String) {
        guard appState.call.canSendDTMF else { return }
        dtmfDigits.append(tone)
        if dtmfDigits.count > 48 {
            dtmfDigits.removeFirst(dtmfDigits.count - 48)
        }
        appState.sendDTMF(tone)
        flash(tone)
    }

    /// Lights the key up briefly, so a tone typed on the keyboard shows which
    /// key it was.
    private func flash(_ tone: String) {
        flashGeneration += 1
        let generation = flashGeneration
        flashedTone = tone
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            guard flashGeneration == generation else { return }
            flashedTone = nil
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard keypadVisible else { return .ignored }
        if press.key == .escape {
            setKeypadVisible(false)
            return .handled
        }
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty,
              let tone = CallATParser.normalizedDTMFTone(press.characters) else {
            return .ignored
        }
        sendDTMFTone(tone)
        return .handled
    }

    private var callAnimation: Animation {
        reduceMotion ? .linear(duration: 0.14) : .smooth(duration: 0.32)
    }

    /// For a change of call state, above all the small card opening when the
    /// call is answered: slower than the keypad, with a little give.
    private var phaseAnimation: Animation {
        reduceMotion ? .linear(duration: 0.18) : .spring(response: 0.52, dampingFraction: 0.86)
    }
}

/// Soft colour behind the card. The side of whoever speaks brightens, which
/// the glass card picks up.
private struct InCallAmbientGlow: View {
    @ObservedObject var monitor: CallAudioLevelMonitor
    let address: String
    let isLive: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let history = monitor.reading.history
        let remote = isLive ? Double(history.latestRemote) : 0
        let local = isLive ? Double(history.latestLocal) : 0
        let strength = colorScheme == .dark ? 0.55 : 1.0
        let contact = AvatarTint.tint(for: ContactFace.face(for: address)).gradientEnd

        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                glow(contact, diameter: 520, opacity: (0.34 + remote * 0.30) * strength)
                    .position(x: size.width * 0.30, y: size.height * 0.30)
                glow(CallVoiceTint.local, diameter: 560, opacity: (0.20 + local * 0.24) * strength)
                    .position(x: size.width * 0.72, y: size.height * 0.74)
                glow(CallVoiceTint.remote, diameter: 320, opacity: 0.16 * strength)
                    .position(x: size.width * 0.68, y: size.height * 0.20)
            }
            .animation(.easeOut(duration: 0.3), value: remote)
            .animation(.easeOut(duration: 0.3), value: local)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, diameter: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [color, color.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: diameter / 2
            ))
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
    }
}
