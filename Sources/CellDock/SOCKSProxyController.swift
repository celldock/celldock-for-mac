import Combine
import Foundation
import Network
import OSLog

private let socksProxyLogger = Logger(
    subsystem: "app.celldock.mac",
    category: "SOCKSProxy"
)

@MainActor
final class SOCKSProxyController: ObservableObject {
    @Published private(set) var runtimeStates: [UUID: SOCKSProxyRuntimeState] = [:]

    let store: SOCKSProxyStore
    private unowned let appState: AppState
    private var servers: [UUID: SOCKSProxyServer] = [:]
    private var observations: Set<AnyCancellable> = []
    private var started = false

    init(appState: AppState, store: SOCKSProxyStore? = nil) {
        self.appState = appState
        self.store = store ?? .shared
    }

    func start() {
        guard !started else { return }
        started = true
        // @Published emits from willSet, so a sink that reads the property
        // back still sees the previous value. Reconciling on the next main
        // queue turn makes a link or mode change take effect at once instead
        // of whenever something else happened to publish again.
        store.$configurations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &observations)
        appState.$networkStatusesByModuleID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &observations)
        appState.$cellularNetworkModesByModuleID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &observations)
        reconcile()
    }

    func stop() {
        servers.values.forEach { $0.stop() }
        servers.removeAll()
        runtimeStates.removeAll()
        observations.removeAll()
        started = false
    }

    /// Single place where a runtime state is published, so every transition is
    /// visible in the log. Diagnosing a proxy that refused to start previously
    /// required a crash report because this layer emitted nothing at all.
    private func apply(_ state: SOCKSProxyRuntimeState, to id: UUID, name: String) {
        guard runtimeStates[id] != state else { return }
        runtimeStates[id] = state
        switch state {
        case .running:
            socksProxyLogger.notice(
                "Proxy listening name=\(name, privacy: .public) state=\(String(describing: state), privacy: .public)"
            )
        case .failedPortInUse, .failedToStart:
            socksProxyLogger.error(
                "Proxy failed name=\(name, privacy: .public) state=\(String(describing: state), privacy: .public)"
            )
        default:
            socksProxyLogger.info(
                "Proxy stopped name=\(name, privacy: .public) state=\(String(describing: state), privacy: .public)"
            )
        }
    }

    func reconcile() {
        let configs = store.configurations
        let validIDs = Set(configs.map(\.id))
        for id in servers.keys where !validIDs.contains(id) { stopServer(id) }
        let conflicts = Set(SOCKSProxyPortAllocator.conflicts(in: configs))

        for config in configs {
            guard !conflicts.contains(config.id) else {
                stopServer(config.id)
                apply(.failedPortInUse(config.port), to: config.id, name: config.name)
                continue
            }
            // Resolved through the app state so that a module whose AT session
            // is merely reconnecting still counts as attached. The listener
            // and its live connections only need the ECM interface.
            guard let moduleID = appState.attachedModuleID(forIMEI: config.moduleIMEI) else {
                stopServer(config.id)
                apply(
                    SOCKSProxyRunPolicy.stoppedState(
                        isEnabled: config.isEnabled,
                        mode: .standby,
                        network: nil
                    ) ?? .stoppedModuleOffline,
                    to: config.id,
                    name: config.name
                )
                continue
            }
            if let stopped = SOCKSProxyRunPolicy.stoppedState(
                isEnabled: config.isEnabled,
                mode: appState.networkMode(for: moduleID),
                network: appState.networkStatus(for: moduleID)
            ) {
                stopServer(config.id)
                apply(stopped, to: config.id, name: config.name)
                continue
            }
            let password = store.password(for: config.id)
            if case .usernamePassword = config.authentication, password?.isEmpty != false {
                stopServer(config.id)
                apply(.stoppedMissingCredentials, to: config.id, name: config.name)
                continue
            }
            if config.listenScope == .lan, case .none = config.authentication {
                stopServer(config.id)
                apply(.stoppedMissingCredentials, to: config.id, name: config.name)
                continue
            }
            ensureServer(config, password: password)
        }
    }

    private func ensureServer(_ config: SOCKSProxyConfiguration, password: String?) {
        // A fresh snapshot is pushed on every reconcile, which fires on network
        // status changes, so sessions never have to reach back to the main actor.
        let binding = appState.socksProxyNetworkBinding(forModuleIMEI: config.moduleIMEI)
        if let existing = servers[config.id], existing.configuration == config {
            existing.updateBinding(binding)
            return
        }
        stopServer(config.id)
        let server = SOCKSProxyServer(configuration: config, password: password)
        server.updateBinding(binding)
        server.onConnectionCountChanged = { [weak self] count in
            DispatchQueue.main.async {
                guard let self, self.servers[config.id] != nil else { return }
                self.apply(.running(connections: count), to: config.id, name: config.name)
            }
        }
        server.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.servers[config.id] != nil else { return }
                self.servers[config.id] = nil
                self.apply(
                    Self.failureState(error, port: config.port),
                    to: config.id,
                    name: config.name
                )
            }
        }
        do {
            try server.start()
            servers[config.id] = server
            apply(.running(connections: 0), to: config.id, name: config.name)
        } catch {
            socksProxyLogger.error(
                "Proxy listener could not start name=\(config.name, privacy: .public) port=\(config.port) error=\(String(describing: error), privacy: .public)"
            )
            apply(Self.failureState(error, port: config.port), to: config.id, name: config.name)
        }
    }

    private static func failureState(_ error: Error, port: UInt16) -> SOCKSProxyRuntimeState {
        guard let posix = error as? NWError, case let .posix(code) = posix else {
            return SOCKSProxyListenerFailure.state(
                posixCode: nil,
                description: error.localizedDescription,
                port: port
            )
        }
        return SOCKSProxyListenerFailure.state(
            posixCode: code.rawValue,
            description: String(describing: code),
            port: port
        )
    }

    private func stopServer(_ id: UUID) {
        servers.removeValue(forKey: id)?.stop()
    }
}
