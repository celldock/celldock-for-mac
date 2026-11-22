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
    /// Whether finished requests are kept in each proxy's in-memory history.
    /// Running requests are always listed.
    @Published var recordsRequestHistory: Bool {
        didSet {
            guard recordsRequestHistory != oldValue else { return }
            defaults.set(recordsRequestHistory, forKey: Self.recordsHistoryKey)
            requestLogs.values.forEach { $0.isRecordingHistory = recordsRequestHistory }
        }
    }

    let store: SOCKSProxyStore
    private unowned let appState: AppState
    private let defaults: UserDefaults
    private var servers: [UUID: SOCKSProxyServer] = [:]
    /// Kept apart from the listeners so a restart does not lose the history.
    private var requestLogs: [UUID: SOCKSProxyRequestLog] = [:]
    private var observations: Set<AnyCancellable> = []
    private var started = false

    private static let recordsHistoryKey = "SOCKSProxyRecordsRequestHistory.v1"

    init(appState: AppState, store: SOCKSProxyStore? = nil, defaults: UserDefaults = .standard) {
        self.appState = appState
        self.store = store ?? .shared
        self.defaults = defaults
        recordsRequestHistory = defaults.object(forKey: Self.recordsHistoryKey) as? Bool ?? true
    }

    // MARK: Requests

    /// Running requests and history of one proxy, also while it is stopped.
    func requestSnapshot(for proxyID: UUID) -> SOCKSProxyRequestSnapshot {
        if let server = servers[proxyID] { return server.snapshot() }
        return requestLogs[proxyID]?.snapshot(active: []) ?? .empty
    }

    func cancelRequest(_ requestID: UUID, proxyID: UUID) {
        servers[proxyID]?.cancel(requestID: requestID)
    }

    func clearRequestHistory(for proxyID: UUID) {
        requestLogs[proxyID]?.clearHistory()
    }

    /// The module the proxy sends its traffic through, if it is attached.
    func egressModuleID(for proxyID: UUID) -> CellularModuleID? {
        guard let config = store.configurations.first(where: { $0.id == proxyID }) else { return nil }
        return appState.attachedModuleID(forIMEI: config.moduleIMEI)
    }

    private func requestLog(for proxyID: UUID) -> SOCKSProxyRequestLog {
        if let existing = requestLogs[proxyID] { return existing }
        let log = SOCKSProxyRequestLog(recordsHistory: recordsRequestHistory)
        requestLogs[proxyID] = log
        return log
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
        for id in requestLogs.keys where !validIDs.contains(id) { requestLogs[id] = nil }
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
        let server = SOCKSProxyServer(
            configuration: config,
            password: password,
            requestLog: requestLog(for: config.id)
        )
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

/// Feeds the request tab of one proxy. It polls the controller once a second
/// only while the tab is on screen, so a proxy with a thousand connections
/// costs nothing while nobody is looking.
@MainActor
final class SOCKSProxyRequestFeed: ObservableObject {
    @Published private(set) var snapshot = SOCKSProxyRequestSnapshot.empty
    /// Speed of this proxy's own traffic, last 60 seconds.
    @Published private(set) var proxyThroughput = NetworkThroughputHistory()
    /// Time of the latest refresh, so running durations tick along.
    @Published private(set) var now = Date()

    let proxyID: UUID
    private weak var controller: SOCKSProxyController?
    private var timer: Timer?
    private var rateTracker = SOCKSProxyTrafficRateTracker()

    init(proxyID: UUID, controller: SOCKSProxyController) {
        self.proxyID = proxyID
        self.controller = controller
    }

    func start() {
        guard timer == nil else { return }
        rateTracker.reset()
        proxyThroughput.removeAll()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard let controller else { return }
        let next = controller.requestSnapshot(for: proxyID)
        if let rate = rateTracker.rate(
            downloaded: next.totalDownloadedBytes,
            uploaded: next.totalUploadedBytes,
            uptime: ProcessInfo.processInfo.systemUptime
        ) {
            proxyThroughput.append(rate)
        }
        if next != snapshot { snapshot = next }
        now = Date()
    }

    func cancel(_ requestID: UUID) {
        controller?.cancelRequest(requestID, proxyID: proxyID)
        refresh()
    }

    func clearHistory() {
        controller?.clearRequestHistory(for: proxyID)
        refresh()
    }
}
