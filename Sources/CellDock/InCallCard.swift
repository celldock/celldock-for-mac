import SwiftUI

/// Everything the in-call card shows, as plain values.
struct InCallCardModel: Equatable {
    var phase: CallPhase
    /// Who the call is with: the contact's name, or the number.
    var title: String
    /// The number under a contact's name. nil when the title is the number.
    var subtitle: String?
    /// The number the avatar's face is drawn from.
    var address: String
    var startedAt: Date?
    var line: LineAppearance
    /// Radio technology of the line, such as "5G".
    var lineDetail: String?
    /// Shown under the name until the call connects.
    var routeSummary = ""
    var muted = false
    var audioActive = false
    var canAnswer = false
    var canHangUp = true
    var canToggleRecording = false
    var isRecording = false
    var recordingStartedAt: Date?
    var isSavingRecording = false
    var recordingError: String?
    var error: String?

    /// The call has been answered. It stays true while a connected call is
    /// ending or its state is being re-read, so the card does not fold up
    /// and open again in the middle of a conversation.
    var isConnected: Bool {
        switch phase {
        case .active:
            return true
        case .ending, .recovering:
            return startedAt != nil
        case .incoming, .dialing, .alerting, .idle, .unavailable, .error:
            return false
        }
    }

    /// Waiting for someone to pick up, on either end.
    var isRinging: Bool {
        phase == .dialing || phase == .alerting || phase == .incoming
    }
}

struct InCallCardActions {
    var toggleMute: () -> Void = {}
    var toggleKeypad: () -> Void = {}
    var toggleRecording: () -> Void = {}
    var hangUp: () -> Void = {}
    var answer: () -> Void = {}
    var sendTone: (String) -> Void = { _ in }
    var clearDigits: () -> Void = {}
}

/// The call as one glass card: who it is with, both voices as waveforms, the
/// keypad that opens inside the card, and the controls pinned to the bottom.
struct InCallCard: View {
    let model: InCallCardModel
    let layout: InCallLayout
    /// Narrower than the layout's width when the window is.
    var maximumWidth: CGFloat = .infinity
    /// Tones sent during this call, shown above the keypad.
    var digits = ""
    /// The key to light up, when a tone was just sent from the keyboard.
    var flashedTone: String?
    let monitor: CallAudioLevelMonitor
    var actions = InCallCardActions()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: InCallLayout.topRowHeight)

            if layout.usesMiniHero {
                miniHero
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -10)))
            } else {
                bigHero
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.82, anchor: .top))
                    )
            }

            Spacer(minLength: layout.minimumGapAboveWaveform)

            if layout.showsWaveform {
                LiveCallWaveformPanel(
                    monitor: monitor,
                    layout: layout,
                    muted: model.muted,
                    audioActive: model.audioActive,
                    isActive: isActive
                )
                .transition(revealTransition)
            }

            if layout.keypadOpen {
                InCallKeypad(
                    layout: layout,
                    digits: digits,
                    flashedTone: flashedTone,
                    send: actions.sendTone,
                    clear: actions.clearDigits
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16)))
            }

            Spacer(minLength: layout.minimumGapAboveControls)

            notices

            controls
        }
        .padding(.horizontal, 26)
        .padding(.top, layout.paddingTop)
        .padding(.bottom, layout.paddingBottom)
        .frame(width: width)
        // Exactly the planned height, whatever room the page offers. Content
        // the plan did not foresee, such as a wrapped label, may make the card
        // taller instead of being clipped.
        .frame(minHeight: layout.cardHeight)
        .fixedSize(horizontal: false, vertical: true)
        // What appears when the call connects is laid out where it will end
        // up, which is outside the card while the card is still opening. The
        // clip lets the growing edge uncover it instead.
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .adaptiveGlassSurface(cornerRadius: Self.cornerRadius, treatment: .clear)
    }

    private static let cornerRadius: CGFloat = 34

    private var isActive: Bool { model.phase == .active }

    private var width: CGFloat { min(layout.cardWidth, maximumWidth) }

    // MARK: - Top row

    private var topRow: some View {
        HStack(spacing: 8) {
            statePill
            Spacer(minLength: 8)
            LineChip(appearance: model.line, detail: model.lineDetail)
        }
    }

    private var statePill: some View {
        let recording = isActive && model.isRecording
        let tint = recording ? InCallPalette.recording : InCallPalette.tint(for: model.phase)
        return HStack(spacing: 5) {
            if recording {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(verbatim: L10n.tr("通话中") + " · " + L10n.tr("正在录音"))
                if let startedAt = model.recordingStartedAt {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                }
            } else {
                Text(verbatim: InCallPalette.title(for: model.phase))
                    .contentTransition(.opacity)
            }
        }
        .font(.appCaptionStrong)
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: AppMetrics.Control.chip)
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Who the call is with

    private var bigHero: some View {
        VStack(spacing: 0) {
            CallVoiceAvatar(
                address: model.address,
                size: layout.avatar,
                isLive: isActive,
                monitor: monitor
            )
            .background {
                CallRingingPulse(
                    tint: InCallPalette.tint(for: model.phase),
                    isRinging: model.isRinging
                )
            }
            .padding(.top, layout.heroTopGap)

            Text(verbatim: model.title)
                .font(.appDisplay)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.top, layout.heroNameGap)

            if let subtitle = model.subtitle {
                Text(verbatim: subtitle)
                    .font(.appBody.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }

            // The timer and the line it replaces share one place and stay in
            // the hierarchy, so they cross-fade where the hero is going
            // instead of one being left behind while the card opens.
            let showsTimer = model.isConnected && model.startedAt != nil
            ZStack {
                Text(verbatim: model.routeSummary)
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .opacity(showsTimer ? 0 : 1)
                    .accessibilityHidden(showsTimer)

                Text(model.startedAt ?? .now, style: .timer)
                    .font(.appTitle.weight(.medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .opacity(showsTimer ? 1 : 0)
                    .accessibilityHidden(!showsTimer)
            }
            .padding(.top, layout.heroTimerGap)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var miniHero: some View {
        HStack(spacing: 12) {
            CallVoiceAvatar(
                address: model.address,
                size: layout.miniAvatar,
                isLive: isActive,
                monitor: monitor
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: model.title)
                    .font(.appHeadline)
                    .lineLimit(1)
                if let subtitle = model.subtitle {
                    Text(verbatim: subtitle)
                        .font(.appCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if model.isConnected, let startedAt = model.startedAt {
                Text(startedAt, style: .timer)
                    .font(.appTitle.weight(.medium).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .fixedSize()
            }
        }
        .padding(.top, layout.miniHeroTopGap)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Notices

    /// Short messages that sit just above the controls.
    @ViewBuilder
    private var notices: some View {
        if model.phase == .incoming {
            Text(verbatim: model.canAnswer ? L10n.tr("使用 Mac 接听") : L10n.tr("USB 语音通道尚未就绪"))
                .font(.appCaption)
                .foregroundStyle(model.canAnswer ? Color.secondary : InCallPalette.incoming)
                .padding(.bottom, 12)
        }

        if model.phase == .recovering, let error = model.error {
            Label(L10n.tr(error), systemImage: "exclamationmark.triangle.fill")
                .font(.appCaption)
                .foregroundStyle(InCallPalette.incoming)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 12)
        }

        if model.isSavingRecording {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("正在保存录音…")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
        }

        if let recordingError = model.recordingError {
            Label(L10n.tr(recordingError), systemImage: "exclamationmark.triangle.fill")
                .font(.appCaption)
                .foregroundStyle(InCallPalette.recording)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Controls

    /// One row for every state. The hang-up button is always the same view,
    /// so when the call connects it slides to its place while the other
    /// controls grow in beside it. The others are inserted and removed, not
    /// hidden: glass keeps drawing under a zero opacity.
    @ViewBuilder
    private var controls: some View {
        let diameter = layout.controlDiameter
        let incoming = model.phase == .incoming
        if model.phase == .idle || model.phase == .unavailable || model.phase == .error {
            EmptyView()
        } else {
            AdaptiveGlassContainer(spacing: 4) {
                HStack(alignment: .top, spacing: 0) {
                    if model.isConnected {
                        InCallControlButton(
                            title: model.muted ? L10n.tr("取消静音") : L10n.tr("静音"),
                            systemImage: model.muted ? "mic.slash.fill" : "mic.fill",
                            style: model.muted ? .selected(CallVoiceTint.local) : .plain,
                            isEnabled: isActive,
                            diameter: diameter,
                            action: actions.toggleMute
                        )
                        .transition(controlTransition(order: 0))

                        InCallControlButton(
                            title: L10n.tr("拨号盘"),
                            systemImage: "circle.grid.3x3.fill",
                            style: layout.keypadOpen ? .selected(CallVoiceTint.local) : .plain,
                            isEnabled: isActive,
                            diameter: diameter,
                            action: actions.toggleKeypad
                        )
                        .transition(controlTransition(order: 1))

                        InCallControlButton(
                            title: model.isRecording ? L10n.tr("停止录音") : L10n.tr("录音"),
                            systemImage: model.isRecording ? "stop.circle.fill" : "record.circle",
                            style: model.isRecording ? .selected(InCallPalette.recording) : .plain,
                            isEnabled: model.canToggleRecording,
                            diameter: diameter,
                            help: model.isRecording
                                ? L10n.tr("停止并保存本次录音")
                                : L10n.tr("录制通话双方声音"),
                            action: actions.toggleRecording
                        )
                        .transition(controlTransition(order: 2))
                    }

                    InCallControlButton(
                        title: incoming ? L10n.tr("拒接") : L10n.tr("挂断"),
                        systemImage: "phone.down.fill",
                        style: .prominent(InCallPalette.hangUp),
                        isEnabled: model.canHangUp,
                        diameter: diameter,
                        action: actions.hangUp
                    )

                    if incoming {
                        // Half a pitch of air between declining and answering.
                        Color.clear
                            .frame(width: InCallLayout.controlPitch / 2, height: 1)

                        InCallControlButton(
                            title: L10n.tr("接听"),
                            systemImage: "phone.fill",
                            style: .prominent(InCallPalette.answer),
                            isEnabled: model.canAnswer,
                            diameter: diameter,
                            action: actions.answer
                        )
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    /// A control that appears when the call connects fades in, one after the
    /// other, once the card has mostly opened. Only a fade: the glass draws
    /// its own arrival, and a scale on top makes disc and icon drift apart.
    private func controlTransition(order: Int) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let appear = Animation
            .easeOut(duration: 0.26)
            .delay(InCallCard.revealDelay + Double(order) * 0.06)
        return .asymmetric(
            insertion: .opacity.animation(appear),
            removal: .opacity
        )
    }

    /// What appears when the call connects waits this long, so it fades in
    /// on a card that has nearly reached its size rather than on one that is
    /// still moving.
    fileprivate static let revealDelay = 0.2

    private var revealTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .center))
                .animation(.easeOut(duration: 0.3).delay(InCallCard.revealDelay)),
            removal: .opacity
        )
    }
}

/// Colours and titles of the call states.
enum InCallPalette {
    static let recording = CallVoiceTint.adaptive(light: 0xB42318, dark: 0xFF8A80)
    static let incoming = CallVoiceTint.adaptive(light: 0xB45309, dark: 0xFFB454)
    static let hangUp = Color(.sRGB, red: 0.86, green: 0.19, blue: 0.14, opacity: 1)
    static let answer = Color(.sRGB, red: 0.13, green: 0.66, blue: 0.31, opacity: 1)

    static func tint(for phase: CallPhase) -> Color {
        switch phase {
        case .incoming: return incoming
        case .active: return CallVoiceTint.remote
        case .dialing, .alerting, .ending, .recovering: return CallVoiceTint.local
        case .unavailable, .idle, .error: return .secondary
        }
    }

    static func title(for phase: CallPhase) -> String {
        switch phase {
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
}

/// The avatar with a soft ring that swells while the other party speaks.
private struct CallVoiceAvatar: View {
    let address: String
    let size: CGFloat
    let isLive: Bool
    @ObservedObject var monitor: CallAudioLevelMonitor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = isLive ? CGFloat(monitor.reading.history.latestRemote) : 0
        let ring = (level * size * 0.12).rounded()
        ContactFaceAvatar(address: address, size: size)
            .background {
                // Only the ring's size follows the voice. Animating the whole
                // circle would also give its position this short animation,
                // and it would run ahead of the avatar while the card opens.
                Circle()
                    .fill(CallVoiceTint.remote.opacity(0.16))
                    .animation(reduceMotion ? nil : .linear(duration: 0.12)) { circle in
                        circle.scaleEffect(1 + ring * 2 / size)
                    }
            }
    }
}

/// Rings that spread from the avatar while the call is ringing, on either
/// end. They fade out when it is answered and the voice ring takes over. The
/// view stays in place either way, so it travels with the avatar.
private struct CallRingingPulse: View {
    let tint: Color
    let isRinging: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period: TimeInterval = 2.0

    var body: some View {
        Group {
            if reduceMotion {
                Circle()
                    .stroke(tint.opacity(0.22), lineWidth: 2)
                    .padding(-7)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRinging)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ring(phase: time / Self.period)
                        ring(phase: time / Self.period + 0.5)
                    }
                }
            }
        }
        .opacity(isRinging ? 1 : 0)
        .accessibilityHidden(true)
    }

    /// One ring: it leaves the avatar's edge, grows and fades out.
    private func ring(phase: Double) -> some View {
        let progress = phase - phase.rounded(.down)
        let eased = 1 - pow(1 - progress, 2)
        return Circle()
            .stroke(tint.opacity(0.30 * (1 - progress)), lineWidth: 2)
            .padding(-(2 + 16 * eased))
    }
}

/// The waveform panel fed by the live levels. It is its own view so the ten
/// readings a second redraw only the panel, not the whole card.
private struct LiveCallWaveformPanel: View {
    @ObservedObject var monitor: CallAudioLevelMonitor
    let layout: InCallLayout
    let muted: Bool
    let audioActive: Bool
    /// False while a connected call is ending or being re-read: the lanes
    /// stay, but nothing is said about who speaks.
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reading = monitor.reading
        CallWaveformPanel(
            history: reading.history,
            takenAt: reduceMotion || !audioActive ? nil : reading.takenAt,
            laneHeight: layout.laneHeight,
            paddingTop: layout.panelPaddingTop,
            paddingBottom: layout.panelPaddingBottom,
            muted: muted,
            hint: layout.keypadOpen ? nil : hint(for: reading.history.speaking)
        )
    }

    private func hint(for speaking: CallSpeakingState) -> String {
        guard isActive else { return "" }
        return CallSpeakingHint.text(speaking: speaking, muted: muted, audioActive: audioActive)
    }
}

/// The keypad that opens inside the card: the tones sent so far, then twelve
/// keys whose outer columns line up with the first and last control below.
struct InCallKeypad: View {
    let layout: InCallLayout
    let digits: String
    var flashedTone: String?
    let send: (String) -> Void
    let clear: () -> Void

    private static let rows: [[(digit: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        VStack(spacing: 0) {
            digitsField
                .frame(width: layout.controlRowExtent, height: layout.digitsHeight)
                .padding(.top, layout.keypadTopGap)

            AdaptiveGlassContainer(spacing: 4) {
                VStack(spacing: layout.keyRowGap) {
                    ForEach(Self.rows.indices, id: \.self) { row in
                        HStack(spacing: layout.keyColumnGap) {
                            ForEach(Self.rows[row], id: \.digit) { key in
                                keyButton(key.digit, letters: key.letters)
                            }
                        }
                    }
                }
            }
            .padding(.top, layout.keysTopGap)
        }
        .frame(maxWidth: .infinity)
    }

    private var digitsField: some View {
        HStack(spacing: 8) {
            Text(verbatim: digits.isEmpty ? L10n.tr("点按键或用键盘输入") : L10n.tr("已发送"))
                .font(.appCallout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: !digits.isEmpty, vertical: false)

            Spacer(minLength: 0)

            if !digits.isEmpty {
                Text(verbatim: digits)
                    .font(.appTitle.weight(.medium).monospacedDigit())
                    .tracking(1)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(1)
                    .accessibilityLabel(L10n.tr("已发送的按键 %@", digits))

                Button(action: clear) {
                    Text("清除")
                        .font(.appCaptionStrong)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: max(22, layout.digitsHeight - 14))
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("清空按键显示，不会撤回已发送的按键"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, digits.isEmpty ? 14 : 6)
        .frame(maxHeight: .infinity)
        .inCallInsetSurface(cornerRadius: layout.digitsHeight / 2)
    }

    private func keyButton(_ digit: String, letters: String) -> some View {
        let size = layout.keySize
        let flashed = flashedTone == digit
        return Button {
            send(digit)
        } label: {
            VStack(spacing: 0) {
                // The asterisk is drawn small and high in the system font;
                // enlarge and lower it so it sits like the digits.
                Text(verbatim: digit)
                    .font(.system(size: size * (digit == "*" ? 0.52 : 0.38), weight: .medium))
                    .baselineOffset(digit == "*" ? -size * 0.15 : 0)
                    .frame(height: (size * 0.44).rounded())
                Text(verbatim: letters.isEmpty ? " " : letters)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .frame(height: 11)
            }
            .frame(width: size, height: size)
            .adaptiveGlassSurface(
                cornerRadius: size / 2,
                treatment: .clear,
                tint: flashed ? CallVoiceTint.local.opacity(0.24) : nil,
                isInteractive: true
            )
            .contentShape(Circle())
        }
        .buttonStyle(InCallPressStyle(isHeld: flashed, pressedScale: 0.92))
        .accessibilityLabel(letters.isEmpty ? digit : L10n.tr("%@，%@", digit, letters))
    }
}

/// One round control with its label underneath. Every control takes one
/// pitch of width, so the row lines up with the keypad above it whatever the
/// label says.
struct InCallControlButton: View {
    enum Style: Equatable {
        case plain
        /// Switched on: tinted glass and icon.
        case selected(Color)
        /// A filled button: answer, hang up.
        case prominent(Color)
    }

    let title: String
    let systemImage: String
    var style: Style = .plain
    var isEnabled = true
    var diameter: CGFloat = 58
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: diameter, height: diameter)
                    .background {
                        Circle()
                            .fill(baseFill)
                            .allowsHitTesting(false)
                    }
                    .adaptiveGlassSurface(
                        cornerRadius: diameter / 2,
                        treatment: style == .plain ? .clear : .regular,
                        tint: glassTint,
                        isInteractive: isEnabled
                    )
                    .contentShape(Circle())

                Text(verbatim: title)
                    .font(.appCaption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: InCallLayout.controlPitch - 6, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: InCallLayout.controlPitch)
        }
        .buttonStyle(InCallPressStyle(isHeld: false, pressedScale: 0.94))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.46)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isSelected: Bool {
        if case .selected = style { return true }
        return false
    }

    private var iconColor: Color {
        switch style {
        case .plain: return .primary
        case let .selected(tint): return tint
        case .prominent: return .white
        }
    }

    private var glassTint: Color? {
        switch style {
        case .plain: return nil
        case let .selected(tint): return tint.opacity(0.2)
        case let .prominent(tint): return tint
        }
    }

    private var baseFill: Color {
        switch style {
        case .plain: return .clear
        case let .selected(tint): return tint.opacity(0.08)
        case let .prominent(tint): return tint.opacity(0.72)
        }
    }
}

private struct InCallPressStyle: ButtonStyle {
    /// Shows the pressed look without a pointer, for a tone sent from the
    /// keyboard.
    let isHeld: Bool
    let pressedScale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isHeld
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? pressedScale : 1)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}
