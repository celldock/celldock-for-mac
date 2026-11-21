import Foundation

struct MessageConversation: Identifiable, Equatable {
    let id: String
    let address: String
    let moduleID: CellularModuleID?
    let messages: [SMSMessage]

    var latestMessage: SMSMessage? {
        messages.last
    }

    var unreadCount: Int {
        messages.lazy.filter { !$0.isOutgoing && !$0.isRead }.count
    }

    var hasUnread: Bool {
        unreadCount > 0
    }

    static func conversationID(
        for address: String,
        moduleID: CellularModuleID? = nil
    ) -> String {
        let addressID = PhoneNumberNormalizer.conversationID(for: address)
        return moduleID.map { "\($0.rawValue)|\(addressID)" } ?? addressID
    }

    /// One conversation per peer on each module. The menu bar groups unread
    /// messages this way because it lists them under the module that got them.
    static func grouped(from messages: [SMSMessage]) -> [MessageConversation] {
        grouped(from: messages) { message in
            conversationID(for: message.peerAddress, moduleID: message.moduleID)
        }
    }

    /// One conversation per peer across every module and SIM slot. The
    /// Messages window uses this so the same number is a single row, and the
    /// thread itself shows which line each stretch of messages went through.
    static func groupedByPeer(from messages: [SMSMessage]) -> [MessageConversation] {
        grouped(from: messages) { message in
            conversationID(for: message.peerAddress)
        }
    }

    private static func grouped(
        from messages: [SMSMessage],
        by key: (SMSMessage) -> String
    ) -> [MessageConversation] {
        Dictionary(grouping: messages, by: key)
        .compactMap { id, groupedMessages in
            let sortedMessages = groupedMessages.sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp < rhs.timestamp
                }
                return lhs.id < rhs.id
            }
            guard let latestMessage = sortedMessages.last else { return nil }
            return MessageConversation(
                id: id,
                address: latestMessage.peerAddress,
                moduleID: latestMessage.moduleID,
                messages: sortedMessages
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.latestMessage?.timestamp ?? .distantPast
            let rhsDate = rhs.latestMessage?.timestamp ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id < rhs.id
        }
    }
}

extension SMSMessage {
    /// The line that carried this message; nil for records stored before
    /// messages were tagged with their module.
    var line: CommunicationLine? {
        moduleID.map { CommunicationLine(moduleID: $0, simSlot: simSlot) }
    }
}

extension MessageConversation {
    /// Every line used with this peer, in order of first use.
    var lines: [CommunicationLine] {
        var seen = Set<CommunicationLine>()
        return messages.compactMap(\.line).filter { seen.insert($0).inserted }
    }

    /// The line of the most recent message that recorded one.
    var latestLine: CommunicationLine? {
        messages.last(where: { $0.line != nil })?.line
    }

    /// Where the thread moves to another line, keyed by message index. The
    /// value is true for the first stretch, which has nothing to switch from.
    /// Conversations that only ever used one line report no changes, so their
    /// thread stays free of line notices.
    var lineChanges: [Int: Bool] {
        guard lines.count > 1 else { return [:] }
        var changes: [Int: Bool] = [:]
        var previous: CommunicationLine?
        for (index, message) in messages.enumerated() {
            guard let line = message.line, line != previous else { continue }
            changes[index] = previous == nil
            previous = line
        }
        return changes
    }
}
