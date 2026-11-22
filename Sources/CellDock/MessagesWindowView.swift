import SwiftUI

struct MessagesWindowView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var model: MessagesWindowModel
    @ObservedObject var contacts: SystemContactStore
    @Binding var sidebarWidth: CGFloat
    var focusFirstItemRequest = false
    var didHandleFocusFirstItemRequest: () -> Void = {}

    @State private var selectedConversationID: MessageConversation.ID?
    @State private var searchText = ""
    @State private var unreadOnly = false
    @State private var isComposingNew = false
    @State private var newDestination = ""
    @FocusState private var listFocused: Bool

    var body: some View {
        let resolver = appState.lineAppearanceResolver
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            conversationSidebar(resolver: resolver)
        } detail: {
            Group {
                if isComposingNew {
                    NewConversationView(
                        destination: $newDestination,
                        contacts: contacts,
                        resolver: resolver
                    ) { destination in
                        selectConversation(for: destination)
                    }
                    .environmentObject(appState)
                } else if let conversation = selectedConversation {
                    MessageThreadView(
                        conversation: conversation,
                        contactName: contacts.displayName(for: conversation.address),
                        resolver: resolver,
                        scrollTargetMessageID: model.requestedMessageID,
                        didRouteMessage: selectConversation(for:)
                    )
                    // Each peer keeps its own draft and line choice.
                    .id(conversation.id)
                    .environmentObject(appState)
                } else {
                    ContentUnavailableView(
                        L10n.tr("选择一段对话"),
                        systemImage: "message",
                        description: Text(L10n.tr("选择左侧会话，或新建短信。"))
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .communicationDetailColumnStyle()
        }
        .onAppear {
            if contacts.authorizationState == .notDetermined {
                contacts.requestAccess()
            } else if contacts.authorizationState.canReadContacts {
                contacts.reload()
            }
            handlePresentationRequest()
            chooseDefaultConversationIfNeeded()
            handleFocusFirstItemRequest()
        }
        .onChange(of: model.requestSerial) { _, _ in
            handlePresentationRequest()
        }
        .onChange(of: model.composeSerial) { _, _ in
            beginNewMessage()
        }
        .onChange(of: focusFirstItemRequest) { _, requested in
            if requested { handleFocusFirstItemRequest() }
        }
        .onChange(of: conversations.map(\.id)) { _, _ in
            chooseDefaultConversationIfNeeded()
        }
        .onChange(of: selectedConversationID) { _, _ in
            isComposingNew = false
            markSelectedConversationRead()
        }
    }

    private func conversationSidebar(resolver: LineAppearanceResolver) -> some View {
        let visible = filtered(conversations)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(L10n.tr("搜索联系人、号码或短信"), text: $searchText)
                    .font(.appCallout)
                    .communicationSearchField()

                CommunicationIconActionButton(
                    systemImage: "square.and.pencil",
                    accessibilityLabel: L10n.tr("新短信"),
                    action: beginNewMessage
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            CommunicationGlassTabs(
                items: [(false, "全部"), (true, "未读")],
                selection: $unreadOnly
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            List {
                if visible.isEmpty {
                    emptyListState
                } else {
                    ForEach(visible) { conversation in
                        conversationRow(conversation, resolver: resolver)
                    }
                }
            }
            .listStyle(.sidebar)
            .communicationEmphasizedSelection()
            .communicationInitialListFocus($listFocused)
            .scrollContentBackground(.hidden)
            .communicationSidebarScrollEdgeEffect()
            .safeAreaInset(edge: .bottom) {
                if appState.unreadCount > 0 {
                    HStack {
                        Text(L10n.tr("%lld 条未读", Int64(appState.unreadCount)))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.tr("全部已读")) { appState.markAllRead() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(10)
                }
            }
        }
        .communicationSidebarColumnStyle()
        .communicationModuleFloatingSidebar()
    }

    @ViewBuilder
    private var emptyListState: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                L10n.tr(unreadOnly ? "没有未读短信" : "没有符合条件的对话"),
                systemImage: unreadOnly ? "envelope.open" : "line.3.horizontal.decrease.circle"
            )
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func conversationRow(
        _ conversation: MessageConversation,
        resolver: LineAppearanceResolver
    ) -> some View {
        let latestLine = conversation.latestLine
        let isSelected = selectedConversationID == conversation.id
        return ConversationRowContent(
            title: presentedIdentity(for: conversation),
            address: conversation.address,
            preview: appState.privacyPresentation.messagePreview(
                conversation.latestMessage?.preview ?? ""
            ),
            timestamp: conversation.latestMessage.map {
                CommunicationUI.listTimestamp($0.timestamp)
            },
            unreadCount: conversation.unreadCount,
            latestIsOutgoing: conversation.latestMessage?.isOutgoing == true,
            line: resolver.appearance(for: latestLine)
        )
        .communicationSelectionHighlight(isSelected)
        .contentShape(Rectangle())
        .onTapGesture { selectedConversationID = conversation.id }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .tag(conversation.id)
        .contextMenu {
            if SMSPDUEncoder.isValidDestination(conversation.address) {
                Button(L10n.tr("呼叫"), systemImage: "phone") {
                    CommunicationWindowController.shared.showPhone(
                        number: conversation.address
                    )
                }
            }
            Button(L10n.tr("全部标为已读"), systemImage: "envelope.open") {
                markConversationRead(conversation)
            }
        }
    }

    /// The conversations of the line picked in the module selector, one per
    /// peer.
    private var conversations: [MessageConversation] {
        let scope = appState.lineScope
        return MessageConversation.groupedByPeer(
            from: appState.messages.filter { scope.contains($0.line) }
        )
    }

    private func filtered(_ conversations: [MessageConversation]) -> [MessageConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { conversation in
            if unreadOnly, !conversation.hasUnread { return false }
            guard !query.isEmpty else { return true }
            let name = contacts.displayName(for: conversation.address) ?? ""
            return name.localizedCaseInsensitiveContains(query) ||
                conversation.address.localizedCaseInsensitiveContains(query) ||
                conversation.messages.contains {
                    $0.body.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var selectedConversation: MessageConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    private func presentedIdentity(for conversation: MessageConversation) -> String {
        appState.privacyPresentation.identity(
            contactName: contacts.displayName(for: conversation.address),
            number: conversation.address
        )
    }

    private func handlePresentationRequest() {
        if let messageID = model.requestedMessageID,
           let message = appState.messages.first(where: { $0.id == messageID }) {
            let conversationID = MessageConversation.conversationID(for: message.peerAddress)
            selectedConversationID = conversationID
            isComposingNew = false
            if let conversation = conversations.first(where: { $0.id == conversationID }) {
                markConversationRead(conversation)
            } else {
                appState.markRead(message)
            }
            return
        }
        if let destination = model.requestedDestination, !destination.isEmpty {
            selectConversation(for: destination)
        }
    }

    private func selectConversation(for destination: String) {
        let id = MessageConversation.conversationID(for: destination)
        if conversations.contains(where: { $0.id == id }) {
            selectedConversationID = id
            isComposingNew = false
        } else if !appState.blocksActionWhileViewingOfflineLine() {
            newDestination = destination
            selectedConversationID = nil
            isComposingNew = true
        }
    }

    private func beginNewMessage() {
        guard !appState.blocksActionWhileViewingOfflineLine() else { return }
        newDestination = ""
        isComposingNew = true
        selectedConversationID = nil
    }

    private func chooseDefaultConversationIfNeeded() {
        guard !isComposingNew else { return }
        if let selectedConversationID,
           conversations.contains(where: { $0.id == selectedConversationID }) {
            return
        }
        selectedConversationID = conversations.first?.id
    }

    private func markSelectedConversationRead() {
        guard let selectedConversation else { return }
        markConversationRead(selectedConversation)
    }

    private func markConversationRead(_ conversation: MessageConversation) {
        appState.markRead(
            conversation.messages.filter { !$0.isOutgoing && !$0.isRead }
        )
    }

    private func handleFocusFirstItemRequest() {
        guard focusFirstItemRequest else { return }
        isComposingNew = false
        selectedConversationID = filtered(conversations).first?.id
        didHandleFocusFirstItemRequest()
        listFocused = false
        DispatchQueue.main.async {
            listFocused = true
        }
    }
}

private struct MessageThreadView: View {
    @EnvironmentObject private var appState: AppState
    let conversation: MessageConversation
    let contactName: String?
    let resolver: LineAppearanceResolver
    let scrollTargetMessageID: SMSMessage.ID?
    let didRouteMessage: (String) -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            threadHeader
            Divider()
            messageHistory
            Divider()
            composer
        }
    }

    private var threadHeader: some View {
        HStack(spacing: 10) {
            ContactFaceAvatar(
                address: conversation.address,
                size: AppMetrics.Avatar.header
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: presentedIdentity)
                    .font(.appHeadline)
                    .lineLimit(1)
                if contactName != nil {
                    Text(verbatim: appState.privacyPresentation.phoneNumber(conversation.address))
                        .font(.appCaption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(conversation.lines.prefix(3).map { resolver.appearance(for: $0) }) { line in
                    LineChip(appearance: line)
                }
            }

            if SMSPDUEncoder.isValidDestination(conversation.address) {
                Button {
                    guard !appState.blocksActionWhileViewingOfflineLine() else { return }
                    CommunicationWindowController.shared.showPhone(number: conversation.address)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.appSymbol(.inline))
                        .frame(width: 16, height: 16)
                }
                .adaptiveGlassButton()
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help(L10n.tr("呼叫 %@", presentedIdentity))
                .accessibilityLabel(L10n.tr("呼叫 %@", presentedIdentity))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: AppMetrics.Row.header)
    }

    private var messageHistory: some View {
        let lineChanges = conversation.lineChanges
        let appearances = Dictionary(
            uniqueKeysWithValues: conversation.lines.map { ($0, resolver.appearance(for: $0)) }
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                        if shouldShowDate(at: index) {
                            Text(verbatim: message.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.appCaption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 5)
                        }
                        if let isFirst = lineChanges[index],
                           let line = message.line,
                           let appearance = appearances[line] {
                            LineChangeNotice(appearance: appearance, isFirst: isFirst)
                        }
                        MessageBubble(
                            message: message,
                            outgoingColor: message.line
                                .flatMap { appearances[$0] }?.tint.solid ?? Color.accentColor
                        )
                            .id(message.id)
                            .contextMenu {
                                Button(L10n.tr("复制"), systemImage: "doc.on.doc") {
                                    appState.copy(message)
                                }
                                if !message.isOutgoing,
                                   SMSPDUEncoder.isValidDestination(message.sender) {
                                    Button(L10n.tr("回复"), systemImage: "arrowshape.turn.up.left") {
                                        composerFocused = true
                                    }
                                }
                                if message.isOutgoing, message.deliveryState == .failed {
                                    Button(L10n.tr("重新发送"), systemImage: "arrow.clockwise") {
                                        appState.sendSMS(
                                            to: conversation.address,
                                            body: message.body,
                                            via: sendModuleID
                                        ) { _ in
                                            didRouteMessage(conversation.address)
                                        }
                                    }
                                    .disabled(
                                        sendModuleID == nil ||
                                            appState.isSendingMessage(via: sendModuleID) ||
                                            appState.moduleHasCall(sendModuleID)
                                    )
                                }
                                Divider()
                                Button(L10n.tr("删除"), systemImage: "trash", role: .destructive) {
                                    appState.delete(message)
                                }
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if let target = validScrollTarget {
                    proxy.scrollTo(target, anchor: .center)
                } else if let last = conversation.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
            .onChange(of: scrollTargetMessageID) { _, id in
                guard let id, conversation.messages.contains(where: { $0.id == id }) else {
                    return
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: conversation.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var validScrollTarget: SMSMessage.ID? {
        guard let scrollTargetMessageID,
              conversation.messages.contains(where: { $0.id == scrollTargetMessageID }) else {
            return nil
        }
        return scrollTargetMessageID
    }

    private var presentedIdentity: String {
        appState.privacyPresentation.identity(
            contactName: contactName,
            number: conversation.address
        )
    }

    private var composer: some View {
        MessageComposerBar(
            draft: $draft,
            options: sendOptions,
            selectedModuleID: sendModuleID,
            onSelectModule: { _ in },
            canSend: canSend,
            isSending: appState.isSendingMessage(via: sendModuleID),
            sendHelp: sendModuleID.map(appState.moduleHasCall) == true
                ? L10n.tr("当前模组通话期间会保存草稿，但不能发送短信")
                : L10n.tr("发送（⌘Return）"),
            note: fallbackNote,
            statusLeading: MessageComposerText.count(for: draft, destination: conversation.address),
            statusTrailing: MessageComposerText.route(for: selectedOption),
            focus: $composerFocused,
            onSend: send
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// Messages go out on the line picked in the module selector.
    private var sendModuleID: CellularModuleID? {
        appState.lineScope.moduleID
    }

    private var sendOptions: [SendLineOption] {
        resolver.sendOptions.filter { $0.moduleID == sendModuleID }
    }

    private var selectedOption: SendLineOption? {
        sendOptions.first
    }

    /// Shown above the input while the list is on a read-only offline line.
    private var fallbackNote: String? {
        let scope = appState.lineScope
        guard !scope.isOnline, scope.line != nil else { return nil }
        return L10n.tr("%@ 已离线，只能查看记录。请先在底部切换到在线线路。", scope.appearance.title)
    }

    private var canSend: Bool {
        guard let sendModuleID else { return false }
        return appState.moduleIsConnected(sendModuleID) &&
            !appState.moduleHasCall(sendModuleID) &&
            !appState.isSendingMessage(via: sendModuleID) &&
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            SMSPDUEncoder.segmentCount(destination: conversation.address, body: draft) != nil
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !body.isEmpty, let sendModuleID else { return }
        draft = ""
        appState.sendSMS(to: conversation.address, body: body, via: sendModuleID) { _ in
            didRouteMessage(conversation.address)
        }
    }

    private func shouldShowDate(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = conversation.messages[index].timestamp
        let previous = conversation.messages[index - 1].timestamp
        return current.timeIntervalSince(previous) > 15 * 60 ||
            !Calendar.current.isDate(current, inSameDayAs: previous)
    }
}

/// The two status texts under the message input.
enum MessageComposerText {
    static func count(for draft: String, destination: String) -> String {
        let count = draft.utf16.count
        guard count > 0 else { return L10n.tr("⌘Return 发送") }
        guard let segments = SMSPDUEncoder.segmentCount(
            destination: destination,
            body: draft
        ) else { return L10n.tr("%lld 字", Int64(count)) }
        return L10n.tr("%lld 字 · %lld 条短信", Int64(count), Int64(segments))
    }

    static func route(for option: SendLineOption?) -> String {
        guard let option else { return L10n.tr("未选择通信模组") }
        return option.isEligible
            ? L10n.tr("通过 %@ 发送", option.appearance.fullTitle)
            : L10n.tr("当前模组未就绪")
    }
}

private struct MessageBubble: View {
    @EnvironmentObject private var appState: AppState
    let message: SMSMessage
    /// Solid colour of the module that sent this message.
    let outgoingColor: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            if message.isOutgoing { Spacer(minLength: 70) }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                SMSMessageContentView(
                    message: message,
                    isOnAccentBackground: message.isOutgoing
                )
                    .font(.appBody)
                    .padding(.leading, message.isOutgoing ? 13 : 19)
                    .padding(.trailing, message.isOutgoing ? 19 : 13)
                    .padding(.vertical, 9)
                    .background(
                        message.isOutgoing ? outgoingColor : Color.secondary.opacity(0.14),
                        in: MessageBubbleShape(isOutgoing: message.isOutgoing)
                    )
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)

                if message.isOutgoing {
                    Label {
                        Text(verbatim: deliveryText)
                    } icon: {
                        Image(systemName: deliveryIcon)
                    }
                        .font(.appCaption)
                        .foregroundStyle(deliveryColor)
                        .help(message.localizedDeliveryDetail ?? deliveryText)
                }
            }

            if !message.isOutgoing { Spacer(minLength: 70) }
        }
        .frame(maxWidth: .infinity)
    }

    private var deliveryText: String {
        switch message.deliveryState {
        case .sending: return L10n.tr("发送中")
        case .sent: return L10n.tr("已发送")
        case .failed: return L10n.tr("发送失败")
        case .uncertain: return L10n.tr("状态未知")
        case .none: return L10n.tr("已发送")
        }
    }

    private var deliveryIcon: String {
        switch message.deliveryState {
        case .sending: return "clock"
        case .sent, .none: return "checkmark"
        case .failed: return "exclamationmark.circle.fill"
        case .uncertain: return "questionmark.circle.fill"
        }
    }

    private var deliveryColor: Color {
        switch message.deliveryState {
        case .failed: return .red
        case .uncertain: return .orange
        case .sending, .sent, .none: return .secondary
        }
    }
}

private struct MessageBubbleShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        let tailWidth: CGFloat = 7
        let radius = min(17, rect.height / 2, rect.width / 2)
        let bodyRect = CGRect(
            x: isOutgoing ? rect.minX : rect.minX + tailWidth,
            y: rect.minY,
            width: max(0, rect.width - tailWidth),
            height: rect.height
        )
        let tailHeight = min(13, max(7, rect.height * 0.34))
        let tailBaseWidth = min(14, max(8, radius * 0.82))
        var path = Path(roundedRect: bodyRect, cornerRadius: radius)

        if isOutgoing {
            let upperJoin = CGPoint(
                x: bodyRect.maxX - 1,
                y: bodyRect.maxY - tailHeight
            )
            let tip = CGPoint(x: rect.maxX, y: rect.maxY - 1)
            let lowerJoin = CGPoint(
                x: bodyRect.maxX - tailBaseWidth,
                y: bodyRect.maxY - 1
            )

            path.move(to: upperJoin)
            path.addCurve(
                to: tip,
                control1: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - tailHeight * 0.45),
                control2: CGPoint(x: rect.maxX - 1, y: rect.maxY - 3)
            )
            path.addCurve(
                to: lowerJoin,
                control1: CGPoint(x: rect.maxX - 4, y: rect.maxY),
                control2: CGPoint(x: bodyRect.maxX - tailBaseWidth * 0.45, y: bodyRect.maxY)
            )
            path.addCurve(
                to: upperJoin,
                control1: CGPoint(
                    x: bodyRect.maxX - tailBaseWidth * 0.45,
                    y: bodyRect.maxY - tailHeight * 0.15
                ),
                control2: CGPoint(x: bodyRect.maxX - 2, y: bodyRect.maxY - tailHeight * 0.55)
            )
            path.closeSubpath()
        } else {
            let upperJoin = CGPoint(
                x: bodyRect.minX + 1,
                y: bodyRect.maxY - tailHeight
            )
            let lowerJoin = CGPoint(
                x: bodyRect.minX + tailBaseWidth,
                y: bodyRect.maxY - 1
            )
            let tip = CGPoint(x: rect.minX, y: rect.maxY - 1)

            path.move(to: upperJoin)
            path.addCurve(
                to: lowerJoin,
                control1: CGPoint(x: bodyRect.minX + 2, y: bodyRect.maxY - tailHeight * 0.55),
                control2: CGPoint(
                    x: bodyRect.minX + tailBaseWidth * 0.45,
                    y: bodyRect.maxY - tailHeight * 0.15
                )
            )
            path.addCurve(
                to: tip,
                control1: CGPoint(x: bodyRect.minX + tailBaseWidth * 0.45, y: bodyRect.maxY),
                control2: CGPoint(x: rect.minX + 4, y: rect.maxY)
            )
            path.addCurve(
                to: upperJoin,
                control1: CGPoint(x: rect.minX + 1, y: rect.maxY - 3),
                control2: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - tailHeight * 0.45)
            )
            path.closeSubpath()
        }
        return path
    }
}

private struct NewConversationView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var destination: String
    @ObservedObject var contacts: SystemContactStore
    let resolver: LineAppearanceResolver
    let didSend: (String) -> Void

    @State private var bodyText = ""
    @FocusState private var recipientFocused: Bool
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.tr("收件人："))
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                Group {
                    if appState.isPresentationPrivacyEnabled {
                        SecureField(L10n.tr("姓名或电话号码"), text: $destination)
                    } else {
                        TextField(L10n.tr("姓名或电话号码"), text: $destination)
                    }
                }
                    .font(.appBody)
                    .textFieldStyle(.plain)
                    .focused($recipientFocused)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: AppMetrics.Row.header)

            if !contactSuggestions.isEmpty, !destination.isEmpty {
                HStack {
                    ForEach(contactSuggestions.prefix(3)) { contact in
                        Button {
                            destination = contact.primaryPhoneNumber ?? ""
                            bodyFocused = true
                        } label: {
                            Label {
                                Text(verbatim: appState.privacyPresentation.contactIdentity(
                                    name: contact.displayName,
                                    identifier: contact.id,
                                    fallbackNumber: contact.primaryPhoneNumber
                                ))
                            } icon: {
                                Image(systemName: "person.crop.circle")
                            }
                            .font(.appCallout)
                        }
                        .adaptiveGlassButton()
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }

            Divider()

            Spacer()

            MessageComposerBar(
                draft: $bodyText,
                options: sendOptions,
                selectedModuleID: sendModuleID,
                onSelectModule: { _ in },
                canSend: canSend,
                isSending: appState.isSendingMessage(via: sendModuleID),
                sendHelp: L10n.tr("发送（⌘Return）"),
                statusLeading: MessageComposerText.count(for: bodyText, destination: destination),
                statusTrailing: MessageComposerText.route(for: selectedOption),
                focus: $bodyFocused,
                onSend: send
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .onAppear { recipientFocused = destination.isEmpty }
    }

    private var contactSuggestions: [SystemContactRecord] {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return contacts.contacts.filter { contact in
            contact.displayName.localizedCaseInsensitiveContains(query) ||
                contact.phoneNumbers.contains { $0.value.localizedCaseInsensitiveContains(query) }
        }
    }

    /// A new conversation goes out on the line picked in the module selector.
    private var sendModuleID: CellularModuleID? {
        appState.lineScope.moduleID
    }

    private var sendOptions: [SendLineOption] {
        resolver.sendOptions.filter { $0.moduleID == sendModuleID }
    }

    private var selectedOption: SendLineOption? {
        sendOptions.first
    }

    private var canSend: Bool {
        guard let sendModuleID else { return false }
        return appState.moduleIsConnected(sendModuleID) &&
            !appState.moduleHasCall(sendModuleID) &&
            !appState.isSendingMessage(via: sendModuleID) &&
            SMSPDUEncoder.segmentCount(destination: destination, body: bodyText) != nil &&
            !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let sendModuleID else { return }
        bodyText = ""
        let recipient = destination
        appState.sendSMS(to: recipient, body: body, via: sendModuleID) { _ in
            didSend(recipient)
        }
    }
}
