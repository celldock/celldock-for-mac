import SwiftUI

private struct ForwardingTestButton: View {
    let channel: SMSForwardChannel
    @State private var isSending = false
    @State private var resultMessage: String?
    @State private var resultIsSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                sendTest()
            } label: {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.tr("发送测试"))
                }
            }
            .adaptiveGlassButton()
            .disabled(isSending)

            if let resultMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: resultIsSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(resultIsSuccess ? .green : .red)
                    Text(resultMessage)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sendTest() {
        isSending = true
        resultMessage = nil
        Task {
            let result = await SMSForwardingService.shared.sendTest(channel)
            await MainActor.run {
                isSending = false
                switch result {
                case .success:
                    resultIsSuccess = true
                    resultMessage = L10n.tr("测试消息已发送，请去对应渠道确认收到。")
                case let .failure(error):
                    resultIsSuccess = false
                    resultMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct ForwardingSheetChrome<Content: View>: View {
    let title: String
    let onSave: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.appHeadline)

            content()

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(L10n.tr("取消")) { dismiss() }
                Button(L10n.tr("保存")) {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 320)
    }
}

struct BarkForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var serverURL: String

    init(store: SMSForwardingStore) {
        self.store = store
        _serverURL = State(initialValue: store.bark.serverURL)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置 Bark")) {
            store.saveBark(BarkForwardingConfiguration(serverURL: serverURL))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("推送地址"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                TextField("https://api.day.app/你的Key/", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.tr("从 Bark App 里复制包含设备 Key 的完整地址。"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)

                ForwardingTestButton(channel: .bark)
                    .padding(.top, 8)
            }
        }
    }
}

struct FeishuForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var webhookURL: String
    @State private var secret: String

    init(store: SMSForwardingStore) {
        self.store = store
        _webhookURL = State(initialValue: store.feishu.webhookURL)
        _secret = State(initialValue: store.feishu.secret)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置飞书机器人")) {
            store.saveFeishu(FeishuForwardingConfiguration(webhookURL: webhookURL, secret: secret))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Webhook 地址"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                TextField("https://open.feishu.cn/open-apis/bot/v2/hook/...", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)

                Text(L10n.tr("签名密钥（可选）"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                SecureField(L10n.tr("开启了“签名校验”才需要填写"), text: $secret)
                    .textFieldStyle(.roundedBorder)

                ForwardingTestButton(channel: .feishu)
                    .padding(.top, 8)
            }
        }
    }
}

struct DingTalkForwardingConfigSheet: View {
    @ObservedObject var store: SMSForwardingStore
    @State private var accessToken: String
    @State private var secret: String

    init(store: SMSForwardingStore) {
        self.store = store
        _accessToken = State(initialValue: store.dingtalk.accessToken)
        _secret = State(initialValue: store.dingtalk.secret)
    }

    var body: some View {
        ForwardingSheetChrome(title: L10n.tr("配置钉钉机器人")) {
            store.saveDingTalk(DingTalkForwardingConfiguration(accessToken: accessToken, secret: secret))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("Webhook AccessToken"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                TextField(L10n.tr("access_token 参数的值"), text: $accessToken)
                    .textFieldStyle(.roundedBorder)

                Text(L10n.tr("签名密钥（可选）"))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                SecureField(L10n.tr("开启了“加签”才需要填写"), text: $secret)
                    .textFieldStyle(.roundedBorder)

                ForwardingTestButton(channel: .dingtalk)
                    .padding(.top, 8)
            }
        }
    }
}
