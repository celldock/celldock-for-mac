import SwiftUI

enum MenuContentPresentation {
    case menuBar
    case window
}

struct MenuContentView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let presentation: MenuContentPresentation
    @State private var deletionConfirmation = SMSDeletionConfirmationState()
    @State private var isComposerPresented = false
    @State private var composerDestination = ""
    @State private var isATConsolePresented = false
    @State private var isMessageDetailPresented = false
    @State private var selectedMessage: SMSMessage?
    @FocusState private var deletionCancelFocused: Bool

    init(presentation: MenuContentPresentation = .menuBar) {
        self.presentation = presentation
    }

    var body: some View {
        ZStack {
            if presentation == .menuBar {
                // The menu bar NSPanel already supplies its own system glass surface.
                // Adding another full-window glass layer makes the popover
                // look denser than the standalone window.
                Color.clear
                    .ignoresSafeArea()
            } else {
                AdaptiveGlassBackdrop()
                    .ignoresSafeArea()
            }

            content
                .disabled(deletionConfirmation.isPresented)
                .allowsHitTesting(!deletionConfirmation.isPresented)
                .accessibilityHidden(deletionConfirmation.isPresented)

            if deletionConfirmation.isPresented {
                Color.black.opacity(0.11)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)
                    .zIndex(1)
                if let pendingDeletion = deletionConfirmation.resolve(in: appState.messages) {
                    deletionConfirmation(for: pendingDeletion)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .frame(
            minWidth: presentation == .window ? 520 : 430,
            maxWidth: presentation == .window ? .infinity : 430,
            minHeight: presentation == .window ? 500 : 740,
            maxHeight: presentation == .window ? .infinity : 740
        )
        .animation(.easeInOut(duration: 0.15), value: deletionConfirmation.isPresented)
        .onChange(of: appState.messageDetailRequestSerial) { _, _ in
            guard presentation == .window,
                  let messageID = appState.requestedMessageDetailID,
                  let message = appState.messages.first(where: { $0.id == messageID }) else {
                return
            }
            selectedMessage = message
            isMessageDetailPresented = true
        }
        .onChange(of: deletionConfirmation.isPresented) { _, isPresented in
            if isPresented {
                DispatchQueue.main.async { deletionCancelFocused = true }
            }
        }
        .onChange(of: appState.messages) { _, messages in
            deletionConfirmation.reconcile(with: messages)
        }
        .onExitCommand {
            if deletionConfirmation.isPresented { deletionConfirmation.cancel() }
        }
        .onDisappear {
            deletionConfirmation.cancel()
            appState.dismissTransientMessage()
        }
        .sheet(isPresented: $isComposerPresented, onDismiss: presentedFlowDidDismiss) {
            SMSComposerView(destination: composerDestination)
                .environmentObject(appState)
        }
        .sheet(isPresented: $isATConsolePresented, onDismiss: presentedFlowDidDismiss) {
            ATConsoleView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $isMessageDetailPresented, onDismiss: messageDetailDidDismiss) {
            if let selectedMessage {
                SMSDetailView(message: selectedMessage)
                    .environmentObject(appState)
            }
        }
    }

    private var content: some View {
        AdaptiveGlassContainer(spacing: 14) {
            VStack(spacing: 14) {
                cellularOverviewCard
                if let message = appState.transientMessage {
                    notice(message, isError: appState.transientIsError)
                }
                if let error = appState.modem.lastError ?? appState.network.lastError {
                    notice(error, isError: true, dismissible: false)
                }
                communicationLauncher
            }
        }
        .padding(16)
    }

    private var communicationLauncher: some View {
        HStack(spacing: 10) {
            Button {
                appState.showPhoneWindow()
            } label: {
                Label(L10n.tr("打开电话"), systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton()

            Button {
                appState.showMessagesWindow()
            } label: {
                HStack(spacing: 6) {
                    Label(L10n.tr("打开短信"), systemImage: "message.fill")
                    if appState.unreadCount > 0 {
                        Text("\(min(appState.unreadCount, 99))")
                            .font(.appCaption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton()
        }
        .adaptiveGlassCard(treatment: .clear)
    }

    private func deletionConfirmation(for message: SMSMessage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.appSymbol(.small, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.11), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("删除这条短信？"))
                        .font(.appBodyStrong)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.tr("删除后这条短信将不再出现在 CellDock 中，此操作无法撤销。"))
                        .font(.appCallout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L10n.tr("取消"), role: .cancel) {
                    deletionConfirmation.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .focused($deletionCancelFocused)
                .adaptiveGlassButton()
                .frame(minWidth: 72)

                Button(L10n.tr("删除"), role: .destructive) {
                    confirmDeletion(message)
                }
                .adaptiveGlassButton(.prominent)
                .tint(.red)
                .frame(minWidth: 72)
            }
            .controlSize(.regular)
        }
        .frame(width: 292)
        .adaptiveGlassSurface(
            cornerRadius: 17,
            padding: 18
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(L10n.tr("删除短信确认"))
    }

    private func confirmDeletion(_ message: SMSMessage) {
        guard let confirmedID = deletionConfirmation.takeConfirmedMessageID(id: message.id),
              let currentMessage = appState.messages.first(where: { $0.id == confirmedID }) else {
            return
        }
        appState.delete(currentMessage)
    }

    private var cellularOverviewCard: some View {
        CellularOverviewCard(
            treatment: contentGlassTreatment,
            onOpenMainWindow: presentation == .menuBar ? presentMainWindow : nil,
            onOpenATConsole: presentATConsole,
            onRefresh: appState.refresh,
            onOpenSettings: presentSettings
        )
    }

    private var callCard: some View {
        CompactCallContent()
        .adaptiveGlassCard(treatment: contentGlassTreatment)
    }

    private var messageSection: some View {
        VStack(spacing: 10) {
            HStack {
                Label(L10n.tr("短信"), systemImage: "message.fill")
                    .font(.appBodyStrong)
                if appState.unreadCount > 0 {
                    Text("\(appState.unreadCount)")
                        .font(.appCaption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue, in: Capsule())
                }
                Spacer()
                if appState.unreadCount > 0 {
                    Button(L10n.tr("全部已读")) { appState.markAllRead() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .font(.appCaption)
                }
                Button {
                    presentSMSComposer()
                } label: {
                    Label(L10n.tr("新短信"), systemImage: "square.and.pencil")
                }
                .adaptiveGlassButton()
                .controlSize(.small)
                .font(.appCaption)
                .disabled(
                    appState.currentCommunicationModule?.isCommunicationEligible != true ||
                        appState.currentCommunicationModuleHasCall
                )
                .help(appState.currentCommunicationModuleHasCall
                    ? L10n.tr("所选模组通话期间暂不发送短信")
                    : L10n.tr("撰写并发送短信"))
                .accessibilityIdentifier("ComposeSMSButton")
            }

            if appState.messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.appSymbol(.button, weight: .regular))
                        .foregroundStyle(.tertiary)
                    Text(appState.cellularModules.contains(where: { $0.modem.isConnected })
                        ? L10n.tr("模组中暂无短信")
                        : L10n.tr("插入模组后会在后台接收短信"))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.messages) { message in
                            messageRow(message)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .adaptiveGlassCard(treatment: contentGlassTreatment)
    }

    private func messageRow(_ message: SMSMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.blue)
                .frame(width: 7, height: 7)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    presentMessageDetail(message)
                } label: {
                    HStack {
                        Text(verbatim: messageIdentity(message))
                            .font(.appCaption.weight(message.isRead ? .medium : .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(message.timestamp, style: .relative)
                            .font(.appCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                if let code = message.verificationCode {
                    if appState.isPresentationPrivacyEnabled {
                        Label(L10n.tr("验证码已隐藏"), systemImage: "eye.slash.fill")
                            .font(.appCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else {
                        VerificationCodeBadge(code: code) {
                            appState.markRead(message)
                        }
                        .fixedSize()
                    }
                }

                Button {
                    presentMessageDetail(message)
                } label: {
                    Text(verbatim: appState.privacyPresentation.messagePreview(message.preview))
                        .font(.appCaption)
                        .foregroundStyle(message.isRead ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .help(L10n.tr("点击正文查看完整短信"))

            Menu {
                Button(L10n.tr("回复"), systemImage: "arrowshape.turn.up.left") {
                    presentSMSComposer(to: message.sender)
                }
                .disabled(!SMSPDUEncoder.isValidDestination(message.sender))
                Button(L10n.tr("复制"), systemImage: "doc.on.doc") { appState.copy(message) }
                Button(L10n.tr("标为已读"), systemImage: "envelope.open") { appState.markRead(message) }
                Divider()
                Button(L10n.tr("删除"), systemImage: "trash", role: .destructive) {
                    DispatchQueue.main.async {
                        deletionConfirmation.request(message)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L10n.tr("短信操作，来自 %@", messageIdentity(message)))
        }
        .padding(10)
        .background(
            message.isRead ? Color.clear : Color.blue.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func messageIdentity(_ message: SMSMessage) -> String {
        appState.privacyPresentation.identity(
            contactName: SystemContactStore.shared.displayName(for: message.sender),
            number: message.sender
        )
    }

    private func notice(_ text: String, isError: Bool = false, dismissible: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(verbatim: text).lineLimit(2)
            Spacer()
            if dismissible {
                Button {
                    appState.dismissTransientMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .adaptiveGlassButton()
                .controlSize(.mini)
            }
        }
        .font(.appCaption)
        .foregroundStyle(isError ? Color.red : Color.primary)
        .padding(9)
        .adaptiveGlassSurface(
            cornerRadius: 12,
            treatment: .clear,
            tint: (isError ? Color.red : Color.green).opacity(0.10)
        )
    }

    private var contentGlassTreatment: AdaptiveGlassTreatment {
        presentation == .menuBar ? .clear : .regular
    }

    private func presentSMSComposer(to destination: String = "") {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneSMSComposer(to: destination)
            }
        } else {
            composerDestination = destination
            isComposerPresented = true
        }
    }

    private func presentATConsole() {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneATConsole()
            }
        } else {
            isATConsolePresented = true
        }
    }

    private func presentMainWindow() {
        transitionFromMenuBar {
            appState.showMainWindow()
        }
    }

    private func presentSettings() {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneSettings()
            }
        } else {
            appState.showPhoneWindow(section: .settings)
        }
    }

    private func presentedFlowDidDismiss() {
        guard presentation == .window else { return }
        appState.presentedFlowDidDismiss()
    }

    private func presentMessageDetail(_ message: SMSMessage) {
        if presentation == .menuBar {
            transitionFromMenuBar {
                appState.showStandaloneMessageDetail(message)
            }
        } else {
            appState.markRead(message)
            selectedMessage = appState.messages.first(where: { $0.id == message.id }) ?? message
            isMessageDetailPresented = true
        }
    }

    private func messageDetailDidDismiss() {
        selectedMessage = nil
        presentedFlowDidDismiss()
    }

    private func transitionFromMenuBar(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: action)
    }

}
