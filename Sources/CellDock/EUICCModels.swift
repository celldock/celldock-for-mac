import Foundation

enum SubscriberCardKind: Equatable {
    case unknown
    case probing
    case physicalSIM
    case eUICC
    case unsupported
    case failed
}

enum ESIMOperation: Equatable {
    case idle
    case detecting
    case refreshing
    case downloading
    case enabling(String)
    case disabling(String)
    case deleting(String)
    case renaming(String)

    var isBusy: Bool { self != .idle }
}

struct ESIMProfile: Codable, Equatable, Identifiable {
    let iccid: String
    let isdpAid: String
    let state: Int
    let `class`: Int
    let nickname: String?
    let serviceProviderName: String?
    let profileName: String?

    var id: String { iccid }
    var isEnabled: Bool { state == 1 }

    var displayName: String {
        let candidates = [nickname, profileName, serviceProviderName]
        return candidates.compactMap { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }.first ?? L10n.tr("eSIM 套餐")
    }
}

struct EUICCSnapshot: Equatable {
    var cardKind: SubscriberCardKind = .unknown
    var eid: String?
    var isdrAidSource: String?
    var profiles: [ESIMProfile] = []
    var operation: ESIMOperation = .idle
    var lastError: String?

    var isBusy: Bool { operation.isBusy }

    static let empty = EUICCSnapshot()
}

struct ESIMActivationCode: Equatable {
    let smdpAddress: String
    let matchingID: String
    let oid: String?
    let confirmationCodeRequired: Bool

    init(rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = normalized.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3,
              fields.count <= 5,
              fields[0].uppercased() == "LPA:1" else {
            throw ESIMActivationCodeError.invalidFormat
        }

        let address = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingID = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSMDPAddress(address) else {
            throw ESIMActivationCodeError.invalidServer
        }
        guard Self.isValidOpaqueIdentifier(matchingID) else {
            throw ESIMActivationCodeError.invalidMatchingID
        }

        let oid = fields.count >= 4 && !fields[3].isEmpty ? fields[3] : nil
        if let oid, !Self.isValidOID(oid) {
            throw ESIMActivationCodeError.invalidOID
        }
        if fields.count == 5, fields[4] != "0", fields[4] != "1", !fields[4].isEmpty {
            throw ESIMActivationCodeError.invalidFormat
        }

        smdpAddress = address
        self.matchingID = matchingID
        self.oid = oid
        confirmationCodeRequired = fields.count == 5 && fields[4] == "1"
    }

    private static func isValidSMDPAddress(_ address: String) -> Bool {
        guard !address.isEmpty,
              !address.contains("/"),
              !address.contains(":"),
              address.count <= 253 else { return false }
        let labels = address.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func isValidOpaqueIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 255 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        }
    }

    private static func isValidOID(_ value: String) -> Bool {
        guard value.count <= 128 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }
}

enum ESIMActivationCodeError: LocalizedError, Equatable {
    case invalidFormat
    case invalidServer
    case invalidMatchingID
    case invalidOID

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return L10n.tr("激活码格式无效，应为 LPA:1$服务器$匹配码。")
        case .invalidServer:
            return L10n.tr("SM-DP+ 服务器地址无效。")
        case .invalidMatchingID:
            return L10n.tr("激活码中的匹配码无效。")
        case .invalidOID:
            return L10n.tr("激活码中的 OID 无效。")
        }
    }
}

enum EUICCHTTPFailureKind: String, Equatable {
    case invalidRequest = "invalid_request"
    case tlsTrust = "tls_trust"
    case timedOut = "timed_out"
    case invalidResponse = "invalid_response"
    case responseTooLarge = "response_too_large"
    case outOfMemory = "out_of_memory"
    case transport
}

struct EUICCHTTPFailure: Equatable, Error {
    let kind: EUICCHTTPFailureKind
    let domain: String
    let code: Int

    init(kind: EUICCHTTPFailureKind, domain: String = "CellDockHTTP", code: Int = 0) {
        self.kind = kind
        self.domain = domain
        self.code = code
    }

    init(error: Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        kind = Self.classify(domain: error.domain, code: error.code)
    }

    static func classify(domain: String, code: Int) -> EUICCHTTPFailureKind {
        guard domain == NSURLErrorDomain else { return .transport }
        switch code {
        case URLError.Code.secureConnectionFailed.rawValue,
             URLError.Code.serverCertificateHasBadDate.rawValue,
             URLError.Code.serverCertificateUntrusted.rawValue,
             URLError.Code.serverCertificateHasUnknownRoot.rawValue,
             URLError.Code.serverCertificateNotYetValid.rawValue:
            return .tlsTrust
        case URLError.Code.timedOut.rawValue:
            return .timedOut
        default:
            return .transport
        }
    }

    var diagnosticCode: String {
        let safeDomain = domain == NSURLErrorDomain ? "NSURLErrorDomain" : "network"
        return "\(kind.rawValue):\(safeDomain):\(code)"
    }

    var userMessage: String {
        switch kind {
        case .invalidRequest:
            return L10n.tr("SM-DP+ 服务器地址无效。")
        case .tlsTrust:
            return L10n.tr("SM-DP+ TLS 证书校验失败。请关闭 HTTPS 代理或 MITM，检查系统时间后重试。")
        case .timedOut:
            return L10n.tr("连接 SM-DP+ 服务器超时，请检查网络后重试。")
        case .invalidResponse:
            return L10n.tr("SM-DP+ 服务器未返回有效的 HTTPS 响应。")
        case .responseTooLarge:
            return L10n.tr("SM-DP+ 服务器响应过大，已中止下载。")
        case .outOfMemory:
            return L10n.tr("处理 SM-DP+ 服务器响应时内存不足。")
        case .transport:
            return L10n.tr("无法连接 SM-DP+ 服务器（网络错误 %lld）。", Int64(code))
        }
    }
}

enum ESIMDownloadStage: String, CaseIterable, Equatable {
    case readEUICCChallenge = "read_euicc_challenge"
    case initiateAuthentication = "initiate_authentication"
    case authenticateServer = "authenticate_server"
    case authenticateClient = "authenticate_client"
    case prepareDownload = "prepare_download"
    case getBoundProfilePackage = "get_bound_profile_package"
    case loadBoundProfilePackage = "load_bound_profile_package"

    static func extract(from message: String) -> ESIMDownloadStage? {
        guard let marker = message.range(of: "stage=") else { return nil }
        let remainder = message[marker.upperBound...]
        let token = remainder.prefix { !$0.isWhitespace && $0 != ":" }
        return ESIMDownloadStage(rawValue: String(token))
    }

    var localizedName: String {
        switch self {
        case .readEUICCChallenge: return L10n.tr("读取 eUICC 挑战信息")
        case .initiateAuthentication: return L10n.tr("初始化服务器认证")
        case .authenticateServer: return L10n.tr("认证 SM-DP+ 服务器")
        case .authenticateClient: return L10n.tr("认证 eUICC 客户端")
        case .prepareDownload: return L10n.tr("准备下载套餐")
        case .getBoundProfilePackage: return L10n.tr("获取加密套餐")
        case .loadBoundProfilePackage: return L10n.tr("写入 eUICC 套餐")
        }
    }
}
