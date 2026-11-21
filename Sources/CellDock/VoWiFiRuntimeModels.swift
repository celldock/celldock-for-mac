import Foundation

/// Mirrors `runtimehost.Phase` in `vowifi-go`. The runtime lifecycle is
/// asynchronous: `start` only admits the request, and the host walks through
/// these phases afterwards.
enum VoWiFiRuntimePhase: String, Equatable, Sendable {
    case starting
    case simReady = "sim_ready"
    case ready
    case stopped
    case error

    var localizedName: String {
        switch self {
        case .starting: return L10n.tr("正在启动")
        case .simReady: return L10n.tr("SIM 已就绪")
        case .ready: return L10n.tr("已就绪")
        case .stopped: return L10n.tr("已停止")
        case .error: return L10n.tr("错误")
        }
    }
}

enum VoWiFiControlProtocol {
    /// Protocol 3 drops every field that only made sense for a module with its
    /// own WLAN radio. In SOCKS mode the module has no Wi-Fi at all: the egress
    /// belongs to the Mac, so the module must never gate on `wifi_connected`.
    static let version = 4

    /// `SOCKSNATTTransport` is rejected by `IKEPacketTunnelManager` unless the
    /// dataplane is userspace, so any other value is a misconfigured host.
    static let requiredDataplaneMode = "userspace"
}

/// One `status` reply from the module-side `vowifi-go` control host. Field
/// names track `runtimehost.State` so a host implementation can serialize its
/// snapshot without inventing a second vocabulary.
struct VoWiFiRuntimeStatus: Equatable, Sendable {
    var protocolVersion = 0
    var isSupported = false
    var isRunning = false
    var sessionID: String?
    var phase: VoWiFiRuntimePhase?
    var dataplaneMode: String?
    var isSIMReady = false
    var isAccessReady = false
    var isTunnelReady = false
    var isIMSReady = false
    var registrationStatus: Int?
    var lastErrorClass: String?
    var lastReason: String?

    /// Machine-readable rejection code emitted when `supported=0`.
    var unsupportedCode: String?

    static func parse(keyValueOutput output: String) -> Self {
        let values = output.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) {
            result, line in
            guard let separator = line.firstIndex(of: "=") else { return }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !key.isEmpty else { return }
            result[key] = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let protocolVersion = Int(values["protocol"] ?? "") ?? 0
        let isSupported = bool(values["supported"]) &&
            protocolVersion == VoWiFiControlProtocol.version
        let unsupportedCode: String? = if isSupported {
            nil
        } else if protocolVersion == VoWiFiControlProtocol.version {
            nonempty(values["reason"])
        } else {
            "control-protocol-unsupported"
        }
        return Self(
            protocolVersion: protocolVersion,
            isSupported: isSupported,
            isRunning: bool(values["running"]),
            sessionID: nonempty(values["session"]),
            phase: nonempty(values["phase"]).flatMap { VoWiFiRuntimePhase(rawValue: $0.lowercased()) },
            dataplaneMode: nonempty(values["dataplane_mode"])?.lowercased(),
            isSIMReady: bool(values["sim_ready"]),
            isAccessReady: bool(values["access_ready"]),
            isTunnelReady: bool(values["tunnel_ready"]),
            isIMSReady: bool(values["ims_ready"]),
            registrationStatus: nonempty(values["reg_status"]).flatMap(Int.init),
            lastErrorClass: nonempty(values["last_error_class"]),
            lastReason: nonempty(values["last_reason"]),
            unsupportedCode: unsupportedCode
        )
    }

    static func parse(jsonData data: Data?) -> Self {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self(
                protocolVersion: VoWiFiControlProtocol.version,
                isSupported: true,
                isRunning: false,
                phase: .stopped,
                dataplaneMode: VoWiFiControlProtocol.requiredDataplaneMode
            )
        }
        func bool(_ key: String) -> Bool {
            (object[key] as? Bool) ?? ((object[key] as? NSNumber)?.boolValue ?? false)
        }
        func string(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let version = (object["protocol"] as? NSNumber)?.intValue ?? 0
        return Self(
            protocolVersion: version,
            isSupported: bool("supported") && version == VoWiFiControlProtocol.version,
            isRunning: bool("running"),
            sessionID: string("session"),
            phase: string("phase").flatMap { VoWiFiRuntimePhase(rawValue: $0) },
            dataplaneMode: string("dataplane_mode"),
            isSIMReady: bool("sim_ready"),
            isAccessReady: bool("access_ready"),
            isTunnelReady: bool("tunnel_ready"),
            isIMSReady: bool("ims_ready"),
            registrationStatus: (object["reg_status"] as? NSNumber)?.intValue,
            lastErrorClass: string("last_error_class"),
            lastReason: string("last_reason"),
            unsupportedCode: version == VoWiFiControlProtocol.version
                ? string("reason")
                : "control-protocol-unsupported"
        )
    }

    var hasRuntimeError: Bool {
        phase == .error || lastErrorClass != nil
    }

    var usesValidDataplane: Bool {
        dataplaneMode == nil || dataplaneMode == VoWiFiControlProtocol.requiredDataplaneMode
    }

    var localizedUnsupportedReason: String {
        switch unsupportedCode {
        case "control-host-missing":
            return L10n.tr("模组固件没有安装 vowifi-go 控制程序。")
        case "control-protocol-unsupported":
            return L10n.tr("VoWiFi 运行时控制接口版本不受支持。")
        case "sim-unavailable":
            return L10n.tr("模组无法为 vowifi-go 提供 SIM/ISIM 鉴权通道。")
        case "dataplane-unavailable":
            return L10n.tr("模组缺少 vowifi-go 用户态数据面所需的 TUN 支持。")
        case let value?:
            return value
        case nil:
            return L10n.tr("模组固件没有安装 vowifi-go 控制程序。")
        }
    }

    var localizedFailureReason: String {
        lastReason ?? lastErrorClass ?? L10n.tr("VoWiFi 运行时启动失败。")
    }

    private static func bool(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "-" else { return nil }
        return value
    }
}

/// Why the Mac cannot currently offer a SOCKS5 egress to the module. This is
/// local knowledge; the module can only ever report that its proxy is dead.
enum VoWiFiEgressProblem: Equatable, Sendable {
    case noInternetInterface
    case moduleLinkDown
    case upstreamProxy(String)

    var localizedDescription: String {
        switch self {
        case .noInternetInterface:
            return L10n.tr("Mac 当前没有可用于 VoWiFi 的网络出口。")
        case .moduleLinkDown:
            return L10n.tr("模组 ECM 链路未就绪，无法建立 VoWiFi 中继。")
        case let .upstreamProxy(reason):
            return reason
        }
    }
}

/// The user-visible lifecycle. Ordering matters: a fault or a session mismatch
/// must win over any optimistic readiness bit reported by a stale runtime.
enum VoWiFiSessionState: Equatable, Sendable {
    case checking
    case unsupported(String)
    case stopped
    case egressUnavailable(VoWiFiEgressProblem)
    case starting(VoWiFiRuntimeStatus)
    case authenticatingSIM(VoWiFiRuntimeStatus)
    case establishingTunnel(VoWiFiRuntimeStatus)
    case registeringIMS(VoWiFiRuntimeStatus)
    case registered(VoWiFiRuntimeStatus)
    /// The module is running a session CellDock did not start, so its SOCKS5
    /// peer is gone. Reported instead of a phantom "registered".
    case desynchronized(VoWiFiRuntimeStatus)
    case failed(String)

    init(status: VoWiFiRuntimeStatus, expectedSessionID: String?) {
        guard status.isSupported else {
            self = .unsupported(status.localizedUnsupportedReason)
            return
        }
        if status.hasRuntimeError {
            self = .failed(status.localizedFailureReason)
            return
        }
        guard status.isRunning else {
            self = .stopped
            return
        }
        // A running runtime whose session token is not ours is pointed at a
        // SOCKS5 relay that no longer exists. Never render it as healthy.
        if let expectedSessionID, status.sessionID != expectedSessionID {
            self = .desynchronized(status)
            return
        }
        guard status.usesValidDataplane else {
            self = .failed(L10n.tr("SOCKS5 代理要求 vowifi-go 使用用户态数据面。"))
            return
        }
        if !status.isSIMReady {
            self = status.phase == .starting ? .starting(status) : .authenticatingSIM(status)
            return
        }
        // `access_ready` covers the runtime's own view of the SOCKS5 association.
        if !status.isAccessReady || !status.isTunnelReady {
            self = .establishingTunnel(status)
            return
        }
        self = status.isIMSReady ? .registered(status) : .registeringIMS(status)
    }

    /// The state for a status query that found no usable network helper.
    /// Without a helper nothing can be running, so a session nobody asked for
    /// is stopped, not faulty. A session that should be running keeps the
    /// failure: the helper may only be briefly unreachable, and reporting it
    /// as stopped would tear the session down.
    static func whenHelperNotReady(runningRequested: Bool, message: String) -> Self {
        runningRequested ? .failed(message) : .stopped
    }

    var status: VoWiFiRuntimeStatus? {
        switch self {
        case let .starting(status), let .authenticatingSIM(status),
             let .establishingTunnel(status), let .registeringIMS(status),
             let .registered(status), let .desynchronized(status):
            return status
        case .checking, .unsupported, .stopped, .egressUnavailable, .failed:
            return nil
        }
    }

    /// True while CellDock believes the module should be running a session.
    var isRunning: Bool {
        switch self {
        case .starting, .authenticatingSIM, .establishingTunnel,
             .registeringIMS, .registered, .desynchronized:
            return true
        case .checking, .unsupported, .stopped, .egressUnavailable, .failed:
            return false
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .checking, .starting, .authenticatingSIM, .establishingTunnel, .registeringIMS:
            return true
        default:
            return false
        }
    }

    /// Polling costs a round trip on the ADB control channel that voice and AT
    /// traffic also share, so steady states must back off hard.
    var pollInterval: TimeInterval? {
        switch self {
        case .checking, .starting, .authenticatingSIM, .establishingTunnel, .registeringIMS:
            return 3
        case .registered:
            return 20
        case .desynchronized, .failed:
            return 10
        case .stopped, .egressUnavailable:
            return 60
        case .unsupported:
            // Firmware cannot gain a control host without a reinsert or an
            // explicit user check.
            return nil
        }
    }

    var localizedTitle: String {
        switch self {
        case .checking: return L10n.tr("正在检测 VoWiFi 运行时")
        case .unsupported: return L10n.tr("当前固件不支持")
        case .stopped: return L10n.tr("VoWiFi 已关闭")
        case .egressUnavailable: return L10n.tr("SOCKS5 出口不可用")
        case .starting: return L10n.tr("正在启动运行时")
        case .authenticatingSIM: return L10n.tr("正在进行 SIM/ISIM 鉴权")
        case .establishingTunnel: return L10n.tr("正在建立 SWu/ePDG 隧道")
        case .registeringIMS: return L10n.tr("正在注册运营商 IMS")
        case .registered: return L10n.tr("VoWiFi 已就绪")
        case .desynchronized: return L10n.tr("运行时会话已失效")
        case .failed: return L10n.tr("VoWiFi 运行时故障")
        }
    }

    var localizedShortTitle: String {
        switch self {
        case .checking: return L10n.tr("正在检测")
        case .unsupported: return L10n.tr("固件不支持")
        case .stopped: return L10n.tr("已关闭")
        case .egressUnavailable: return L10n.tr("出口不可用")
        case .starting: return L10n.tr("正在启动")
        case .authenticatingSIM: return L10n.tr("正在鉴权 SIM")
        case .establishingTunnel: return L10n.tr("正在建立 SWu 隧道")
        case .registeringIMS: return L10n.tr("正在注册 IMS")
        case .registered: return L10n.tr("VoWiFi 已注册")
        case .desynchronized: return L10n.tr("会话已失效")
        case .failed: return L10n.tr("运行时故障")
        }
    }

    /// Message shown in the detail pane's warning card, if any.
    var localizedProblem: String? {
        switch self {
        case let .unsupported(reason), let .failed(reason):
            return reason
        case let .egressUnavailable(problem):
            return problem.localizedDescription
        case .desynchronized:
            return L10n.tr("模组正在运行一个由其他会话启动的运行时，其 SOCKS5 中继已不存在。CellDock 会自动重建会话。")
        default:
            return nil
        }
    }
}
