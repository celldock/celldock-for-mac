import Combine
import Foundation
import CellDockNetworkIPC
import OSLog

private let voWiFiLogger = Logger(
    subsystem: "app.celldock.mac",
    category: "VoWiFi"
)

private struct VoWiFiMacHostIdentity: Equatable {
    let egressBSDName: String
    let egressAddress: String?
    let gateway: String?
    let upstreamProxyID: UUID?
}

private struct VoWiFiMacHostSession {
    let sessionID: String
    let identity: VoWiFiMacHostIdentity
}

/// Drives the privileged Mac-side `vowifi-go` runtime while the attached modem
/// remains the sole owner of SIM/ISIM authentication material.
///
/// The controller owns three pieces of state that must stay consistent:
/// the user's intent, the Mac-side SOCKS5 relay, and the session the module
/// actually runs. `SOCKSNATTTransport` in `vowifi-go` never redials a broken
/// association, so any drift between them is repaired by restarting the whole
/// session rather than by hoping the runtime recovers.
@MainActor
final class VoWiFiController: ObservableObject {
    @Published private(set) var states: [CellularModuleID: VoWiFiSessionState] = [:]
    let upstreamStore = VoWiFiUpstreamProxyStore.shared

    private unowned let appState: AppState
    private var observations: Set<AnyCancellable> = []
    private let hostClient = NetworkHelperClient()
    private var simBridges: [CellularModuleID: VoWiFiSIMBridge] = [:]
    private var hostSessions: [CellularModuleID: VoWiFiMacHostSession] = [:]
    /// Modules the user asked to keep running. Not persisted: a VoWiFi session
    /// is only meaningful while its Mac-side relay exists.
    private var desiredRunning: Set<CellularModuleID> = []
    private var inFlight: Set<CellularModuleID> = []
    private var polls: [CellularModuleID: DispatchWorkItem] = [:]
    /// Modules whose leftover runtime has already been cleaned up once, so a
    /// module that refuses to stop cannot become a restart loop.
    private var probeAssociations: [UUID: SOCKS5UpstreamAssociation] = [:]
    private var started = false

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        guard !started else { return }
        started = true
        appState.$discoveredModemDevices
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reconcileModules() }
            }
            .store(in: &observations)
        // A Wi-Fi address or gateway change invalidates protected ePDG routes.
        appState.$networkStatusesByModuleID
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reconcileRelayIdentities() }
            }
            .store(in: &observations)
        reconcileModules()
    }

    func stop() {
        observations.removeAll()
        polls.values.forEach { $0.cancel() }
        polls.removeAll()
        inFlight.removeAll()
        for moduleID in desiredRunning {
            hostClient.stopVoWiFiHost(runtimeKey: runtimeKey(for: moduleID)) { _ in }
        }
        desiredRunning.removeAll()
        simBridges.values.forEach { $0.stop() }
        simBridges.removeAll()
        hostSessions.removeAll()
        probeAssociations.values.forEach { $0.stop() }
        probeAssociations.removeAll()
        states.removeAll()
        started = false
    }

    // MARK: - User intent

    func setRunning(_ running: Bool, for moduleID: CellularModuleID) {
        guard availableModules.contains(where: { $0.id == moduleID }) else { return }
        if running {
            startSession(moduleID, installKind: .userInitiated)
        } else {
            stopSession(moduleID)
        }
    }

    /// Applies a changed upstream route to a live session. Restarting is the
    /// only correct action: the runtime holds a single SOCKS5 association for
    /// the whole IKE SA and cannot be re-pointed in place.
    func reapplyUpstreamRoute(for moduleID: CellularModuleID) {
        guard desiredRunning.contains(moduleID) else { return }
        restartSession(moduleID, installKind: .userInitiated)
    }

    func refreshAll() {
        reconcileModules()
        for module in availableModules {
            pollNow(module.id)
        }
    }

    func refresh(_ moduleID: CellularModuleID) {
        pollNow(moduleID)
    }

    // MARK: - Session lifecycle

    private func startSession(
        _ moduleID: CellularModuleID,
        installKind: NetworkHelperInstallRequestKind
    ) {
        guard let module = availableModules.first(where: { $0.id == moduleID }),
              claim(moduleID) else { return }
        desiredRunning.insert(moduleID)
        apply(.checking, to: moduleID)

        guard let egress = VoWiFiEgress.current(excludingBSDNames: cellularInterfaceNames) else {
            release(moduleID)
            desiredRunning.remove(moduleID)
            finish(.egressUnavailable(.noInternetInterface), for: moduleID)
            return
        }
        let upstream: VoWiFiUpstreamProxySnapshot?
        do {
            upstream = try upstreamSnapshot(for: module)
        } catch {
            release(moduleID)
            desiredRunning.remove(moduleID)
            finish(.egressUnavailable(.upstreamProxy(error.localizedDescription)), for: moduleID)
            return
        }

        simBridges.removeValue(forKey: moduleID)?.stop()
        let bridge = VoWiFiSIMBridge(moduleID: moduleID) { [weak self] command, timeout, completion in
            guard let self else {
                completion(VoWiFiATResult(output: "", error: L10n.tr("CellDock 已停止。")))
                return
            }
            self.appState.executeVoWiFiAT(
                command,
                timeout: timeout,
                for: moduleID,
                completion: completion
            )
        }
        simBridges[moduleID] = bridge
        bridge.start { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(host):
                self.admitSession(
                    module: module,
                    bridge: bridge,
                    bridgeHost: host,
                    egress: egress,
                    upstream: upstream,
                    moduleID: moduleID,
                    installKind: installKind
                )
            case let .failure(error):
                self.release(moduleID)
                self.desiredRunning.remove(moduleID)
                self.teardownHost(moduleID)
                self.finish(.failed(error.localizedDescription), for: moduleID)
            }
        }
    }

    private func admitSession(
        module: CellularModuleSummary,
        bridge: VoWiFiSIMBridge,
        bridgeHost: String,
        egress: VoWiFiEgress,
        upstream: VoWiFiUpstreamProxySnapshot?,
        moduleID: CellularModuleID,
        installKind: NetworkHelperInstallRequestKind
    ) {
        guard desiredRunning.contains(moduleID) else {
            release(moduleID)
            teardownHost(moduleID)
            return
        }
        let sessionID = VoWiFiRuntimeControl.newSessionID()
        let identity = VoWiFiMacHostIdentity(
            egressBSDName: egress.bsdName,
            egressAddress: egress.ipv4Address,
            gateway: egress.router,
            upstreamProxyID: upstream?.id
        )
        hostSessions[moduleID] = VoWiFiMacHostSession(sessionID: sessionID, identity: identity)
        let request = VoWiFiHostStartRequest(
            runtimeKey: runtimeKey(for: moduleID),
            sessionID: sessionID,
            simBridgeHost: bridgeHost,
            simBridgeToken: bridge.token,
            outerInterface: egress.bsdName,
            outerGateway: egress.router,
            outerLocalIP: egress.ipv4Address,
            proxyURL: upstream.map(proxyURL),
            tunMTU: 1_280
        )
        hostClient.startVoWiFiHost(request, installKind: installKind) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.release(moduleID)
                switch result {
                case let .success(data):
                    var status = VoWiFiRuntimeStatus.parse(jsonData: data)
                    if !status.isRunning {
                        status.isRunning = true
                        status.sessionID = sessionID
                        status.phase = .starting
                    }
                    self.finish(
                        VoWiFiSessionState(status: status, expectedSessionID: sessionID),
                        for: moduleID
                    )
                case let .failure(error):
                    self.teardownHost(moduleID)
                    self.desiredRunning.remove(moduleID)
                    self.finish(.failed(error.localizedDescription), for: moduleID)
                }
            }
        }
    }

    private func stopSession(_ moduleID: CellularModuleID) {
        guard claim(moduleID) else { return }
        desiredRunning.remove(moduleID)
        apply(.checking, to: moduleID)
        hostClient.stopVoWiFiHost(runtimeKey: runtimeKey(for: moduleID)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.release(moduleID)
                self.teardownHost(moduleID)
                switch result {
                case .success: self.finish(.stopped, for: moduleID)
                case let .failure(error): self.finish(.failed(error.localizedDescription), for: moduleID)
                }
            }
        }
    }

    private func restartSession(
        _ moduleID: CellularModuleID,
        installKind: NetworkHelperInstallRequestKind
    ) {
        guard claim(moduleID) else { return }
        apply(.checking, to: moduleID)
        hostClient.stopVoWiFiHost(runtimeKey: runtimeKey(for: moduleID)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.release(moduleID)
                self.teardownHost(moduleID)
                switch result {
                case .success: self.startSession(moduleID, installKind: installKind)
                case let .failure(error):
                    self.desiredRunning.remove(moduleID)
                    self.finish(.failed(error.localizedDescription), for: moduleID)
                }
            }
        }
    }

    // MARK: - Polling

    private func pollNow(_ moduleID: CellularModuleID) {
        polls.removeValue(forKey: moduleID)?.cancel()
        guard availableModules.contains(where: { $0.id == moduleID }), claim(moduleID) else {
            return
        }
        hostClient.queryVoWiFiHost(runtimeKey: runtimeKey(for: moduleID)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.release(moduleID)
                guard self.availableModules.contains(where: { $0.id == moduleID }) else { return }
                switch result {
                case let .success(data):
                    self.evaluate(VoWiFiRuntimeStatus.parse(jsonData: data), for: moduleID)
                case let .failure(error as NetworkHelperNotReadyError):
                    self.finish(
                        .whenHelperNotReady(
                            runningRequested: self.desiredRunning.contains(moduleID),
                            message: error.message
                        ),
                        for: moduleID
                    )
                case let .failure(error):
                    self.finish(.failed(error.localizedDescription), for: moduleID)
                }
            }
        }
    }

    private func evaluate(_ status: VoWiFiRuntimeStatus, for moduleID: CellularModuleID) {
        let session = hostSessions[moduleID]
        let state = VoWiFiSessionState(status: status, expectedSessionID: session?.sessionID)

        if desiredRunning.contains(moduleID) {
            // The module can only report that its proxy died; whether the Mac
            // still has an egress at all is local knowledge.
            if VoWiFiEgress.current(excludingBSDNames: cellularInterfaceNames) == nil {
                finish(.egressUnavailable(.noInternetInterface), for: moduleID)
                return
            }
            switch state {
            case .desynchronized:
                restartSession(moduleID, installKind: .automatic)
                return
            case .stopped, .failed:
                teardownHost(moduleID)
                desiredRunning.remove(moduleID)
            default:
                if let session, let current = currentHostIdentity(for: moduleID),
                   session.identity != current {
                    voWiFiLogger.notice(
                        "Rebuilding VoWiFi session after network change module=\(moduleID.rawValue, privacy: .public)"
                    )
                    restartSession(moduleID, installKind: .automatic)
                    return
                }
            }
        }
        finish(state, for: moduleID)
    }

    private func schedulePoll(after interval: TimeInterval?, for moduleID: CellularModuleID) {
        polls.removeValue(forKey: moduleID)?.cancel()
        guard let interval else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pollNow(moduleID) }
        }
        polls[moduleID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    // MARK: - Upstream proxies

    func probeUpstream(_ id: UUID) {
        guard probeAssociations[id] == nil else { return }
        upstreamStore.setProbeState(.probing, for: id)
        let snapshot: VoWiFiUpstreamProxySnapshot
        do {
            snapshot = try upstreamStore.snapshot(for: id)
        } catch {
            upstreamStore.setProbeState(.failed(error.localizedDescription), for: id)
            return
        }
        guard let egress = VoWiFiEgress.current(excludingBSDNames: cellularInterfaceNames) else {
            upstreamStore.setProbeState(
                .failed(VoWiFiEgressProblem.noInternetInterface.localizedDescription),
                for: id
            )
            return
        }
        let queue = DispatchQueue(label: "app.celldock.vowifi.probe.\(id.uuidString)")
        let association = SOCKS5UpstreamAssociation(
            configuration: snapshot,
            bsdName: snapshot.usesLoopbackEndpoint ? "lo0" : egress.bsdName,
            dnsServers: egress.dnsServers,
            queue: queue
        )
        probeAssociations[id] = association
        association.start { [weak self, weak association] result in
            DispatchQueue.main.async {
                guard let self else { return }
                association?.stop()
                self.probeAssociations[id] = nil
                switch result {
                case .success:
                    self.upstreamStore.setProbeState(.succeeded(Date()), for: id)
                case let .failure(error):
                    self.upstreamStore.setProbeState(.failed(error.localizedDescription), for: id)
                }
            }
        }
    }

    // MARK: - Reconciliation

    private func reconcileModules() {
        let availableIDs = Set(availableModules.map(\.id))
        for moduleID in Set(states.keys).subtracting(availableIDs) {
            states[moduleID] = nil
            polls.removeValue(forKey: moduleID)?.cancel()
            teardownHost(moduleID)
            desiredRunning.remove(moduleID)
        }
        inFlight.formIntersection(availableIDs)
        for moduleID in availableIDs where states[moduleID] == nil {
            states[moduleID] = .checking
            pollNow(moduleID)
        }
    }

    private func reconcileRelayIdentities() {
        for moduleID in desiredRunning {
            guard let session = hostSessions[moduleID],
                  let current = currentHostIdentity(for: moduleID),
                  session.identity != current else {
                continue
            }
            // Wi-Fi changes restart a running session in the background.
            restartSession(moduleID, installKind: .automatic)
        }
    }

    private func currentHostIdentity(for moduleID: CellularModuleID) -> VoWiFiMacHostIdentity? {
        guard let module = availableModules.first(where: { $0.id == moduleID }),
              let egress = VoWiFiEgress.current(excludingBSDNames: cellularInterfaceNames) else {
            return nil
        }
        let identity = module.modem.moduleIMEI ?? module.id.rawValue
        let upstreamProxyID: UUID? = switch upstreamStore.route(for: identity) {
        case .direct: nil
        case let .proxy(id): id
        }
        return VoWiFiMacHostIdentity(
            egressBSDName: egress.bsdName,
            egressAddress: egress.ipv4Address,
            gateway: egress.router,
            upstreamProxyID: upstreamProxyID
        )
    }

    private func upstreamSnapshot(
        for module: CellularModuleSummary
    ) throws -> VoWiFiUpstreamProxySnapshot? {
        let identity = module.modem.moduleIMEI ?? module.id.rawValue
        switch upstreamStore.route(for: identity) {
        case .direct:
            return nil
        case let .proxy(id):
            return try upstreamStore.snapshot(for: id)
        }
    }

    // MARK: - Helpers

    var availableModules: [CellularModuleSummary] {
        appState.cellularModules.filter { $0.modem.isConnected && $0.isActiveSession }
    }

    func isRunningRequested(_ moduleID: CellularModuleID) -> Bool {
        desiredRunning.contains(moduleID)
    }

    func relayDescription(for moduleID: CellularModuleID) -> String? {
        hostSessions[moduleID]?.identity.egressBSDName
    }

    private var cellularInterfaceNames: Set<String> {
        Set(appState.cellularModules.compactMap(\.network.bsdName))
    }

    private func claim(_ moduleID: CellularModuleID) -> Bool {
        inFlight.insert(moduleID).inserted
    }

    private func release(_ moduleID: CellularModuleID) {
        inFlight.remove(moduleID)
    }

    private func teardownHost(_ moduleID: CellularModuleID) {
        simBridges.removeValue(forKey: moduleID)?.stop()
        hostSessions.removeValue(forKey: moduleID)
    }

    private func runtimeKey(for moduleID: CellularModuleID) -> String {
        let value = moduleID.rawValue.lowercased().filter { $0.isLetter || $0.isNumber }
        return String(value.prefix(80))
    }

    private func proxyURL(_ proxy: VoWiFiUpstreamProxySnapshot) -> String {
        var components = URLComponents()
        components.scheme = "socks5"
        components.host = proxy.host
        components.port = Int(proxy.port)
        if let username = proxy.username {
            components.user = username
            components.password = proxy.password
        }
        return components.string ?? "socks5://\(proxy.host):\(proxy.port)"
    }

    /// Publishes a state and arms the next poll for it in one place, so no path
    /// can leave a module without a scheduled refresh.
    private func finish(_ state: VoWiFiSessionState, for moduleID: CellularModuleID) {
        guard availableModules.contains(where: { $0.id == moduleID }) else { return }
        apply(state, to: moduleID)
        schedulePoll(after: state.pollInterval, for: moduleID)
    }

    private func apply(_ state: VoWiFiSessionState, to moduleID: CellularModuleID) {
        guard states[moduleID] != state else { return }
        states[moduleID] = state
        switch state {
        case .registered:
            voWiFiLogger.notice(
                "VoWiFi registered over SOCKS5 module=\(moduleID.rawValue, privacy: .public)"
            )
        case let .unsupported(reason), let .failed(reason):
            voWiFiLogger.info(
                "VoWiFi unavailable module=\(moduleID.rawValue, privacy: .public) reason=\(reason, privacy: .private(mask: .hash))"
            )
        default:
            voWiFiLogger.info(
                "VoWiFi state module=\(moduleID.rawValue, privacy: .public) state=\(String(describing: state), privacy: .private(mask: .hash))"
            )
        }
    }
}
