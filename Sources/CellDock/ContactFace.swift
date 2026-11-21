import Foundation

/// The expression drawn on a number's avatar.
enum ContactFaceExpression: Int, CaseIterable {
    case smile
    case dots
    case flat
    case wink
    case surprised
    case sleepy
    /// Square eyes, used for automated senders instead of a human expression.
    case robot

    static let human: [ContactFaceExpression] = [.smile, .dots, .flat, .wink, .surprised, .sleepy]
}

/// The face of one number. It is derived from the number alone, so the same
/// number shows the same face in Messages, Recents and Recordings, whichever
/// module carried the record.
struct ContactFace: Equatable {
    let expression: ContactFaceExpression
    /// -1, 0 or 1: the face looks slightly left, straight ahead or right.
    let glance: Int

    static func face(for address: String) -> ContactFace {
        if isAutomatedSender(address) {
            return ContactFace(expression: .robot, glance: 0)
        }
        let identity = PhoneNumberNormalizer.conversationID(for: address)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let human = ContactFaceExpression.human
        let expression = human[Int(hash % UInt64(human.count))]
        let glance = Int((hash / UInt64(human.count)) % 3) - 1
        return ContactFace(expression: expression, glance: glance)
    }

    /// Service numbers and sender IDs that no person answers: short codes,
    /// SMS gateways, toll-free hotlines and alphanumeric senders.
    static func isAutomatedSender(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: \.isLetter) { return true }
        var digits = PhoneNumberNormalizer.normalized(trimmed)
        if digits.hasPrefix("+") { digits.removeFirst() }
        guard !digits.isEmpty else { return false }
        if digits.count <= 6 { return true }
        if digits.hasPrefix("106") { return true }
        if digits.count == 10, digits.hasPrefix("400") || digits.hasPrefix("800") { return true }
        if digits.count <= 8, digits.hasPrefix("95") || digits.hasPrefix("96") { return true }
        return false
    }
}
