import Foundation

/// Spots SMS centre (SMSC) addresses that are known not to deliver from a
/// module on the current network, and names the replacement.
///
/// CellDock leaves AT+CSCA as the SIM provides it. Some China Telecom cards
/// still carry the regional SMSC numbers from the CDMA era (+86133…). In a
/// module on LTE, messages sent to those numbers are accepted (+CMGS returns a
/// reference) but never reach the recipient. China Telecom publishes a gateway
/// SMSC for each of the same regions; switching to it makes delivery work.
/// Phones are unaffected because the carrier configuration overrides the SIM.
enum SMSServiceCenterAdvisor {
    struct Recommendation: Equatable {
        let current: String
        let recommended: String
    }

    /// China Telecom home networks (MCC 460, MNC 03/05/11).
    private static let chinaTelecomPLMNs: Set<String> = ["46003", "46005", "46011"]

    /// CDMA-era regional SMSC → LTE gateway SMSC for the same regions, as
    /// listed by China Telecom (manyou.189.cn, "短信中心号码").
    private static let chinaTelecomReplacements: [String: String] = [
        // Beijing, Tianjin, Hebei, Shanxi, Inner Mongolia, Liaoning, Jilin,
        // Heilongjiang, Shandong, Shaanxi, Gansu, Ningxia, Qinghai, Xinjiang
        "+8613334113200": "+316540942002",
        // Shanghai, Jiangsu, Zhejiang, Anhui, Fujian, Jiangxi
        "+8613344181200": "+316540942001",
        // Guangdong, Guangxi, Hainan, Hunan, Hubei, Henan, Yunnan, Guizhou,
        // Tibet, Sichuan, Chongqing
        "+8613334262200": "+316540942000",
    ]

    static func recommendation(imsi: String?, serviceCenter: String?) -> Recommendation? {
        guard let imsi, imsi.count >= 5,
              chinaTelecomPLMNs.contains(String(imsi.prefix(5))),
              let current = normalized(serviceCenter),
              let recommended = chinaTelecomReplacements[current] else {
            return nil
        }
        return Recommendation(current: current, recommended: recommended)
    }

    /// Normalises "8613344181200", "+86 133 4418 1200" and similar to
    /// "+8613344181200". Returns nil for an empty or non-numeric value.
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return "+" + digits
    }

    /// AT command that stores `number` as the SMSC (international format).
    static func writeCommand(for number: String) -> String? {
        guard let normalized = normalized(number), normalized.count <= 21 else { return nil }
        return "AT+CSCA=\"\(normalized)\",145"
    }
}
