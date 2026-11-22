import SwiftUI

struct DialerView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: PhoneWindowModel
    @ObservedObject var contacts: SystemContactStore
    @FocusState private var numberFocused: Bool

    private let keypad: [(digit: String, letters: String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", "")
    ]

    var body: some View {
        GeometryReader { proxy in
            let metrics = DialerMetrics(availableHeight: proxy.size.height)

            ScrollView(.vertical) {
                AdaptiveGlassContainer(spacing: metrics.spacing) {
                    dialerCard(metrics: metrics)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, proxy.size.height - (metrics.outerPadding * 2)))
                .padding(.horizontal, metrics.outerPadding)
                .padding(.vertical, metrics.outerPadding)
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            numberFocused = model.dialNumber.isEmpty
        }
    }

    private func dialerCard(metrics: DialerMetrics) -> some View {
        VStack(spacing: metrics.spacing) {
            identityHeader(metrics: metrics)
            numberField(metrics: metrics)
            keypadView(metrics: metrics)
            bottomActions(metrics: metrics)

            if let endDescription = appState.call.lastEndDescription {
                Label {
                    Text(verbatim: endDescription)
                } icon: {
                    Image(systemName: "info.circle")
                }
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, metrics.cardHorizontalPadding)
        .padding(.vertical, metrics.contentVerticalPadding)
        .frame(maxWidth: metrics.cardMaximumWidth)
        .adaptiveGlassSurface(
            cornerRadius: metrics.cardCornerRadius,
            treatment: .clear
        )
    }

    private func identityHeader(metrics: DialerMetrics) -> some View {
        VStack(spacing: metrics.compact ? 5 : 7) {
            // The face of the number being dialled, in the colour and with the
            // badge of the line the call will go out on.
            if model.dialNumber.isEmpty {
                DialerAvatar(
                    title: nil,
                    color: dialingLine.tint.solid,
                    size: metrics.avatarSize
                )
            } else {
                ContactFaceAvatar(
                    address: model.dialNumber,
                    size: metrics.avatarSize,
                    badgeText: dialingLine.badgeText,
                    badgeColor: dialingLine.tint.solid
                )
                .help(dialingLine.fullTitle)
            }

            Text(verbatim: identityTitle)
                .font(.appTitle)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(verbatim: callAvailabilityText)
                    .font(.appCallout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if offersVoiceCallSwitch {
                    // The switch lives on the SIM page, with its confirmation.
                    Button(L10n.tr("去开启")) {
                        model.present(
                            number: nil,
                            section: nil,
                            simModuleID: appState.currentCommunicationModuleID
                        )
                    }
                    .buttonStyle(.link)
                    .font(.appCallout)
                    .help(L10n.tr("在 SIM 页开启该模组的语音通话"))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func numberField(metrics: DialerMetrics) -> some View {
        HStack(spacing: 8) {
            Group {
                if appState.isPresentationPrivacyEnabled {
                    SecureField(L10n.tr("输入电话号码"), text: dialNumberBinding)
                } else {
                    TextField(L10n.tr("输入电话号码"), text: dialNumberBinding)
                }
            }
                .textFieldStyle(.plain)
                .font(metrics.compact ? .appTitle.weight(.medium) : .appDisplay.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .focused($numberFocused)
                .onSubmit(dial)

            Button {
                model.dialNumber = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSymbol(.button))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.dialNumber.isEmpty)
            .opacity(model.dialNumber.isEmpty ? 0.35 : 1)
            .help(L10n.tr("清除号码"))
            .accessibilityLabel(L10n.tr("清除号码"))
        }
        .padding(.horizontal, 15)
        .frame(height: metrics.numberFieldHeight)
        .adaptiveGlassSurface(
            cornerRadius: metrics.numberFieldHeight / 2,
            treatment: .clear,
            isInteractive: true
        )
        .frame(width: metrics.keypadWidth)
    }

    private func keypadView(metrics: DialerMetrics) -> some View {
        let columns = Array(
            repeating: GridItem(
                .fixed(metrics.keySize),
                spacing: metrics.keyColumnSpacing
            ),
            count: 3
        )

        return LazyVGrid(columns: columns, spacing: metrics.keyRowSpacing) {
            ForEach(keypad, id: \.digit) { key in
                DialerKeyButton(
                    digit: key.digit,
                    letters: key.letters,
                    size: metrics.keySize
                ) {
                    appendDigit(key.digit)
                }
            }
        }
        .frame(width: metrics.keypadWidth)
    }

    private func bottomActions(metrics: DialerMetrics) -> some View {
        ZStack {
            DialerIconButton(
                systemImage: "message",
                size: metrics.secondaryActionSize,
                isEnabled: canMessage,
                accessibilityLabel: L10n.tr("发短信")
            ) {
                CommunicationWindowController.shared.showMessages(
                    destination: model.dialNumber
                )
            }
            .offset(x: -metrics.bottomSideActionOffset)

            DialerIconButton(
                systemImage: "phone.fill",
                size: metrics.secondaryActionSize,
                width: metrics.callActionWidth,
                tint: .green,
                isProminent: true,
                isEnabled: canDial,
                accessibilityLabel: L10n.tr("拨打")
            ) {
                dial()
            }

            DialerIconButton(
                systemImage: "delete.left",
                size: metrics.secondaryActionSize,
                isEnabled: !model.dialNumber.isEmpty,
                accessibilityLabel: L10n.tr("删除最后一位")
            ) {
                deleteLastDigit()
            }
            .offset(x: metrics.bottomSideActionOffset)
        }
        .frame(
            width: metrics.keypadWidth,
            height: metrics.secondaryActionSize
        )
    }

    private var dialNumberBinding: Binding<String> {
        Binding(
            get: { model.dialNumber },
            set: { model.dialNumber = String($0.prefix(32)) }
        )
    }

    private var matchedContact: String? {
        contacts.displayName(for: model.dialNumber)
    }

    private var identityTitle: String {
        guard !model.dialNumber.isEmpty else { return L10n.tr("拨打新号码") }
        return appState.privacyPresentation.identity(
            contactName: matchedContact,
            number: model.dialNumber
        )
    }

    private var dialingLine: LineAppearance {
        appState.lineAppearanceResolver.currentAppearance(
            moduleID: appState.currentCommunicationModuleID
        )
    }

    /// Voice is switched off in the module's firmware and the SIM page can
    /// switch it on.
    private var offersVoiceCallSwitch: Bool {
        let modem = appState.currentCommunicationModemSnapshot
        return modem.isConnected &&
            modem.simReady &&
            modem.voiceServiceAvailability == .disabledByFirmware &&
            modem.firmwareVoiceCallsEnabled == false &&
            appState.currentCommunicationModuleID != nil
    }

    private var callAvailabilityText: String {
        let modem = appState.currentCommunicationModemSnapshot
        guard modem.isConnected else { return L10n.tr("当前通信模组未连接") }
        if let simBlocker = modem.dialBlockedBySIMText { return simBlocker }
        if let caution = modem.voiceServiceCautionText { return caution }
        if let operatorName = modem.operatorName, !operatorName.isEmpty {
            let moduleName = appState.currentCommunicationModule?.displayName ?? L10n.tr("当前模组")
            return L10n.tr("可通过 %@ · %@ 呼叫", moduleName, CarrierNameFormatter.localized(operatorName))
        }
        return L10n.tr("可通过当前通信 SIM 卡呼叫")
    }

    private var canDial: Bool {
        appState.currentCommunicationModemSnapshot.simReady &&
            appState.call.canDial &&
            !appState.isChangingCall &&
            CallATParser.normalizedDialNumber(model.dialNumber) != nil
    }

    private var canMessage: Bool {
        SMSPDUEncoder.isValidDestination(model.dialNumber)
    }

    private func appendDigit(_ digit: String) {
        guard model.dialNumber.count < 32 else { return }
        model.dialNumber.append(digit)
    }

    private func deleteLastDigit() {
        guard !model.dialNumber.isEmpty else { return }
        model.dialNumber.removeLast()
    }

    private func dial() {
        guard canDial else { return }
        appState.dial(model.dialNumber)
    }

}

private struct DialerMetrics {
    let compact: Bool
    let outerPadding: CGFloat
    let contentVerticalPadding: CGFloat
    let cardHorizontalPadding: CGFloat
    let cardMaximumWidth: CGFloat
    let cardCornerRadius: CGFloat
    let spacing: CGFloat
    let avatarSize: CGFloat
    let numberFieldHeight: CGFloat
    let keySize: CGFloat
    let keyColumnSpacing: CGFloat
    let keyRowSpacing: CGFloat
    let secondaryActionSize: CGFloat
    let callActionWidth: CGFloat

    init(availableHeight: CGFloat) {
        compact = availableHeight < 610
        outerPadding = compact ? 12 : 22
        contentVerticalPadding = compact ? 14 : 20
        cardHorizontalPadding = compact ? 18 : 26
        cardMaximumWidth = compact ? 390 : 430
        cardCornerRadius = compact ? 26 : 32
        spacing = compact ? 10 : 13
        avatarSize = compact ? 50 : 64
        numberFieldHeight = compact ? 46 : 52
        keySize = compact ? 56 : 64
        keyColumnSpacing = compact ? 14 : 18
        keyRowSpacing = compact ? 8 : 11
        secondaryActionSize = compact ? 52 : 58
        callActionWidth = compact ? 72 : 88
    }

    var keypadWidth: CGFloat {
        (keySize * 3) + (keyColumnSpacing * 2)
    }

    var bottomSideActionOffset: CGFloat {
        keySize + keyColumnSpacing
    }
}

private struct DialerAvatar: View {
    let title: String?
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(color.gradient)
            if let title {
                Text(verbatim: title)
                    .font(.system(size: size * 0.40, weight: .semibold))
            } else {
                Image(systemName: "number")
                    .font(.system(size: size * 0.32, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.18), radius: 8, y: 3)
    }
}

private struct DialerKeyButton: View {
    let digit: String
    let letters: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(verbatim: digit)
                    .font(.system(size: size * 0.39, weight: .medium))
                Text(verbatim: letters.isEmpty ? " " : letters)
                    .font(.system(size: max(10, size * 0.13), weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .frame(height: max(11, size * 0.17))
            }
        }
        .buttonStyle(DialerCircleButtonStyle(size: size))
        .accessibilityLabel(letters.isEmpty ? digit : L10n.tr("%@，%@", digit, letters))
    }
}

private struct DialerIconButton: View {
    let systemImage: String
    let size: CGFloat
    var width: CGFloat? = nil
    var tint: Color?
    var isProminent = false
    let isEnabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.34, weight: .semibold))
        }
        .buttonStyle(
            DialerActionButtonStyle(
                width: width ?? size,
                height: size,
                tint: tint,
                isProminent: isProminent
            )
        )
        .disabled(!isEnabled)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct DialerActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let width: CGFloat
    let height: CGFloat
    var tint: Color?
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)

        configuration.label
            .foregroundStyle(foregroundStyle)
            .frame(width: width, height: height)
            .contentShape(shape)
            .adaptiveGlassSurface(
                cornerRadius: height / 2,
                treatment: isProminent ? .regular : .clear,
                tint: surfaceTint,
                isInteractive: isEnabled
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }

    private var foregroundStyle: Color {
        if isProminent { return .white }
        return isEnabled ? .primary : .secondary
    }

    private var surfaceTint: Color? {
        guard let tint else { return nil }
        return tint.opacity(isProminent ? 0.82 : 0.12)
    }
}

private struct DialerCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let size: CGFloat
    var tint: Color?
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundStyle)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .adaptiveGlassSurface(
                cornerRadius: size / 2,
                treatment: isProminent ? .regular : .clear,
                tint: surfaceTint,
                isInteractive: isEnabled
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
    }

    private var foregroundStyle: Color {
        if isProminent { return .white }
        return isEnabled ? .primary : .secondary
    }

    private var surfaceTint: Color? {
        guard let tint else { return nil }
        return tint.opacity(isProminent ? 0.82 : 0.12)
    }
}
