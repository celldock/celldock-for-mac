import SwiftUI

struct SMSComposerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    private let onClose: (() -> Void)?
    private let isReply: Bool
    @State private var destination: String
    @State private var messageBody = ""
    @State private var localError: String?
    @FocusState private var destinationFocused: Bool
    @FocusState private var messageFocused: Bool

    init(destination: String = "", onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        isReply = !destination.isEmpty
        _destination = State(initialValue: destination)
    }

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            AdaptiveGlassContainer(spacing: 14) {
                composerContent
            }
            .padding(24)
        }
        .frame(width: 520, height: 440)
        .onAppear {
            if isReply {
                messageFocused = true
            } else {
                destinationFocused = true
            }
        }
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isReply ? L10n.tr("回复短信") : L10n.tr("新短信"))
                        .font(.appTitle)
                    Text(L10n.tr("通过当前 SIM 卡发送"))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                }
                .adaptiveGlassButton()
                .controlSize(.small)
                .disabled(appState.isSendingMessageOnCurrentModule)
                .accessibilityLabel(L10n.tr("关闭"))
            }

            recipientSection
            messageSection

            if let localError {
                Label {
                    Text(verbatim: localError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                    .font(.appCaption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let segmentCount, segmentCount > 1 {
                Label(
                    L10n.tr("运营商会按 %lld 条长短信分片计费。", Int64(segmentCount)),
                    systemImage: "info.circle"
                )
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(appState.moduleIsConnected(nil) ? L10n.tr("模块已连接") : L10n.tr("模块未连接"))
                    .font(.appCaption)
                    .foregroundStyle(appState.moduleIsConnected(nil) ? Color.secondary : Color.red)
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) { close() }
                    .adaptiveGlassButton()
                    .disabled(appState.isSendingMessageOnCurrentModule)
                Button {
                    send()
                } label: {
                    if appState.isSendingMessageOnCurrentModule {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("发送中"))
                        }
                    } else {
                        Label {
                            Text(verbatim: sendButtonTitle)
                        } icon: {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                }
                .adaptiveGlassButton(.prominent)
                .disabled(!canSend)
            }
        }
    }

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.tr("收件人"))
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if appState.isPresentationPrivacyEnabled {
                    SecureField(L10n.tr("手机号"), text: $destination)
                } else {
                    TextField(L10n.tr("手机号，例如 13800138000"), text: $destination)
                }
            }
                .textFieldStyle(.roundedBorder)
                .focused($destinationFocused)
                .disabled(appState.isSendingMessageOnCurrentModule)
        }
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.tr("内容"))
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: compositionSummary)
                    .font(.appCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                if messageBody.isEmpty {
                    Text(L10n.tr("输入短信内容…"))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $messageBody)
                    .font(.appBody)
                    .focused($messageFocused)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .disabled(appState.isSendingMessageOnCurrentModule)
            }
            .frame(minHeight: 150)
            .adaptiveGlassSurface(cornerRadius: 13, treatment: .clear)
        }
    }

    private var segmentCount: Int? {
        SMSPDUEncoder.segmentCount(destination: destination, body: messageBody)
    }

    private var compositionSummary: String {
        let units = messageBody.utf16.count
        guard let segmentCount else {
            return L10n.tr("%lld 个 UCS-2 单元", Int64(units))
        }
        return L10n.tr("%lld 个单元 · %lld 条", Int64(units), Int64(segmentCount))
    }

    private var sendButtonTitle: String {
        guard let segmentCount, segmentCount > 1 else { return L10n.tr("发送") }
        return L10n.tr("发送（%lld 条）", Int64(segmentCount))
    }

    private var canSend: Bool {
        appState.moduleIsConnected(nil) &&
            !appState.currentCommunicationModuleHasCall &&
            !appState.isSendingMessageOnCurrentModule &&
            segmentCount != nil &&
            !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        localError = nil
        appState.sendSMS(to: destination, body: messageBody) { result in
            switch result {
            case .success:
                close()
            case let .failure(message, isDeliveryUncertain):
                if isDeliveryUncertain {
                    close()
                } else {
                    localError = message
                }
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
