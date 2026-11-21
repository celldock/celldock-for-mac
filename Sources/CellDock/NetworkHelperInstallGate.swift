import Foundation
import CellDockNetworkIPC

/// Result of one ping of the installed helper.
enum NetworkHelperPingState: Equatable {
    case ready
    case unavailable(String)
    case incompatible(Int)
    case outdated
}

/// Why the helper could not be used for a request.
enum NetworkHelperGateFailure: Error, Equatable {
    /// A passive request found no usable helper. Carries the ping detail.
    case notReady(String)
    /// An install was suppressed or did not produce a usable helper.
    case unavailable(String)

    var message: String {
        switch self {
        case let .notReady(message), let .unavailable(message): return message
        }
    }
}

/// One process-wide gate for installing the privileged network helper.
///
/// Every `NetworkHelperClient` goes through it, so only one
/// ping-install-wait sequence runs at a time and overlapping requests cannot
/// open overlapping administrator prompts. A request that waited behind
/// another request's install pings again before deciding anything.
final class NetworkHelperInstallGate {
    static let shared = NetworkHelperInstallGate()

    private static let declinedBuildVersionKey = "CellDock.networkHelperInstallDeclinedBuildVersion"

    /// Serialises whole sequences. Work on it may block while it waits for a
    /// ping reply, which always arrives on another queue.
    private let sequenceQueue = DispatchQueue(label: "app.celldock.mac.network.helper.install-gate")
    private let defaults: UserDefaults
    private let installer: NetworkHelperInstaller
    private var policy: NetworkHelperInstallPolicy

    init(
        defaults: UserDefaults = .standard,
        installer: NetworkHelperInstaller = NetworkHelperInstaller()
    ) {
        self.defaults = defaults
        self.installer = installer
        let stored = defaults.object(forKey: Self.declinedBuildVersionKey) as? Int
        policy = NetworkHelperInstallPolicy(
            helperBuildVersion: CellDockNetworkIPC.helperBuildVersion,
            declinedHelperBuildVersion: stored
        )
    }

    /// Makes sure the helper answers, installing it only when the policy allows.
    /// `ping` must call its completion exactly once, on any queue other than
    /// the gate's own.
    func ensureHelper(
        kind: NetworkHelperInstallRequestKind,
        ping: @escaping (@escaping (NetworkHelperPingState) -> Void) -> Void,
        completion: @escaping (Result<Void, NetworkHelperGateFailure>) -> Void
    ) {
        sequenceQueue.async { [self] in
            completion(runSequence(kind: kind, ping: ping))
        }
    }

    private func runSequence(
        kind: NetworkHelperInstallRequestKind,
        ping: @escaping (@escaping (NetworkHelperPingState) -> Void) -> Void
    ) -> Result<Void, NetworkHelperGateFailure> {
        let initialState = Self.pingSynchronously(ping)
        if initialState == .ready {
            return .success(())
        }

        switch policy.decision(for: kind) {
        case let .suppressed(reason):
            return .failure(Self.failure(for: reason, pingState: initialState))
        case .prompt:
            break
        }

        switch installer.install() {
        case .failure(.cancelled):
            record(.cancelled, for: kind)
            return .failure(.unavailable(Self.declinedMessage))
        case let .failure(error):
            let message = error.localizedDescription
            record(.failed(message), for: kind)
            return .failure(.unavailable(message))
        case .success:
            break
        }

        var state = Self.pingSynchronously(ping)
        var attemptsRemaining = 11
        while case .unavailable = state, attemptsRemaining > 0 {
            Thread.sleep(forTimeInterval: 0.25)
            state = Self.pingSynchronously(ping)
            attemptsRemaining -= 1
        }
        if state == .ready {
            record(.installedAndReady, for: kind)
            return .success(())
        }
        let detail = Self.describe(state)
        record(.installedButUnusable(detail), for: kind)
        return .failure(.unavailable(Self.installedButUnusableMessage(detail)))
    }

    private func record(
        _ outcome: NetworkHelperInstallOutcome,
        for kind: NetworkHelperInstallRequestKind
    ) {
        policy.record(outcome, for: kind)
        if let version = policy.declinedHelperBuildVersion {
            defaults.set(version, forKey: Self.declinedBuildVersionKey)
        } else {
            defaults.removeObject(forKey: Self.declinedBuildVersionKey)
        }
    }

    private static func pingSynchronously(
        _ ping: @escaping (@escaping (NetworkHelperPingState) -> Void) -> Void
    ) -> NetworkHelperPingState {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: NetworkHelperPingState = .unavailable(L10n.tr("连接超时"))
        ping { state in
            lock.withLock { result = state }
            semaphore.signal()
        }
        // The ping enforces its own 4 s timeout; this is only a backstop.
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            return .unavailable(L10n.tr("连接超时"))
        }
        return lock.withLock { result }
    }

    // MARK: - Messages

    private static var declinedMessage: String {
        L10n.tr("网络 helper 尚未安装。重新开启蜂窝网络时会再次提供安装。")
    }

    private static func installedButUnusableMessage(_ detail: String) -> String {
        L10n.tr(
            "网络 helper 已安装，但拒绝或无法完成连接（例如 CellDock 的签名与 helper 不一致）：%@。CellDock 已停止请求管理员密码，请重新安装官方版本。",
            detail
        )
    }

    private static func failure(
        for reason: NetworkHelperInstallSuppression,
        pingState: NetworkHelperPingState
    ) -> NetworkHelperGateFailure {
        switch reason {
        case .passiveRequest:
            return .notReady(describe(pingState))
        case .declined:
            return .unavailable(declinedMessage)
        case let .failed(message):
            return .unavailable(L10n.tr("%@ 已停止自动重试安装网络 helper。", message))
        case let .installedButUnusable(detail):
            return .unavailable(installedButUnusableMessage(detail))
        case .alreadyAttempted:
            return .unavailable(L10n.tr(
                "网络 helper 当前不可用，本次运行中不会再自动请求管理员密码。重新开启蜂窝网络即可重试。"
            ))
        }
    }

    private static func describe(_ state: NetworkHelperPingState) -> String {
        switch state {
        case .ready:
            return ""
        case let .unavailable(message):
            return message
        case let .incompatible(version):
            return L10n.tr(
                "已安装的网络 helper 协议版本为 %lld，但 CellDock 需要 %lld。请重新安装最新版。",
                Int64(version),
                Int64(CellDockNetworkIPC.protocolVersion)
            )
        case .outdated:
            return L10n.tr("网络 helper 已安装，但版本仍不是当前版本。请重新安装最新版。")
        }
    }
}
