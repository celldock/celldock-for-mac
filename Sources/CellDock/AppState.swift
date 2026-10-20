import AppKit
import AVFoundation
import Combine
import Foundation
import CellDockNetworkIPC
import OSLog

private let cellularNetworkLogger = Logger(
    subsystem: "app.celldock.mac",
    category: "CellularNetwork"
)

private struct NetworkModuleRestartContext {
    let moduleID: CellularModuleID
    let locationID: UInt32
    var didRebuildService = false
}

@MainActor
final class AppState: ObservableObject {
    lazy var localCallAPIController = LocalCallAPIController(appState: self)
    lazy var socksProxyController = SOCKSProxyController(appState: self)
    lazy var voWiFiController = VoWiFiController(appState: self)
    @Published private(set) var modem = ModemSnapshot()
    @Published private(set) var euicc = EUICCSnapshot.empty
    @Published private(set) var network = CellularNetworkStatus()
    @Published private(set) var networkStatusesByModuleID:
        [CellularModuleID: CellularNetworkStatus] = [:]
    @Published private(set) var discoveredModemDevices: [DiscoveredModemDevice] = []
    @Published private(set) var auxiliaryModemSnapshots: [UInt32: ModemSnapshot] = [:]
    @Published private(set) var auxiliaryEUICCSnapshots: [UInt32: EUICCSnapshot] = [:]
    @Published private(set) var currentCommunicationModuleID: CellularModuleID? =
        .compatibilityPrimary
    @Published private(set) var primaryDataModuleID: CellularModuleID? = .compatibilityPrimary
    @Published private(set) var messages: [SMSMessage] = []
    @Published private(set) var call = CallSnapshot()
    @Published var isChangingNetwork = false
    @Published private(set) var cellularNetworkMode: CellularNetworkMode = .off
    @Published private(set) var pendingCellularNetworkMode: CellularNetworkMode?
    @Published private(set) var cellularNetworkModesByModuleID:
        [CellularModuleID: CellularNetworkMode] = [:]
    @Published private(set) var pendingCellularNetworkModesByModuleID:
        [CellularModuleID: CellularNetworkMode] = [:]
    /// The module whose link is being repaired, if any. Recovery reconfigures
    /// the shared service order, so it stays serialized; only the target
    /// changes. Nil means no recovery is running.
    @Published private(set) var recoveringNetworkLinkModuleID: CellularModuleID?
    @Published var isConfiguringECM = false
    @Published var isConvertingModuleIdentity = false
    @Published var isChangingCall = false
    @Published var isChangingIncomingCallSetting = false
    @Published var isSendingMessage = false
    @Published var isExecutingAT = false
    @Published private(set) var transientMessage: String?
    @Published private(set) var transientIsError = false
    @Published private(set) var messageDetailRequestSerial = 0
    @Published private(set) var requestedMessageDetailID: SMSMessage.ID?
    @Published private(set) var hideMenuBarIconWhenDisconnected: Bool
    @Published private(set) var autoDeleteReadVerificationMessages: Bool
    @Published private(set) var automaticallyRecordCalls: Bool
    @Published private(set) var isPresentationPrivacyEnabled: Bool
    @Published private(set) var isMenuBarStatusItemVisible: Bool
    @Published private(set) var showsMenuBarNetworkSpeed: Bool
    @Published private(set) var notificationAuthorizationStatus: AppNotificationAuthorizationStatus = .unknown
    @Published private(set) var isRequestingNotificationAuthorization = false
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var isChangingLaunchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private let modemService = ModemService()
    private let modemInventoryService = ModemInventoryService()
    private var secondaryModemServices: [UInt32: ModemService] = [:]
    private var secondaryEUICCServices: [UInt32: EUICCService] = [:]
    private var secondaryEUICCProbeIdentities: [UInt32: String] = [:]
    private var moduleCallSnapshots: [CellularModuleID: CallSnapshot] = [:]
    private var activeCallModuleID: CellularModuleID?
    private var sendingMessageModuleIDs: Set<CellularModuleID> = []
    private lazy var euiccService = EUICCService(modemService: modemService)
    let callHistory = CallHistoryStore()
    let callRecordings = CallRecordingStore.shared
    let alertSounds = AlertSoundService.shared
    private let networkController = NetworkServiceController()
    private let cellularNetworkingPreferenceStore = CellularNetworkingPreferenceStore()
    private let messageStore = MessageStore()
    private let launchAtLoginController = LaunchAtLoginController()
    private var started = false
    private var notificationAuthorizationCompletions: [() -> Void] = []
    private var lastEUICCProbeIdentity: String?
    private var activeModemLocationID: UInt32?
    private var deletingMessageIDs: Set<SMSMessage.ID> = []
    private var verificationAutoDeleteTask: Task<Void, Never>?
    private var verificationAutoDeleteRetryDates: [SMSMessage.ID: Date] = [:]
    private var transientDismissalTask: Task<Void, Never>?
    private var cellularLinkRecoveryTask: Task<Void, Never>?
    private var cellularLinkRecoveryInFlight = false
    private var cellularLinkRecoveryGeneration: UInt64 = 0
    private var cellularRecoveryOwnsNetworkChange = false
    private var completedCellularLinkRecoveryAttempts: [CellularModuleID: Int] = [:]
    private var automaticPriorityInFlight = false
    private var lastAutomaticPriorityAttemptServiceID: String?
    private var startupCellularRestorePending = false
    private var startupCellularRestoreInFlight = false
    private var cellularRestoreModuleIdentity: String?
    private var cellularRestoreDesiredMode: CellularNetworkMode?
    private var networkModeIdentityByModuleID: [CellularModuleID: String] = [:]
    private var provisionalNetworkPreferenceModuleIDs: Set<CellularModuleID> = []
    private var lastScheduledNetworkConfigurationSignature: String?
    private var didRestartModuleForCellularRecovery: Set<CellularModuleID> = []
    private var lastCellularModuleRestartAt: [CellularModuleID: Date] = [:]
    private var pendingNetworkModuleRestart: NetworkModuleRestartContext?
    private var networkModuleRestartTask: Task<Void, Never>?
    private var secondaryModemServiceRebuilds: Set<UInt32> = []
    private var initialSetupPromptTask: Task<Void, Never>?
    private var initialSetupWasPresentedForCurrentInsertion = false
    private var initialSetupPresentationIsActive = false
    private var automaticRecordingAttemptedCallID: UUID?
    private let privacyAliasSalt: String
    private static let initialSetupCompletedKey = "CellDockInitialSetupCompleted.v1"
    private static let networkServiceRecordKey = "CellDock.modemNetworkServiceRecord"
    private static let selectedInternetModuleKey = "SelectedInternetModule.v1"
    private static let hideDisconnectedMenuBarIconKey = "HideMenuBarIconWhenDisconnected.v1"
    private static let showsMenuBarNetworkSpeedKey = "ShowsMenuBarNetworkSpeed.v1"
    private static let autoDeleteReadVerificationMessagesKey =
        "AutoDeleteReadVerificationMessages.v1"
    private static let automaticallyRecordCallsKey = "AutomaticallyRecordCalls.v1"

    init() {
        try? launchAtLoginController.migrateLegacyRegistrationIfNeeded()
        let shouldHide = UserDefaults.standard.bool(forKey: Self.hideDisconnectedMenuBarIconKey)
        hideMenuBarIconWhenDisconnected = shouldHide
        autoDeleteReadVerificationMessages = UserDefaults.standard.bool(
            forKey: Self.autoDeleteReadVerificationMessagesKey
        )
        automaticallyRecordCalls = UserDefaults.standard.bool(
            forKey: Self.automaticallyRecordCallsKey
        )
        isPresentationPrivacyEnabled = UserDefaults.standard.bool(
            forKey: PrivacyProtectionPreferences.enabledKey
        )
        privacyAliasSalt = PrivacyProtectionPreferences.aliasSalt()
        isMenuBarStatusItemVisible = !shouldHide
        showsMenuBarNetworkSpeed = UserDefaults.standard.bool(
            forKey: Self.showsMenuBarNetworkSpeedKey
        )
        launchAtLoginStatus = launchAtLoginController.status
        if let storedModuleID = UserDefaults.standard.string(
            forKey: Self.selectedInternetModuleKey
        ) {
            primaryDataModuleID = CellularModuleID(rawValue: storedModuleID)
        }
    }

    var unreadCount: Int {
        messages.lazy.filter { !$0.isRead }.count
    }

    var privacyPresentation: PrivacyPresentation {
        PrivacyPresentation(
            isEnabled: isPresentationPrivacyEnabled,
            aliasSalt: privacyAliasSalt
        )
    }

    var presentedCellularNetworkingEnabled: Bool {
        presentedCellularNetworkMode.isEnabled
    }

    var presentedCellularNetworkMode: CellularNetworkMode {
        pendingCellularNetworkMode ?? cellularNetworkMode
    }

    var preferredCellularModuleID: CellularModuleID? {
        cellularModules.first { networkMode(for: $0.id) == .preferred }?.id
    }

    var enabledCellularModuleCount: Int {
        cellularModules.filter { networkMode(for: $0.id).isEnabled }.count
    }

    /// True when an attached module's live network state does not match the mode
    /// the user asked for, e.g. it was set to cellular priority but the system
    /// never handed it the default route. Modules mid-transaction are excluded.
    var hasCellularNetworkConfigurationIssue: Bool {
        cellularModules.contains { module in
            guard !isChangingNetworkMode(for: module.id) else { return false }
            let status = networkStatus(for: module.id)
            guard status.isHardwarePresent else { return false }
            if status.issue?.isWarning == true { return true }
            return !CellularNetworkStartupPolicy.isApplied(
                networkMode(for: module.id),
                to: status
            )
        }
    }

    var hasEnabledCellularModule: Bool {
        enabledCellularModuleCount > 0
    }

    func networkMode(for moduleID: CellularModuleID) -> CellularNetworkMode {
        if let pending = pendingCellularNetworkModesByModuleID[moduleID] { return pending }
        if let stored = cellularNetworkModesByModuleID[moduleID] { return stored }
        return storedCellularNetworkMode(for: moduleID) ?? .defaultConnectionMode
    }

    func networkStatus(for moduleID: CellularModuleID) -> CellularNetworkStatus {
        networkStatusesByModuleID[moduleID] ?? (
            primaryDataModuleID == moduleID ? network : CellularNetworkStatus()
        )
    }

    /// Resolves a persisted modem identity to its current network interface in
    /// one main-actor pass. A missing result is fail-closed: the modem is absent,
    /// still enumerating, or does not currently own a network service.
    func socksProxyNetworkBinding(
        forModuleIMEI moduleIMEI: String
    ) -> SOCKSModuleNetworkBindingSnapshot? {
        guard let module = cellularModules.first(where: { $0.modem.moduleIMEI == moduleIMEI }),
              let serviceID = module.network.serviceID,
              let bsdName = module.network.bsdName else {
            return nil
        }
        return SOCKSModuleNetworkBindingSnapshot(
            moduleID: module.id,
            moduleIMEI: moduleIMEI,
            serviceID: serviceID,
            bsdName: bsdName,
            ipv4Address: module.network.ipv4Address,
            ipv6Address: module.network.ipv6Address,
            dnsServers: module.network.dnsServers
        )
    }

    func probeVoWiFiRuntime(
        for moduleID: CellularModuleID,
        completion: @escaping (Result<VoWiFiRuntimeStatus, Error>) -> Void
    ) {
        withVoWiFiService(moduleID, completion: completion) { service in
            service.probeVoWiFiRuntime(completion: completion)
        }
    }

    func startVoWiFiRuntime(
        _ request: VoWiFiSessionRequest,
        for moduleID: CellularModuleID,
        completion: @escaping (Result<VoWiFiRuntimeStatus, Error>) -> Void
    ) {
        withVoWiFiService(moduleID, completion: completion) { service in
            service.startVoWiFiRuntime(request, completion: completion)
        }
    }

    func stopVoWiFiRuntime(
        for moduleID: CellularModuleID,
        timeout: TimeInterval = 20,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        withVoWiFiService(moduleID, completion: completion) { service in
            service.stopVoWiFiRuntime(timeout: timeout, completion: completion)
        }
    }

    func executeVoWiFiAT(
        _ command: String,
        timeout: Int,
        for moduleID: CellularModuleID,
        completion: @escaping (VoWiFiATResult) -> Void
    ) {
        guard let service = modemService(for: moduleID) else {
            completion(VoWiFiATResult(output: "", error: L10n.tr("模块尚未连接。")))
            return
        }
        service.executeVoWiFiAT(command, timeout: timeout, completion: completion)
    }

    private func withVoWiFiService<Value>(
        _ moduleID: CellularModuleID,
        completion: @escaping (Result<Value, Error>) -> Void,
        body: (ModemService) -> Void
    ) {
        guard cellularModules.contains(where: { $0.id == moduleID }),
              let service = modemService(for: moduleID) else {
            completion(.failure(ModuleVoiceRuntime.RuntimeError.moduleCommand(
                L10n.tr("模块尚未连接。")
            )))
            return
        }
        body(service)
    }

    func isChangingNetworkMode(for moduleID: CellularModuleID) -> Bool {
        pendingCellularNetworkModesByModuleID[moduleID] != nil
    }

    var isRecoveringNetworkLink: Bool {
        recoveringNetworkLinkModuleID != nil
    }

    func isRecoveringNetworkLink(for moduleID: CellularModuleID) -> Bool {
        recoveringNetworkLinkModuleID == moduleID
    }

    func isRetryingCellularLink(for moduleID: CellularModuleID) -> Bool {
        CellularLinkRecoveryPolicy.isRetrying(
            completedAttempts: completedCellularLinkRecoveryAttempts[moduleID] ?? 0,
            hasRestarted: didRestartModuleForCellularRecovery.contains(moduleID)
        )
    }

    var cellularDataConnectionState: CellularDataConnectionState {
        CellularDataConnectionPolicy.state(
            modem: primaryDataModemSnapshot,
            network: network,
            isPresentedEnabled: presentedCellularNetworkingEnabled,
            isChangingNetwork: isChangingNetwork,
            isRecovering: isRecoveringNetworkLink,
            isRetryingLink: primaryDataModuleID
                .map(isRetryingCellularLink(for:)) ?? true
        )
    }

    /// Every physically present modem is published from IOKit. The currently owned
    /// AT session contributes its live SIM/radio snapshot; other devices remain
    /// visible as discovered modules until the session manager activates them.
    var cellularModules: [CellularModuleSummary] {
        if discoveredModemDevices.isEmpty {
            guard modem.state != .disconnected else { return [] }
            let id = CellularModuleID.compatibilityPrimary
            return [
                CellularModuleSummary(
                    id: id,
                    displayName: L10n.tr("模组 %lld", Int64(1)),
                    modem: modem,
                    network: network,
                    cardKind: euicc.cardKind,
                    isActiveSession: true,
                    isPrimaryData: networkMode(for: id) == .preferred
                )
            ]
        }

        return discoveredModemDevices.enumerated().map { index, device in
            let isActive = device.locationID == activeModemLocationID
            let moduleSnapshot = isActive ? modem : (
                auxiliaryModemSnapshots[device.locationID] ?? ModemSnapshot(
                    state: .connected,
                    usbIdentity: device.usbIdentity,
                    usbLocationID: device.locationID,
                    usbRegistryID: device.registryID,
                    usbVendorName: device.usbVendorName,
                    usbProductName: device.usbProductName,
                    hardwareFamily: device.hardwareFamily,
                    simState: .initializing,
                    endpointDescription: "USB location \(device.locationDescription)",
                    lastError: L10n.tr("模组已被 IOKit 发现，正在建立独立 AT 监控会话。")
                )
            )
            let cardKind = isActive
                ? euicc.cardKind
                : (auxiliaryEUICCSnapshots[device.locationID]?.cardKind ?? .unknown)
            return CellularModuleSummary(
                id: device.moduleID,
                displayName: L10n.tr("模组 %lld", Int64(index + 1)),
                modem: moduleSnapshot,
                network: networkStatus(for: device.moduleID),
                cardKind: cardKind,
                isActiveSession: isActive || secondaryModemServices[device.locationID] != nil,
                isPrimaryData: networkMode(for: device.moduleID) == .preferred
            )
        }
    }

    var currentCommunicationModule: CellularModuleSummary? {
        guard let currentCommunicationModuleID else { return nil }
        return cellularModules.first { $0.id == currentCommunicationModuleID }
    }

    var menuBarStatusModule: CellularModuleSummary? {
        let modules = cellularModules
        guard let moduleID = MenuBarStatusModuleSelectionPolicy.resolvedModuleID(
            isCellularNetworkingEnabled: presentedCellularNetworkingEnabled,
            primaryDataModuleID: primaryDataModuleID,
            currentCommunicationModuleID: currentCommunicationModuleID,
            modules: modules
        ) else {
            return nil
        }
        return modules.first { $0.id == moduleID }
    }

    var currentCommunicationModemSnapshot: ModemSnapshot {
        guard let currentCommunicationModuleID else { return modem }
        return moduleSnapshot(for: currentCommunicationModuleID)
    }

    var primaryDataModem: ModemSnapshot {
        primaryDataModemSnapshot
    }

    var activeCallModemSnapshot: ModemSnapshot {
        guard let moduleID = activeCallModuleID ?? call.moduleID else {
            return currentCommunicationModemSnapshot
        }
        return moduleSnapshot(for: moduleID)
    }

    var isSendingMessageOnCurrentModule: Bool {
        let id = communicationModuleID()
        return sendingMessageModuleIDs.contains(id)
    }

    var currentCommunicationModuleHasCall: Bool {
        let id = communicationModuleID()
        return moduleCallSnapshots[id]?.hasCall == true
    }

    func isSendingMessage(via moduleID: CellularModuleID?) -> Bool {
        let id = communicationModuleID(requested: moduleID)
        return sendingMessageModuleIDs.contains(id)
    }

    func moduleHasCall(_ moduleID: CellularModuleID?) -> Bool {
        let id = communicationModuleID(requested: moduleID)
        return moduleCallSnapshots[id]?.hasCall == true
    }

    func moduleCanDial(_ moduleID: CellularModuleID?) -> Bool {
        let id = communicationModuleID(requested: moduleID)
        guard !call.hasCall else { return false }
        return moduleCallSnapshots[id]?.canDial == true
    }

    func moduleIsConnected(_ moduleID: CellularModuleID?) -> Bool {
        let id = communicationModuleID(requested: moduleID)
        return moduleSnapshot(for: id).isConnected
    }

    func communicationModuleSnapshot(_ moduleID: CellularModuleID?) -> ModemSnapshot {
        let id = communicationModuleID(requested: moduleID)
        return moduleSnapshot(for: id)
    }

    func euiccSnapshot(for moduleID: CellularModuleID?) -> EUICCSnapshot {
        let id = moduleID ?? activeCommunicationModuleID
        if id == activeCommunicationModuleID || id == .compatibilityPrimary {
            return euicc
        }
        guard let locationID = locationID(for: id) else { return .empty }
        return auxiliaryEUICCSnapshots[locationID] ?? .empty
    }

    func selectCommunicationModule(_ id: CellularModuleID?) {
        guard let id else {
            currentCommunicationModuleID = nil
            return
        }
        guard let module = cellularModules.first(where: { $0.id == id }),
              module.isCommunicationEligible else {
            presentTransientMessage(L10n.tr("该模组尚不能用于拨号或短信。"), isError: true)
            return
        }
        currentCommunicationModuleID = id
        if activeCallModuleID == nil {
            call = moduleCallSnapshots[id] ?? CallSnapshot(moduleID: id)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        SOCKSSignalSafety.install()
        localCallAPIController.start()
        socksProxyController.start()
        voWiFiController.start()
        modemInventoryService.onDevices = { [weak self] devices in
            guard let self, !AppTerminationCoordinator.shared.isTerminationPending else { return }
            self.discoveredModemDevices = devices
            self.reconcileDiscoveredModuleRoles()
            self.reconcileSecondaryModemServices()
            self.refreshPendingNetworkModuleRestart()
        }
        modemInventoryService.start()
        MainWindowController.shared.configure(appState: self)
        StandaloneFlowWindowController.shared.configure(appState: self)
        CommunicationWindowController.shared.configure(appState: self)
        InitialSetupWindowController.shared.configure(appState: self)
        AppTerminationCoordinator.shared.onTerminationCancelled = { [weak self] in
            guard let self else { return }
            self.modemService.start()
            self.secondaryModemServices.values.forEach { $0.start() }
            self.modemInventoryService.start()
            self.modemInventoryService.refresh()
            self.localCallAPIController.start()
        }
        AppTerminationCoordinator.shared.onTerminationConfirmed = { [weak self] in
            self?.alertSounds.stopAll()
            self?.socksProxyController.stop()
            self?.voWiFiController.stop()
        }
        AppTerminationCoordinator.shared.cleanup = { [weak self] attempt, completion in
            guard let self else {
                completion(true)
                return
            }
            self.localCallAPIController.stop()
            let shutdown = { [weak self] in
                guard attempt.beginShutdown() else { return }
                guard let self else {
                    completion(true)
                    return
                }
                self.networkModuleRestartTask?.cancel()
                self.networkModuleRestartTask = nil
                self.pendingNetworkModuleRestart = nil
                self.modemInventoryService.stop()
                self.shutdownAllModemServices(completion: completion)
            }
            if self.callRecordings.isRecording {
                self.stopCallRecording { shutdown() }
            } else {
                self.callRecordings.performWhenIdle(shutdown)
            }
        }
        messages = messageStore.messages
        if autoDeleteReadVerificationMessages {
            messageStore.fillMissingVerificationReadDates()
            messages = messageStore.messages
            scheduleVerificationAutoDelete()
        }
        if !hasCompletedInitialSetup,
           !messages.isEmpty || UserDefaults.standard.data(forKey: Self.networkServiceRecordKey) != nil {
            recordInitialSetupSuccess()
        }
        NotificationService.shared.configure(
            onAnswerCall: { [weak self] in
                guard let self, self.call.phase == .incoming else { return }
                self.showPhoneWindow()
                self.answerCall()
            },
            onRejectCall: { [weak self] in
                guard let self, self.call.phase == .incoming else { return }
                self.hangUp()
            },
            onOpenCallWindow: { [weak self] in
                self?.showPhoneWindow()
            },
            onOpenMissedCall: { [weak self] callRecordID in
                self?.showPhoneWindow(
                    section: .recents,
                    callRecordID: callRecordID
                )
            },
            onOpenMessage: { [weak self] messageID in
                guard let self else { return }
                if let message = self.messages.first(where: { $0.id == messageID }) {
                    self.showMessagesWindow(messageID: message.id)
                } else {
                    self.showMessagesWindow()
                }
            }
        )
        if isPresentationPrivacyEnabled {
            NotificationService.shared.clearSensitiveNotifications()
        }
        euiccService.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.handleEUICCSnapshot(snapshot, moduleID: self.activeCommunicationModuleID)
        }

        modemService.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            let previousSnapshot = self.modem
            let wasPhysicallyPresent = self.modem.state != .disconnected
            let wasDisconnected = self.modem.state == .disconnected
            if let locationID = snapshot.usbLocationID {
                self.activeModemLocationID = locationID
            }
            self.modem = snapshot
            self.reconcileDiscoveredModuleRoles()
            self.reconcileSecondaryModemServices()
            self.completePendingNetworkModuleRestartIfReady(
                moduleID: self.activeCommunicationModuleID,
                snapshot: snapshot
            )
            self.updateEUICCDetection(for: snapshot)
            if self.primaryDataModuleID == self.activeCommunicationModuleID {
                self.prepareCellularRestore(for: snapshot)
            }
            self.scheduleCellularLinkRecoveryIfNeeded()
            if snapshot.state == .disconnected, wasPhysicallyPresent {
                self.initialSetupWasPresentedForCurrentInsertion = false
            } else if wasDisconnected,
                      snapshot.state != .disconnected,
                      !self.initialSetupPresentationIsActive {
                self.initialSetupWasPresentedForCurrentInsertion = false
            }
            self.updateMenuBarIconVisibility()
            self.handleInitialSetupSnapshot(snapshot)
            if !snapshot.isConnected {
                self.messageStore.invalidateModemReferences(
                    for: self.activeCommunicationModuleID
                )
                self.messages = self.messageStore.messages
            }
            if previousSnapshot.state != snapshot.state ||
                previousSnapshot.usbNetMode != snapshot.usbNetMode ||
                previousSnapshot.usbIdentity != snapshot.usbIdentity {
                self.networkController.refresh()
            }
            self.automaticallyRestoreCellularOnStartupIfNeeded()
            self.automaticallyPrioritizeCellularIfNeeded()
        }
        modemService.onMessages = { [weak self] incoming, isInitialSync in
            guard let self else { return }
            self.handleIncomingMessages(
                incoming,
                moduleID: self.activeCommunicationModuleID,
                isInitialSync: isInitialSync
            )
        }
        modemService.onCallSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.handleCallSnapshot(
                snapshot,
                moduleID: self.activeCommunicationModuleID
            )
        }
        networkController.onStatus = { [weak self] status in
            guard let self else { return }
            self.network = status
            cellularNetworkLogger.info(
                "Status interface=\(status.bsdName ?? "none", privacy: .public) enabled=\(status.isEnabled) active=\(status.isActive) present=\(status.isHardwarePresent) prioritized=\(status.isPrioritized)"
            )
            if let desiredMode = self.cellularRestoreDesiredMode,
               CellularNetworkStartupPolicy.isApplied(desiredMode, to: status) {
                self.startupCellularRestorePending = false
            }
            if self.cellularNetworkMode != .preferred ||
                !status.isEnabled || !status.isHardwarePresent || status.isPrioritized {
                self.lastAutomaticPriorityAttemptServiceID = nil
            }
            if status.isActive || !status.isEnabled || !status.isHardwarePresent {
                self.cancelCellularLinkRecovery(resetAttempts: true)
            } else {
                self.scheduleCellularLinkRecoveryIfNeeded()
            }
            self.automaticallyRestoreCellularOnStartupIfNeeded()
            self.automaticallyPrioritizeCellularIfNeeded()
        }
        networkController.onStatuses = { [weak self] statusesByLocation in
            guard let self else { return }
            var mapped: [CellularModuleID: CellularNetworkStatus] = [:]
            for (locationID, status) in statusesByLocation {
                mapped[self.moduleID(for: locationID)] = status
            }
            self.networkStatusesByModuleID = mapped
            // A module that carries traffic again has earned a clean slate, so a
            // later outage gets the full soft-recovery budget instead of jumping
            // straight to a restart.
            for (moduleID, status) in mapped where status.isActive {
                self.completedCellularLinkRecoveryAttempts[moduleID] = nil
                // Soft recovery is cheap, so its budget resets immediately, but
                // the restart guard only lifts once the module has stayed
                // healthy past the cooldown. Otherwise a module that merely
                // blips active between failures gets power cycled in a loop.
                if CellularLinkRecoveryPolicy.canClearRestartGuard(
                    lastRestart: self.lastCellularModuleRestartAt[moduleID],
                    now: Date()
                ) {
                    self.didRestartModuleForCellularRecovery.remove(moduleID)
                    self.lastCellularModuleRestartAt[moduleID] = nil
                }
            }
            if let selectedID = self.primaryDataModuleID,
               let selectedStatus = mapped[selectedID] {
                self.network = selectedStatus
            }
            self.scheduleCellularLinkRecoveryIfNeeded()
        }

        networkController.startMonitoring()
        modemService.start()

        scheduleInitialSetupPromptIfNeeded()
    }

    func refresh() {
        modemInventoryService.refresh()
        modemService.refresh()
        for service in secondaryModemServices.values { service.refresh() }
        networkController.refresh()
        if modem.simReady {
            if euicc.cardKind == .eUICC {
                euiccService.refresh()
            } else if !euicc.isBusy {
                lastEUICCProbeIdentity = nil
                updateEUICCDetection(for: modem)
            }
        }
        for (locationID, service) in secondaryEUICCServices {
            guard let modemSnapshot = auxiliaryModemSnapshots[locationID],
                  modemSnapshot.simReady else { continue }
            let snapshot = auxiliaryEUICCSnapshots[locationID] ?? .empty
            if snapshot.cardKind == .eUICC, !snapshot.isBusy {
                service.refresh()
            } else if !snapshot.isBusy {
                secondaryEUICCProbeIdentities.removeValue(forKey: locationID)
                updateEUICCDetection(
                    for: modemSnapshot,
                    moduleID: moduleID(for: locationID),
                    locationID: locationID
                )
            }
        }
    }

    private func reconcileDiscoveredModuleRoles() {
        guard let activeModemLocationID,
              let preferredDevice = discoveredModemDevices.first(where: {
                  $0.locationID == activeModemLocationID
              }) else {
            return
        }
        if currentCommunicationModuleID == .compatibilityPrimary {
            currentCommunicationModuleID = preferredDevice.moduleID
        }
        if primaryDataModuleID == .compatibilityPrimary {
            primaryDataModuleID = preferredDevice.moduleID
            networkController.setPreferredLocationID(preferredDevice.locationID)
        } else if let primaryDataModuleID,
                  let selectedDevice = discoveredModemDevices.first(where: {
                      $0.moduleID == primaryDataModuleID
                  }) {
            // Restore only the route explicitly chosen by the user. A missing
            // module is never replaced by another module automatically.
            networkController.setPreferredLocationID(selectedDevice.locationID)
        }
        reconcileCellularNetworkModes()
    }

    private func reconcileCellularNetworkModes() {
        let availableIDs = discoveredModemDevices.map(\.moduleID)
        provisionalNetworkPreferenceModuleIDs.formIntersection(availableIDs)
        networkModeIdentityByModuleID = networkModeIdentityByModuleID.filter {
            availableIDs.contains($0.key)
        }
        var modes = cellularNetworkModesByModuleID.filter { availableIDs.contains($0.key) }
        for device in discoveredModemDevices {
            let identity = cellularNetworkPreferenceIdentity(for: device.moduleID)
            if networkModeIdentityByModuleID[device.moduleID] != identity {
                let storedMode = storedCellularNetworkMode(for: device.moduleID)
                modes[device.moduleID] = storedMode
                    ?? (moduleSnapshot(for: device.moduleID).moduleIMEI == nil
                        ? modes[device.moduleID]
                        : nil)
                    ?? .defaultConnectionMode
                if let imei = moduleSnapshot(for: device.moduleID).moduleIMEI,
                   cellularNetworkingPreferenceStore.preferredMode(forModule: imei) == nil,
                   provisionalNetworkPreferenceModuleIDs.contains(device.moduleID),
                   let storedMode {
                    cellularNetworkingPreferenceStore.setPreferredMode(
                        storedMode,
                        forModule: imei
                    )
                    provisionalNetworkPreferenceModuleIDs.remove(device.moduleID)
                }
                networkModeIdentityByModuleID[device.moduleID] = identity
            } else if modes[device.moduleID] == nil {
                modes[device.moduleID] = .defaultConnectionMode
            }
        }
        modes = CellularNetworkModePlanner.collapsingExtraPreferred(
            modes: modes,
            moduleIDs: availableIDs,
            retaining: primaryDataModuleID
        )
        cellularNetworkModesByModuleID = modes
        let preferred = availableIDs.first { modes[$0] == .preferred }
        let enabledFallback = availableIDs.first { modes[$0]?.isEnabled == true }
        primaryDataModuleID = preferred ?? enabledFallback ?? primaryDataModuleID
        if let primaryDataModuleID, let locationID = locationID(for: primaryDataModuleID) {
            cellularNetworkMode = modes[primaryDataModuleID] ?? .off
            networkController.setPreferredLocationID(locationID)
        }
        let signature = networkConfigurationSignature(
            modes: modes,
            moduleIDs: availableIDs
        )
        let enabledModulesAreReady = cellularModules.allSatisfy {
            modes[$0.id]?.isEnabled != true || $0.isDataEligible
        }
        if !signature.isEmpty,
           signature != lastScheduledNetworkConfigurationSignature,
           enabledModulesAreReady,
           !isChangingNetwork {
            lastScheduledNetworkConfigurationSignature = signature
            DispatchQueue.main.async { [weak self] in
                self?.applyCellularNetworkModes(modes, preparing: nil, force: true)
            }
        }
    }

    private func reconcileSecondaryModemServices() {
        guard let activeModemLocationID else { return }
        let desiredDevices = Dictionary(
            uniqueKeysWithValues: discoveredModemDevices
                .filter { $0.locationID != activeModemLocationID }
                .map { ($0.locationID, $0) }
        )

        for locationID in Array(secondaryModemServices.keys) where desiredDevices[locationID] == nil {
            secondaryEUICCServices.removeValue(forKey: locationID)
            secondaryEUICCProbeIdentities.removeValue(forKey: locationID)
            auxiliaryEUICCSnapshots.removeValue(forKey: locationID)
            if let service = secondaryModemServices.removeValue(forKey: locationID) {
                // Keep the service alive until its queue has closed the C handle and
                // any call-media resources for the detached device.
                service.shutdown { _ in _ = service }
            }
            auxiliaryModemSnapshots.removeValue(forKey: locationID)
            moduleCallSnapshots.removeValue(forKey: moduleID(for: locationID))
        }

        for (locationID, device) in desiredDevices
        where secondaryModemServices[locationID] == nil {
            guard !secondaryModemServiceRebuilds.contains(locationID) else { continue }
            installSecondaryModemService(for: device)
        }
    }

    private func installSecondaryModemService(for device: DiscoveredModemDevice) {
        let service = ModemService(locationID: device.locationID)
        let euiccService = EUICCService(modemService: service)
        euiccService.onSnapshot = { [weak self] snapshot in
            self?.handleEUICCSnapshot(snapshot, moduleID: device.moduleID)
        }
        secondaryEUICCServices[device.locationID] = euiccService
        configureSecondaryModemService(service, device: device)
        secondaryModemServices[device.locationID] = service
        service.start()
    }

    private func shutdownAllModemServices(completion: @escaping (Bool) -> Void) {
        let services = [modemService] + Array(secondaryModemServices.values)
        // Retain the services so a cancelled quit can restart every module after
        // all shutdown callbacks finish, including modules that closed cleanly.
        guard !services.isEmpty else {
            completion(true)
            return
        }
        let group = DispatchGroup()
        var allClean = true
        for service in services {
            group.enter()
            service.shutdown { clean in
                allClean = allClean && clean
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(allClean) }
    }

    private var activeCommunicationModuleID: CellularModuleID {
        activeModemLocationID.map(moduleID(for:)) ?? .compatibilityPrimary
    }

    private func moduleID(for locationID: UInt32) -> CellularModuleID {
        CellularModuleID(rawValue: String(format: "usb-location:%08X", locationID))
    }

    private func locationID(for moduleID: CellularModuleID) -> UInt32? {
        discoveredModemDevices.first(where: { $0.moduleID == moduleID })?.locationID
    }

    private func modemService(for moduleID: CellularModuleID?) -> ModemService? {
        let requestedID = communicationModuleID(requested: moduleID)
        if requestedID == activeCommunicationModuleID || requestedID == .compatibilityPrimary {
            return modemService
        }
        guard let locationID = locationID(for: requestedID) else { return nil }
        return secondaryModemServices[locationID]
    }

    private func moduleSnapshot(for moduleID: CellularModuleID) -> ModemSnapshot {
        if moduleID == activeCommunicationModuleID { return modem }
        guard let locationID = locationID(for: moduleID) else { return ModemSnapshot() }
        return auxiliaryModemSnapshots[locationID] ?? ModemSnapshot()
    }

    private func communicationModuleID(
        requested: CellularModuleID? = nil
    ) -> CellularModuleID {
        CommunicationModuleRoutingPolicy.resolvedModuleID(
            requested: requested,
            current: currentCommunicationModuleID,
            fallback: activeCommunicationModuleID
        )
    }

    private var primaryDataModemSnapshot: ModemSnapshot {
        guard let primaryDataModuleID else { return modem }
        return moduleSnapshot(for: primaryDataModuleID)
    }

    private var primaryDataModemService: ModemService {
        modemService(for: primaryDataModuleID) ?? modemService
    }

    private func configureSecondaryModemService(
        _ service: ModemService,
        device: DiscoveredModemDevice
    ) {
        let id = device.moduleID
        service.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.auxiliaryModemSnapshots[device.locationID] = snapshot
            self.reconcileCellularNetworkModes()
            self.completePendingNetworkModuleRestartIfReady(
                moduleID: id,
                snapshot: snapshot
            )
            self.updateEUICCDetection(
                for: snapshot,
                moduleID: id,
                locationID: device.locationID
            )
            if self.primaryDataModuleID == id {
                self.prepareCellularRestore(for: snapshot)
                self.scheduleCellularLinkRecoveryIfNeeded()
            }
            if !snapshot.isConnected {
                self.messageStore.invalidateModemReferences(for: id)
                self.messages = self.messageStore.messages
            }
        }
        service.onMessages = { [weak self] incoming, isInitialSync in
            self?.handleIncomingMessages(
                incoming,
                moduleID: id,
                isInitialSync: isInitialSync
            )
        }
        service.onCallSnapshot = { [weak self] snapshot in
            self?.handleCallSnapshot(snapshot, moduleID: id)
        }
    }

    private func handleIncomingMessages(
        _ incoming: [SMSMessage],
        moduleID: CellularModuleID,
        isInitialSync: Bool
    ) {
        let taggedMessages = incoming.map { message in
            var tagged = message
            tagged.assignModule(moduleID)
            return tagged
        }
        let newMessages = messageStore.merge(taggedMessages)
        if autoDeleteReadVerificationMessages {
            messageStore.fillMissingVerificationReadDates()
        }
        let updatedMessages = messageStore.messages
        if messages != updatedMessages {
            messages = updatedMessages
            scheduleVerificationAutoDelete()
        }
        guard !isInitialSync else { return }
        for message in newMessages {
            alertSounds.playMessageAlert()
            NotificationService.shared.postNewMessage(
                message,
                displayName: SystemContactStore.shared.displayName(for: message.sender),
                presentation: privacyPresentation
            )
            if !message.isOutgoing {
                SMSForwardingService.shared.forward(message)
            }
        }
    }

    private func handleCallSnapshot(
        _ snapshot: CallSnapshot,
        moduleID: CellularModuleID
    ) {
        var taggedSnapshot = snapshot
        taggedSnapshot.moduleID = moduleID
        let previousModuleCall = moduleCallSnapshots[moduleID] ?? CallSnapshot(moduleID: moduleID)
        moduleCallSnapshots[moduleID] = taggedSnapshot
        let completedCall = callHistory.consume(
            previous: previousModuleCall,
            current: taggedSnapshot
        )

        if taggedSnapshot.hasCall {
            if let activeCallModuleID, activeCallModuleID != moduleID {
                return
            }
            activeCallModuleID = moduleID
        } else {
            if let activeCallModuleID, activeCallModuleID != moduleID {
                if let completedCall, completedCall.isMissed {
                    NotificationService.shared.postMissedCall(
                        completedCall,
                        displayName: SystemContactStore.shared.displayName(for: completedCall.number),
                        presentation: privacyPresentation
                    )
                }
                return
            }
            if activeCallModuleID == nil, currentCommunicationModuleID != moduleID {
                if let completedCall, completedCall.isMissed {
                    NotificationService.shared.postMissedCall(
                        completedCall,
                        displayName: SystemContactStore.shared.displayName(for: completedCall.number),
                        presentation: privacyPresentation
                    )
                }
                return
            }
        }

        let previousCall = call
        let shouldNotify = taggedSnapshot.phase == .incoming &&
            (previousCall.phase != .incoming || previousCall.number != taggedSnapshot.number)
        call = taggedSnapshot
        CommunicationWindowController.shared.callDidChange(
            previousHadCall: previousCall.hasCall
        )
        if previousCall.hasCall, !taggedSnapshot.hasCall, callRecordings.isRecording {
            stopCallRecording()
        }
        if taggedSnapshot.hasCall {
            startAutomaticCallRecordingIfNeeded()
        } else {
            automaticRecordingAttemptedCallID = nil
            activeCallModuleID = nil
        }
        scheduleCellularLinkRecoveryIfNeeded()

        if CallTonePolicy.wantsOutgoingRingback(for: taggedSnapshot) {
            alertSounds.startOutgoingRingback()
        } else {
            alertSounds.stopOutgoingRingback()
        }
        if CallTonePolicy.wantsHangupTone(for: completedCall) {
            alertSounds.playHangupTone()
        }

        if taggedSnapshot.phase == .incoming {
            if shouldNotify {
                alertSounds.startIncomingRingtone()
                if !CommunicationWindowController.shared.isPresentingCallUI {
                    NotificationService.shared.postIncomingCall(
                        number: taggedSnapshot.number,
                        displayName: taggedSnapshot.number.flatMap {
                            SystemContactStore.shared.displayName(for: $0)
                        },
                        presentation: privacyPresentation
                    )
                }
            }
            return
        }

        alertSounds.stopIncomingRingtone()
        NotificationService.shared.clearIncomingCall()
        if let completedCall, completedCall.isMissed {
            NotificationService.shared.postMissedCall(
                completedCall,
                displayName: SystemContactStore.shared.displayName(for: completedCall.number),
                presentation: privacyPresentation
            )
        }

        if !taggedSnapshot.hasCall,
           let pending = moduleCallSnapshots.first(where: { $0.value.hasCall }) {
            handleCallSnapshot(pending.value, moduleID: pending.key)
        }
    }

    func refreshEUICC(moduleID: CellularModuleID? = nil) {
        let id = moduleID ?? activeCommunicationModuleID
        let snapshot = euiccSnapshot(for: id)
        guard snapshot.cardKind == .eUICC,
              !snapshot.isBusy,
              let service = euiccServiceForModule(id) else { return }
        dismissTransientMessage()
        service.refresh()
    }

    func enableESIMProfile(_ profile: ESIMProfile, moduleID: CellularModuleID? = nil) {
        let id = moduleID ?? activeCommunicationModuleID
        let snapshot = euiccSnapshot(for: id)
        guard snapshot.cardKind == .eUICC,
              !snapshot.isBusy,
              let service = euiccServiceForModule(id) else { return }
        dismissTransientMessage()
        service.enable(profile: profile)
    }

    func disableESIMProfile(_ profile: ESIMProfile, moduleID: CellularModuleID? = nil) {
        let id = moduleID ?? activeCommunicationModuleID
        let snapshot = euiccSnapshot(for: id)
        guard snapshot.cardKind == .eUICC,
              !snapshot.isBusy,
              let service = euiccServiceForModule(id) else { return }
        dismissTransientMessage()
        service.disable(profile: profile)
    }

    func deleteESIMProfile(_ profile: ESIMProfile, moduleID: CellularModuleID? = nil) {
        let id = moduleID ?? activeCommunicationModuleID
        let snapshot = euiccSnapshot(for: id)
        guard snapshot.cardKind == .eUICC,
              !snapshot.isBusy,
              let service = euiccServiceForModule(id) else { return }
        dismissTransientMessage()
        service.delete(profile: profile)
    }

    func renameESIMProfile(
        _ profile: ESIMProfile,
        nickname: String,
        moduleID: CellularModuleID? = nil
    ) {
        let normalized = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = moduleID ?? activeCommunicationModuleID
        let snapshot = euiccSnapshot(for: id)
        guard snapshot.cardKind == .eUICC,
              !snapshot.isBusy,
              let service = euiccServiceForModule(id) else { return }
        guard !normalized.isEmpty, normalized.count <= 64 else {
            presentTransientMessage(L10n.tr("eSIM 名称应为 1–64 个字符。"), isError: true)
            return
        }
        dismissTransientMessage()
        service.rename(profile: profile, nickname: normalized)
    }

    func downloadESIMProfile(
        activationCode rawCode: String,
        confirmationCode: String?,
        moduleID: CellularModuleID? = nil
    ) {
        let id = moduleID ?? activeCommunicationModuleID
        let snapshot = euiccSnapshot(for: id)
        guard snapshot.cardKind == .eUICC,
              !snapshot.isBusy,
              let service = euiccServiceForModule(id) else { return }
        do {
            let activationCode = try ESIMActivationCode(rawValue: rawCode)
            let confirmation = confirmationCode?.trimmingCharacters(in: .whitespacesAndNewlines)
            if activationCode.confirmationCodeRequired, confirmation?.isEmpty != false {
                presentTransientMessage(L10n.tr("此激活码需要运营商提供的确认码。"), isError: true)
                return
            }
            dismissTransientMessage()
            service.download(
                activationCode: activationCode,
                confirmationCode: confirmation,
                imei: moduleSnapshot(for: id).moduleIMEI
            )
        } catch {
            presentTransientMessage(error.localizedDescription, isError: true)
        }
    }

    private func updateEUICCDetection(
        for snapshot: ModemSnapshot,
        moduleID: CellularModuleID? = nil,
        locationID: UInt32? = nil
    ) {
        let id = moduleID ?? activeCommunicationModuleID
        let isPrimary = id == activeCommunicationModuleID || id == .compatibilityPrimary
        guard let service = euiccServiceForModule(id) else { return }
        guard snapshot.simReady else {
            if isPrimary {
                lastEUICCProbeIdentity = nil
            } else if let locationID {
                secondaryEUICCProbeIdentities.removeValue(forKey: locationID)
            }
            service.reset()
            return
        }
        let identity = snapshot.simICCID ?? "ready:\(snapshot.moduleIMEI ?? snapshot.usbIdentity ?? "module")"
        let previousIdentity = isPrimary
            ? lastEUICCProbeIdentity
            : locationID.flatMap { secondaryEUICCProbeIdentities[$0] }
        guard identity != previousIdentity, !euiccSnapshot(for: id).isBusy else { return }
        if isPrimary {
            lastEUICCProbeIdentity = identity
        } else if let locationID {
            secondaryEUICCProbeIdentities[locationID] = identity
        }
        service.detect()
    }

    private func euiccServiceForModule(_ moduleID: CellularModuleID) -> EUICCService? {
        if moduleID == activeCommunicationModuleID || moduleID == .compatibilityPrimary {
            return euiccService
        }
        guard let locationID = locationID(for: moduleID) else { return nil }
        return secondaryEUICCServices[locationID]
    }

    private func handleEUICCSnapshot(
        _ snapshot: EUICCSnapshot,
        moduleID: CellularModuleID
    ) {
        let previousOperation = euiccSnapshot(for: moduleID).operation
        if moduleID == activeCommunicationModuleID || moduleID == .compatibilityPrimary {
            euicc = snapshot
        } else if let locationID = locationID(for: moduleID) {
            auxiliaryEUICCSnapshots[locationID] = snapshot
        }
        guard previousOperation.isBusy, !snapshot.operation.isBusy else { return }
        if let error = snapshot.lastError {
            if previousOperation != .detecting || snapshot.cardKind == .failed {
                presentTransientMessage(error, isError: true)
            }
            return
        }
        switch previousOperation {
        case .downloading: presentTransientMessage(L10n.tr("eSIM 套餐已下载。"))
        case .enabling: presentTransientMessage(L10n.tr("eSIM 套餐已启用。"))
        case .disabling: presentTransientMessage(L10n.tr("eSIM 套餐已停用。"))
        case .deleting: presentTransientMessage(L10n.tr("eSIM 套餐已删除。"))
        case .renaming: presentTransientMessage(L10n.tr("eSIM 套餐名称已更新。"))
        case .idle, .detecting, .refreshing: break
        }
    }

    func retryCallInitialization() {
        guard !isChangingCall else { return }
        let moduleID = activeCallModuleID ?? currentCommunicationModuleID
        guard let service = modemService(for: moduleID) else {
            presentTransientMessage(L10n.tr("所选通信模组尚未就绪。"), isError: true)
            return
        }
        isChangingCall = true
        dismissTransientMessage()
        service.retryCallInitialization { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
        }
    }

    func forceReleaseCallControlInterface() {
        guard !isChangingCall, call.controlInterfaceBusy else { return }
        let moduleID = activeCallModuleID ?? call.moduleID ?? currentCommunicationModuleID
        guard let service = modemService(for: moduleID) else {
            presentTransientMessage(L10n.tr("通话模组已断开。"), isError: true)
            return
        }
        isChangingCall = true
        dismissTransientMessage()
        service.forceReleaseCallControlInterface { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
        }
    }

    func setCellularNetworkMode(
        _ mode: CellularNetworkMode,
        for moduleID: CellularModuleID,
        replacingPreviousPreferredWith replacementMode: CellularNetworkMode? = nil
    ) {
        guard !isChangingNetwork else {
            presentTransientMessage(
                L10n.tr("正在应用另一项蜂窝网络更改，请稍后重试。"),
                isError: true
            )
            return
        }
        let outcome = CellularNetworkModePlanner.plan(
            setting: mode,
            for: moduleID,
            moduleIDs: cellularModules.map(\.id),
            currentModes: CellularNetworkModePlanner.normalizedModes(
                moduleIDs: cellularModules.map(\.id),
                currentModes: cellularNetworkModesByModuleID,
                fallback: { self.networkMode(for: $0) }
            ),
            replacingPreviousPreferredWith: replacementMode
        )
        switch outcome {
        case .unknownModule:
            return
        case .needsPreferredConflictResolution:
            presentTransientMessage(
                L10n.tr("请先确认如何处理当前蜂窝优先模组。"),
                isError: true
            )
        case let .apply(updatedModes):
            applyCellularNetworkModes(updatedModes, preparing: mode.isEnabled ? moduleID : nil)
        }
    }

    func closeAllCellularNetworks() {
        applyCellularNetworkModes(
            CellularNetworkModePlanner.turningEverythingOff(
                moduleIDs: cellularModules.map(\.id),
                currentModes: cellularNetworkModesByModuleID
            ),
            preparing: nil
        )
    }

    func reapplyCellularNetworkPriorities() {
        let modes = Dictionary(uniqueKeysWithValues: cellularModules.map {
            ($0.id, networkMode(for: $0.id))
        })
        applyCellularNetworkModes(modes, preparing: nil, force: true)
    }

    private func applyCellularNetworkModes(
        _ updatedModes: [CellularModuleID: CellularNetworkMode],
        preparing moduleIDToPrepare: CellularModuleID?,
        force: Bool = false
    ) {
        guard !isChangingNetwork else { return }
        let changedModes = updatedModes.filter { networkMode(for: $0.key) != $0.value }
        guard force || !changedModes.isEmpty else { return }
        if let moduleIDToPrepare,
           updatedModes[moduleIDToPrepare]?.isEnabled == true,
           cellularModules.first(where: { $0.id == moduleIDToPrepare })?.isDataEligible != true {
            presentTransientMessage(L10n.tr("ECM 接口尚未就绪，不能启用蜂窝网络。"), isError: true)
            return
        }
        guard let request = networkConfigurationRequest(for: updatedModes) else {
            presentTransientMessage(L10n.tr("无法建立多模组蜂窝网络配置。"), isError: true)
            return
        }

        startupCellularRestorePending = false
        isChangingNetwork = true
        pendingCellularNetworkModesByModuleID = force ? updatedModes : changedModes
        if let primaryDataModuleID {
            pendingCellularNetworkMode = changedModes[primaryDataModuleID]
        }
        cancelCellularLinkRecovery(resetAttempts: true)
        dismissTransientMessage()

        let apply = { [weak self] in
            guard let self else { return }
            self.networkController.applyConfiguration(request) { [weak self] result in
                guard let self else { return }
                self.isChangingNetwork = false
                self.pendingCellularNetworkModesByModuleID.removeAll()
                self.pendingCellularNetworkMode = nil
                self.logNetworkActionResult(result.displayResult, action: "multi-module-config")
                // A DHCP-stage failure still means the helper committed the new
                // service order, so the requested modes have to be persisted or
                // the UI would drift away from the live system configuration.
                let configurationWasApplied = result.failureReason?.configurationWasApplied ?? true
                if configurationWasApplied {
                    self.cellularNetworkModesByModuleID = updatedModes
                    self.lastScheduledNetworkConfigurationSignature =
                        self.networkConfigurationSignature(
                            modes: updatedModes,
                            moduleIDs: self.cellularModules.map(\.id)
                        )
                    for module in self.cellularModules {
                        guard let mode = updatedModes[module.id] else { continue }
                        self.saveCellularNetworkMode(mode, for: module.id)
                    }
                    let preferredID = self.cellularModules.first {
                        updatedModes[$0.id] == .preferred
                    }?.id
                    let fallbackID = self.cellularModules.first {
                        updatedModes[$0.id]?.isEnabled == true
                    }?.id
                    self.primaryDataModuleID = preferredID ?? fallbackID
                    if let selectedID = self.primaryDataModuleID,
                       let locationID = self.locationID(for: selectedID) {
                        self.cellularNetworkMode = updatedModes[selectedID] ?? .off
                        self.cellularRestoreDesiredMode = self.cellularNetworkMode
                        self.cellularRestoreModuleIdentity = self.moduleSnapshot(
                            for: selectedID
                        ).moduleIMEI
                        self.networkController.setPreferredLocationID(locationID)
                        UserDefaults.standard.set(
                            selectedID.rawValue,
                            forKey: Self.selectedInternetModuleKey
                        )
                    } else {
                        self.cellularNetworkMode = .off
                        self.cellularRestoreDesiredMode = .off
                        self.networkController.setPreferredLocationID(nil)
                        UserDefaults.standard.removeObject(forKey: Self.selectedInternetModuleKey)
                    }
                }
                self.show(result.displayResult)
                self.networkController.refresh()
                self.scheduleCellularLinkRecoveryIfNeeded()
            }
        }

        if let moduleIDToPrepare,
           CellularLinkRecoveryPolicy.needsLinkPreparation(
               networkStatus(for: moduleIDToPrepare)
           ),
           let service = modemService(for: moduleIDToPrepare) {
            presentTransientMessage(L10n.tr("正在准备目标模组的 ECM 链路…"))
            service.recoverCellularNetworkLink { [weak self] result in
                self?.logNetworkActionResult(result, action: "multi-module-ecm-prepare")
                apply()
            }
        } else {
            apply()
        }
    }

    private func networkConfigurationRequest(
        for modes: [CellularModuleID: CellularNetworkMode]
    ) -> CellularNetworkConfigurationRequest? {
        var preferredLocationID: UInt32?
        var standbyLocationIDs: [UInt32] = []
        var offLocationIDs: [UInt32] = []
        for module in cellularModules {
            guard let locationID = locationID(for: module.id) else { continue }
            switch modes[module.id] ?? .off {
            case .preferred:
                guard preferredLocationID == nil else { return nil }
                preferredLocationID = locationID
            case .standby:
                standbyLocationIDs.append(locationID)
            case .off:
                offLocationIDs.append(locationID)
            }
        }
        return CellularNetworkConfigurationRequest(
            preferredLocationID: preferredLocationID,
            standbyLocationIDs: standbyLocationIDs,
            offLocationIDs: offLocationIDs
        )
    }

    private func networkConfigurationSignature(
        modes: [CellularModuleID: CellularNetworkMode],
        moduleIDs: [CellularModuleID]
    ) -> String {
        moduleIDs.map {
            "\($0.rawValue):\(modes[$0]?.rawValue ?? CellularNetworkMode.off.rawValue)"
        }.joined(separator: "|")
    }

    private func cellularNetworkPreferenceIdentity(
        for moduleID: CellularModuleID
    ) -> String {
        moduleSnapshot(for: moduleID).moduleIMEI ?? "usb:\(moduleID.rawValue)"
    }

    private func storedCellularNetworkMode(
        for moduleID: CellularModuleID
    ) -> CellularNetworkMode? {
        let fallbackIdentity = "usb:\(moduleID.rawValue)"
        let fallbackMode = cellularNetworkingPreferenceStore.preferredMode(
            forModule: fallbackIdentity
        )
        guard let imei = moduleSnapshot(for: moduleID).moduleIMEI else {
            return fallbackMode
        }
        if let imeiMode = cellularNetworkingPreferenceStore.preferredMode(forModule: imei) {
            return imeiMode
        }
        return provisionalNetworkPreferenceModuleIDs.contains(moduleID) ? fallbackMode : nil
    }

    private func saveCellularNetworkMode(
        _ mode: CellularNetworkMode,
        for moduleID: CellularModuleID
    ) {
        cellularNetworkingPreferenceStore.setPreferredMode(
            mode,
            forModule: "usb:\(moduleID.rawValue)"
        )
        if let imei = moduleSnapshot(for: moduleID).moduleIMEI {
            cellularNetworkingPreferenceStore.setPreferredMode(mode, forModule: imei)
            provisionalNetworkPreferenceModuleIDs.remove(moduleID)
        } else {
            provisionalNetworkPreferenceModuleIDs.insert(moduleID)
        }
    }

    private func applyCurrentCellularNetworkConfiguration(
        completion: @escaping (CellularNetworkActionResult) -> Void
    ) {
        let modes = Dictionary(uniqueKeysWithValues: cellularModules.map {
            ($0.id, networkMode(for: $0.id))
        })
        guard let request = networkConfigurationRequest(for: modes) else {
            completion(.failure(L10n.tr("无法建立多模组蜂窝网络配置。"), reason: .other))
            return
        }
        networkController.applyConfiguration(request, completion: completion)
    }

    private func automaticallyRestoreCellularOnStartupIfNeeded() {
        guard discoveredModemDevices.isEmpty else { return }
        guard CellularNetworkStartupPolicy.shouldRestore(
            network: network,
            modem: primaryDataModemSnapshot,
            isChangingNetwork: isChangingNetwork,
            restorePending: startupCellularRestorePending,
            restoreInFlight: startupCellularRestoreInFlight,
            desiredMode: cellularRestoreDesiredMode
        ) else {
            return
        }
        guard let desiredMode = cellularRestoreDesiredMode else { return }
        startupCellularRestorePending = false
        startupCellularRestoreInFlight = true
        isChangingNetwork = true
        cellularNetworkLogger.notice(
            "Restoring persisted cellular mode=\(desiredMode.rawValue) interface=\(self.network.bsdName ?? "unknown", privacy: .public)"
        )
        applyCurrentCellularNetworkConfiguration { [weak self] result in
            guard let self else { return }
            self.startupCellularRestoreInFlight = false
            self.isChangingNetwork = false
            self.logNetworkActionResult(result.displayResult, action: "startup-restore")
            if self.recoverNetworkFailureImmediatelyIfNeeded(
                result,
                source: "startup-restore"
            ) {
                return
            }
            switch result {
            case .success:
                self.networkController.refresh()
            case let .failure(message, _):
                self.presentTransientMessage(
                    L10n.tr("无法恢复该模块的蜂窝联网状态：%@", message),
                    isError: true
                )
            }
            self.scheduleCellularLinkRecoveryIfNeeded()
        }
    }

    private func prepareCellularRestore(for snapshot: ModemSnapshot) {
        guard snapshot.isConnected, let moduleIdentity = snapshot.moduleIMEI else {
            if snapshot.state == .disconnected {
                cellularRestoreModuleIdentity = nil
                cellularRestoreDesiredMode = nil
                cellularNetworkMode = .off
                startupCellularRestorePending = false
            }
            return
        }
        guard cellularRestoreModuleIdentity != moduleIdentity else { return }
        cellularRestoreModuleIdentity = moduleIdentity
        cellularRestoreDesiredMode = cellularNetworkingPreferenceStore.preferredMode(
            forModule: moduleIdentity
        ) ?? .defaultConnectionMode
        cellularNetworkMode = cellularRestoreDesiredMode ?? .off
        startupCellularRestorePending = true
        startupCellularRestoreInFlight = false
    }

    private func automaticallyPrioritizeCellularIfNeeded() {
        guard cellularNetworkMode == .preferred,
              !automaticPriorityInFlight,
              CellularNetworkPriorityPolicy.shouldAutoPromote(
                  network: network,
                  modem: primaryDataModemSnapshot,
                  desiredMode: cellularNetworkMode,
                  isChangingNetwork: isChangingNetwork,
                  attemptedServiceID: lastAutomaticPriorityAttemptServiceID
              ),
              let serviceID = network.serviceID else {
            return
        }
        automaticPriorityInFlight = true
        lastAutomaticPriorityAttemptServiceID = serviceID
        isChangingNetwork = true
        applyCurrentCellularNetworkConfiguration { [weak self] result in
            guard let self else { return }
            self.automaticPriorityInFlight = false
            self.isChangingNetwork = false
            if self.recoverNetworkFailureImmediatelyIfNeeded(
                result,
                source: "automatic-priority"
            ) {
                return
            }
            switch result {
            case .success:
                self.networkController.refresh()
            case let .failure(message, _):
                self.presentTransientMessage(
                    L10n.tr("无法自动将蜂窝网络设为最高优先级：%@", message),
                    isError: true
                )
            }
        }
    }

    /// Picks the next module whose link needs repairing. The preferred module
    /// wins when several qualify, because it carries the default route.
    private func cellularLinkRecoveryCandidate() -> CellularModuleID? {
        let candidates = cellularModules.map(\.id).filter { moduleID in
            CellularLinkRecoveryPolicy.shouldAttempt(
                network: networkStatus(for: moduleID),
                modem: moduleSnapshot(for: moduleID),
                desiredMode: networkMode(for: moduleID),
                hasCall: call.hasCall,
                isChangingNetwork: isChangingNetwork,
                isInFlight: cellularLinkRecoveryInFlight,
                completedAttempts: completedCellularLinkRecoveryAttempts[moduleID] ?? 0
            )
        }
        return candidates.first { networkMode(for: $0) == .preferred } ?? candidates.first
    }

    private func scheduleCellularLinkRecoveryIfNeeded() {
        guard cellularLinkRecoveryTask == nil,
              let moduleID = cellularLinkRecoveryCandidate() else {
            return
        }
        let delay = CellularLinkRecoveryPolicy.delayNanoseconds(
            completedAttempts: completedCellularLinkRecoveryAttempts[moduleID] ?? 0
        )
        let generation = cellularLinkRecoveryGeneration
        cellularLinkRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, self.cellularLinkRecoveryGeneration == generation else { return }
            self.cellularLinkRecoveryTask = nil
            self.networkController.refresh()
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard self.cellularLinkRecoveryGeneration == generation,
                  self.cellularLinkRecoveryCandidate() == moduleID else {
                return
            }
            self.performCellularLinkRecovery(generation: generation, moduleID: moduleID)
        }
    }

    private func performCellularLinkRecovery(
        generation: UInt64,
        moduleID: CellularModuleID
    ) {
        guard cellularLinkRecoveryGeneration == generation,
              !cellularLinkRecoveryInFlight,
              let service = modemService(for: moduleID) else { return }
        cellularLinkRecoveryInFlight = true
        cellularRecoveryOwnsNetworkChange = true
        isChangingNetwork = true
        recoveringNetworkLinkModuleID = moduleID
        let attempt = (completedCellularLinkRecoveryAttempts[moduleID] ?? 0) + 1
        completedCellularLinkRecoveryAttempts[moduleID] = attempt
        cellularNetworkLogger.notice(
            """
            Starting cellular soft recovery \
            module=\(moduleID.rawValue, privacy: .public) attempt=\(attempt)
            """
        )
        service.recoverCellularNetworkLink { [weak self] result in
            guard let self, self.cellularLinkRecoveryGeneration == generation else { return }
            switch result {
            case .success:
                cellularNetworkLogger.info("Module ECM bridge recovery succeeded")
                self.applyCurrentCellularNetworkConfiguration { [weak self] dhcpResult in
                    guard let self,
                          self.cellularLinkRecoveryGeneration == generation else { return }
                    self.logNetworkActionResult(
                        dhcpResult.displayResult,
                        action: "recovery-dhcp"
                    )
                    switch dhcpResult {
                    case .success:
                        self.verifyCellularLinkRecovery(
                            generation: generation,
                            moduleID: moduleID
                        )
                    case let .failure(message, reason):
                        self.finishRecoveryOperation()
                        self.recoveringNetworkLinkModuleID = nil
                        if self.recoverNetworkFailureImmediatelyIfNeeded(
                            dhcpResult,
                            source: "recovery-dhcp",
                            moduleID: moduleID
                        ) {
                            return
                        }
                        self.finishCellularLinkRecoveryAttempt(
                            moduleID: moduleID,
                            error: reason == .linkInactive
                                ? L10n.tr("模块内部链路已就绪，但 ECM 载波尚未恢复：%@", message)
                                : L10n.tr("模块链路已恢复，但 macOS DHCP 刷新失败：%@", message)
                        )
                    }
                }
            case let .failure(message):
                cellularNetworkLogger.error(
                    "Module ECM bridge recovery failed: \(message, privacy: .public)"
                )
                self.finishRecoveryOperation()
                self.recoveringNetworkLinkModuleID = nil
                self.finishCellularLinkRecoveryAttempt(moduleID: moduleID, error: message)
            }
        }
    }

    private func verifyCellularLinkRecovery(
        generation: UInt64,
        moduleID: CellularModuleID
    ) {
        cellularLinkRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                return
            }
            guard let self, self.cellularLinkRecoveryGeneration == generation else { return }
            self.networkController.refresh()
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard self.cellularLinkRecoveryGeneration == generation else { return }
            self.cellularLinkRecoveryTask = nil
            self.finishRecoveryOperation()
            self.recoveringNetworkLinkModuleID = nil
            if self.networkStatus(for: moduleID).isActive {
                cellularNetworkLogger.notice(
                    "Cellular recovery verified active module=\(moduleID.rawValue, privacy: .public)"
                )
                // Another module may still be waiting for its turn.
                self.scheduleCellularLinkRecoveryIfNeeded()
            } else {
                cellularNetworkLogger.error("Cellular recovery did not produce an active lease")
                self.finishCellularLinkRecoveryAttempt(moduleID: moduleID)
            }
        }
    }

    @discardableResult
    private func recoverNetworkFailureImmediatelyIfNeeded(
        _ result: CellularNetworkActionResult,
        source: String,
        moduleID: CellularModuleID? = nil
    ) -> Bool {
        guard let reason = result.failureReason else { return false }
        let targetModuleID = moduleID
            ?? primaryDataModuleID
            ?? activeCommunicationModuleID
        // Returning false hands the failure back to the soft-recovery ladder,
        // which retries with backoff and only then considers a restart.
        guard CellularLinkRecoveryPolicy.shouldEscalateToRestart(
            reason: reason,
            completedAttempts: completedCellularLinkRecoveryAttempts[targetModuleID] ?? 0
        ) else {
            return false
        }

        let isDHCPTimeout = reason == .dhcpTimeout

        if didRestartModuleForCellularRecovery.contains(targetModuleID) {
            presentTransientMessage(
                isDHCPTimeout
                    ? L10n.tr("DHCP 在一次自动重启后仍然超时，请拔下模块后重新插入。")
                    : L10n.tr("ECM 链路在一次自动重启后仍未激活，请拔下模块后重新插入。"),
                isError: true
            )
            return true
        }
        guard !call.hasCall else {
            presentTransientMessage(
                isDHCPTimeout
                    ? L10n.tr("DHCP 等待超时；通话期间不会自动重启模组，请在通话结束后重试。")
                    : L10n.tr("ECM 链路未激活；通话期间不会自动重启模组，请在通话结束后重试。"),
                isError: true
            )
            return true
        }

        cancelCellularLinkRecovery(resetAttempts: false)
        let logMessage = isDHCPTimeout
            ? "DHCP timed out source=\(source); restarting the target modem once"
            : "ECM link remained inactive source=\(source); restarting the target modem once"
        cellularNetworkLogger.notice("\(logMessage, privacy: .public)")
        presentTransientMessage(
            isDHCPTimeout
                ? L10n.tr("DHCP 等待超时，正在重启目标模组并重新枚举网络接口。")
                : L10n.tr("ECM 链路未激活，正在重启目标模组并重新枚举网络接口。")
        )
        restartModuleForCellularRecovery(
            moduleID: targetModuleID,
            logMessage: logMessage,
            successMessage: isDHCPTimeout
                ? L10n.tr("DHCP 等待超时，已自动重启目标模组并等待网络接口重新枚举。")
                : L10n.tr("ECM 链路未激活，已自动重启目标模组并等待网络接口重新枚举。")
        )
        return true
    }

    private func finishCellularLinkRecoveryAttempt(
        moduleID: CellularModuleID,
        error: String? = nil
    ) {
        let attempts = completedCellularLinkRecoveryAttempts[moduleID] ?? 0
        if attempts >= CellularLinkRecoveryPolicy.maximumAttempts {
            if CellularLinkRecoveryPolicy.shouldRestartModule(
                network: networkStatus(for: moduleID),
                modem: moduleSnapshot(for: moduleID),
                desiredMode: networkMode(for: moduleID),
                hasCall: call.hasCall,
                completedAttempts: attempts,
                alreadyRestarted: didRestartModuleForCellularRecovery.contains(moduleID)
            ) {
                restartModuleForCellularRecovery(moduleID: moduleID)
                return
            }
            let finalMessage: String
            if call.hasCall {
                finalMessage = error ?? L10n.tr("模块网络软恢复失败；通话期间未自动重启模块。")
            } else if didRestartModuleForCellularRecovery.contains(moduleID) {
                finalMessage = error ?? L10n.tr("模块网络链路在软恢复和一次自动重启后仍不可用，请拔下模块后重新插入。")
            } else {
                finalMessage = error ?? L10n.tr("模块网络软恢复失败，当前无法安全自动重启模块。")
            }
            presentTransientMessage(
                finalMessage,
                isError: true
            )
            return
        }
        scheduleCellularLinkRecoveryIfNeeded()
    }

    private func restartModuleForCellularRecovery(
        moduleID: CellularModuleID? = nil,
        logMessage: String = "Soft recovery exhausted; restarting the modem once",
        successMessage: String = L10n.tr("软恢复未成功，已自动重启模组并等待 ECM 重新枚举。")
    ) {
        let targetModuleID = moduleID ?? primaryDataModuleID ?? activeCommunicationModuleID
        let targetLocationID = locationID(for: targetModuleID) ?? (
            targetModuleID == activeCommunicationModuleID ? activeModemLocationID : nil
        )
        guard let targetLocationID,
              let targetService = modemService(for: targetModuleID) else {
            recoveringNetworkLinkModuleID = nil
            presentTransientMessage(
                L10n.tr("目标模组的 AT 服务已断开，无法执行自动重启。"),
                isError: true
            )
            return
        }

        didRestartModuleForCellularRecovery.insert(targetModuleID)
        lastCellularModuleRestartAt[targetModuleID] = Date()
        recoveringNetworkLinkModuleID = targetModuleID
        cellularNetworkLogger.notice("\(logMessage, privacy: .public)")
        targetService.restartForCellularNetworkRecovery { [weak self] result in
            guard let self else { return }
            self.logNetworkActionResult(result, action: "module-restart")
            switch result {
            case .success:
                self.beginNetworkModuleRestartMonitoring(
                    moduleID: targetModuleID,
                    locationID: targetLocationID
                )
                self.presentTransientMessage(
                    successMessage,
                    isError: false
                )
            case let .failure(message):
                self.recoveringNetworkLinkModuleID = nil
                self.presentTransientMessage(message, isError: true)
            }
        }
    }

    private func beginNetworkModuleRestartMonitoring(
        moduleID: CellularModuleID,
        locationID: UInt32
    ) {
        networkModuleRestartTask?.cancel()
        pendingNetworkModuleRestart = NetworkModuleRestartContext(
            moduleID: moduleID,
            locationID: locationID
        )
        recoveringNetworkLinkModuleID = moduleID
        networkModuleRestartTask = Task { [weak self] in
            for attempt in 1 ... 30 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self,
                      let context = self.pendingNetworkModuleRestart,
                      context.moduleID == moduleID,
                      context.locationID == locationID else {
                    return
                }

                self.modemInventoryService.refresh()
                self.networkController.setPreferredLocationID(locationID)
                self.networkController.refresh()

                if attempt >= 4,
                   !context.didRebuildService,
                   locationID != self.activeModemLocationID {
                    self.pendingNetworkModuleRestart?.didRebuildService = true
                    self.rebuildSecondaryModemService(locationID: locationID)
                } else {
                    self.modemService(for: moduleID)?.refresh()
                }
            }

            guard let self,
                  self.pendingNetworkModuleRestart?.moduleID == moduleID else {
                return
            }
            self.pendingNetworkModuleRestart = nil
            self.networkModuleRestartTask = nil
            self.recoveringNetworkLinkModuleID = nil
            self.presentTransientMessage(
                L10n.tr("目标模组重启后 60 秒内未恢复 AT 接口，请拔下后重新插入。"),
                isError: true
            )
        }
    }

    private func refreshPendingNetworkModuleRestart() {
        guard let context = pendingNetworkModuleRestart else { return }
        networkController.setPreferredLocationID(context.locationID)
        modemService(for: context.moduleID)?.refresh()
    }

    private func completePendingNetworkModuleRestartIfReady(
        moduleID: CellularModuleID,
        snapshot: ModemSnapshot
    ) {
        guard let context = pendingNetworkModuleRestart,
              context.moduleID == moduleID,
              snapshot.usbLocationID == context.locationID,
              snapshot.isConnected else {
            return
        }

        networkModuleRestartTask?.cancel()
        networkModuleRestartTask = nil
        pendingNetworkModuleRestart = nil
        recoveringNetworkLinkModuleID = nil
        networkController.setPreferredLocationID(context.locationID)
        networkController.refresh()
        if cellularRestoreDesiredMode?.isEnabled == true, !network.isActive {
            startupCellularRestorePending = true
        }
        cellularNetworkLogger.notice(
            "Target modem AT interface reconnected location=\(context.locationID, privacy: .public)"
        )
        presentTransientMessage(L10n.tr("目标模组已重新连接，正在恢复蜂窝网络。"))
        automaticallyRestoreCellularOnStartupIfNeeded()
        scheduleCellularLinkRecoveryIfNeeded()
    }

    private func rebuildSecondaryModemService(locationID: UInt32) {
        guard locationID != activeModemLocationID,
              !secondaryModemServiceRebuilds.contains(locationID) else {
            return
        }
        secondaryModemServiceRebuilds.insert(locationID)
        secondaryEUICCServices.removeValue(forKey: locationID)
        secondaryEUICCProbeIdentities.removeValue(forKey: locationID)
        auxiliaryEUICCSnapshots.removeValue(forKey: locationID)
        let previousService = secondaryModemServices.removeValue(forKey: locationID)

        let installReplacement = { [weak self] in
            guard let self else { return }
            self.secondaryModemServiceRebuilds.remove(locationID)
            guard !AppTerminationCoordinator.shared.isTerminationPending else { return }
            guard let device = self.discoveredModemDevices.first(where: {
                $0.locationID == locationID
            }) else {
                return
            }
            self.installSecondaryModemService(for: device)
        }

        guard let previousService else {
            installReplacement()
            return
        }
        cellularNetworkLogger.notice(
            "Rebuilding secondary modem service location=\(locationID, privacy: .public)"
        )
        previousService.shutdown { _ in
            installReplacement()
        }
    }

    private func logNetworkActionResult(_ result: ModemActionResult, action: String) {
        switch result {
        case let .success(message):
            cellularNetworkLogger.info(
                "Action \(action, privacy: .public) succeeded: \(message ?? "", privacy: .public)"
            )
        case let .failure(message):
            cellularNetworkLogger.error(
                "Action \(action, privacy: .public) failed: \(message, privacy: .public)"
            )
        }
    }

    private func finishRecoveryOperation() {
        cellularLinkRecoveryInFlight = false
        if cellularRecoveryOwnsNetworkChange {
            cellularRecoveryOwnsNetworkChange = false
            isChangingNetwork = false
        }
    }

    private func cancelCellularLinkRecovery(resetAttempts: Bool) {
        if cellularLinkRecoveryTask != nil ||
            cellularLinkRecoveryInFlight ||
            cellularRecoveryOwnsNetworkChange {
            cellularLinkRecoveryGeneration &+= 1
        }
        cellularLinkRecoveryTask?.cancel()
        cellularLinkRecoveryTask = nil
        finishRecoveryOperation()
        recoveringNetworkLinkModuleID = nil
        if resetAttempts {
            completedCellularLinkRecoveryAttempts.removeAll()
        }
    }

    func configureECM() {
        guard !isConfiguringECM else { return }
        isConfiguringECM = true
        dismissTransientMessage()
        primaryDataModemService.configureECM { [weak self] result in
            guard let self else { return }
            self.isConfiguringECM = false
            self.show(result)
        }
    }

    func convertDJIModuleIdentity() {
        guard !isConvertingModuleIdentity else { return }
        isConvertingModuleIdentity = true
        dismissTransientMessage()
        modemService.convertDJIModuleIdentity { [weak self] result in
            guard let self else { return }
            self.isConvertingModuleIdentity = false
            self.show(result)
        }
    }

    func setHideMenuBarIconWhenDisconnected(_ enabled: Bool) {
        guard hideMenuBarIconWhenDisconnected != enabled else { return }
        hideMenuBarIconWhenDisconnected = enabled
        UserDefaults.standard.set(enabled, forKey: Self.hideDisconnectedMenuBarIconKey)
        updateMenuBarIconVisibility()
    }

    func setShowsMenuBarNetworkSpeed(_ enabled: Bool) {
        guard showsMenuBarNetworkSpeed != enabled else { return }
        showsMenuBarNetworkSpeed = enabled
        UserDefaults.standard.set(enabled, forKey: Self.showsMenuBarNetworkSpeedKey)
    }

    func setAutoDeleteReadVerificationMessages(_ enabled: Bool) {
        guard autoDeleteReadVerificationMessages != enabled else { return }
        autoDeleteReadVerificationMessages = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoDeleteReadVerificationMessagesKey)
        verificationAutoDeleteRetryDates.removeAll()
        if enabled {
            messageStore.resetVerificationReadDates()
            messages = messageStore.messages
        }
        scheduleVerificationAutoDelete()
    }

    func setAutomaticallyRecordCalls(_ enabled: Bool) {
        guard automaticallyRecordCalls != enabled else { return }
        automaticallyRecordCalls = enabled
        UserDefaults.standard.set(enabled, forKey: Self.automaticallyRecordCallsKey)
        if enabled {
            startAutomaticCallRecordingIfNeeded()
        }
    }

    func setPresentationPrivacyEnabled(_ enabled: Bool) {
        guard isPresentationPrivacyEnabled != enabled else { return }
        isPresentationPrivacyEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PrivacyProtectionPreferences.enabledKey)
        if enabled {
            NotificationService.shared.clearSensitiveNotifications()
        }
    }

    func refreshSystemSettingsStatus() {
        launchAtLoginStatus = launchAtLoginController.status
        NotificationService.shared.authorizationStatus { [weak self] status in
            self?.notificationAuthorizationStatus = status
        }
    }

    func requestNotificationAuthorization(completion: (() -> Void)? = nil) {
        if let completion {
            notificationAuthorizationCompletions.append(completion)
        }
        guard !isRequestingNotificationAuthorization else { return }
        isRequestingNotificationAuthorization = true
        NotificationService.shared.requestAuthorization { [weak self] status, error in
            guard let self else { return }
            self.isRequestingNotificationAuthorization = false
            self.notificationAuthorizationStatus = status
            if let error {
                self.presentTransientMessage(error, isError: true)
            }
            let completions = self.notificationAuthorizationCompletions
            self.notificationAuthorizationCompletions.removeAll(keepingCapacity: false)
            completions.forEach { $0() }
        }
    }

    /// Requests first-run permissions only after the app has finished launching
    /// and has a visible window. System prompts are serialized so the
    /// microphone sheet never competes with the notification alert.
    func requestStartupPermissionsIfNeeded() {
        NotificationService.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            self.notificationAuthorizationStatus = status
            if status == .notDetermined {
                self.requestNotificationAuthorization { [weak self] in
                    self?.requestMicrophoneAuthorizationIfNeeded()
                }
            } else {
                self.requestMicrophoneAuthorizationIfNeeded()
            }
        }
    }

    private func requestMicrophoneAuthorizationIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func openNotificationSettings() {
        NotificationService.shared.openSystemSettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        launchAtLoginError = nil
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginStatus = launchAtLoginController.status
        } catch {
            launchAtLoginStatus = launchAtLoginController.status
            launchAtLoginError = error.localizedDescription
        }
        isChangingLaunchAtLogin = false
    }

    func setIncomingCallsEnabled(
        _ enabled: Bool,
        moduleID requestedModuleID: CellularModuleID? = nil
    ) {
        guard !isChangingIncomingCallSetting else { return }
        let moduleID = requestedModuleID ?? currentCommunicationModuleID
        guard !euiccSnapshot(for: moduleID).isBusy else {
            presentTransientMessage(L10n.tr("eSIM 操作期间不能更改来电设置。"), isError: true)
            return
        }
        guard let service = modemService(for: moduleID) else {
            presentTransientMessage(L10n.tr("所选模组尚未就绪。"), isError: true)
            return
        }
        isChangingIncomingCallSetting = true
        dismissTransientMessage()
        service.setIncomingCallsEnabled(enabled) { [weak self] result in
            guard let self else { return }
            self.isChangingIncomingCallSetting = false
            self.show(result)
        }
    }

    func dial(_ number: String) {
        dial(number, completion: { _ in })
    }

    func dial(_ number: String, completion: @escaping (ModemActionResult) -> Void) {
        let moduleID = communicationModuleID()
        guard let service = modemService(for: moduleID) else {
            let result = ModemActionResult.failure(L10n.tr("当前通信模组尚未就绪。"))
            show(result)
            completion(result)
            return
        }
        guard !euiccSnapshot(for: moduleID).isBusy else {
            let result = ModemActionResult.failure(L10n.tr("eSIM 操作期间不能拨号。"))
            show(result)
            completion(result)
            return
        }
        guard !call.hasCall else {
            let result = ModemActionResult.failure(L10n.tr("已有一路通话，结束后才能使用另一张卡拨号。"))
            show(result)
            completion(result)
            return
        }
        guard !isChangingCall, !AppTerminationCoordinator.shared.isTerminationPending else {
            completion(.failure(L10n.tr("通话操作正在进行，请稍后重试。")))
            return
        }
        isChangingCall = true
        dismissTransientMessage()
        service.dial(number) { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
            completion(result)
        }
    }

    func answerCall() {
        answerCall(completion: { _ in })
    }

    func answerCall(completion: @escaping (ModemActionResult) -> Void) {
        let moduleID = activeCallModuleID ?? call.moduleID
        guard let service = modemService(for: moduleID) else {
            let result = ModemActionResult.failure(L10n.tr("来电模组已断开。"))
            show(result)
            completion(result)
            return
        }
        guard !euiccSnapshot(for: moduleID).isBusy else {
            let result = ModemActionResult.failure(L10n.tr("eSIM 操作期间暂时不能接听。"))
            show(result)
            completion(result)
            return
        }
        guard !isChangingCall, !AppTerminationCoordinator.shared.isTerminationPending else {
            completion(.failure(L10n.tr("通话操作正在进行，请稍后重试。")))
            return
        }
        isChangingCall = true
        service.answerCall { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
            completion(result)
        }
    }

    func hangUp() {
        hangUp(completion: { _ in })
    }

    func hangUp(completion: @escaping (ModemActionResult) -> Void) {
        guard !isChangingCall, !AppTerminationCoordinator.shared.isTerminationPending else {
            completion(.failure(L10n.tr("通话操作正在进行，请稍后重试。")))
            return
        }
        guard let service = modemService(for: activeCallModuleID ?? call.moduleID) else {
            let result = ModemActionResult.failure(L10n.tr("通话模组已断开。"))
            show(result)
            completion(result)
            return
        }
        isChangingCall = true
        service.hangUp { [weak self] result in
            guard let self else { return }
            self.isChangingCall = false
            self.show(result)
            completion(result)
        }
    }

    func setCallMuted(_ muted: Bool) {
        modemService(for: activeCallModuleID ?? call.moduleID)?.setCallMuted(muted)
    }

    func startCallRecording() {
        guard call.phase == .active, call.audioActive else {
            presentTransientMessage(L10n.tr("通话音频尚未就绪，暂时无法开始录音。"), isError: true)
            return
        }
        guard callRecordings.phase == .idle else { return }
        callRecordings.start(
            localNumber: call.moduleID.map(moduleSnapshot(for:))?.simPhoneNumber,
            number: call.number ?? "",
            direction: call.direction ?? .outgoing,
            callID: callHistory.currentCallID(for: call.moduleID)
        )
        if let error = callRecordings.lastError {
            presentTransientMessage(L10n.tr("无法开始通话录音：%@", error), isError: true)
        }
    }

    private func startAutomaticCallRecordingIfNeeded() {
        guard automaticallyRecordCalls,
              call.phase == .active,
              call.audioActive,
              let callID = callHistory.currentCallID(for: call.moduleID),
              automaticRecordingAttemptedCallID != callID else {
            return
        }
        automaticRecordingAttemptedCallID = callID
        guard callRecordings.phase == .idle else { return }
        startCallRecording()
    }

    func stopCallRecording(completion: (() -> Void)? = nil) {
        guard callRecordings.isRecording else {
            callRecordings.performWhenIdle { completion?() }
            return
        }
        callRecordings.stop { [weak self] record in
            if let record, let callID = record.callID {
                self?.callHistory.attachRecording(record.id, toCallID: callID)
            }
            completion?()
        }
    }

    func sendDTMF(_ tone: String) {
        guard let service = modemService(for: activeCallModuleID ?? call.moduleID) else { return }
        service.sendDTMF(tone) { [weak self] result in
            self?.show(result)
        }
    }

    func executeAT(
        _ command: String,
        via requestedModuleID: CellularModuleID? = nil,
        completion: @escaping (ATConsoleExecutionResult) -> Void
    ) {
        let moduleID = communicationModuleID(requested: requestedModuleID)
        guard !euiccSnapshot(for: moduleID).isBusy else {
            completion(ATConsoleExecutionResult(
                command: command,
                output: "",
                error: L10n.tr("eSIM 操作期间不能执行手动 AT 命令。"),
                elapsedMilliseconds: 0,
                timestamp: Date()
            ))
            return
        }
        guard !isExecutingAT else { return }
        isExecutingAT = true
        guard let service = modemService(for: moduleID) else {
            isExecutingAT = false
            completion(ATConsoleExecutionResult(
                command: command,
                output: "",
                error: L10n.tr("所选模组尚未就绪。"),
                elapsedMilliseconds: 0,
                timestamp: Date()
            ))
            return
        }
        service.executeAT(command) { [weak self] result in
            guard let self else { return }
            self.isExecutingAT = false
            completion(result)
        }
    }

    func sendSMS(
        to destination: String,
        body: String,
        via requestedModuleID: CellularModuleID? = nil,
        completion: @escaping (SMSMessageSendResult) -> Void
    ) {
        let moduleID = communicationModuleID(requested: requestedModuleID)
        guard !euiccSnapshot(for: moduleID).isBusy else {
            completion(.failure(
                L10n.tr("eSIM 操作期间不能发送短信。"),
                isDeliveryUncertain: false
            ))
            return
        }
        guard let service = modemService(for: moduleID) else {
            completion(.failure(
                L10n.tr("所选模组尚未就绪，无法发送短信。"),
                isDeliveryUncertain: false
            ))
            return
        }
        guard sendingMessageModuleIDs.insert(moduleID).inserted else {
            completion(.failure(
                L10n.tr("该模组已有短信正在发送。"),
                isDeliveryUncertain: false
            ))
            return
        }
        let outgoingMessageID = messageStore.appendOutgoing(
            to: destination,
            body: body,
            moduleID: moduleID
        )
        messages = messageStore.messages
        isSendingMessage = true
        dismissTransientMessage()
        service.sendMessage(to: destination, body: body) { [weak self] sendResult in
            guard let self else { return }
            self.sendingMessageModuleIDs.remove(moduleID)
            self.isSendingMessage = !self.sendingMessageModuleIDs.isEmpty
            switch sendResult {
            case .success:
                self.messageStore.updateOutgoing(
                    id: outgoingMessageID,
                    state: .sent
                )
            case let .failure(message, isDeliveryUncertain):
                self.messageStore.updateOutgoing(
                    id: outgoingMessageID,
                    state: isDeliveryUncertain ? .uncertain : .failed,
                    detail: message
                )
            }
            let result = sendResult.actionResult
            self.messages = self.messageStore.messages
            self.show(result)
            completion(sendResult)
        }
    }

    func showMainWindow() {
        MainWindowController.shared.show()
    }

    func showPhoneWindow(
        number: String? = nil,
        section: PhoneWindowSection? = nil,
        callRecordID: CallHistoryRecord.ID? = nil,
        simModuleID: CellularModuleID? = nil
    ) {
        if call.hasCall,
           number == nil,
           section == nil,
           callRecordID == nil,
           simModuleID == nil {
            CommunicationWindowController.shared.showCurrentCall()
            return
        }
        CommunicationWindowController.shared.showPhone(
            number: number,
            section: section,
            callRecordID: callRecordID,
            simModuleID: simModuleID
        )
    }

    func showMessagesWindow(
        messageID: SMSMessage.ID? = nil,
        destination: String? = nil
    ) {
        CommunicationWindowController.shared.showMessages(
            messageID: messageID,
            destination: destination
        )
    }

    func showStandaloneSMSComposer(to destination: String = "") {
        StandaloneFlowWindowController.shared.showSMSComposer(to: destination)
    }

    func showStandaloneATConsole() {
        StandaloneFlowWindowController.shared.showATConsole()
    }

    func showStandaloneSettings() {
        showPhoneWindow(section: .settings)
    }

    func showStandaloneMessageDetail(_ message: SMSMessage) {
        markRead(message)
        StandaloneFlowWindowController.shared.showMessageDetail(message)
    }

    func showInitialSetupWindow() {
        InitialSetupWindowController.shared.show()
    }

    func showMainWindowAndMessageDetail(_ message: SMSMessage) {
        markRead(message)
        requestedMessageDetailID = message.id
        MainWindowController.shared.showForPresentedFlow()
        messageDetailRequestSerial &+= 1
    }

    func completeInitialSetup() {
        recordInitialSetupSuccess()
    }

    func initialSetupDidDismiss() {
        initialSetupPresentationIsActive = false
    }

    func presentedFlowDidDismiss() {
        MainWindowController.shared.presentedFlowDidDismiss()
    }

    func markRead(_ message: SMSMessage) {
        messageStore.markRead(id: message.id)
        messages = messageStore.messages
        scheduleVerificationAutoDelete()
    }

    func markRead(_ conversationMessages: [SMSMessage]) {
        guard !conversationMessages.isEmpty else { return }
        messageStore.markRead(ids: Set(conversationMessages.map(\.id)))
        messages = messageStore.messages
        scheduleVerificationAutoDelete()
    }

    func markAllRead() {
        messageStore.markAllRead()
        messages = messageStore.messages
        scheduleVerificationAutoDelete()
    }

    func delete(_ message: SMSMessage) {
        delete(message, automatically: false)
    }

    private func delete(_ message: SMSMessage, automatically: Bool) {
        guard let currentMessage = messageStore.messages.first(where: { $0.id == message.id }),
              deletingMessageIDs.insert(currentMessage.id).inserted else {
            return
        }
        let references = currentMessage.effectiveModemReferences
        if !automatically {
            messageStore.remove(id: currentMessage.id)
            messages = messageStore.messages
            verificationAutoDeleteRetryDates.removeValue(forKey: currentMessage.id)
            presentTransientMessage(L10n.tr("短信已删除。"))
            if references.isEmpty {
                deletingMessageIDs.remove(currentMessage.id)
                DispatchQueue.main.async { [weak self] in self?.scheduleVerificationAutoDelete() }
                return
            }
        }
        if automatically, references.isEmpty {
            messageStore.remove(id: currentMessage.id)
            messages = messageStore.messages
            deletingMessageIDs.remove(currentMessage.id)
            verificationAutoDeleteRetryDates.removeValue(forKey: currentMessage.id)
            DispatchQueue.main.async { [weak self] in self?.scheduleVerificationAutoDelete() }
            return
        }
        guard let service = modemService(for: currentMessage.moduleID) else {
            deletingMessageIDs.remove(currentMessage.id)
            if automatically {
                verificationAutoDeleteRetryDates[currentMessage.id] = Date().addingTimeInterval(5 * 60)
            }
            scheduleVerificationAutoDelete()
            return
        }
        service.deleteMessage(
            references: references
        ) { [weak self] result in
            guard let self else { return }
            self.deletingMessageIDs.remove(currentMessage.id)
            if automatically, case .success = result {
                self.messageStore.remove(id: currentMessage.id)
                self.messages = self.messageStore.messages
                self.verificationAutoDeleteRetryDates.removeValue(forKey: currentMessage.id)
            } else if automatically, case .failure = result {
                self.verificationAutoDeleteRetryDates[currentMessage.id] =
                    Date().addingTimeInterval(5 * 60)
            }
            if !automatically, case let .failure(message) = result {
                NSLog("CellDock hid a deleted SMS locally but module cleanup failed: %@", message)
            }
            self.scheduleVerificationAutoDelete()
        }
    }

    func copy(_ message: SMSMessage) {
        guard !isPresentationPrivacyEnabled else {
            presentTransientMessage(L10n.tr("演示隐私保护开启时不能复制短信。"), isError: true)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(message.sender)\n\(message.body)", forType: .string)
        presentTransientMessage(L10n.tr("短信已复制。"))
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func dismissTransientMessage() {
        transientDismissalTask?.cancel()
        transientDismissalTask = nil
        transientMessage = nil
        transientIsError = false
    }

    private func show(_ result: ModemActionResult) {
        switch result {
        case let .success(message):
            if let message, !message.isEmpty {
                presentTransientMessage(message)
            } else {
                dismissTransientMessage()
            }
        case let .failure(message):
            presentTransientMessage(message, isError: true)
        }
    }

    private func presentTransientMessage(_ message: String, isError: Bool = false) {
        transientDismissalTask?.cancel()
        transientMessage = message
        transientIsError = isError

        let delay: UInt64 = isError ? 6_000_000_000 : 4_000_000_000
        transientDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.dismissTransientMessage()
        }
    }

    private func scheduleVerificationAutoDelete(now: Date = Date()) {
        verificationAutoDeleteTask?.cancel()
        verificationAutoDeleteTask = nil
        guard autoDeleteReadVerificationMessages else { return }

        let messageIDs = Set(messageStore.messages.map(\.id))
        verificationAutoDeleteRetryDates = verificationAutoDeleteRetryDates.filter {
            messageIDs.contains($0.key)
        }
        let candidates = messageStore.messages.compactMap { message -> (SMSMessage, Date)? in
            guard !deletingMessageIDs.contains(message.id),
                  let policyDate = VerificationMessageAutoDeletePolicy.deletionDate(
                      for: message,
                      enabled: true
                  ) else {
                return nil
            }
            let deletionDate = max(policyDate, verificationAutoDeleteRetryDates[message.id] ?? policyDate)
            return (message, deletionDate)
        }
        guard let next = candidates.min(by: { $0.1 < $1.1 }) else { return }

        let delay = next.1.timeIntervalSince(now)
        if delay > 0 {
            scheduleVerificationAutoDeleteWake(after: delay)
            return
        }
        if !deletingMessageIDs.isEmpty {
            scheduleVerificationAutoDeleteWake(after: 5)
            return
        }

        let moduleIsBusy = !modem.isConnected ||
            call.hasCall ||
            isChangingCall ||
            isSendingMessage ||
            isExecutingAT ||
            isChangingIncomingCallSetting ||
            isConfiguringECM ||
            isConvertingModuleIdentity
        if moduleIsBusy {
            verificationAutoDeleteRetryDates[next.0.id] = now.addingTimeInterval(60)
            scheduleVerificationAutoDelete(now: now)
            return
        }
        delete(next.0, automatically: true)
    }

    private func scheduleVerificationAutoDeleteWake(after delay: TimeInterval) {
        let boundedDelay = min(max(delay, 0.1), 7 * 24 * 60 * 60)
        verificationAutoDeleteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(boundedDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.scheduleVerificationAutoDelete()
        }
    }

    private func updateMenuBarIconVisibility() {
        let shouldInsert = !hideMenuBarIconWhenDisconnected || modem.state != .disconnected
        guard isMenuBarStatusItemVisible != shouldInsert else { return }
        isMenuBarStatusItemVisible = shouldInsert
    }

    private var hasCompletedInitialSetup: Bool {
        UserDefaults.standard.bool(forKey: Self.initialSetupCompletedKey)
    }

    private func handleInitialSetupSnapshot(_ snapshot: ModemSnapshot) {
        switch snapshot.initialSetupState {
        case .ready:
            recordInitialSetupSuccess()
        case .inspecting:
            if !hasCompletedInitialSetup {
                scheduleInitialSetupPromptIfNeeded(afterNanoseconds: 1_500_000_000)
            }
        case .insertModule:
            if !hasCompletedInitialSetup {
                scheduleInitialSetupPromptIfNeeded()
            }
        case .needsIdentityConversion, .needsECM, .unsupportedIdentity,
             .unsupportedUSBConfiguration, .unsupportedUSBNetMode:
            presentInitialSetupIfNeeded(forUninitializedModule: true)
        case .failed:
            if snapshot.usbIdentity != nil {
                presentInitialSetupIfNeeded(forUninitializedModule: true)
            } else if !hasCompletedInitialSetup {
                presentInitialSetupIfNeeded()
            }
        }
    }

    private func scheduleInitialSetupPromptIfNeeded(
        afterNanoseconds delay: UInt64 = 2_500_000_000
    ) {
        guard !hasCompletedInitialSetup,
              !initialSetupWasPresentedForCurrentInsertion,
              initialSetupPromptTask == nil else {
            return
        }
        initialSetupPromptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.initialSetupPromptTask = nil
            guard !self.hasCompletedInitialSetup else { return }
            switch self.modem.initialSetupState {
            case .ready:
                self.recordInitialSetupSuccess()
            case .inspecting:
                self.scheduleInitialSetupPromptIfNeeded(afterNanoseconds: 1_500_000_000)
            case .insertModule, .needsIdentityConversion, .needsECM, .unsupportedIdentity,
                 .unsupportedUSBConfiguration, .unsupportedUSBNetMode, .failed:
                self.presentInitialSetupIfNeeded()
            }
        }
    }

    private func presentInitialSetupIfNeeded(forUninitializedModule: Bool = false) {
        guard (forUninitializedModule || !hasCompletedInitialSetup),
              !initialSetupWasPresentedForCurrentInsertion,
              !initialSetupPresentationIsActive else {
            return
        }
        initialSetupWasPresentedForCurrentInsertion = true
        initialSetupPresentationIsActive = true
        showInitialSetupWindow()
    }

    private func recordInitialSetupSuccess() {
        if !hasCompletedInitialSetup {
            UserDefaults.standard.set(true, forKey: Self.initialSetupCompletedKey)
        }
        initialSetupPromptTask?.cancel()
        initialSetupPromptTask = nil
        if initialSetupPresentationIsActive || InitialSetupWindowController.shared.isVisible {
            InitialSetupWindowController.shared.scheduleDismissAfterSuccess()
        }
    }
}
