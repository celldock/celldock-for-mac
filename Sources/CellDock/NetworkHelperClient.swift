import Foundation
import CellDockNetworkIPC

final class NetworkHelperClient {
    private let queue = DispatchQueue(label: "app.celldock.mac.network.helper.client")
    private let installGate: NetworkHelperInstallGate

    init(installGate: NetworkHelperInstallGate = .shared) {
        self.installGate = installGate
    }

    func startVoWiFiHost(
        _ request: VoWiFiHostStartRequest,
        installKind: NetworkHelperInstallRequestKind,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        ensureHelper(kind: installKind) { [weak self] result in
            switch result {
            case .success:
                self?.invokeVoWiFiStart(request, completion: completion)
            case let .failure(failure):
                completion(.failure(VoWiFiHostClientError.helperUnavailable(failure.message)))
            }
        }
    }

    /// Passive: never installs the helper. Without a helper there is no
    /// runtime to stop, so that counts as stopped.
    func stopVoWiFiHost(
        runtimeKey: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        ensureHelper(kind: .passive) { [weak self] result in
            switch result {
            case .success:
                self?.invokeVoWiFiStop(runtimeKey: runtimeKey, completion: completion)
            case .failure(.notReady):
                completion(.success(()))
            case let .failure(failure):
                completion(.failure(VoWiFiHostClientError.helperUnavailable(failure.message)))
            }
        }
    }

    /// Passive: never installs the helper. A missing or unusable helper is
    /// reported as `NetworkHelperNotReadyError`, so the caller can tell it
    /// apart from a runtime failure.
    func queryVoWiFiHost(
        runtimeKey: String,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        ensureHelper(kind: .passive) { [weak self] result in
            switch result {
            case .success:
                self?.invokeVoWiFiQuery(runtimeKey: runtimeKey, completion: completion)
            case let .failure(.notReady(message)):
                completion(.failure(NetworkHelperNotReadyError(message: message)))
            case let .failure(failure):
                completion(.failure(VoWiFiHostClientError.helperUnavailable(failure.message)))
            }
        }
    }

    func applyCellularNetworkConfiguration(
        _ request: CellularNetworkConfigurationRequest,
        installKind: NetworkHelperInstallRequestKind,
        completion: @escaping (CellularNetworkActionResult) -> Void
    ) {
        ensureHelper(kind: installKind) { [weak self] result in
            switch result {
            case .success:
                self?.invokeApply(request, completion: completion)
            case let .failure(failure):
                completion(.failure(failure.message, reason: .other))
            }
        }
    }

    /// Runs the shared ping-install-wait sequence and delivers the result on
    /// this client's queue.
    private func ensureHelper(
        kind: NetworkHelperInstallRequestKind,
        completion: @escaping (Result<Void, NetworkHelperGateFailure>) -> Void
    ) {
        installGate.ensureHelper(
            kind: kind,
            ping: { [weak self] reply in
                guard let self else {
                    reply(.unavailable(L10n.tr("CellDock 已停止。")))
                    return
                }
                self.ping(completion: reply)
            },
            completion: { [queue] result in
                queue.async { completion(result) }
            }
        )
    }

    private func ping(completion: @escaping (NetworkHelperPingState) -> Void) {
        let connection = makeConnection()
        let gate = OneShot<NetworkHelperPingState> { [queue] result in
            connection.invalidate()
            queue.async { completion(result) }
        }
        connection.resume()
        queue.asyncAfter(deadline: .now() + .seconds(4)) {
            gate.resolve(.unavailable(L10n.tr("连接超时")))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resolve(.unavailable(error.localizedDescription))
        }) as? CellDockNetworkHelperProtocol else {
            gate.resolve(.unavailable(L10n.tr("无法建立 XPC 代理")))
            return
        }
        proxy.ping { version, identity in
            if version != CellDockNetworkIPC.protocolVersion {
                gate.resolve(.incompatible(version))
            } else if identity != CellDockNetworkIPC.helperIdentity {
                gate.resolve(.outdated)
            } else {
                gate.resolve(.ready)
            }
        }
    }

    private func invokeApply(
        _ request: CellularNetworkConfigurationRequest,
        completion: @escaping (CellularNetworkActionResult) -> Void
    ) {
        let connection = makeConnection()
        let gate = OneShot<CellularNetworkActionResult> { [queue] result in
            connection.invalidate()
            queue.async { completion(result) }
        }
        connection.resume()
        // Budget per newly enabled module: up to 30s waiting for the ECM carrier
        // plus up to 20s for configd's DHCP attempt and one verified client
        // reset. Cold-starting two modules at once is the worst case, so this is
        // a safety net for a wedged helper rather than an expected wait.
        queue.asyncAfter(deadline: .now() + .seconds(120)) {
            gate.resolve(.failure(
                L10n.tr("网络 helper 操作超时；未继续重试，以免重复修改。"),
                reason: .other
            ))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resolve(.failure(
                L10n.error("网络 helper 连接中断：%@", underlying: error),
                reason: .other
            ))
        }) as? CellDockNetworkHelperProtocol else {
            gate.resolve(.failure(L10n.tr("无法建立网络 helper XPC 代理。"), reason: .other))
            return
        }
        guard let requestData = try? JSONEncoder().encode(request) else {
            gate.resolve(.failure(L10n.tr("无法编码蜂窝网络配置。"), reason: .other))
            return
        }
        proxy.applyCellularNetworkConfiguration(requestData) { rawCode, message in
            switch CellDockNetworkResultCode(rawValue: rawCode) {
            case .success:
                gate.resolve(.success(message))
            case .linkInactive:
                gate.resolve(.failure(message, reason: .linkInactive))
            case .dhcpTimeout:
                gate.resolve(.failure(message, reason: .dhcpTimeout))
            case .failure, nil:
                gate.resolve(.failure(message, reason: .other))
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: CellDockNetworkIPC.helperLabel,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CellDockNetworkHelperProtocol.self)
        return connection
    }

    private func invokeVoWiFiStart(
        _ request: VoWiFiHostStartRequest,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        invokeVoWiFiData(method: .start, request: request, completion: completion)
    }

    private func invokeVoWiFiQuery(
        runtimeKey: String,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        invokeVoWiFiData(
            method: .query,
            request: VoWiFiHostStatusRequest(runtimeKey: runtimeKey),
            completion: completion
        )
    }

    private enum VoWiFiDataMethod { case start, query }

    private func invokeVoWiFiData<Request: Encodable>(
        method: VoWiFiDataMethod,
        request: Request,
        completion: @escaping (Result<Data?, Error>) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(request) else {
            completion(.failure(VoWiFiHostClientError.invalidRequest))
            return
        }
        let connection = makeConnection()
        let gate = OneShot<Result<Data?, Error>> { [queue] result in
            connection.invalidate()
            queue.async { completion(result) }
        }
        connection.resume()
        queue.asyncAfter(deadline: .now() + .seconds(20)) {
            gate.resolve(.failure(VoWiFiHostClientError.timeout))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resolve(.failure(error))
        }) as? CellDockNetworkHelperProtocol else {
            gate.resolve(.failure(VoWiFiHostClientError.helperUnavailable(
                L10n.tr("无法建立网络 helper XPC 代理。")
            )))
            return
        }
        let reply: (Int, String, Data?) -> Void = { code, message, response in
            if CellDockNetworkResultCode(rawValue: code) == .success {
                gate.resolve(.success(response))
            } else {
                gate.resolve(.failure(VoWiFiHostClientError.helperFailure(message)))
            }
        }
        switch method {
        case .start: proxy.startVoWiFiHost(data, reply: reply)
        case .query: proxy.queryVoWiFiHost(data, reply: reply)
        }
    }

    private func invokeVoWiFiStop(
        runtimeKey: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(
            VoWiFiHostStatusRequest(runtimeKey: runtimeKey)
        ) else {
            completion(.failure(VoWiFiHostClientError.invalidRequest))
            return
        }
        let connection = makeConnection()
        let gate = OneShot<Result<Void, Error>> { [queue] result in
            connection.invalidate()
            queue.async { completion(result) }
        }
        connection.resume()
        queue.asyncAfter(deadline: .now() + .seconds(15)) {
            gate.resolve(.failure(VoWiFiHostClientError.timeout))
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            gate.resolve(.failure(error))
        }) as? CellDockNetworkHelperProtocol else {
            gate.resolve(.failure(VoWiFiHostClientError.helperUnavailable(
                L10n.tr("无法建立网络 helper XPC 代理。")
            )))
            return
        }
        proxy.stopVoWiFiHost(data) { code, message in
            if CellDockNetworkResultCode(rawValue: code) == .success {
                gate.resolve(.success(()))
            } else {
                gate.resolve(.failure(VoWiFiHostClientError.helperFailure(message)))
            }
        }
    }
}

/// A status query found no usable network helper and, being passive, did not
/// offer to install one.
struct NetworkHelperNotReadyError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum VoWiFiHostClientError: LocalizedError {
    case invalidRequest
    case timeout
    case helperUnavailable(String)
    case helperFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return L10n.tr("无法编码 VoWiFi 请求。")
        case .timeout: return L10n.tr("VoWiFi helper 操作超时。")
        case let .helperUnavailable(message), let .helperFailure(message): return message
        }
    }
}

private final class OneShot<Value> {
    private let lock = NSLock()
    private var action: ((Value) -> Void)?

    init(_ action: @escaping (Value) -> Void) {
        self.action = action
    }

    func resolve(_ value: Value) {
        let callback: ((Value) -> Void)? = lock.withLock {
            defer { action = nil }
            return action
        }
        callback?(value)
    }
}
