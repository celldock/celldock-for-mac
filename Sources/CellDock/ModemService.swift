import CModemBridge
import Foundation

struct EUICCATResponse {
    let output: String
    let error: String?
    let isSuccess: Bool
}

enum SMSMessageSendResult {
    case success(String?)
    case failure(String, isDeliveryUncertain: Bool)

    var actionResult: ModemActionResult {
        switch self {
        case let .success(message): return .success(message)
        case let .failure(message, _): return .failure(message)
        }
    }
}

enum EUICCModemLeaseError: LocalizedError {
    case disconnected
    case callInProgress
    case busy

    var errorDescription: String? {
        switch self {
        case .disconnected: return L10n.tr("模块尚未连接。")
        case .callInProgress: return L10n.tr("通话期间不能管理 eSIM。")
        case .busy: return L10n.tr("另一项 eSIM 操作仍在进行。")
        }
    }
}

@_cdecl("celldock_modem_stream_callback")
func celldockModemStreamCallback(
    context: UnsafeMutableRawPointer?,
    bytes: UnsafePointer<UInt8>?,
    length: Int
) {
    guard let context, let bytes, length > 0 else { return }
    let service = Unmanaged<ModemService>.fromOpaque(context).takeUnretainedValue()
    service.consumeCommandStreamBytes(bytes, length: length)
}

final class ModemService {
    var onSnapshot: ((ModemSnapshot) -> Void)?
    var onMessages: (([SMSMessage], Bool) -> Void)?
    var onCallSnapshot: ((CallSnapshot) -> Void)?

    private struct PendingMessageLocation {
        let location: ModemMessageLocation
        var attempts: Int
    }

    private struct CallActionToken: Equatable {
        let id: UInt64
        let modemGeneration: UInt64
        let registryID: UInt64
    }

    private struct PendingQDCMediaSession: Equatable {
        let id: UInt64
        let modemGeneration: UInt64
        let registryID: UInt64
        let direction: CallDirection
        let preferredUACUID: String
        var callIndex: Int?
    }

    private enum ExpectedPDUState {
        case exact
        case gone
        case unknown(String)
    }

    private enum CallPresence {
        case present([ModemCallInfo])
        case empty
        case unknown(String)
        case differentDevice
    }

    private enum CallMediaBackend {
        case none
        case qpcmv
        case qdcUAC
        case qdcModuleBridge
    }

    private let queue = DispatchQueue(label: "app.celldock.mac.modem", qos: .userInitiated)
    private let preferredLocationID: UInt32?
    private let shutdownControlQueue = DispatchQueue(
        label: "app.celldock.mac.modem.shutdown",
        qos: .userInitiated
    )
    private let interfaceContentionQueue = DispatchQueue(
        label: "app.celldock.mac.usb-contention",
        qos: .userInitiated
    )
    private let modemHandleLock = NSLock()
    private let voiceAudio = VoiceAudioService()
    private var timer: DispatchSourceTimer?
    private var eventTimer: DispatchSourceTimer?
    private var modem: OpaquePointer?
    private var interruptibleModem: OpaquePointer?
    private var snapshot = ModemSnapshot()
    private var lastPublishedSnapshot: ModemSnapshot?
    private var lastPublishedCallFingerprint: CallSnapshot?
    private var tickNumber = 0
    private var needsImmediateMessagePoll = false
    private var needsSIMRefresh = false
    private var didQuerySIMIdentity = false
    private var nextSIMRefreshAt = Date.distantPast
    private var simFastPollingDeadline: Date?
    private var consecutiveSIMQueryFailures = 0
    private var expectedRestartStartedAt: Date?
    private var expectedRestartObservedDisconnect = false
    private var isRunning = false
    private var currentMessageStorage: String?
    private var readableMessageStorages: [String] = []
    private var observedMessageStorages: Set<String> = []
    private var pendingMessageLocations: [PendingMessageLocation] = []
    private var inFlightMessageLocations: Set<ModemMessageLocation> = []
    private var urcFramer = ModemURCStreamFramer()
    private var bufferedSMSAssembler = BufferedSMSAssembler()
    private var messageStorageSyncTracker = MessageStorageSyncTracker()
    private var callSnapshot = CallSnapshot()
    private var callURCFramer = CallURCStreamFramer()
    private var callStateChangedAt = Date.distantPast
    private var callPollMisses = 0
    private var pcmSessionEnabled = false
    private var callMediaBackend: CallMediaBackend = .none
    private var moduleVoiceRuntime: ModuleVoiceRuntime?
    private var callActionInFlight = false
    private var euiccOperationInFlight = false
    private var commandInFlight = false
    private var commandStreamAcceptsCallInfo = true
    private var callCleanupScheduled = false
    private var callMediaCleanupPending = false
    private var modemRegistryID: UInt64 = 0
    private var modemLocationID: UInt32 = 0
    private var modemGeneration: UInt64 = 0
    private var callActionID: UInt64 = 0
    private var callActionModemGeneration: UInt64 = 0
    private var qdcMediaSessionID: UInt64 = 0
    private var pendingQDCMediaSession: PendingQDCMediaSession?
    private var qdcMediaStartInFlight = false
    private var needsPostCallInitialization = false
    private var isShuttingDown = false
    private var qdcInitializationRetryGeneration: UInt64 = 0
    private var qdcInitializationRetryAttempts = 0

    init(locationID: UInt32? = nil) {
        preferredLocationID = locationID
        voiceAudio.onError = { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                self.callSnapshot.audioActive = false
                self.callSnapshot.lastError = error
                self.publishCallSnapshot()
                if self.callSnapshot.hasCall {
                    _ = self.terminateAndConfirmCall(reason: .failed)
                }
            }
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.isShuttingDown = false
            self.modem = celldock_modem_create()
            self.setInterruptibleModem(self.modem)
            guard self.modem != nil else {
                self.publishSnapshot(
                    ModemSnapshot(
                        state: .error,
                        lastError: L10n.tr("无法初始化 IOKit AT 接口桥接。")
                    )
                )
                return
            }
            celldock_modem_set_stream_callback(
                self.modem,
                celldockModemStreamCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(150))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()

            let eventTimer = DispatchSource.makeTimerSource(queue: self.queue)
            eventTimer.schedule(
                deadline: .now() + .milliseconds(40),
                repeating: .milliseconds(40),
                leeway: .milliseconds(5)
            )
            eventTimer.setEventHandler { [weak self] in self?.pumpUnsolicitedEvents() }
            self.eventTimer = eventTimer
            eventTimer.resume()
        }
    }

    func stop() {
        shutdown { _ in }
    }

    func shutdown(completion: @escaping (Bool) -> Void) {
        shutdownControlQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            self.interruptPendingModemRead()
            self.enqueueShutdown(completion: completion)
        }
    }

    private func enqueueShutdown(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            guard !self.isShuttingDown else {
                let clean = !self.callSnapshot.hasCall && !self.hasPendingMediaCleanup
                DispatchQueue.main.async { completion(clean) }
                return
            }
            self.isShuttingDown = true
            let deferredInitialization = self.needsPostCallInitialization
            self.needsPostCallInitialization = false
            if self.callSnapshot.hasCall {
                guard self.terminateAndConfirmCall(reason: .localHangup) else {
                    self.needsPostCallInitialization = deferredInitialization
                    self.isShuttingDown = false
                    DispatchQueue.main.async { completion(false) }
                    return
                }
            } else {
                guard self.cleanupCallMedia() else {
                    self.needsPostCallInitialization = deferredInitialization
                    self.isShuttingDown = false
                    DispatchQueue.main.async { completion(false) }
                    return
                }
            }
            self.timer?.cancel()
            self.timer = nil
            self.eventTimer?.cancel()
            self.eventTimer = nil
            if let modem = self.modem {
                celldock_modem_set_stream_callback(modem, nil, nil)
                self.destroyModem(modem)
            }
            self.modem = nil
            self.isRunning = false
            self.resetCallConnectionState(disconnected: true)
            DispatchQueue.main.async { completion(true) }
        }
    }

    private func setInterruptibleModem(_ modem: OpaquePointer?) {
        modemHandleLock.lock()
        interruptibleModem = modem
        modemHandleLock.unlock()
    }

    private func interruptPendingModemRead() {
        modemHandleLock.lock()
        if let modem = interruptibleModem {
            _ = celldock_modem_interrupt_read(modem)
        }
        modemHandleLock.unlock()
    }

    private func destroyModem(_ modem: OpaquePointer) {
        modemHandleLock.lock()
        interruptibleModem = nil
        celldock_modem_destroy(modem)
        modemHandleLock.unlock()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.needsImmediateMessagePoll = true
            self.needsSIMRefresh = true
            self.tickNumber = 9
            self.tick()
        }
    }

    func performExclusiveEUICCWork(
        _ work: @escaping () throws -> EUICCSnapshot,
        completion: @escaping (Result<EUICCSnapshot, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(EUICCModemLeaseError.disconnected)) }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async { completion(.failure(EUICCModemLeaseError.callInProgress)) }
                return
            }
            guard !self.euiccOperationInFlight else {
                DispatchQueue.main.async { completion(.failure(EUICCModemLeaseError.busy)) }
                return
            }

            self.euiccOperationInFlight = true
            let result = Result { try work() }
            self.euiccOperationInFlight = false
            self.needsSIMRefresh = true
            self.tickNumber = 9
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Must only be called by an active `performExclusiveEUICCWork` closure.
    func executeEUICCATCommand(
        _ value: String,
        timeout: Int,
        capacity: Int = 256 * 1_024
    ) -> EUICCATResponse {
        guard euiccOperationInFlight else {
            return EUICCATResponse(
                output: "",
                error: L10n.tr("eSIM 命令未取得模块独占访问权。"),
                isSuccess: false
            )
        }
        let result = command(value, timeout: timeout, capacity: capacity)
        return EUICCATResponse(
            output: result.output,
            error: result.error,
            isSuccess: result.isSuccess
        )
    }

    func retryCallInitialization(completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("模块尚未连接。"))) }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("当前通话状态尚未清理完成，不能重新初始化。")))
                }
                return
            }
            switch self.queryCallPresence() {
            case .empty:
                break
            case .present:
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("模块中存在通话，不能重新初始化通话组件。")))
                }
                return
            case let .unknown(error):
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法确认模块通话状态：%@", error)))
                }
                return
            case .differentDevice:
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("原模块已断开，请重新插入后再试。")))
                }
                return
            }

            self.initializeConnectedModem()
            let result: ModemActionResult = self.callSnapshot.voiceOverUSBSupported
                ? .success(L10n.tr("电话组件已就绪。"))
                : .failure(self.callSnapshot.lastError ?? L10n.tr("电话组件仍不可用。"))
            DispatchQueue.main.async { completion(result) }
        }
    }

    func forceReleaseCallControlInterface(
        completion: @escaping (ModemActionResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.isOpen, self.modemLocationID != 0 else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("模块尚未连接。"))) }
                return
            }
            guard self.callSnapshot.controlInterfaceBusy else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("当前没有检测到可结束的接口占用。")))
                }
                return
            }
            self.cancelQDCInitializationRetry()
            let locationID = self.modemLocationID
            self.interfaceContentionQueue.async { [weak self] in
                guard let self else { return }
                let release = USBInterfaceContentionResolver.forceReleaseADBInterface(
                    locationID: locationID
                )
                guard let release else {
                    // The owner may have exited between the UI update and the
                    // click. Retry directly instead of reporting a stale error.
                    self.retryCallInitialization(completion: completion)
                    return
                }
                guard release.terminated else {
                    DispatchQueue.main.async { completion(.failure(release.message)) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
                self.retryCallInitialization { result in
                    switch result {
                    case let .success(message):
                        let detail = [release.message, message]
                            .compactMap { $0 }
                            .joined(separator: " ")
                        completion(.success(detail))
                    case let .failure(message):
                        completion(.failure(L10n.tr("%@ 但电话初始化仍失败：%@", release.message, message)))
                    }
                }
            }
        }
    }

    func recoverCellularNetworkLink(completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isOpen,
                  self.snapshot.usbIdentity?.uppercased() == "2C7C:0125",
                  self.snapshot.usbNetMode == 1,
                  self.modemLocationID != 0 else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("模块 ECM 接口尚未就绪。")))
                }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("通话期间不会重置模块网络链路。")))
                }
                return
            }

            do {
                let runtime: ModuleVoiceRuntime
                if let existing = self.moduleVoiceRuntime {
                    runtime = existing
                } else {
                    runtime = try ModuleVoiceRuntime(locationID: self.modemLocationID)
                    self.moduleVoiceRuntime = runtime
                }
                try runtime.recoverECMNetworkLink()
                DispatchQueue.main.async { completion(.success()) }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(L10n.error("模块网络链路恢复失败：%@", underlying: error)))
                }
            }
        }
    }

    func probeVoWiFiRuntime(
        completion: @escaping (Result<VoWiFiRuntimeStatus, Error>) -> Void
    ) {
        withVoWiFiRuntime(requiresIdleVoicePath: false, completion: completion) { runtime in
            try runtime.voWiFiRuntimeStatus()
        }
    }

    func startVoWiFiRuntime(
        _ request: VoWiFiSessionRequest,
        completion: @escaping (Result<VoWiFiRuntimeStatus, Error>) -> Void
    ) {
        withVoWiFiRuntime(requiresIdleVoicePath: true, completion: completion) { runtime in
            try runtime.startVoWiFiRuntime(request)
        }
    }

    func stopVoWiFiRuntime(
        timeout: TimeInterval = 20,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        withVoWiFiRuntime(requiresIdleVoicePath: true, completion: completion) { runtime in
            try runtime.stopVoWiFiRuntime(timeout: timeout)
        }
    }

    private func withVoWiFiRuntime<Value>(
        requiresIdleVoicePath: Bool,
        completion: @escaping (Result<Value, Error>) -> Void,
        body: @escaping (ModuleVoiceRuntime) throws -> Value
    ) {
        queue.async { [weak self] in
            guard let self, self.isOpen, self.modemLocationID != 0 else {
                DispatchQueue.main.async {
                    completion(.failure(ModuleVoiceRuntime.RuntimeError.moduleCommand(
                        L10n.tr("模块尚未连接。")
                    )))
                }
                return
            }
            if requiresIdleVoicePath {
                guard !self.callSnapshot.hasCall,
                      !self.hasPendingMediaCleanup,
                      !self.callActionInFlight else {
                    DispatchQueue.main.async {
                        completion(.failure(ModuleVoiceRuntime.RuntimeError.moduleCommand(
                            L10n.tr("通话期间不能切换 VoWiFi。")
                        )))
                    }
                    return
                }
            }
            do {
                let runtime: ModuleVoiceRuntime
                if let existing = self.moduleVoiceRuntime {
                    runtime = existing
                } else {
                    runtime = try ModuleVoiceRuntime(locationID: self.modemLocationID)
                    self.moduleVoiceRuntime = runtime
                }
                let status = try body(runtime)
                DispatchQueue.main.async { completion(.success(status)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func restartForCellularNetworkRecovery(
        completion: @escaping (ModemActionResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.isOpen,
                  self.snapshot.usbIdentity?.uppercased() == "2C7C:0125",
                  self.snapshot.usbNetMode == 1 else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("模块尚未就绪，无法执行网络恢复重启。")))
                }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("通话期间不会自动重启模块恢复网络。")))
                }
                return
            }

            let restart = self.command("AT+CFUN=1,1", timeout: 1_000)
            guard restart.isSuccess || restart.isTransportAmbiguous else {
                DispatchQueue.main.async {
                    completion(.failure(restart.error ?? L10n.tr("模块拒绝网络恢复重启。")))
                }
                return
            }
            self.beginExpectedModuleRestart()
            DispatchQueue.main.async {
                completion(.success(L10n.tr("模块正在重启并重新枚举 CDC-ECM。")))
            }
        }
    }

    func executeAT(
        _ rawCommand: String,
        completion: @escaping (ATConsoleExecutionResult) -> Void
    ) {
        let command: String
        do {
            command = try ATConsoleCommandValidator.validate(rawCommand)
        } catch {
            let result = ATConsoleExecutionResult(
                command: rawCommand,
                output: "",
                error: error.localizedDescription,
                elapsedMilliseconds: 0,
                timestamp: Date()
            )
            DispatchQueue.main.async { completion(result) }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard self.isOpen else {
                DispatchQueue.main.async {
                    completion(ATConsoleExecutionResult(
                        command: command,
                        output: "",
                        error: L10n.tr("模块未连接，无法执行 AT 命令。"),
                        elapsedMilliseconds: 0,
                        timestamp: Date()
                    ))
                }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(ATConsoleExecutionResult(
                        command: command,
                        output: "",
                        error: L10n.tr("通话或语音清理期间不能执行手动 AT 命令。"),
                        elapsedMilliseconds: 0,
                        timestamp: Date()
                    ))
                }
                return
            }

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let response = self.command(command, timeout: 15_000, capacity: 256 * 1_024)
            let finishedAt = DispatchTime.now().uptimeNanoseconds
            let elapsed = finishedAt >= startedAt
                ? Int((finishedAt - startedAt) / 1_000_000)
                : 0
            let result = ATConsoleExecutionResult(
                command: command,
                output: response.output.trimmingCharacters(in: .whitespacesAndNewlines),
                error: response.isSuccess ? nil : (response.error ?? L10n.tr("模块未返回 OK。")),
                elapsedMilliseconds: elapsed,
                timestamp: Date()
            )
            self.tickNumber = 9
            DispatchQueue.main.async { completion(result) }
        }
    }

    func executeVoWiFiAT(
        _ rawCommand: String,
        timeout: Int,
        completion: @escaping (VoWiFiATResult) -> Void
    ) {
        guard VoWiFiSIMBridge.isAllowed(command: rawCommand) else {
            completion(VoWiFiATResult(output: "", error: L10n.tr("VoWiFi 请求了未授权的 AT 命令。")))
            return
        }
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async {
                    completion(VoWiFiATResult(output: "", error: L10n.tr("模块未连接，无法进行 SIM 鉴权。")))
                }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(VoWiFiATResult(output: "", error: L10n.tr("通话期间不能执行 VoWiFi SIM 鉴权。")))
                }
                return
            }
            let response = self.command(
                rawCommand,
                timeout: min(max(timeout, 1_000), 20_000),
                capacity: 256 * 1_024
            )
            let result = VoWiFiATResult(
                output: response.output,
                error: response.isSuccess ? nil : (response.error ?? L10n.tr("SIM AT 命令失败。"))
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    func dial(_ rawNumber: String, completion: @escaping (ModemActionResult) -> Void) {
        guard let number = CallATParser.normalizedDialNumber(rawNumber) else {
            completion(.failure(L10n.tr("号码格式无效；只允许数字和开头的 +。")))
            return
        }
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("模块未连接，无法拨号。"))) }
                return
            }
            guard self.snapshot.simState == .ready else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("SIM 卡尚未就绪，无法拨号。"))) }
                return
            }
            guard self.callSnapshot.canDial,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("当前不能发起新的通话。"))) }
                return
            }
            let token = self.beginCallAction()
            self.voiceAudio.requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard granted else {
                        self.invalidateCallAction()
                        DispatchQueue.main.async {
                            completion(.failure(L10n.tr("需要麦克风权限才能进行通话。请在系统设置中允许后重试。")))
                        }
                        return
                    }
                    guard self.isCurrentCallAction(token),
                          self.callSnapshot.canDial,
                          !self.hasPendingMediaCleanup,
                          self.isOpen else {
                        self.invalidateCallAction()
                        DispatchQueue.main.async {
                            completion(.failure(L10n.tr("拨号准备期间模块或通话状态已改变，请重试。")))
                        }
                        return
                    }
                    self.beginOutgoingCall(number, token: token, completion: completion)
                }
            }
        }
    }

    func answerCall(completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("模块未连接，无法接听。"))) }
                return
            }
            guard self.callSnapshot.phase == .incoming, !self.callActionInFlight else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("当前没有可接听的来电。"))) }
                return
            }
            let token = self.beginCallAction()
            self.voiceAudio.requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard granted else {
                        self.invalidateCallAction()
                        DispatchQueue.main.async {
                            completion(.failure(L10n.tr("需要麦克风权限才能接听。请在系统设置中允许后重试。")))
                        }
                        return
                    }
                    guard self.isCurrentCallAction(token),
                          self.callSnapshot.phase == .incoming,
                          self.isOpen else {
                        self.invalidateCallAction()
                        DispatchQueue.main.async {
                            completion(.failure(L10n.tr("来电已结束或模块已断开。")))
                        }
                        return
                    }
                    self.beginAnsweringCall(token: token, completion: completion)
                }
            }
        }
    }

    func hangUp(completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.callSnapshot.hasCall, !self.callActionInFlight else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("当前没有可挂断的通话。"))) }
                return
            }
            _ = self.beginCallAction()
            let confirmed = self.terminateAndConfirmCall(reason: .localHangup)
            let failure = self.callSnapshot.hasCall
                ? L10n.tr("尚未确认蜂窝通话已结束；应用会保留恢复状态，请重试挂断。")
                : (self.callSnapshot.lastError ?? L10n.tr("通话已结束，但语音媒体清理未完整确认。"))
            DispatchQueue.main.async {
                completion(confirmed
                    ? .success(L10n.tr("通话已结束。"))
                    : .failure(failure))
            }
        }
    }

    func setCallMuted(_ muted: Bool) {
        queue.async { [weak self] in
            guard let self, self.callSnapshot.hasCall else { return }
            self.voiceAudio.setMuted(muted)
            self.callSnapshot.muted = muted
            self.publishCallSnapshot()
        }
    }

    func sendDTMF(_ rawTone: String, completion: @escaping (ModemActionResult) -> Void) {
        guard let command = CallATParser.dtmfCommand(for: rawTone) else {
            completion(.failure(L10n.tr("通话按键无效；只允许单个 0–9、* 或 #。")))
            return
        }
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("模块已断开，无法发送通话按键。"))) }
                return
            }
            guard self.callSnapshot.canSendDTMF,
                  !self.callMediaCleanupPending,
                  !self.callActionInFlight,
                  !self.callCleanupScheduled else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("只有通话接通后才能使用拨号盘。"))) }
                return
            }

            // Do not retry an ambiguous DTMF command: retransmission could make
            // an IVR select the same option twice.
            let response = self.callCommand(command, timeout: 5_000)
            DispatchQueue.main.async {
                completion(response.isSuccess
                    ? .success(nil)
                    : .failure(response.error ?? L10n.tr("模块未接受通话按键。")))
            }
        }
    }

    func sendMessage(
        to destination: String,
        body: String,
        completion: @escaping (SMSMessageSendResult) -> Void
    ) {
        let segments: [SMSSubmitSegment]
        do {
            segments = try SMSPDUEncoder.encode(destination: destination, body: body)
        } catch {
            completion(.failure(error.localizedDescription, isDeliveryUncertain: false))
            return
        }

        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async {
                    completion(.failure(
                        L10n.tr("模块未连接，无法发送短信。"),
                        isDeliveryUncertain: false
                    ))
                }
                return
            }
            guard self.snapshot.simState == .ready else {
                DispatchQueue.main.async {
                    completion(.failure(
                        L10n.tr("SIM 卡尚未就绪，无法发送短信。"),
                        isDeliveryUncertain: false
                    ))
                }
                return
            }
            guard !self.callSnapshot.hasCall else {
                DispatchQueue.main.async {
                    completion(.failure(
                        L10n.tr("通话期间暂不发送短信，请挂断后重试。"),
                        isDeliveryUncertain: false
                    ))
                }
                return
            }

            let pduMode = self.command("AT+CMGF=0", timeout: 3_000)
            guard pduMode.isSuccess else {
                DispatchQueue.main.async {
                    completion(.failure(
                        pduMode.error ?? L10n.tr("模块未能切换到短信 PDU 模式。"),
                        isDeliveryUncertain: false
                    ))
                }
                return
            }

            var confirmedCount = 0
            for segment in segments {
                guard self.isOpen else {
                    let isDeliveryUncertain = confirmedCount > 0
                    let detail = isDeliveryUncertain
                        ? L10n.tr(
                            "已确认发送 %lld/%lld 个分片；接口随后断开，请勿直接重发整条长短信。",
                            Int64(confirmedCount),
                            Int64(segments.count)
                        )
                        : L10n.tr("模块接口已断开，短信未确认发送。")
                    DispatchQueue.main.async {
                        completion(.failure(
                            detail,
                            isDeliveryUncertain: isDeliveryUncertain
                        ))
                    }
                    return
                }

                let response = self.submitSMSPDU(segment)
                let lines = ATResponseParser.normalizedLines(response.output)
                let hasMessageReference = lines.contains { $0.uppercased().hasPrefix("+CMGS:") }
                if response.isSuccess, hasMessageReference {
                    confirmedCount += 1
                    continue
                }

                var details: [String] = []
                if confirmedCount > 0 {
                    details.append(
                        L10n.tr(
                            "已确认发送 %lld/%lld 个分片；请勿直接重发整条长短信，以免前面的分片重复。",
                            Int64(confirmedCount),
                            Int64(segments.count)
                        )
                    )
                }
                let isDeliveryUncertain = confirmedCount > 0 || response.isTransportAmbiguous
                details.append(
                    response.error ?? L10n.tr("模块没有返回 +CMGS 发送确认；当前分片状态未知。")
                )
                DispatchQueue.main.async {
                    completion(.failure(
                        details.joined(separator: "\n"),
                        isDeliveryUncertain: isDeliveryUncertain
                    ))
                }
                return
            }

            let message = segments.count == 1
                ? L10n.tr("短信已发送。")
                : L10n.tr("长短信已分 %lld 条发送。", Int64(segments.count))
            DispatchQueue.main.async { completion(.success(message)) }
        }
    }

    func deleteMessage(
        references: [ModemPDUReference],
        completion: @escaping (ModemActionResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("模块未连接，无法从 SIM/模块中删除短信。"))) }
                return
            }
            // Delete from the highest index down within each storage. MT is a
            // virtual combined view on this module and can refresh its visible
            // indexes after a deletion; descending order avoids invalidating a
            // later target before it is processed.
            let references = SMSDeletionPlanner.orderedTargets(from: references)
            guard !references.isEmpty,
                  references.allSatisfy({
                      ["SM", "ME", "MT"].contains($0.storage.uppercased()) &&
                          $0.index >= 0 &&
                          (try? SMSPDUDecoder.decode($0.rawPDU)) != nil
                  }) else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("短信存储引用无效，已拒绝删除。"))) }
                return
            }
            let originalStorage = self.currentMessageStorage
            func restoreStorage() {
                if let originalStorage { _ = self.selectMessageStorage(originalStorage) }
            }
            func label(_ reference: ModemPDUReference) -> String {
                L10n.tr("%@ 索引 %lld", reference.storage, Int64(reference.index))
            }

            var deletionTargets: [ModemPDUReference] = []
            var preflightErrors: [String] = []
            for reference in references {
                guard self.selectMessageStorage(reference.storage) else {
                    preflightErrors.append(L10n.tr("%@：无法切换存储区", label(reference)))
                    continue
                }
                switch self.inspectExpectedPDU(index: reference.index, expectedPDU: reference.rawPDU) {
                case .exact:
                    deletionTargets.append(reference)
                case .gone:
                    // This also makes a retry after a partial multi-part deletion safe.
                    continue
                case let .unknown(error):
                    preflightErrors.append("\(label(reference))：\(error)")
                }
            }
            guard preflightErrors.isEmpty else {
                restoreStorage()
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法完成删除前校验；未执行新的删除。\n%@", preflightErrors.joined(separator: "\n"))))
                }
                return
            }

            var remaining = deletionTargets
            var lastErrors: [ModemPDUReference: String] = [:]
            var transportLost = false
            for attempt in 0 ..< 4 {
                guard !remaining.isEmpty, !transportLost else { break }
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
                var nextRemaining: [ModemPDUReference] = []

                for target in remaining {
                    guard self.isOpen, self.selectMessageStorage(target.storage) else {
                        nextRemaining.append(target)
                        lastErrors[target] = L10n.tr("无法切换存储区")
                        continue
                    }

                    // Verify immediately before every destructive attempt. A
                    // recycled index with a different PDU is treated as gone,
                    // never as a replacement deletion target.
                    switch self.inspectExpectedPDU(index: target.index, expectedPDU: target.rawPDU) {
                    case .gone:
                        lastErrors.removeValue(forKey: target)
                        continue
                    case let .unknown(error):
                        nextRemaining.append(target)
                        lastErrors[target] = error
                        continue
                    case .exact:
                        break
                    }

                    // CMGR may update the message status before CMGD. Give the
                    // module a short settling window and make delflag=0
                    // explicit so only this verified physical entry is removed.
                    Thread.sleep(forTimeInterval: 0.12)
                    let response = self.command("AT+CMGD=\(target.index),0", timeout: 6_000)
                    if response.isTransportAmbiguous {
                        // The module may have accepted the command. Do not
                        // reconnect and blindly repeat it inside this action.
                        nextRemaining.append(target)
                        lastErrors[target] = response.error ?? L10n.tr("删除响应丢失，等待 AT 接口恢复后再核对")
                        transportLost = true
                        continue
                    }

                    // QDC507/MT can acknowledge CMGD before the combined
                    // storage view has finished updating.
                    Thread.sleep(forTimeInterval: 0.35)
                    guard self.isOpen, self.selectMessageStorage(target.storage) else {
                        nextRemaining.append(target)
                        lastErrors[target] = L10n.tr("删除后无法重新选择存储区")
                        continue
                    }
                    switch self.inspectExpectedPDU(index: target.index, expectedPDU: target.rawPDU) {
                    case .gone:
                        lastErrors.removeValue(forKey: target)
                    case .exact:
                        nextRemaining.append(target)
                        lastErrors[target] = response.isSuccess
                            ? L10n.tr("删除命令返回 OK，但分片仍存在")
                            : (response.error ?? L10n.tr("模块拒绝删除"))
                    case let .unknown(error):
                        nextRemaining.append(target)
                        lastErrors[target] = error
                    }
                }
                remaining = nextRemaining
            }

            // Re-check every original reference, including commands that
            // returned OK. This prevents a delayed or ignored CMGD response
            // from being reported as a successful long-message deletion.
            if !deletionTargets.isEmpty, !transportLost {
                Thread.sleep(forTimeInterval: 0.4)
            }
            var stillPresent: [String] = []
            var verificationErrors: [String] = []
            for item in references {
                guard self.isOpen, self.selectMessageStorage(item.storage) else {
                    verificationErrors.append(L10n.tr("%@：无法切换存储区", label(item)))
                    continue
                }
                switch self.inspectExpectedPDU(index: item.index, expectedPDU: item.rawPDU) {
                case .gone:
                    continue
                case .exact:
                    stillPresent.append(label(item))
                case let .unknown(error):
                    verificationErrors.append(L10n.tr("%@：%@", label(item), lastErrors[item] ?? error))
                }
            }
            restoreStorage()
            self.needsImmediateMessagePoll = true
            if stillPresent.isEmpty, verificationErrors.isEmpty {
                DispatchQueue.main.async { completion(.success()) }
            } else {
                var details: [String] = []
                if !stillPresent.isEmpty {
                    details.append(L10n.tr("自动重试后仍存在的分片：%@", stillPresent.joined(separator: ", ")))
                }
                details += verificationErrors
                DispatchQueue.main.async {
                    completion(.failure(
                        L10n.tr("长短信尚未全部删除；已删除的分片可安全跳过，再次重试不会删除索引中的其他短信。\n%@", details.joined(separator: "\n"))
                    ))
                }
            }
        }
    }

    func configureECM(completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isOpen, let modem = self.modem else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("请先插入蜂窝模块。"))) }
                return
            }
            guard celldock_modem_vendor_id(modem) == 0x2C7C,
                  celldock_modem_product_id(modem) == 0x0125,
                  self.connectedModemMatchesExpectedIdentity() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("当前 AT 接口不是已锁定的 2C7C:0125 模块，未执行配置。")))
                }
                return
            }
            guard self.snapshot.hardwareFamily != .unknown else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("USB 厂商和产品字符串无法识别，未执行持久配置写入。")))
                }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("通话期间不能重启或切换模块网络模式。"))) }
                return
            }
            guard case .empty = self.queryCallPresence() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法确认模块中没有语音通话，未执行配置。")))
                }
                return
            }

            let configurationQuery = self.command("AT+QCFG=\"USBCFG\"", timeout: 5_000)
            guard configurationQuery.isSuccess,
                  let currentConfiguration = ATResponseParser.parseUSBConfiguration(
                      configurationQuery.output
                  ) else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法可靠读取当前 USBCFG，未执行写入。")))
                }
                return
            }
            let mayWriteFullConfiguration = currentConfiguration.isCellDockTarget ||
                (self.snapshot.hardwareFamily == .quectelNativeVoice &&
                    currentConfiguration.isSafeQuectelSource)
            guard mayWriteFullConfiguration else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("当前 USBCFG 不属于已验证的 Quectel 原值或 CellDock 目标值，拒绝写入。")))
                }
                return
            }

            let usbNetQuery = self.command("AT+QCFG=\"usbnet\"", timeout: 3_000)
            guard usbNetQuery.isSuccess,
                  let currentMode = ATResponseParser.parseUSBNetMode(usbNetQuery.output),
                  currentMode == 0 || currentMode == 1 else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("无法可靠读取当前 usbnet 模式，未执行写入。"))) }
                return
            }

            let needsUSBNetWrite = currentMode != 1
            // Native Quectel voice support does not load the QDC507 KO payload,
            // so ADB is not a runtime prerequisite. All other USB capability
            // checks remain unchanged.
            let nativeConfigurationIsReady =
                self.snapshot.hardwareFamily == .quectelNativeVoice &&
                currentConfiguration.supportsNativeQuectelRuntime
            let needsConfigurationWrite = !currentConfiguration.isCellDockTarget &&
                !nativeConfigurationIsReady
            guard needsUSBNetWrite || needsConfigurationWrite else {
                DispatchQueue.main.async {
                    completion(.success(L10n.tr("模块已经是 CDC-ECM 模式。")))
                }
                return
            }

            // usbnet is written first because a USBCFG change may immediately
            // tear down and re-enumerate the current USB composite device.
            if needsUSBNetWrite {
                let writeUSBNet = self.command("AT+QCFG=\"usbnet\",1", timeout: 5_000)
                guard writeUSBNet.isSuccess else {
                    DispatchQueue.main.async {
                        completion(.failure(writeUSBNet.error ?? L10n.tr("模块拒绝切换到 CDC-ECM 模式。")))
                    }
                    return
                }
                let verifyUSBNet = self.command("AT+QCFG=\"usbnet\"", timeout: 3_000)
                guard verifyUSBNet.isSuccess,
                      ATResponseParser.parseUSBNetMode(verifyUSBNet.output) == 1 else {
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("CDC-ECM 写入后的读回校验失败，未继续修改 USB 配置。")))
                    }
                    return
                }
            }

            if needsConfigurationWrite {
                let writeConfiguration = self.command(
                    ModemUSBConfiguration.cellDockFullTarget.usbcfgWriteCommand,
                    timeout: 8_000
                )
                if writeConfiguration.isTransportAmbiguous {
                    self.beginExpectedModuleRestart()
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("USBCFG 写入响应不明确，CellDock 未自动重试；正在等待 USB 重新枚举并回读实际状态。")))
                    }
                    return
                }
                guard writeConfiguration.isSuccess else {
                    DispatchQueue.main.async {
                        completion(.failure(writeConfiguration.error ?? L10n.tr("模块拒绝写入完整 USB 配置。")))
                    }
                    return
                }
                let verifyConfiguration = self.command("AT+QCFG=\"USBCFG\"", timeout: 5_000)
                if verifyConfiguration.isTransportAmbiguous {
                    self.beginExpectedModuleRestart()
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("USBCFG 已写入，但模块在回读前重新枚举；CellDock 不会重复写入，将在重连后核对。")))
                    }
                    return
                }
                guard verifyConfiguration.isSuccess,
                      ATResponseParser.parseUSBConfiguration(
                          verifyConfiguration.output
                      )?.isCellDockTarget == true else {
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("USBCFG 写入后的精确读回校验失败，未重启模块。")))
                    }
                    return
                }
            }

            self.snapshot.usbConfiguration = needsConfigurationWrite
                ? .cellDockFullTarget
                : currentConfiguration
            self.snapshot.usbNetMode = 1
            _ = self.command("AT+CFUN=1,1", timeout: 1_000)
            self.beginExpectedModuleRestart()
            DispatchQueue.main.async {
                completion(.success(
                    needsConfigurationWrite
                        ? L10n.tr("已写入完整 USB 配置并启用 CDC-ECM，模块正在重新枚举。")
                        : L10n.tr("已切换 CDC-ECM，模块正在重新枚举。")
                ))
            }
        }
    }

    func convertDJIModuleIdentity(completion: @escaping (ModemActionResult) -> Void) {
        queue.async { [weak self] in
            guard let self, self.isOpen, let modem = self.modem else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("请先插入 DJI 4G 模块。"))) }
                return
            }
            guard celldock_modem_vendor_id(modem) == 0x2CA3,
                  celldock_modem_product_id(modem) == 0x4006,
                  self.connectedModemMatchesExpectedIdentity() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("当前 AT 接口不是已锁定的 2CA3:4006 模块，未执行转换。")))
                }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("通话或语音清理期间不能转换模块身份。")))
                }
                return
            }
            guard case .empty = self.queryCallPresence() else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法确认模块中没有语音通话，未执行转换。")))
                }
                return
            }

            let challengeResponse = self.command("AT+QADBKEY?", timeout: 3_000)
            guard challengeResponse.isSuccess,
                  let challenge = ATResponseParser.parseQADBKeyChallenge(challengeResponse.output),
                  let unlockKey = QADBKeyDeriver.response(for: challenge) else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法读取或计算模组解锁码，未执行配置写入。")))
                }
                return
            }
            let unlock = self.command("AT+QADBKEY=\"\(unlockKey)\"", timeout: 5_000)
            guard unlock.isSuccess else {
                DispatchQueue.main.async {
                    completion(.failure(unlock.error ?? L10n.tr("模组拒绝解锁，未执行配置写入。")))
                }
                return
            }

            let usbConfigurationResponse = self.command("AT+QCFG=\"USBCFG\"", timeout: 5_000)
            guard usbConfigurationResponse.isSuccess,
                  let currentConfiguration = ATResponseParser.parseUSBConfiguration(
                      usbConfigurationResponse.output
                  ),
                  currentConfiguration.isSafeIdentityConversionSource else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("当前 USBCFG 不是已验证的 DJI 原值、过渡值或 CellDock 目标值，拒绝写入。")))
                }
                return
            }

            if !currentConfiguration.audioEnabled {
                let pcmCapability = self.command("AT+QPCMV=?", timeout: 5_000)
                let advertisesUACMode = ATResponseParser.normalizedLines(pcmCapability.output)
                    .contains { $0.uppercased().hasPrefix("+QPCMV:") && $0.contains("0-2") }
                guard pcmCapability.isSuccess, advertisesUACMode else {
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("模块未报告 QPCMV 0-2 能力，拒绝启用 CellDock USB 音频配置。")))
                    }
                    return
                }
            }

            let usbNetResponse = self.command("AT+QCFG=\"usbnet\"", timeout: 5_000)
            guard usbNetResponse.isSuccess,
                  let usbNetMode = ATResponseParser.parseUSBNetMode(usbNetResponse.output),
                  usbNetMode == 0 || usbNetMode == 1 else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法确认 usbnet 是 0 或 1，未执行转换。")))
                }
                return
            }

            if !currentConfiguration.isCellDockTarget {
                let targetCommand = ModemUSBConfiguration.maVoTarget.usbcfgWriteCommand
                let write = self.command(targetCommand, timeout: 8_000)
                if write.isTransportAmbiguous {
                    self.beginExpectedModuleRestart()
                    DispatchQueue.main.async {
                        completion(.failure(
                            L10n.tr("USBCFG 写入响应不明确，CellDock 未自动重试；正在等待 USB 重新枚举并回读实际状态。")
                        ))
                    }
                    return
                }
                guard write.isSuccess else {
                    DispatchQueue.main.async {
                        completion(.failure(write.error ?? L10n.tr("模块拒绝转换 USB 身份。")))
                    }
                    return
                }

                let readBack = self.command("AT+QCFG=\"USBCFG\"", timeout: 5_000)
                guard readBack.isSuccess,
                      ATResponseParser.parseUSBConfiguration(readBack.output)?.isCellDockTarget == true else {
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("USB 身份写入后的精确回读校验失败，未重启模块。")))
                    }
                    return
                }
            }

            if usbNetMode == 0 {
                let writeUSBNet = self.command("AT+QCFG=\"usbnet\",1", timeout: 5_000)
                guard writeUSBNet.isSuccess else {
                    DispatchQueue.main.async {
                        completion(.failure(writeUSBNet.error ?? L10n.tr("USB 身份已转换，但 CDC-ECM 写入失败；未重启。")))
                    }
                    return
                }
                let verifyUSBNet = self.command("AT+QCFG=\"usbnet\"", timeout: 5_000)
                guard verifyUSBNet.isSuccess,
                      ATResponseParser.parseUSBNetMode(verifyUSBNet.output) == 1 else {
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("CDC-ECM 写入后的回读校验失败，未重启模块。")))
                    }
                    return
                }
            }

            let finalConfiguration = self.command("AT+QCFG=\"USBCFG\"", timeout: 5_000)
            guard finalConfiguration.isSuccess,
                  ATResponseParser.parseUSBConfiguration(finalConfiguration.output)?.isCellDockTarget == true else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("重启前无法再次确认 CellDock USB 目标配置，已停止。")))
                }
                return
            }

            self.snapshot.usbConfiguration = .maVoTarget
            self.snapshot.usbNetMode = 1
            _ = self.command("AT+CFUN=1,1", timeout: 1_000)
            self.beginExpectedModuleRestart()
            DispatchQueue.main.async {
                completion(.success(L10n.tr("已转换为 2C7C:0125，并启用 ADB、USB 通话音频与 CDC-ECM，模块正在重新枚举。")))
            }
        }
    }

    func setIncomingCallsEnabled(
        _ enabled: Bool,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.isOpen else {
                DispatchQueue.main.async { completion(.failure(L10n.tr("请先插入 QDC507 模块。"))) }
                return
            }
            guard !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  !self.callActionInFlight else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("通话或语音清理期间不能切换来电设置。")))
                }
                return
            }

            let targetMode = enabled ? 1 : 0
            let query = self.command("AT+QCFG=\"ims\"", timeout: 5_000)
            guard query.isSuccess,
                  let currentMode = ATResponseParser.parseIMSMode(query.output) else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("无法可靠读取当前 IMS 模式，未执行写入。")))
                }
                return
            }

            if enabled {
                let volte = self.command("AT+QCFG=\"volte_disable\"", timeout: 5_000)
                guard volte.isSuccess,
                      ATResponseParser.parseVoLTEDisabled(volte.output) == false else {
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("无法确认 VoLTE 已启用，未修改 IMS 或重启模块。")))
                    }
                    return
                }
            }

            if currentMode == targetMode {
                self.snapshot.imsMode = targetMode
                self.snapshot.volteSessionAvailable = ATResponseParser.parseVoLTESessionAvailable(query.output)
                self.publishSnapshot(self.snapshot)
                DispatchQueue.main.async {
                    completion(.success(enabled ? L10n.tr("接收来电已经开启。") : L10n.tr("接收来电已经关闭。")))
                }
                return
            }

            let write = self.command("AT+QCFG=\"ims\",\(targetMode)", timeout: 8_000)
            guard write.isSuccess else {
                DispatchQueue.main.async {
                    completion(.failure(write.error ?? L10n.tr("模块拒绝修改 IMS 模式。")))
                }
                return
            }

            let verify = self.command("AT+QCFG=\"ims\"", timeout: 5_000)
            guard verify.isSuccess,
                  ATResponseParser.parseIMSMode(verify.output) == targetMode else {
                DispatchQueue.main.async {
                    completion(.failure(L10n.tr("IMS 写入后的回读校验失败，未重启模块。")))
                }
                return
            }

            self.snapshot.imsMode = targetMode
            self.snapshot.volteSessionAvailable = ATResponseParser.parseVoLTESessionAvailable(verify.output)
            self.publishSnapshot(self.snapshot)
            _ = self.command("AT+CFUN=1,1", timeout: 1_000)
            self.beginExpectedModuleRestart()
            DispatchQueue.main.async {
                completion(.success(
                    enabled
                        ? L10n.tr("已开启接收来电，模块正在重启。")
                        : L10n.tr("已关闭接收来电，模块正在重启。")
                ))
            }
        }
    }

    private func beginOutgoingCall(
        _ number: String,
        token: CallActionToken,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        callSnapshot.phase = .dialing
        callSnapshot.direction = .outgoing
        callSnapshot.number = number
        callSnapshot.startedAt = nil
        callSnapshot.clearEnd()
        callSnapshot.lastError = nil
        callStateChangedAt = Date()
        callPollMisses = 0
        publishCallSnapshot()

        if callMediaBackend == .qdcUAC {
            beginQDCOutgoingCall(number, token: token, completion: completion)
            return
        }

        preparePCMSessionAndAudio(token: token) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                self.failCallSetup(result, completion: completion)
                return
            }
            guard self.isCurrentCallAction(token),
                  self.callSnapshot.phase == .dialing,
                  !self.callCleanupScheduled else {
                self.failCallSetup(
                    .failure(L10n.tr("拨号准备期间通话状态已改变。")),
                    completion: completion
                )
                return
            }
            let dial = self.callCommand("ATD\(number);", timeout: 12_000)
            guard dial.isSuccess else {
                if dial.isTransportAmbiguous {
                    self.reconcileAmbiguousStart(completion: completion)
                    return
                }
                self.failCallSetup(
                    .failure(dial.error ?? self.callFailureMessage(from: dial.output)),
                    completion: completion
                )
                return
            }
            self.voiceAudio.setMediaEnabled(true)
            self.callSnapshot.audioActive = true
            self.callActionInFlight = false
            self.callStateChangedAt = Date()
            self.publishCallSnapshot()
            DispatchQueue.main.async { completion(.success(L10n.tr("正在拨号…"))) }
        }
    }

    private func beginAnsweringCall(
        token: CallActionToken,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        callSnapshot.lastError = nil
        callSnapshot.clearEnd()
        publishCallSnapshot()
        if callMediaBackend == .qdcUAC {
            beginQDCAnsweringCall(token: token, completion: completion)
            return
        }
        preparePCMSessionAndAudio(token: token) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                self.failCallSetup(result, completion: completion, preserveIncoming: true)
                return
            }
            guard self.isCurrentCallAction(token),
                  self.callSnapshot.phase == .incoming,
                  !self.callCleanupScheduled else {
                self.failCallSetup(
                    .failure(L10n.tr("来电已在接听准备期间结束。")),
                    completion: completion
                )
                return
            }
            let answer = self.callCommand("ATA", timeout: 12_000)
            guard answer.isSuccess else {
                if answer.isTransportAmbiguous {
                    self.reconcileAmbiguousStart(completion: completion)
                    return
                }
                self.failCallSetup(
                    .failure(answer.error ?? self.callFailureMessage(from: answer.output)),
                    completion: completion,
                    preserveIncoming: true
                )
                return
            }
            self.voiceAudio.setMediaEnabled(true)
            self.callSnapshot.phase = .active
            self.callSnapshot.audioActive = true
            self.callSnapshot.startedAt = Date()
            self.callActionInFlight = false
            self.callStateChangedAt = Date()
            self.callPollMisses = 0
            self.publishCallSnapshot()
            DispatchQueue.main.async { completion(.success(L10n.tr("通话已接通。"))) }
        }
    }

    private func beginQDCOutgoingCall(
        _ number: String,
        token: CallActionToken,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard let modem, moduleVoiceRuntime != nil else {
            failCallSetup(
                .failure(L10n.tr("QDC507 UAC 通话运行时未初始化。")),
                completion: completion
            )
            return
        }
        let vendorID = celldock_modem_vendor_id(modem)
        let productID = celldock_modem_product_id(modem)
        voiceAudio.validateUAC(
            vendorID: vendorID,
            productID: productID,
            matchingLocationID: modemLocationID
        ) { [weak self] validation in
            guard let self else { return }
            self.queue.async {
                guard self.isCurrentCallAction(token),
                      self.callSnapshot.phase == .dialing,
                      self.isOpen else {
                    self.invalidateCallAction()
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("UAC 预检期间模块或通话状态已改变。")))
                    }
                    return
                }
                guard case let .success(uid?) = validation, !uid.isEmpty else {
                    let error: String
                    if case let .failure(message) = validation {
                        error = message
                    } else {
                        error = L10n.tr("UAC 预检没有返回可绑定的设备 UID。")
                    }
                    self.failCallSetup(.failure(error), completion: completion)
                    return
                }

                let mediaSession = self.makePendingQDCMediaSession(
                    direction: .outgoing,
                    preferredUACUID: uid
                )
                let dial = self.callCommand("ATD\(number);", timeout: 12_000)
                guard dial.isSuccess else {
                    if dial.isTransportAmbiguous {
                        self.reconcileAmbiguousQDCStart(
                            mediaSession: mediaSession,
                            completion: completion
                        )
                        return
                    }
                    self.cancelPendingQDCMediaSession()
                    self.failCallSetup(
                        .failure(dial.error ?? self.callFailureMessage(from: dial.output)),
                        completion: completion
                    )
                    return
                }
                self.invalidateCallAction()
                self.callSnapshot.audioActive = false
                self.callStateChangedAt = Date()
                self.publishCallSnapshot()
                DispatchQueue.main.async { completion(.success(L10n.tr("正在拨号…"))) }
                self.queue.async { [weak self] in self?.refreshCallState() }
            }
        }
    }

    private func beginQDCAnsweringCall(
        token: CallActionToken,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard let modem, moduleVoiceRuntime != nil else {
            failCallSetup(
                .failure(L10n.tr("QDC507 UAC 通话运行时未初始化。")),
                completion: completion,
                preserveIncoming: true
            )
            return
        }
        let vendorID = celldock_modem_vendor_id(modem)
        let productID = celldock_modem_product_id(modem)
        voiceAudio.validateUAC(
            vendorID: vendorID,
            productID: productID,
            matchingLocationID: modemLocationID
        ) { [weak self] validation in
            guard let self else { return }
            self.queue.async {
                guard self.isCurrentCallAction(token),
                      self.callSnapshot.phase == .incoming,
                      self.isOpen else {
                    self.invalidateCallAction()
                    DispatchQueue.main.async {
                        completion(.failure(L10n.tr("UAC 预检期间来电或模块状态已改变。")))
                    }
                    return
                }
                guard case let .success(uid?) = validation, !uid.isEmpty else {
                    let error: String
                    if case let .failure(message) = validation {
                        error = message
                    } else {
                        error = L10n.tr("UAC 预检没有返回可绑定的设备 UID。")
                    }
                    self.failCallSetup(
                        .failure(error),
                        completion: completion,
                        preserveIncoming: true
                    )
                    return
                }

                let mediaSession = self.makePendingQDCMediaSession(
                    direction: .incoming,
                    preferredUACUID: uid
                )
                let answer = self.callCommand("ATA", timeout: 12_000)
                guard answer.isSuccess else {
                    if answer.isTransportAmbiguous {
                        self.reconcileAmbiguousQDCStart(
                            mediaSession: mediaSession,
                            completion: completion
                        )
                        return
                    }
                    self.cancelPendingQDCMediaSession()
                    self.failCallSetup(
                        .failure(answer.error ?? self.callFailureMessage(from: answer.output)),
                        completion: completion,
                        preserveIncoming: true
                    )
                    return
                }
                self.invalidateCallAction()
                self.callSnapshot.audioActive = false
                self.callStateChangedAt = Date()
                self.publishCallSnapshot()
                DispatchQueue.main.async { completion(.success(L10n.tr("正在接通…"))) }
                self.queue.async { [weak self] in self?.refreshCallState() }
            }
        }
    }

    private func reconcileAmbiguousQDCStart(
        mediaSession: PendingQDCMediaSession,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        callSnapshot.phase = .recovering
        callSnapshot.lastError = L10n.tr("通话命令响应丢失，正在读取 CLCC…")
        publishCallSnapshot()
        switch queryCallPresence() {
        case let .present(calls):
            guard let primary = calls.first(where: {
                $0.direction == mediaSession.direction
            }) else {
                cancelPendingQDCMediaSession()
                failCallSetup(
                    .failure(L10n.tr("CLCC 中没有找到本次通话。")),
                    completion: completion
                )
                return
            }
            applyCallInfo(primary)
            invalidateCallAction()
            callSnapshot.lastError = nil
            publishCallSnapshot()
            DispatchQueue.main.async {
                completion(.success(L10n.tr("命令响应丢失，但已从 CLCC 恢复通话状态。")))
            }
        case .empty:
            cancelPendingQDCMediaSession()
            failCallSetup(.failure(L10n.tr("模块未建立通话。")), completion: completion)
        case let .unknown(error):
            invalidateCallAction()
            callSnapshot.phase = .recovering
            callSnapshot.audioActive = false
            callSnapshot.lastError = L10n.tr("通话状态未确认：%@", error)
            publishCallSnapshot()
            DispatchQueue.main.async {
                completion(.failure(L10n.tr("通话状态尚未确认；请点击“重试挂断”。")))
            }
        case .differentDevice:
            cancelPendingQDCMediaSession()
            invalidateCallAction()
            callSnapshot.phase = .recovering
            callSnapshot.audioActive = false
            callSnapshot.lastError = L10n.tr("原通话模块已不可达；未把其他模块当作同一通话。")
            publishCallSnapshot()
            DispatchQueue.main.async {
                completion(.failure(L10n.tr("通话准备期间模块已更换。")))
            }
        }
    }

    private func makePendingQDCMediaSession(
        direction: CallDirection,
        preferredUACUID: String
    ) -> PendingQDCMediaSession {
        qdcMediaSessionID &+= 1
        qdcMediaStartInFlight = false
        let session = PendingQDCMediaSession(
            id: qdcMediaSessionID,
            modemGeneration: modemGeneration,
            registryID: modemRegistryID,
            direction: direction,
            preferredUACUID: preferredUACUID,
            callIndex: nil
        )
        pendingQDCMediaSession = session
        return session
    }

    private func cancelPendingQDCMediaSession() {
        qdcMediaSessionID &+= 1
        pendingQDCMediaSession = nil
        qdcMediaStartInFlight = false
    }

    private func isCurrentQDCMediaSession(_ session: PendingQDCMediaSession) -> Bool {
        pendingQDCMediaSession?.id == session.id &&
            qdcMediaSessionID == session.id &&
            modemGeneration == session.modemGeneration &&
            modemRegistryID == session.registryID
    }

    private func activeCallMatches(_ session: PendingQDCMediaSession) -> Bool {
        switch queryCallPresence() {
        case let .present(calls):
            guard calls.count == 1, let call = calls.first,
                  call.status == .active,
                  call.direction == session.direction else {
                return false
            }
            return session.callIndex == nil || session.callIndex == call.index
        case .empty, .unknown, .differentDevice:
            return false
        }
    }

    private func startQDCMediaIfNeeded(for info: ModemCallInfo) {
        guard callMediaBackend == .qdcUAC,
              info.status == .active,
              !callSnapshot.audioActive,
              !voiceAudio.isRunning,
              !pcmSessionEnabled,
              !qdcMediaStartInFlight,
              var session = pendingQDCMediaSession,
              session.direction == info.direction,
              isCurrentQDCMediaSession(session),
              let runtime = moduleVoiceRuntime,
              let modem else {
            return
        }
        if let callIndex = session.callIndex, callIndex != info.index { return }
        session.callIndex = info.index
        pendingQDCMediaSession = session
        guard activeCallMatches(session) else { return }

        qdcMediaStartInFlight = true
        pcmSessionEnabled = true
        do {
            try runtime.startRouteOnly()
        } catch {
            handleQDCMediaStartFailure(
                L10n.error("无法启动 QDC507 D4/UAC 路由：%@", underlying: error),
                session: session
            )
            return
        }
        guard isCurrentQDCMediaSession(session), activeCallMatches(session) else {
            handleQDCMediaStartFailure(
                L10n.tr("D4 路由启动后，本次 active CLCC 已无法确认。"),
                session: session
            )
            return
        }

        let vendorID = celldock_modem_vendor_id(modem)
        let productID = celldock_modem_product_id(modem)
        voiceAudio.startUAC(
            vendorID: vendorID,
            productID: productID,
            matchingLocationID: modemLocationID,
            preferredUID: session.preferredUACUID
        ) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.isCurrentQDCMediaSession(session) else { return }
                self.qdcMediaStartInFlight = false
                switch result {
                case .success:
                    guard self.activeCallMatches(session) else {
                        self.handleQDCMediaStartFailure(
                            L10n.tr("CoreAudio 启动后，本次 active CLCC 已无法确认。"),
                            session: session
                        )
                        return
                    }
                    self.voiceAudio.setMediaEnabled(true)
                    self.callSnapshot.audioActive = true
                    self.callSnapshot.lastError = nil
                    self.publishCallSnapshot()
                case let .failure(message):
                    self.handleQDCMediaStartFailure(
                        L10n.tr("QDC507 UAC 启动失败：%@", message),
                        session: session
                    )
                }
            }
        }
    }

    private func handleQDCMediaStartFailure(
        _ message: String,
        session: PendingQDCMediaSession
    ) {
        guard isCurrentQDCMediaSession(session) else { return }
        qdcMediaStartInFlight = false
        callSnapshot.audioActive = false
        callSnapshot.lastError = message
        publishCallSnapshot()
        let confirmed = terminateAndConfirmCall(reason: .failed)
        if confirmed {
            callSnapshot.lastError = message
            publishCallSnapshot()
        }
    }

    private func reconcileAmbiguousStart(
        completion: @escaping (ModemActionResult) -> Void
    ) {
        callSnapshot.phase = .recovering
        callSnapshot.lastError = L10n.tr("通话命令响应丢失，正在读取 CLCC…")
        publishCallSnapshot()
        switch queryCallPresence() {
        case let .present(calls):
            if let primary = calls.first { applyCallInfo(primary) }
            voiceAudio.setMediaEnabled(true)
            callSnapshot.audioActive = voiceAudio.isRunning
            invalidateCallAction()
            publishCallSnapshot()
            DispatchQueue.main.async {
                completion(.success(L10n.tr("命令响应丢失，但已从 CLCC 恢复通话状态。")))
            }
        case .empty:
            failCallSetup(
                .failure(L10n.tr("模块未建立通话。")),
                completion: completion
            )
        case let .unknown(error):
            _ = stopVoiceAudioAndWait()
            invalidateCallAction()
            callSnapshot.phase = .recovering
            callSnapshot.audioActive = false
            callSnapshot.lastError = L10n.tr("通话状态未确认：%@", error)
            publishCallSnapshot()
            DispatchQueue.main.async {
                completion(.failure(L10n.tr("通话状态尚未确认；请点击“重试挂断”。")))
            }
        case .differentDevice:
            pcmSessionEnabled = false
            _ = stopVoiceAudioAndWait()
            invalidateCallAction()
            callSnapshot.phase = .recovering
            callSnapshot.audioActive = false
            callSnapshot.lastError = L10n.tr("原通话模块已不可达；未把其他模块当作同一通话。")
            publishCallSnapshot()
            DispatchQueue.main.async {
                completion(.failure(L10n.tr("通话准备期间模块已更换。")))
            }
        }
    }

    private func preparePCMSessionAndAudio(
        token: CallActionToken,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        guard isOpen,
              callSnapshot.voiceOverUSBSupported,
              isCurrentCallAction(token),
              modemLocationID != 0 else {
            completion(.failure(L10n.tr("当前固件未确认支持 USB 原始语音。")))
            return
        }
        switch callMediaBackend {
        case .qdcUAC:
            completion(.failure(
                L10n.tr("QDC507 UAC 必须等 active CLCC 后启动；拒绝执行拨号前媒体初始化。")
            ))
        case .qpcmv, .qdcModuleBridge:
            prepareRawPCMSessionAndAudio(
                token: token,
                fallbackFrom: nil,
                completion: completion
            )
        case .none:
            completion(.failure(L10n.tr("当前模块没有可用的通话媒体后端。")))
        }
    }

    private func prepareRawPCMSessionAndAudio(
        token: CallActionToken,
        fallbackFrom uacError: String?,
        completion: @escaping (ModemActionResult) -> Void
    ) {
        let gps = command("AT+QGPS?", timeout: 2_000)
        let gpsActive = gps.isSuccess && ATResponseParser.normalizedLines(gps.output)
            .map { $0.replacingOccurrences(of: " ", with: "").uppercased() }
            .contains("+QGPS:1")
        guard !gpsActive else {
            let rawError = L10n.tr("GNSS 正在使用 USB NMEA 口，不能启用 interface 1 原始语音。")
            completion(.failure(
                uacError.map { L10n.tr("UAC 启动失败：%@\n原始 PCM 备用通道不可用：%@", $0, rawError) }
                    ?? rawError
            ))
            return
        }
        guard isCurrentCallAction(token) else {
            completion(.failure(L10n.tr("启动原始语音期间模块状态已改变。")))
            return
        }

        voiceAudio.setPCMFlowReady(true)
        switch callMediaBackend {
        case .qpcmv:
            pcmSessionEnabled = true
            let reset = command("AT+QPCMV=0", timeout: 3_000)
            guard reset.isSuccess, isCurrentCallAction(token) else {
                let cleaned = disablePCMSessionIfNeeded()
                completion(.failure(
                    (reset.error ?? L10n.tr("模块拒绝重置 USB 语音会话。")) +
                        (cleaned ? "" : L10n.tr("\nUSB 语音状态未知，应用会继续重试清理。"))
                ))
                return
            }
            let enable = command("AT+QPCMV=1,0", timeout: 3_000)
            guard enable.isSuccess, isCurrentCallAction(token) else {
                let cleaned = disablePCMSessionIfNeeded()
                completion(.failure(
                    (enable.error ?? L10n.tr("模块拒绝开启 USB interface 1 语音。")) +
                        (cleaned ? "" : L10n.tr("\nUSB 语音状态未知，应用会继续重试清理。"))
                ))
                return
            }
        case .qdcModuleBridge:
            guard let moduleVoiceRuntime else {
                completion(.failure(L10n.tr("QDC507 通话运行时未初始化。")))
                return
            }
            // startBridge sends S and starts a process. Retain cleanup
            // ownership even when its final ADB response is lost.
            pcmSessionEnabled = true
            do {
                try moduleVoiceRuntime.startBridge()
            } catch {
                let rawError = L10n.error("无法启动 QDC507 PCM 桥：%@", underlying: error)
                let cleaned = disablePCMSessionIfNeeded()
                let cleanupSuffix = cleaned
                    ? ""
                    : L10n.tr("\nPCM 桥状态未知，应用会继续重试清理。")
                completion(.failure(
                    (uacError.map {
                        L10n.tr("UAC 启动失败：%@\n原始 PCM 备用通道也失败：%@", $0, rawError)
                    } ?? rawError) + cleanupSuffix
                ))
                return
            }
            guard isCurrentCallAction(token) else {
                _ = disablePCMSessionIfNeeded()
                completion(.failure(L10n.tr("启动语音期间模块状态已改变。")))
                return
            }
        case .qdcUAC, .none:
            completion(.failure(L10n.tr("原始 PCM 后端状态无效。")))
            return
        }
        voiceAudio.start(matchingLocationID: modemLocationID) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.isOpen, self.isCurrentCallAction(token) else {
                    _ = self.stopVoiceAudioAndWait()
                    if self.modemGeneration == token.modemGeneration,
                       self.modemRegistryID == token.registryID {
                        self.disablePCMSessionIfNeeded()
                    } else {
                        self.pcmSessionEnabled = false
                    }
                    completion(.failure(L10n.tr("模块或通话操作在准备语音时已改变。")))
                    return
                }
                if case .failure = result {
                    self.disablePCMSessionIfNeeded()
                    if let uacError,
                       case let .failure(rawError) = result {
                        completion(.failure(
                            L10n.tr("UAC 启动失败：%@\n原始 PCM 备用通道也失败：%@", uacError, rawError)
                        ))
                        return
                    }
                }
                completion(result)
            }
        }
    }

    private func failCallSetup(
        _ result: ModemActionResult,
        completion: @escaping (ModemActionResult) -> Void,
        preserveIncoming: Bool = false
    ) {
        let mediaCleaned = cleanupCallMedia()
        invalidateCallAction()
        var message: String
        if case let .failure(error) = result {
            message = error
        } else {
            message = L10n.tr("通话准备失败。")
        }
        if !mediaCleaned {
            message += L10n.tr("\n语音媒体清理未完整确认，应用会继续重试。")
        }
        if preserveIncoming {
            callSnapshot.phase = .incoming
            callSnapshot.audioActive = false
            callSnapshot.lastError = message
            publishCallSnapshot()
        } else {
            setCallIdle(reason: .failed, error: message)
        }
        DispatchQueue.main.async { completion(.failure(message)) }
    }

    @discardableResult
    private func disablePCMSessionIfNeeded() -> Bool {
        guard pcmSessionEnabled else { return true }
        let stopped: Bool
        switch callMediaBackend {
        case .qpcmv:
            guard isOpen else { return false }
            stopped = command("AT+QPCMV=0", timeout: 3_000).isSuccess
        case .qdcUAC:
            if let moduleVoiceRuntime {
                do {
                    try moduleVoiceRuntime.stopRouteOnly()
                    stopped = true
                } catch {
                    callSnapshot.lastError = L10n.error(
                        "模块 UAC 语音路由清理失败：%@",
                        underlying: error
                    )
                    stopped = false
                }
            } else {
                stopped = false
            }
        case .qdcModuleBridge:
            if let moduleVoiceRuntime {
                do {
                    try moduleVoiceRuntime.stopBridge()
                    stopped = true
                } catch {
                    callSnapshot.lastError = L10n.error(
                        "模块 PCM 桥清理失败：%@",
                        underlying: error
                    )
                    stopped = false
                }
            } else {
                stopped = false
            }
        case .none:
            stopped = true
        }
        if stopped {
            pcmSessionEnabled = false
        } else {
            switch callMediaBackend {
            case .qdcUAC where callSnapshot.lastError == nil:
                callSnapshot.lastError = L10n.tr("模块 UAC 语音路由清理失败，稍后将重试。")
            case .qdcModuleBridge where callSnapshot.lastError == nil:
                callSnapshot.lastError = L10n.tr("模块 PCM 桥清理失败，稍后将重试。")
            case .qpcmv:
                callSnapshot.lastError = L10n.tr("模块拒绝关闭 USB 语音会话，稍后将重试。")
            case .qdcUAC, .qdcModuleBridge, .none:
                break
            }
        }
        return stopped
    }

    private func scheduleCallCleanup(reason: CallEndReason, evidence: CallEndEvidence) {
        callSnapshot.recordEnd(reason, evidence: evidence)
        guard !callCleanupScheduled else { return }
        callCleanupScheduled = true
        cancelPendingQDCMediaSession()
        voiceAudio.setMediaEnabled(false)
        callSnapshot.audioActive = false
        publishCallSnapshot()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.callSnapshot.hasCall || self.pcmSessionEnabled else {
                self.callCleanupScheduled = false
                return
            }
            switch self.queryCallPresence() {
            case .empty:
                _ = self.finishConfirmedCallEnd(
                    reason: self.callSnapshot.lastEndReason ?? reason,
                    evidence: self.callSnapshot.lastEndEvidence ?? evidence
                )
            case let .present(calls):
                if let primary = calls.first { self.applyCallInfo(primary) }
                self.callSnapshot.lastError = L10n.tr("收到通话结束提示，但 CLCC 仍报告语音通话。")
                self.publishCallSnapshot()
            case let .unknown(error):
                self.callSnapshot.phase = .recovering
                self.callSnapshot.lastError = L10n.tr("通话结束后尚未确认 CLCC 已清空：%@", error)
                self.publishCallSnapshot()
            case .differentDevice:
                self.callSnapshot.phase = .recovering
                self.callSnapshot.lastError = L10n.tr("原通话模块不可达，无法确认 CLCC 已清空。")
                self.publishCallSnapshot()
            }
            self.callCleanupScheduled = false
        }
    }

    @discardableResult
    private func finishConfirmedCallEnd(reason: CallEndReason, evidence: CallEndEvidence) -> Bool {
        voiceAudio.setMediaEnabled(false)
        let fullyClean = cleanupCallMedia()
        let cleanupError = callSnapshot.lastError
        invalidateCallAction()
        setCallIdle(
            reason: reason,
            evidence: evidence,
            error: fullyClean
                ? nil
                : (cleanupError ?? L10n.tr("通话已结束，但语音媒体清理未完整确认。"))
        )
        if fullyClean, needsPostCallInitialization, isOpen, !isShuttingDown {
            needsPostCallInitialization = false
            initializeConnectedModem()
        }
        return fullyClean
    }

    @discardableResult
    private func cleanupCallMedia() -> Bool {
        cancelPendingQDCMediaSession()
        let audioStopped = stopVoiceAudioAndWait()
        let uacResolved = !voiceAudio.hasUnresolvedUACCleanup
        let backendStopped = disablePCMSessionIfNeeded()
        let fullyClean = audioStopped && uacResolved && backendStopped
        callMediaCleanupPending = !fullyClean
        return fullyClean
    }

    private var hasPendingMediaCleanup: Bool {
        callMediaCleanupPending || pcmSessionEnabled || voiceAudio.hasUnresolvedUACCleanup
    }

    private func queryCallPresence() -> CallPresence {
        guard let modem else { return .unknown(L10n.tr("AT 桥未初始化")) }
        if !isOpen {
            guard modemLocationID != 0 else {
                return .unknown(L10n.tr("原模块缺少可绑定的 USB locationID"))
            }
            let result = celldock_modem_open_for_location(modem, modemLocationID)
            if result == CELLDOCK_MODEM_NOT_FOUND {
                return .differentDevice
            }
            guard result == CELLDOCK_MODEM_OK else {
                return .unknown(lastBridgeError())
            }
            let sameDevice = connectedModemMatchesExpectedIdentity()
            if !sameDevice {
                celldock_modem_close(modem)
            }
            guard sameDevice else { return .differentDevice }
            consumeBufferedURCsBeforeCommands()
        }

        let response = command("AT+CLCC", timeout: 3_000)
        guard response.isSuccess else {
            return .unknown(response.error ?? L10n.tr("无法读取 CLCC"))
        }
        let calls = CallATParser.parseCLCCResponse(response.output)
        return calls.isEmpty ? .empty : .present(calls)
    }

    @discardableResult
    private func terminateAndConfirmCall(reason: CallEndReason) -> Bool {
        cancelPendingQDCMediaSession()
        callSnapshot.phase = .ending
        callSnapshot.lastError = nil
        callSnapshot.audioActive = false
        voiceAudio.setMediaEnabled(false)
        publishCallSnapshot()

        var explicitEnd = false
        if isOpen {
            let hangup = callCommand("ATH", timeout: 3_000)
            let uppercase = hangup.output.uppercased()
            explicitEnd = uppercase.contains("NO CARRIER")
        }
        var lastError = explicitEnd
            ? L10n.tr("已收到 NO CARRIER，但仍需独立确认 CLCC 已清空")
            : L10n.tr("无法确认 CLCC 已清空")
        for attempt in 0 ..< 4 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.2)
            }
            switch queryCallPresence() {
            case .empty:
                return finishConfirmedCallEnd(
                    reason: reason,
                    evidence: CallEndEvidence(source: reason == .localHangup ? .localAction : .internalFailure)
                )
            case let .present(calls):
                if let primary = calls.first { applyCallInfo(primary) }
                if isOpen {
                    _ = callCommand("ATH", timeout: 3_000)
                }
                lastError = L10n.tr("模块仍报告活动通话")
            case let .unknown(error):
                lastError = error
            case .differentDevice:
                lastError = L10n.tr("原通话模块不可达或身份不匹配")
            }
        }

        invalidateCallAction()
        callSnapshot.phase = .recovering
        callSnapshot.audioActive = false
        callSnapshot.lastError = L10n.tr("挂断状态未确认：%@", lastError)
        publishCallSnapshot()
        return false
    }

    private func setCallIdle(
        reason: CallEndReason? = nil,
        evidence: CallEndEvidence = CallEndEvidence(source: .internalFailure),
        error: String? = nil
    ) {
        callSnapshot.phase = callSnapshot.voiceOverUSBSupported ? .idle : .unavailable
        callSnapshot.direction = nil
        callSnapshot.number = nil
        callSnapshot.audioActive = false
        callSnapshot.muted = false
        voiceAudio.setMuted(false)
        callSnapshot.startedAt = nil
        if let reason {
            callSnapshot.recordEnd(reason, evidence: evidence)
        } else {
            callSnapshot.clearEnd()
        }
        callSnapshot.lastError = error
        callSnapshot.controlInterfaceBusy = false
        callPollMisses = 0
        callStateChangedAt = Date()
        publishCallSnapshot()
    }

    private func resetCallConnectionState(disconnected: Bool) {
        let hadCall = callSnapshot.hasCall
        cancelQDCInitializationRetry()
        cancelPendingQDCMediaSession()
        voiceAudio.stop()
        pcmSessionEnabled = false
        callMediaCleanupPending = false
        callMediaBackend = .none
        moduleVoiceRuntime = nil
        invalidateCallAction()
        callCleanupScheduled = false
        needsPostCallInitialization = false
        callURCFramer.reset()
        callPollMisses = 0
        callSnapshot = CallSnapshot(
            phase: .unavailable,
            lastEndReason: hadCall || disconnected ? .deviceDisconnected : nil,
            lastEndEvidence: hadCall || disconnected ? CallEndEvidence(source: .deviceDisconnected) : nil
        )
        publishCallSnapshot()
    }

    private func callFailureMessage(from output: String) -> String {
        let uppercase = output.uppercased()
        if uppercase.contains("BUSY") { return CallEndReason.busy.localizedDescription }
        if uppercase.contains("NO ANSWER") { return CallEndReason.noAnswer.localizedDescription }
        if uppercase.contains("NO DIAL") { return CallEndReason.noDialTone.localizedDescription }
        if uppercase.contains("NO CARRIER") { return CallEndReason.unknown.localizedDescription }
        return L10n.tr("模块未接受通话命令。")
    }

    private func beginCallAction() -> CallActionToken {
        callActionID &+= 1
        callActionInFlight = true
        callActionModemGeneration = modemGeneration
        return CallActionToken(
            id: callActionID,
            modemGeneration: modemGeneration,
            registryID: modemRegistryID
        )
    }

    private func invalidateCallAction() {
        callActionID &+= 1
        callActionInFlight = false
        callActionModemGeneration = modemGeneration
    }

    private func isCurrentCallAction(_ token: CallActionToken) -> Bool {
        callActionInFlight &&
            callActionID == token.id &&
            callActionModemGeneration == token.modemGeneration &&
            modemGeneration == token.modemGeneration &&
            modemRegistryID == token.registryID
    }

    @discardableResult
    private func recordConnectedModemIdentity() -> Bool {
        guard let modem else { return false }
        let registryID = celldock_modem_registry_id(modem)
        let discoveredLocationID = celldock_modem_location_id(modem)
        let locationFallback = UInt64(discoveredLocationID)
        let identity = registryID == 0 ? locationFallback : registryID
        guard identity != 0 else { return false }
        if modemRegistryID == 0 {
            modemRegistryID = identity
            modemLocationID = discoveredLocationID
            modemGeneration &+= 1
            return true
        }
        guard modemRegistryID != identity else { return true }
        modemRegistryID = identity
        modemLocationID = discoveredLocationID
        modemGeneration &+= 1
        invalidateCallAction()
        return false
    }

    private func connectedModemMatchesExpectedIdentity() -> Bool {
        guard let modem, modemRegistryID != 0, modemLocationID != 0 else { return false }
        let registryID = celldock_modem_registry_id(modem)
        let locationID = celldock_modem_location_id(modem)
        let identity = registryID == 0 ? UInt64(locationID) : registryID
        return identity == modemRegistryID && locationID == modemLocationID
    }

    @discardableResult
    private func stopVoiceAudioAndWait() -> Bool {
        let stopped = DispatchSemaphore(value: 0)
        voiceAudio.stop { stopped.signal() }
        return stopped.wait(timeout: .now() + 5) == .success
    }

    private var isOpen: Bool {
        guard let modem else { return false }
        return celldock_modem_is_open(modem) != 0
    }

    private var isExpectingModuleRestart: Bool {
        guard let expectedRestartStartedAt else { return false }
        return Date().timeIntervalSince(expectedRestartStartedAt) < 45
    }

    private func beginExpectedModuleRestart(closeModem: Bool = true) {
        expectedRestartStartedAt = Date()
        expectedRestartObservedDisconnect = false
        if closeModem, let modem {
            celldock_modem_close(modem)
        }
        snapshot.state = .connecting
        snapshot.lifecyclePhase = .restarting
        snapshot.simState = .unavailable
        snapshot.simLastError = nil
        snapshot.registrationState = .unavailable
        snapshot.voiceRegistrationState = .unavailable
        snapshot.volteSessionAvailable = nil
        snapshot.lastError = nil
        publishSnapshot(snapshot)
        resetSMSConnectionState()
    }

    private func publishExpectedRestartWaitingState() {
        snapshot.state = .connecting
        if snapshot.lifecyclePhase != .reconnecting {
            snapshot.lifecyclePhase = .restarting
        }
        snapshot.simState = .unavailable
        snapshot.simLastError = nil
        snapshot.registrationState = .unavailable
        snapshot.voiceRegistrationState = .unavailable
        snapshot.volteSessionAvailable = nil
        snapshot.lastError = nil
        publishSnapshot(snapshot)
    }

    private func clearExpectedModuleRestart() {
        expectedRestartStartedAt = nil
        expectedRestartObservedDisconnect = false
        snapshot.lifecyclePhase = .normal
    }

    private func beginSIMInitialization() {
        snapshot.simState = .initializing
        snapshot.simLastError = nil
        snapshot.registrationState = .unavailable
        snapshot.voiceRegistrationState = .unavailable
        snapshot.volteSessionAvailable = nil
        consecutiveSIMQueryFailures = 0
        simFastPollingDeadline = Date().addingTimeInterval(30)
        nextSIMRefreshAt = Date()
    }

    private func tick() {
        guard let modem else { return }
        tickNumber += 1

        if !isOpen {
            if let expectedRestartStartedAt,
               !expectedRestartObservedDisconnect,
               Date().timeIntervalSince(expectedRestartStartedAt) < 2 {
                publishExpectedRestartWaitingState()
                return
            }
            let wasRecoveringCall = callSnapshot.hasCall || hasPendingMediaCleanup
            let result: Int32
            if wasRecoveringCall {
                guard modemLocationID != 0 else {
                    callSnapshot.phase = .recovering
                    callSnapshot.lastError = L10n.tr("原模块缺少可绑定的 USB locationID，拒绝连接其他模块。")
                    publishCallSnapshot()
                    return
                }
                result = celldock_modem_open_for_location(modem, modemLocationID)
            } else if let preferredLocationID {
                result = celldock_modem_open_for_location(modem, preferredLocationID)
            } else {
                result = celldock_modem_open(modem)
            }
            if result == CELLDOCK_MODEM_OK {
                if let expectedRestartStartedAt,
                   !expectedRestartObservedDisconnect,
                   Date().timeIntervalSince(expectedRestartStartedAt) < 5 {
                    celldock_modem_close(modem)
                    publishExpectedRestartWaitingState()
                    return
                }
                let sameDevice = wasRecoveringCall
                    ? connectedModemMatchesExpectedIdentity()
                    : recordConnectedModemIdentity()
                if wasRecoveringCall, !sameDevice {
                    celldock_modem_close(modem)
                    callSnapshot.phase = .recovering
                    callSnapshot.lastError = L10n.tr("原通话模块身份不匹配，拒绝连接其他模块。")
                    publishCallSnapshot()
                    return
                }
                resetSMSConnectionState()
                consumeBufferedURCsBeforeCommands()
                if wasRecoveringCall {
                    if sameDevice {
                        reconcileCallAfterATRecovery()
                    } else {
                        pcmSessionEnabled = false
                        resetCallConnectionState(disconnected: true)
                        initializeConnectedModem()
                    }
                } else {
                    if recoverExistingCallBeforeInitialization() {
                        return
                    }
                    initializeConnectedModem()
                }
                if !isOpen { return }
            } else {
                resetSMSConnectionState()
                if isExpectingModuleRestart {
                    expectedRestartObservedDisconnect = true
                    publishExpectedRestartWaitingState()
                    return
                }
                if expectedRestartStartedAt != nil {
                    clearExpectedModuleRestart()
                    snapshot = ModemSnapshot(
                        state: .error,
                        simState: .unavailable,
                        lastError: L10n.tr("模组重启后 45 秒内未恢复 USB/AT 接口。")
                    )
                    publishSnapshot(snapshot)
                    return
                }
                if result == CELLDOCK_MODEM_NOT_FOUND,
                   callSnapshot.phase != .unavailable,
                   !wasRecoveringCall {
                    resetCallConnectionState(disconnected: true)
                } else if wasRecoveringCall {
                    callSnapshot.phase = .recovering
                    callSnapshot.lastError = lastBridgeError()
                    publishCallSnapshot()
                }
                let newState: ModemConnectionState = result == CELLDOCK_MODEM_NOT_FOUND ? .disconnected : .error
                let error = result == CELLDOCK_MODEM_NOT_FOUND ? nil : lastBridgeError()
                if snapshot.state != newState || snapshot.lastError != error {
                    snapshot = ModemSnapshot(state: newState, lastError: error)
                    publishSnapshot(snapshot)
                }
                return
            }
        }

        consumeURCBytes(readPendingEvents())
        if !isOpen {
            resetSMSConnectionState()
            if callSnapshot.hasCall || pcmSessionEnabled {
                callSnapshot.phase = .recovering
                callSnapshot.lastError = L10n.tr("AT 接口暂时断开，正在恢复并核对 CLCC。")
                publishCallSnapshot()
            } else {
                resetCallConnectionState(disconnected: true)
            }
            if isExpectingModuleRestart {
                publishExpectedRestartWaitingState()
                return
            }
            if expectedRestartStartedAt != nil {
                clearExpectedModuleRestart()
                snapshot = ModemSnapshot(
                    state: .error,
                    simState: .unavailable,
                    lastError: L10n.tr("模组重启后 45 秒内未恢复 USB/AT 接口。")
                )
                publishSnapshot(snapshot)
                return
            }
            snapshot = ModemSnapshot(
                state: .disconnected,
                simState: .unavailable,
                lastError: callSnapshot.hasCall ? L10n.tr("通话期间 AT 接口断开，正在恢复。") : nil
            )
            publishSnapshot(snapshot)
            return
        }

        if !callSnapshot.hasCall, hasPendingMediaCleanup {
            _ = finishConfirmedCallEnd(
                reason: callSnapshot.lastEndReason ?? .failed,
                evidence: callSnapshot.lastEndEvidence ?? CallEndEvidence(source: .internalFailure)
            )
            return
        }

        if callSnapshot.hasCall {
            refreshCallState()
            return
        }
        if tickNumber.isMultiple(of: 10) {
            refreshRadioSnapshot()
        }
        if needsSIMRefresh || Date() >= nextSIMRefreshAt {
            needsSIMRefresh = false
            refreshSIMSnapshot()
            if snapshot.state == .connected {
                publishSnapshot(snapshot)
            }
        }
        if !pendingMessageLocations.isEmpty {
            pollIndicatedMessages()
        }
        if needsImmediateMessagePoll || tickNumber.isMultiple(of: 3) {
            needsImmediateMessagePoll = false
            pollMessages()
        }
    }

    private func recoverExistingCallBeforeInitialization() -> Bool {
        switch queryCallPresence() {
        case let .present(calls):
            // This process did not create the pre-existing media route. Do not
            // claim ownership of it or send QPCMV/T during eventual cleanup.
            callMediaBackend = .none
            moduleVoiceRuntime = nil
            callSnapshot = CallSnapshot(
                phase: .recovering,
                voiceOverUSBSupported: false,
                audioActive: false,
                lastError: L10n.tr("检测到模块中已有通话；为安全起见未自动接管麦克风，请先挂断。")
            )
            pcmSessionEnabled = false
            needsPostCallInitialization = true
            if let primary = calls.first { applyCallInfo(primary) }
            callSnapshot.audioActive = false
            callSnapshot.lastError = L10n.tr("检测到模块中已有通话；为安全起见未自动接管麦克风，请先挂断。")
            let locationID = modem.map { celldock_modem_location_id($0) } ?? 0
            let usbNames = ModemUSBIdentityResolver.names(for: locationID)
            snapshot = ModemSnapshot(
                state: .connected,
                usbIdentity: modem.map {
                    String(format: "%04X:%04X", celldock_modem_vendor_id($0), celldock_modem_product_id($0))
                },
                usbLocationID: locationID == 0 ? nil : locationID,
                usbRegistryID: modem.map { celldock_modem_registry_id($0) },
                usbVendorName: usbNames.vendor,
                usbProductName: usbNames.product,
                hardwareFamily: .classify(
                    vendorName: usbNames.vendor,
                    productName: usbNames.product
                ),
                voiceCapability: .probeFailed(
                    reason: L10n.tr("模块中已有通话，未执行启动语音能力探测。")
                ),
                endpointDescription: modem.map {
                    String(
                        format: "AT #2 · OUT 0x%02X · IN 0x%02X",
                        celldock_modem_output_endpoint($0),
                        celldock_modem_input_endpoint($0)
                    )
                },
                lastError: L10n.tr("模块中存在启动前已建立的通话。")
            )
            publishSnapshot(snapshot)
            publishCallSnapshot()
            return true
        case .empty:
            // Backend-specific stale media cleanup runs after firmware
            // identification. Do not send QPCMV to customized QDC firmware.
            pcmSessionEnabled = false
            return false
        case let .unknown(error):
            needsPostCallInitialization = true
            callSnapshot.phase = .recovering
            callSnapshot.lastError = L10n.tr("启动时无法确认是否存在通话：%@", error)
            publishCallSnapshot()
            return true
        case .differentDevice:
            return false
        }
    }

    private func reconcileCallAfterATRecovery() {
        callSnapshot.phase = .recovering
        callSnapshot.lastError = L10n.tr("AT 接口已恢复，正在核对 CLCC。")
        publishCallSnapshot()
        switch queryCallPresence() {
        case let .present(calls):
            if let primary = calls.first { applyCallInfo(primary) }
            callSnapshot.audioActive = voiceAudio.isRunning
            if !voiceAudio.isRunning {
                callSnapshot.lastError = L10n.tr("蜂窝通话仍存在，但 USB 音频已停止；请挂断后重拨。")
            } else {
                callSnapshot.lastError = nil
            }
            publishCallSnapshot()
        case .empty:
            needsPostCallInitialization = true
            _ = finishConfirmedCallEnd(
                reason: callSnapshot.lastEndReason ?? .unknown,
                evidence: callSnapshot.lastEndEvidence ?? CallEndEvidence(source: .callListEmpty)
            )
        case let .unknown(error):
            callSnapshot.phase = .recovering
            callSnapshot.lastError = L10n.tr("AT 已恢复，但 CLCC 查询失败：%@", error)
            publishCallSnapshot()
        case .differentDevice:
            callSnapshot.phase = .recovering
            callSnapshot.lastError = L10n.tr("原通话模块身份不匹配，拒绝连接其他模块。")
            publishCallSnapshot()
        }
    }

    private func initializeConnectedModem() {
        guard let modem else { return }
        let isRestartReconnect = expectedRestartStartedAt != nil
        cancelQDCInitializationRetry()
        didQuerySIMIdentity = false
        let usbLocationID = celldock_modem_location_id(modem)
        let usbNames = ModemUSBIdentityResolver.names(for: usbLocationID)
        let hardwareFamily = ModemHardwareFamily.classify(
            vendorName: usbNames.vendor,
            productName: usbNames.product
        )
        snapshot = ModemSnapshot(
            state: .connecting,
            lifecyclePhase: isRestartReconnect ? .reconnecting : .normal,
            usbIdentity: String(format: "%04X:%04X", celldock_modem_vendor_id(modem), celldock_modem_product_id(modem)),
            usbLocationID: usbLocationID,
            usbRegistryID: celldock_modem_registry_id(modem),
            usbVendorName: usbNames.vendor,
            usbProductName: usbNames.product,
            hardwareFamily: hardwareFamily,
            voiceCapability: hardwareFamily == .unknown ? .unknown : .probing,
            simState: .initializing,
            endpointDescription: String(
                format: "AT #2 · OUT 0x%02X · IN 0x%02X",
                celldock_modem_output_endpoint(modem),
                celldock_modem_input_endpoint(modem)
            )
        )
        beginSIMInitialization()
        publishSnapshot(snapshot)

        let handshake = command("AT", timeout: 2_000)
        guard handshake.isSuccess else {
            if isExpectingModuleRestart {
                snapshot.state = .connecting
                snapshot.lifecyclePhase = .reconnecting
                snapshot.lastError = nil
            } else {
                clearExpectedModuleRestart()
                snapshot.state = .error
                snapshot.lastError = handshake.error ?? L10n.tr("AT 接口没有响应")
            }
            publishSnapshot(snapshot)
            celldock_modem_close(modem)
            resetSMSConnectionState()
            return
        }

        _ = command("ATE0", timeout: 2_000)
        _ = command("AT+CMEE=2", timeout: 2_000)
        let moduleIdentity = command("AT+CGSN", timeout: 3_000)
        snapshot.moduleIMEI = ATResponseParser.parseIMEI(moduleIdentity.output)
        _ = command("AT+CLIP=1", timeout: 2_000)
        _ = command("AT+CRC=1", timeout: 2_000)
        let firmware = command("AT+QGMR", timeout: 3_000)
        let firmwareIdentity = ATResponseParser.normalizedLines(firmware.output)
            .filter { line in
                let upper = line.uppercased()
                return upper != "OK" && upper != "ERROR" && upper != "AT+QGMR"
            }
            .joined(separator: " ")
        snapshot.firmwareVersion = firmwareIdentity.isEmpty ? nil : firmwareIdentity
        let pcmCapability: CommandResult? = hardwareFamily == .quectelNativeVoice
            ? command("AT+QPCMV=?", timeout: 3_000)
            : nil
        let supportsRawPCM = pcmCapability?.isSuccess == true &&
            CallATParser.testResponseSupportsRawPCM(pcmCapability?.output ?? "") &&
            modemLocationID != 0
        var mediaAvailable = false
        var mediaError: String?
        var shouldRetryQDCInitialization = false
        moduleVoiceRuntime = nil
        switch CallATParser.preferredMediaBackend(
            hardwareFamily: hardwareFamily,
            supportsRawPCM: supportsRawPCM,
            hasUSBLocation: modemLocationID != 0
        ) {
        case .qdcModuleBridge:
            do {
                let runtime = try ModuleVoiceRuntime(locationID: modemLocationID)
                _ = try runtime.prepare()
                // CLCC was confirmed empty before initialization. Clear any
                // helper/route left behind by a prior app crash or USB-only
                // unplug while the module kept external power.
                try runtime.stopBridge()
                moduleVoiceRuntime = runtime
                callMediaBackend = .qdcUAC
                mediaAvailable = true
                snapshot.voiceCapability = .supported(
                    backend: .injectedQDC507,
                    verified: false
                )
            } catch {
                callMediaBackend = .none
                mediaError = L10n.error("QDC507 通话组件尚不可用：%@", underlying: error)
                snapshot.voiceCapability = .initializationFailed(
                    reason: mediaError ?? L10n.tr("Baiwang 语音组件初始化失败。")
                )
                shouldRetryQDCInitialization = ADBModuleController.isInterfaceBusyError(error)
            }
        case .qpcmv:
            let reset = command("AT+QPCMV=0", timeout: 3_000)
            if reset.isSuccess {
                callMediaBackend = .qpcmv
                mediaAvailable = true
                snapshot.voiceCapability = .supported(
                    backend: .nativeQPCMV,
                    verified: false
                )
            } else {
                callMediaBackend = .none
                mediaError = reset.error ?? L10n.tr("无法重置 USB 语音会话。")
                snapshot.voiceCapability = .initializationFailed(
                    reason: mediaError ?? L10n.tr("原生 QPCMV 初始化失败。")
                )
            }
        case .none:
            callMediaBackend = .none
            switch hardwareFamily {
            case .quectelNativeVoice:
                if let pcmCapability, pcmCapability.isSuccess {
                    snapshot.voiceCapability = .unsupported(
                        reason: L10n.tr("AT+QPCMV=? 未报告 CellDock 所需的原始 PCM 模式。")
                    )
                } else if let pcmCapability,
                          pcmCapability.output.uppercased().contains("ERROR") {
                    snapshot.voiceCapability = .unsupported(
                        reason: L10n.tr("当前 Quectel 固件不支持 AT+QPCMV。")
                    )
                } else {
                    snapshot.voiceCapability = .probeFailed(
                        reason: pcmCapability?.error ?? L10n.tr("无法完成 AT+QPCMV 能力探测。")
                    )
                }
            case .baiwangInjectedVoice:
                snapshot.voiceCapability = .initializationFailed(
                    reason: L10n.tr("Baiwang 动态语音后端不可用。")
                )
            case .unknown:
                snapshot.voiceCapability = .probeFailed(
                    reason: L10n.tr("USB 厂商和产品字符串无法识别，未选择语音后端。")
                )
            }
        }
        pcmSessionEnabled = false
        callSnapshot.resetForInitialization(
            phase: mediaAvailable ? .idle : .unavailable,
            voiceOverUSBSupported: mediaAvailable,
            lastError: mediaAvailable
                ? nil
                : (mediaError ?? L10n.tr("固件未报告可用的 USB 通话媒体通道。")),
            controlInterfaceBusy: shouldRetryQDCInitialization
        )
        publishCallSnapshot()
        if shouldRetryQDCInitialization {
            scheduleQDCInitializationRetry()
        }
        let pduMode = command("AT+CMGF=0", timeout: 2_000)
        let indications = command("AT+CNMI=2,1,0,0,0", timeout: 2_000)
        let storage = command("AT+CPMS?", timeout: 3_000)
        currentMessageStorage = ATResponseParser.parseCPMSStorage(storage.output)
        if let currentMessageStorage {
            observedMessageStorages.insert(currentMessageStorage)
        }
        let storageCapabilities = command("AT+CPMS=?", timeout: 3_000)
        if storageCapabilities.isSuccess {
            readableMessageStorages = ModemMessageStorageCapabilities.readableStorages(
                from: storageCapabilities.output
            )
        }

        refreshSIMSnapshot()
        let usbNet = command("AT+QCFG=\"usbnet\"", timeout: 3_000)
        snapshot.usbNetMode = ATResponseParser.parseUSBNetMode(usbNet.output)
        let usbConfiguration = command("AT+QCFG=\"USBCFG\"", timeout: 3_000)
        snapshot.usbConfiguration = ATResponseParser.parseUSBConfiguration(usbConfiguration.output)
        let ims = command("AT+QCFG=\"ims\"", timeout: 3_000)
        snapshot.imsMode = ATResponseParser.parseIMSMode(ims.output)
        snapshot.volteSessionAvailable = ATResponseParser.parseVoLTESessionAvailable(ims.output)
        snapshot.state = .connected
        clearExpectedModuleRestart()
        snapshot.lastError = pduMode.isSuccess && indications.isSuccess
            ? nil
            : L10n.tr("模块已连接，但短信 PDU/CNMI 初始化失败。")
        refreshRadioSnapshot()
        needsImmediateMessagePoll = true
    }

    private func scheduleQDCInitializationRetry() {
        guard let delay = ModuleVoiceInitializationRetryPolicy.delay(
            forCompletedAttempts: qdcInitializationRetryAttempts
        ) else {
            return
        }
        let generation = qdcInitializationRetryGeneration
        qdcInitializationRetryAttempts += 1
        callSnapshot.lastError = L10n.tr(
            "模块控制接口正被其他 ADB 客户端占用；CellDock 将自动重试（%lld/5）。",
            Int64(qdcInitializationRetryAttempts)
        )
        callSnapshot.controlInterfaceBusy = true
        publishCallSnapshot()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.qdcInitializationRetryGeneration == generation,
                  self.isOpen,
                  !self.isShuttingDown,
                  !self.callSnapshot.hasCall,
                  !self.hasPendingMediaCleanup,
                  self.callSnapshot.phase == .unavailable else {
                return
            }
            self.retryQDCInitializationAfterContention()
        }
    }

    private func retryQDCInitializationAfterContention() {
        moduleVoiceRuntime = nil
        do {
            let runtime = try ModuleVoiceRuntime(locationID: modemLocationID)
            _ = try runtime.prepare()
            try runtime.stopBridge()
            moduleVoiceRuntime = runtime
            callMediaBackend = .qdcUAC
            pcmSessionEnabled = false
            callSnapshot.resetForInitialization(
                phase: .idle,
                voiceOverUSBSupported: true
            )
            snapshot.voiceCapability = .supported(
                backend: .injectedQDC507,
                verified: false
            )
            cancelQDCInitializationRetry()
            publishSnapshot(snapshot)
            publishCallSnapshot()
        } catch {
            callMediaBackend = .none
            callSnapshot.phase = .unavailable
            callSnapshot.voiceOverUSBSupported = false
            callSnapshot.lastError = L10n.error(
                "QDC507 通话组件尚不可用：%@",
                underlying: error
            )
            callSnapshot.controlInterfaceBusy = ADBModuleController.isInterfaceBusyError(error)
            snapshot.voiceCapability = .initializationFailed(
                reason: callSnapshot.lastError ?? L10n.tr("Baiwang 语音组件初始化失败。")
            )
            publishSnapshot(snapshot)
            publishCallSnapshot()
            if ADBModuleController.isInterfaceBusyError(error) {
                scheduleQDCInitializationRetry()
            } else {
                cancelQDCInitializationRetry()
            }
        }
    }

    private func cancelQDCInitializationRetry() {
        qdcInitializationRetryGeneration &+= 1
        qdcInitializationRetryAttempts = 0
    }

    private func refreshSIMSnapshot() {
        guard isOpen else { return }
        let sim = command("AT+CPIN?", timeout: 3_000)
        let now = Date()
        guard let state = ATResponseParser.parseSIMState(sim.output) else {
            consecutiveSIMQueryFailures += 1
            snapshot.simPhoneNumber = nil
            snapshot.simICCID = nil
            snapshot.simIMSI = nil
            snapshot.registrationState = .unavailable
            snapshot.voiceRegistrationState = .unavailable
            snapshot.volteSessionAvailable = nil
            didQuerySIMIdentity = false
            let isWithinFastPollingWindow = simFastPollingDeadline.map { now < $0 } == true
            if isWithinFastPollingWindow, consecutiveSIMQueryFailures < 3 {
                snapshot.simState = .initializing
                snapshot.simLastError = nil
                nextSIMRefreshAt = now.addingTimeInterval(2)
            } else {
                snapshot.simState = .queryFailed
                snapshot.simLastError = sim.error ?? L10n.tr("AT+CPIN? 未返回可识别的 SIM 状态。")
                simFastPollingDeadline = nil
                nextSIMRefreshAt = now.addingTimeInterval(15)
            }
            return
        }

        consecutiveSIMQueryFailures = 0
        simFastPollingDeadline = nil
        snapshot.simState = state
        snapshot.simLastError = nil
        nextSIMRefreshAt = now.addingTimeInterval(state == .ready ? 60 : 10)
        guard state == .ready else {
            snapshot.simPhoneNumber = nil
            snapshot.simICCID = nil
            snapshot.simIMSI = nil
            snapshot.registrationState = .unavailable
            snapshot.voiceRegistrationState = .unavailable
            snapshot.volteSessionAvailable = nil
            didQuerySIMIdentity = false
            return
        }
        let previousICCID = snapshot.simICCID
        let quectelICCID = command("AT+QCCID", timeout: 3_000)
        var currentICCID = ATResponseParser.parseICCID(quectelICCID.output)
        if currentICCID == nil {
            let standardICCID = command("AT+CCID", timeout: 3_000)
            currentICCID = ATResponseParser.parseICCID(standardICCID.output)
        }

        let simIdentityChanged = currentICCID.map { $0 != previousICCID } == true
        if let currentICCID {
            snapshot.simICCID = currentICCID
        }
        if simIdentityChanged {
            snapshot.simPhoneNumber = nil
            snapshot.simIMSI = nil
            didQuerySIMIdentity = false
        }

        if snapshot.simIMSI == nil {
            let imsi = command("AT+CIMI", timeout: 3_000)
            if imsi.isSuccess {
                snapshot.simIMSI = ATResponseParser.parseIMSI(imsi.output)
            }
        }

        guard !didQuerySIMIdentity else { return }
        let subscriberNumber = command("AT+CNUM", timeout: 3_000)
        if subscriberNumber.isSuccess {
            snapshot.simPhoneNumber = ATResponseParser.parseSubscriberNumber(subscriberNumber.output)
            didQuerySIMIdentity = true
        } else {
            snapshot.simPhoneNumber = nil
            didQuerySIMIdentity = false
        }
    }

    private func refreshRadioSnapshot() {
        guard isOpen else { return }
        if snapshot.simState == .ready {
            let dataRegistration = command("AT+CEREG?", timeout: 3_000)
            snapshot.registrationState = dataRegistration.isSuccess
                ? (ATResponseParser.parseRegistrationState(dataRegistration.output) ?? .queryFailed)
                : .queryFailed

            let voiceRegistration = command("AT+CREG?", timeout: 3_000)
            snapshot.voiceRegistrationState = voiceRegistration.isSuccess
                ? (ATResponseParser.parseRegistrationState(
                    voiceRegistration.output,
                    prefix: "+CREG"
                ) ?? .queryFailed)
                : .queryFailed

            let ims = command("AT+QCFG=\"ims\"", timeout: 3_000)
            if ims.isSuccess {
                snapshot.imsMode = ATResponseParser.parseIMSMode(ims.output)
                snapshot.volteSessionAvailable = ATResponseParser.parseVoLTESessionAvailable(ims.output)
            } else {
                snapshot.volteSessionAvailable = nil
            }
        } else {
            snapshot.registrationState = .unavailable
            snapshot.voiceRegistrationState = .unavailable
            snapshot.volteSessionAvailable = nil
        }
        let operatorResponse = command("AT+COPS?", timeout: 3_000)
        let parsedOperator = ATResponseParser.parseOperator(operatorResponse.output)
        if let name = parsedOperator.name { snapshot.operatorName = name }
        if let technology = parsedOperator.technology { snapshot.accessTechnology = technology }

        let qcsq = command("AT+QCSQ", timeout: 3_000)
        if let signal = ATResponseParser.parseQCSQ(qcsq.output) {
            snapshot.signalDBm = signal.dbm
            snapshot.accessTechnology = signal.technology
            snapshot.signalDetail = signal.detail
        } else {
            let csq = command("AT+CSQ", timeout: 3_000)
            snapshot.signalDBm = ATResponseParser.parseCSQ(csq.output)
            snapshot.signalDetail = snapshot.signalDBm.map { L10n.tr("CSQ 换算 · %lld dBm", Int64($0)) }
        }
        guard isOpen else {
            snapshot = ModemSnapshot(state: .disconnected)
            publishSnapshot(snapshot)
            return
        }
        snapshot.state = .connected
        publishSnapshot(snapshot)
    }

    private func pollMessages() {
        guard isOpen else { return }
        let originalStorage = currentMessageStorage

        for storage in messageStoragesForFullPoll() {
            guard selectMessageStorage(storage) else { continue }
            let response = command("AT+CMGL=4", timeout: 10_000, capacity: 256 * 1_024)
            guard response.isSuccess else { continue }
            let stored = ATResponseParser.parseCMGL(response.output).map { item in
                ModemStoredPDU(
                    index: item.index,
                    status: item.status,
                    declaredLength: item.declaredLength,
                    rawPDU: item.rawPDU,
                    storage: storage
                )
            }
            let messages = bufferedSMSAssembler.ingest(stored)
            let isInitialStorageSync = messageStorageSyncTracker.markSuccessfulPoll(of: storage)
            publishMessages(messages, isInitial: isInitialStorageSync)
        }
        if let originalStorage { _ = selectMessageStorage(originalStorage) }
    }

    private func readPendingEvents(timeout: Int32 = 25) -> String {
        guard let modem, isOpen else { return "" }
        var buffer = [CChar](repeating: 0, count: 8_192)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            celldock_modem_read(modem, timeout, pointer.baseAddress, pointer.count)
        }
        guard result > 0 else { return "" }
        return String(cString: buffer)
    }

    private func pumpUnsolicitedEvents() {
        guard isOpen else { return }
        consumeURCBytes(readPendingEvents(timeout: 5))
    }

    private func consumeBufferedURCsBeforeCommands() {
        // The C bridge preserves bytes observed while resynchronizing. Consume
        // them before issuing a new command so a buffered +CMT header cannot be
        // reordered behind its PDU if that PDU arrives with a command response.
        for _ in 0 ..< 64 {
            let text = readPendingEvents()
            guard !text.isEmpty else { return }
            consumeURCBytes(text)
        }
    }

    private func consumeURCBytes(_ text: String, acceptsCallInfo: Bool = true) {
        guard !text.isEmpty else { return }
        for event in callURCFramer.consume(text) {
            if !acceptsCallInfo, case .callInfo = event { continue }
            handleCallEvent(event)
        }
        let batch = urcFramer.consume(text)
        for location in batch.messageLocations {
            observedMessageStorages.insert(location.storage)
            enqueueMessageLocation(location)
        }
        if !batch.messageLocations.isEmpty {
            needsImmediateMessagePoll = true
        }

        guard !batch.directPDUs.isEmpty else { return }
        let stored = batch.directPDUs.map {
            ModemStoredPDU(index: -1, status: 0, declaredLength: nil, rawPDU: $0, storage: nil)
        }
        let messages = bufferedSMSAssembler.ingest(stored)
        publishMessages(messages, isInitial: false)
    }

    fileprivate func consumeCommandStreamBytes(
        _ bytes: UnsafePointer<UInt8>,
        length: Int
    ) {
        // The C bridge invokes this callback synchronously from inside
        // celldock_modem_command. Copy its temporary buffer now, but defer all state
        // handling until the current command has unwound. A solicited +CLCC
        // response can otherwise trigger another +CLCC from the callback and
        // recurse through IOKit until this queue exhausts its thread stack.
        let text = String(
            decoding: UnsafeBufferPointer(start: bytes, count: length),
            as: UTF8.self
        )
        let acceptsCallInfo = commandStreamAcceptsCallInfo
        guard !text.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.consumeURCBytes(text, acceptsCallInfo: acceptsCallInfo)
        }
    }

    private func handleCallEvent(_ event: ModemCallEvent) {
        switch event {
        case .ring:
            if callSnapshot.phase == .idle || callSnapshot.phase == .unavailable {
                callSnapshot.phase = .incoming
                callSnapshot.direction = .incoming
                callSnapshot.clearEnd()
                callSnapshot.lastError = nil
                callSnapshot.startedAt = nil
                callStateChangedAt = Date()
                callPollMisses = 0
                publishCallSnapshot()
            }
        case let .callerID(number):
            if callSnapshot.phase == .idle || callSnapshot.phase == .unavailable {
                callSnapshot.phase = .incoming
                callSnapshot.direction = .incoming
                callSnapshot.clearEnd()
                callStateChangedAt = Date()
            }
            callSnapshot.number = number
            publishCallSnapshot()
        case let .callInfo(info):
            applyCallInfo(info)
        case .connected:
            guard callSnapshot.hasCall else { return }
            // CONNECT alone is not proof of a cellular voice bearer. Keep the
            // current dialing/alerting state and require CLCC status 0 before
            // starting D4 or CoreAudio.
            callStateChangedAt = Date()
            callPollMisses = 0
            publishCallSnapshot()
        case let .ended(reason, evidence):
            guard callSnapshot.hasCall || pcmSessionEnabled else {
                callSnapshot.recordEnd(reason, evidence: evidence)
                publishCallSnapshot()
                return
            }
            scheduleCallCleanup(reason: reason, evidence: evidence)
        case let .pcmFlowReady(ready):
            voiceAudio.setPCMFlowReady(ready)
        }
    }

    private func applyCallInfo(_ info: ModemCallInfo) {
        if !callSnapshot.hasCall { callSnapshot.clearEnd() }
        callSnapshot.direction = info.direction
        if let number = info.number, !number.isEmpty {
            callSnapshot.number = number
        }
        switch info.status {
        case .active, .held:
            callSnapshot.phase = .active
            callSnapshot.startedAt = callSnapshot.startedAt ?? Date()
        case .dialing:
            callSnapshot.phase = .dialing
        case .alerting:
            callSnapshot.phase = .alerting
        case .incoming, .waiting:
            callSnapshot.phase = .incoming
        }
        callStateChangedAt = Date()
        callPollMisses = 0
        publishCallSnapshot()
        if info.status == .active {
            startQDCMediaIfNeeded(for: info)
        }
    }

    private func refreshCallState() {
        guard isOpen, callSnapshot.hasCall else { return }
        let response = command("AT+CLCC", timeout: 2_500)
        guard response.isSuccess else { return }
        let calls = CallATParser.parseCLCCResponse(response.output)
        guard !calls.isEmpty else {
            if Date().timeIntervalSince(callStateChangedAt) >= 3 {
                callPollMisses += 1
                if callPollMisses >= 2 {
                    scheduleCallCleanup(
                        reason: .unknown, evidence: CallEndEvidence(source: .callListEmpty)
                    )
                }
            }
            return
        }
        callPollMisses = 0
        let rank: [ModemCallStatus: Int] = [
            .active: 0,
            .held: 1,
            .incoming: 2,
            .waiting: 3,
            .alerting: 4,
            .dialing: 5,
        ]
        if let primary = calls.min(by: { (rank[$0.status] ?? 99) < (rank[$1.status] ?? 99) }) {
            applyCallInfo(primary)
        }
    }

    private func pollIndicatedMessages() {
        let locations = pendingMessageLocations
        pendingMessageLocations.removeAll()
        let originalStorage = currentMessageStorage
        inFlightMessageLocations = Set(locations.map(\.location))
        defer { inFlightMessageLocations.removeAll() }

        for pending in locations {
            let location = pending.location
            observedMessageStorages.insert(location.storage)
            guard selectMessageStorage(location.storage) else {
                retryMessageLocation(pending)
                continue
            }
            let response = command("AT+CMGR=\(location.index)", timeout: 5_000)
            guard response.isSuccess,
                  let pdu = ATResponseParser.parseCMGR(response.output),
                  (try? SMSPDUDecoder.decode(pdu)) != nil else {
                retryMessageLocation(pending)
                continue
            }
            let stored = ModemStoredPDU(
                index: location.index,
                status: 0,
                declaredLength: nil,
                rawPDU: pdu,
                storage: location.storage
            )
            publishMessages(bufferedSMSAssembler.ingest([stored]), isInitial: false)
        }
        if let originalStorage { _ = selectMessageStorage(originalStorage) }
        needsImmediateMessagePoll = true
    }

    private func enqueueMessageLocation(_ location: ModemMessageLocation) {
        guard !inFlightMessageLocations.contains(location),
              !pendingMessageLocations.contains(where: { $0.location == location }) else {
            return
        }
        pendingMessageLocations.append(PendingMessageLocation(location: location, attempts: 0))
    }

    private func retryMessageLocation(_ pending: PendingMessageLocation) {
        guard pending.attempts < 4,
              !pendingMessageLocations.contains(where: { $0.location == pending.location }) else {
            return
        }
        pendingMessageLocations.append(
            PendingMessageLocation(location: pending.location, attempts: pending.attempts + 1)
        )
    }

    private func messageStoragesForFullPoll() -> [String] {
        if currentMessageStorage == "MT" || readableMessageStorages.contains("MT") {
            return ["MT"]
        }

        var result: [String] = []
        func append(_ storage: String?) {
            guard let storage,
                  ["SM", "ME", "MT"].contains(storage),
                  !result.contains(storage) else {
                return
            }
            result.append(storage)
        }

        append(currentMessageStorage)
        if readableMessageStorages.isEmpty {
            for storage in observedMessageStorages.sorted() { append(storage) }
            // QDC507 normally exposes both; failed selections are harmless and leave
            // the original mem1 untouched.
            append("SM")
            append("ME")
        } else {
            for storage in readableMessageStorages { append(storage) }
            for storage in observedMessageStorages.sorted() { append(storage) }
        }
        return result
    }

    private func resetSMSConnectionState() {
        currentMessageStorage = nil
        readableMessageStorages.removeAll()
        observedMessageStorages.removeAll()
        pendingMessageLocations.removeAll()
        inFlightMessageLocations.removeAll()
        urcFramer.reset()
        bufferedSMSAssembler.reset()
        messageStorageSyncTracker.reset()
        needsImmediateMessagePoll = false
    }

    private func inspectExpectedPDU(index: Int, expectedPDU: String) -> ExpectedPDUState {
        let readBack = command("AT+CMGR=\(index)", timeout: 4_000)
        if readBack.isSuccess {
            if let currentPDU = ATResponseParser.parseCMGR(readBack.output) {
                return currentPDU.caseInsensitiveCompare(expectedPDU) == .orderedSame
                    ? .exact
                    : .gone
            }
            // This QDC507 firmware reports an empty/deleted CMGR slot as a
            // successful bare OK rather than +CMS ERROR: 321.
            if SMSDeletionPlanner.isBareEmptyCMGR(
                ATResponseParser.normalizedLines(readBack.output),
                index: index
            ) { return .gone }
            return .unknown(L10n.tr("模块返回了无法解析的 CMGR 响应"))
        }
        if isMissingMessageResponse(readBack) {
            return .gone
        }
        return .unknown(readBack.error ?? L10n.tr("无法读取模块中的短信"))
    }

    private func isMissingMessageResponse(_ response: CommandResult) -> Bool {
        let normalized = ATResponseParser.normalizedLines(response.output)
            .map { $0.uppercased() }
        return normalized.contains { line in
            line.contains("+CMS ERROR: 321") || line.contains("INVALID MEMORY INDEX")
        }
    }

    @discardableResult
    private func selectMessageStorage(_ storage: String) -> Bool {
        let normalized = storage.uppercased()
        guard isOpen, ["SM", "ME", "MT"].contains(normalized) else { return false }
        if currentMessageStorage == normalized { return true }
        let response = command("AT+CPMS=\"\(normalized)\"", timeout: 4_000)
        guard response.isSuccess else { return false }
        currentMessageStorage = normalized
        observedMessageStorages.insert(normalized)
        return true
    }

    private func publishMessages(_ messages: [SMSMessage], isInitial: Bool) {
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onMessages?(messages, isInitial)
        }
    }

    private struct CommandResult {
        let output: String
        let code: Int32
        let error: String?

        var isSuccess: Bool {
            guard code == CELLDOCK_MODEM_OK, error == nil else { return false }
            let lines = ATResponseParser.normalizedLines(output).map { $0.uppercased() }
            let hasSuccess = lines.contains("OK") ||
                lines.contains("CONNECT") ||
                lines.contains("MO CONNECTED")
            return hasSuccess && !lines.contains(where: { $0.contains("ERROR") })
        }

        var isTransportAmbiguous: Bool {
            code != CELLDOCK_MODEM_OK
        }
    }

    private func command(_ value: String, timeout: Int, capacity: Int = 64 * 1_024) -> CommandResult {
        executeCommand(value, timeout: timeout, capacity: capacity, acceptsCallResults: false)
    }

    private func callCommand(
        _ value: String,
        timeout: Int,
        capacity: Int = 64 * 1_024
    ) -> CommandResult {
        executeCommand(value, timeout: timeout, capacity: capacity, acceptsCallResults: true)
    }

    private func submitSMSPDU(_ segment: SMSSubmitSegment) -> CommandResult {
        guard let modem, isOpen else {
            return CommandResult(output: "", code: Int32(CELLDOCK_MODEM_NOT_OPEN), error: L10n.tr("模块已断开"))
        }
        guard !commandInFlight else {
            return CommandResult(
                output: "",
                code: Int32(CELLDOCK_MODEM_NOT_OPEN),
                error: L10n.tr("内部错误：检测到同步 AT 命令重入，已阻止。")
            )
        }
        commandInFlight = true
        commandStreamAcceptsCallInfo = true
        defer {
            commandStreamAcceptsCallInfo = true
            commandInFlight = false
        }

        var buffer = [CChar](repeating: 0, count: 64 * 1_024)
        let result: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
            celldock_modem_send_sms_pdu(
                modem,
                segment.pdu,
                segment.tpduLength,
                90_000,
                pointer.baseAddress,
                pointer.count
            )
        }
        let output = String(cString: buffer)
        let terminalError = ATResponseParser.normalizedLines(output).first { line in
            let uppercase = line.uppercased()
            return uppercase == "ERROR" ||
                uppercase.hasPrefix("+CME ERROR:") ||
                uppercase.hasPrefix("+CMS ERROR:")
        }
        let error = result == CELLDOCK_MODEM_OK ? terminalError : lastBridgeError()
        return CommandResult(output: output, code: result, error: error)
    }

    private func executeCommand(
        _ value: String,
        timeout: Int,
        capacity: Int,
        acceptsCallResults: Bool
    ) -> CommandResult {
        guard let modem, isOpen else {
            return CommandResult(output: "", code: Int32(CELLDOCK_MODEM_NOT_OPEN), error: L10n.tr("模块已断开"))
        }
        guard !commandInFlight else {
            return CommandResult(
                output: "",
                code: Int32(CELLDOCK_MODEM_NOT_OPEN),
                error: L10n.tr("内部错误：检测到同步 AT 命令重入，已阻止。")
            )
        }
        commandInFlight = true
        commandStreamAcceptsCallInfo = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() != "AT+CLCC"
        defer {
            commandStreamAcceptsCallInfo = true
            commandInFlight = false
        }
        var buffer = [CChar](repeating: 0, count: capacity)
        let result: Int32 = buffer.withUnsafeMutableBufferPointer { pointer in
            if acceptsCallResults {
                return celldock_modem_call_command(
                    modem,
                    value,
                    Int32(timeout),
                    pointer.baseAddress,
                    pointer.count
                )
            }
            return celldock_modem_command(
                modem,
                value,
                Int32(timeout),
                pointer.baseAddress,
                pointer.count
            )
        }
        let output = String(cString: buffer)
        let terminalError = ATResponseParser.normalizedLines(output).first { line in
            let uppercase = line.uppercased()
            if uppercase == "ERROR" || uppercase.hasPrefix("+CME ERROR:") || uppercase.hasPrefix("+CMS ERROR:") {
                return true
            }
            guard acceptsCallResults else { return false }
            return ["BUSY", "NO CARRIER", "NO ANSWER", "NO DIALTONE", "NO DIAL TONE"]
                .contains(uppercase)
        }
        let error = result == CELLDOCK_MODEM_OK ? terminalError : lastBridgeError()
        return CommandResult(output: output, code: result, error: error)
    }

    private func lastBridgeError() -> String {
        guard let modem, let pointer = celldock_modem_last_error(modem) else {
            return L10n.tr("未知的 USB/AT 错误")
        }
        let value = String(cString: pointer)
        return value.isEmpty ? L10n.tr("未知的 USB/AT 错误") : value
    }

    private func publishSnapshot(_ value: ModemSnapshot) {
        guard lastPublishedSnapshot != value else { return }
        lastPublishedSnapshot = value
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(value)
        }
    }

    private func publishCallSnapshot() {
        callSnapshot.mediaCleanupPending = hasPendingMediaCleanup
        callSnapshot.uacMedia = voiceAudio.uacMediaSnapshot
        let value = callSnapshot
        var fingerprint = value
        // Audio counters are useful diagnostic data but are not rendered by
        // the app. Ignore them for UI invalidation so an active call does not
        // redraw the entire interface every second.
        fingerprint.uacMedia = nil
        guard lastPublishedCallFingerprint != fingerprint else { return }
        lastPublishedCallFingerprint = fingerprint
        DispatchQueue.main.async { [weak self] in
            self?.onCallSnapshot?(value)
        }
    }
}
