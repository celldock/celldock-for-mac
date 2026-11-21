import CryptoKit
import Foundation

/// Pure signature helpers for the SMS-forwarding webhook channels. Kept free
/// of networking/model dependencies so the self-test target can exercise
/// them in isolation against hand-computed test vectors.
enum SMSForwardingSigning {
    /// Feishu (Lark) custom bot signing: the HMAC key is
    /// "`timestamp`\n`secret`" and the signed message is empty. See
    /// https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot
    static func feishuSign(secret: String, timestampSeconds: Int) -> String {
        let stringToSign = "\(timestampSeconds)\n\(secret)"
        let key = SymmetricKey(data: Data(stringToSign.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(), using: key)
        return Data(mac).base64EncodedString()
    }

    /// DingTalk custom robot signing: the HMAC key is the raw secret and the
    /// signed message is "`timestamp`\n`secret`" (timestamp in
    /// milliseconds) — the key/message roles are the reverse of Feishu's.
    /// See https://open.dingtalk.com/document/orgapp/customize-robot-security-settings
    static func dingTalkSign(secret: String, timestampMilliseconds: Int) -> String {
        let stringToSign = "\(timestampMilliseconds)\n\(secret)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    /// Reads a webhook's own verdict out of its JSON reply.
    ///
    /// Feishu and DingTalk answer HTTP 200 whether or not they accepted the
    /// message; the outcome is a numeric code in the body, zero for success.
    /// Returns a short description when one of `resultCodeKeys` holds a
    /// non-zero code, and nil when the message was accepted or the body has no
    /// such field (some gateways reply with an empty body on success).
    static func webhookRejection(in body: Data, resultCodeKeys: [String]) -> String? {
        guard !resultCodeKeys.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        for key in resultCodeKeys {
            let code: Int?
            switch object[key] {
            case let number as NSNumber: code = number.intValue
            case let text as String: code = Int(text.trimmingCharacters(in: .whitespaces))
            default: code = nil
            }
            guard let code, code != 0 else { continue }
            let message = ["msg", "errmsg", "StatusMessage"]
                .compactMap { object[$0] as? String }
                .first { !$0.isEmpty }
            return message.map { "\(code) \($0)" } ?? String(code)
        }
        return nil
    }

    /// Percent-encodes a base64 signature for safe inclusion in a URL query
    /// component (base64 can contain `+`, `/`, `=`).
    static func urlEncodedQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
