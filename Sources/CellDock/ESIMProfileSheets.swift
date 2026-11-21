import AppKit
import SwiftUI

struct AddESIMProfileSheet: View {
    let onAdd: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var activationCode = ""
    @State private var confirmationCode = ""
    @State private var localError: String?
    @State private var isReadingQRCode = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.appSymbol(.rail, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(Color.blue.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加 eSIM")
                        .font(.appHeadline)
                    Text("导入运营商二维码，或粘贴 LPA 激活码")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("激活码")
                    .font(.appCalloutStrong)
                SecureField("LPA:1$sm-dp-plus.example$MATCHING-ID", text: $activationCode)
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFocused)
                Text("激活码仅用于本次下载，不会保存到磁盘或日志。")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("确认码（可选）")
                    .font(.appCalloutStrong)
                SecureField("运营商要求时填写", text: $confirmationCode)
                    .textFieldStyle(.roundedBorder)
            }

            if let localError {
                Label(localError, systemImage: "exclamationmark.triangle.fill")
                    .font(.appCaption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button {
                    chooseQRCodeImage()
                } label: {
                    if isReadingQRCode {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("导入二维码图片", systemImage: "photo")
                    }
                }
                .disabled(isReadingQRCode)

                Spacer()

                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载并安装") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { codeFocused = true }
    }

    private func submit() {
        do {
            let parsed = try ESIMActivationCode(rawValue: activationCode)
            if parsed.confirmationCodeRequired,
               confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                localError = L10n.tr("此激活码需要运营商提供的确认码。")
                return
            }
            localError = nil
            onAdd(activationCode, confirmationCode.isEmpty ? nil : confirmationCode)
            activationCode = ""
            confirmationCode = ""
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func chooseQRCodeImage() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择 eSIM 二维码图片")
        panel.prompt = L10n.tr("读取二维码")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isReadingQRCode = true
        localError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ESIMQRCodeReader.activationCode(in: url) }
            DispatchQueue.main.async {
                isReadingQRCode = false
                switch result {
                case let .success(code):
                    activationCode = code
                case let .failure(error):
                    localError = error.localizedDescription
                }
            }
        }
    }
}

struct RenameESIMProfileSheet: View {
    let profile: ESIMProfile
    let onRename: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nickname: String
    @FocusState private var focused: Bool

    init(profile: ESIMProfile, onRename: @escaping (String) -> Void) {
        self.profile = profile
        self.onRename = onRename
        _nickname = State(initialValue: profile.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名 eSIM 套餐")
                .font(.appHeadline)
            TextField("套餐名称", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存") {
                    onRename(nickname)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}
