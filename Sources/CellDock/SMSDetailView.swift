import SwiftUI

struct SMSDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let message: SMSMessage
    private let onClose: (() -> Void)?

    init(message: SMSMessage, onClose: (() -> Void)? = nil) {
        self.message = message
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "message.fill")
                        .font(.appSymbol(.button, weight: .regular))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: senderIdentity)
                            .font(.appHeadline)
                        Text(verbatim: fullTimestamp)
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                    Spacer()
                }

                ScrollView {
                    SMSMessageContentView(message: message, onOpenDialer: close)
                        .font(.appBody)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .adaptiveGlassSurface(cornerRadius: 16, treatment: .clear)

                HStack(spacing: 10) {
                    Text(verbatim: appState.isPresentationPrivacyEnabled
                        ? L10n.tr("内容已隐藏")
                        : L10n.tr("%lld 个字符", Int64(message.body.count)))
                        .font(.appCaption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        appState.showStandaloneSMSComposer(to: message.sender)
                    } label: {
                        Label(L10n.tr("回复"), systemImage: "arrowshape.turn.up.left")
                    }
                    .adaptiveGlassButton()
                    .disabled(!SMSPDUEncoder.isValidDestination(message.sender))
                    .help(SMSPDUEncoder.isValidDestination(message.sender)
                        ? L10n.tr("回复这条短信")
                        : L10n.tr("该发件人地址不能直接回复"))

                    Button {
                        appState.copy(message)
                    } label: {
                        Label(L10n.tr("复制"), systemImage: "doc.on.doc")
                    }
                    .adaptiveGlassButton()

                    Button(L10n.tr("完成")) { close() }
                        .adaptiveGlassButton(.prominent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 500, height: 500)
        .accessibilityLabel(L10n.tr("短信详情，来自 %@", senderIdentity))
    }

    private var senderIdentity: String {
        appState.privacyPresentation.identity(
            contactName: SystemContactStore.shared.displayName(for: message.sender),
            number: message.sender
        )
    }

    private var fullTimestamp: String {
        message.timestamp.formatted(
            .dateTime
                .year()
                .month(.wide)
                .day()
                .hour()
                .minute()
                .second()
        )
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
