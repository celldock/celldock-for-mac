import Foundation
#if canImport(CellDockNetworkIPC)
import CellDockNetworkIPC
#endif

enum ModemConnectionState: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case error
}

enum ModemLifecyclePhase: Equatable {
    case normal
    case restarting
    case reconnecting
}

enum ModemOperationalState: Equatable {
    case absent
    case enumerating
    case initializing
    case configurationRequired
    case ready
    case restarting
    case reconnecting
    case failed
}

enum SIMState: Equatable {
    case unavailable
    case initializing
    case absent
    case pinRequired
    case pukRequired
    case ready
    case queryFailed
}

enum CellularRegistrationState: Equatable {
    case unavailable
    case notRegistered
    case registered
    case searching
    case denied
    case unknown
    case roaming
    case queryFailed

    var hasService: Bool {
        self == .registered || self == .roaming
    }
}

enum VoiceServiceAvailability: Equatable {
    case unavailable
    case available
    /// The module's firmware has voice calls switched off. Dialing answers
    /// NO CARRIER whatever the SIM and the network would allow.
    case disabledByFirmware
    /// The module's IMS is switched off or was never brought up, so there is
    /// no VoLTE to place a call over. The SIM is not the problem.
    case imsDisabled
    /// IMS is running but the module does not report VoLTE as ready.
    case volteNotReady
    case likelyDataOnly
    case unknown
}

enum ModemHardwareFamily: Equatable {
    case baiwangInjectedVoice
    case quectelNativeVoice
    case unknown

    static func classify(vendorName: String?, productName: String?) -> Self {
        let vendor = normalizedUSBName(vendorName)
        let product = normalizedUSBName(productName)
        // Product wins deliberately: Baiwang devices can carry a Quectel VID,
        // PID or vendor string after their USB identity has been customized.
        if product == "BAIWANG" { return .baiwangInjectedVoice }
        if vendor == "QUECTEL" { return .quectelNativeVoice }
        return .unknown
    }

    private static func normalizedUSBName(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}

enum ModemVoiceBackend: Equatable {
    case nativeQPCMV
    case injectedQDC507
}

enum ModemVoiceCapability: Equatable {
    case unknown
    case probing
    case supported(backend: ModemVoiceBackend, verified: Bool)
    case unsupported(reason: String)
    case probeFailed(reason: String)
    case initializationFailed(reason: String)

    /// The same capability once a call has connected over it. Anything other
    /// than an unverified `.supported` is returned unchanged.
    var verifiedByCall: ModemVoiceCapability {
        guard case let .supported(backend, _) = self else { return self }
        return .supported(backend: backend, verified: true)
    }
}

/// Remembers which modules have carried a connected call, so "verified by a
/// call" survives a reconnect and an app restart instead of resetting every
/// time the module is initialized.
///
/// Keyed by IMEI and voice backend: a different module, or the same module
/// after a change that switches its backend, has to prove itself again.
struct VoiceCapabilityVerificationStore {
    static let defaultsKey = "VoiceCapabilityVerifiedModules.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(imei: String?, backend: ModemVoiceBackend) -> String? {
        guard let imei = imei?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imei.isEmpty else {
            return nil
        }
        switch backend {
        case .nativeQPCMV: return "\(imei)|qpcmv"
        case .injectedQDC507: return "\(imei)|qdc507"
        }
    }

    func isVerified(imei: String?, backend: ModemVoiceBackend) -> Bool {
        guard let key = Self.key(imei: imei, backend: backend) else { return false }
        return (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(key)
    }

    func markVerified(imei: String?, backend: ModemVoiceBackend) {
        guard let key = Self.key(imei: imei, backend: backend) else { return }
        var keys = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        guard !keys.contains(key) else { return }
        keys.append(key)
        defaults.set(keys, forKey: Self.defaultsKey)
    }
}

/// How the SIM's own number is shown on the SIM page.
enum SIMPhoneNumberPresentation {
    /// "861 •••• 3173": enough to recognize the line, not enough to read the
    /// number off a shared screen. Numbers too short to mask are left as is.
    static func masked(_ number: String) -> String {
        let digits = number.filter { $0 >= "0" && $0 <= "9" }
        guard digits.count >= 7 else { return number }
        return "\(digits.prefix(3)) •••• \(digits.suffix(4))"
    }

    /// What a reveal belongs to: one number on one module. Selecting another
    /// module, or the SIM reporting another number, no longer matches the
    /// key that was revealed, so the new number starts out masked.
    static func revealKey(moduleID: String?, number: String?) -> String? {
        guard let number, !number.isEmpty else { return nil }
        return "\(moduleID ?? "")|\(number)"
    }
}

/// AT+QCALLCFG="voice_disable" on data-only Quectel modules. Two of its four
/// values are understood: 1, which the RM520N-GL ships with and which makes
/// every ATD answer NO CARRIER, and 2, which Quectel support gives for
/// enabling calls. Nothing is offered or written for the others.
enum VoiceCallSwitchPolicy {
    static let disabledSetting = 1
    static let enabledSetting = 2

    static func isEnabled(setting: Int?) -> Bool? {
        switch setting {
        case disabledSetting: return false
        case enabledSetting: return true
        default: return nil
        }
    }

    static func setting(enabled: Bool) -> Int {
        enabled ? enabledSetting : disabledSetting
    }
}

/// Holds back "VoLTE is not available" until the module has kept saying so
/// for a while. IMS registers a few seconds after the packet
/// domain does, so the first reads after a start, a SIM change or a slot
/// switch are 0 on every healthy line and must not raise a warning.
struct VoLTEReportDebouncer: Equatable {
    /// Two regular radio refreshes after the first negative reading.
    static let settleInterval: TimeInterval = 20

    private(set) var firstNegativeAt: Date?

    mutating func reset() {
        firstNegativeAt = nil
    }

    /// Feeds one AT+QCFG="ims" reading; returns what may be published.
    mutating func publishable(_ reported: Bool?, now: Date) -> Bool? {
        guard reported == false else {
            firstNegativeAt = nil
            return reported
        }
        guard let firstNegativeAt else {
            self.firstNegativeAt = now
            return nil
        }
        return now.timeIntervalSince(firstNegativeAt) >= Self.settleInterval ? false : nil
    }
}

enum CellularDataConnectionState: Equatable {
    case disabled
    case waitingForModem
    case starting
    /// The service is enabled but the ECM interface has no carrier at all.
    /// Nothing is "connecting" here, so this must not be reported as `starting`;
    /// `isRetrying` says whether automatic repair is still working on it.
    case linkDown(isRetrying: Bool)
    case interfaceReady
    case available
    case recovering
    case failed
}

struct ModemUSBConfiguration: Equatable {
    let vendorID: Int
    let productID: Int
    let diagnosticEnabled: Bool
    let nmeaEnabled: Bool
    let atPortEnabled: Bool
    let modemEnabled: Bool
    let networkEnabled: Bool
    let adbEnabled: Bool
    let audioEnabled: Bool

    static let cellDockFullTarget = ModemUSBConfiguration(
        vendorID: 0x2C7C,
        productID: 0x0125,
        diagnosticEnabled: true,
        nmeaEnabled: true,
        atPortEnabled: true,
        modemEnabled: true,
        networkEnabled: true,
        adbEnabled: true,
        audioEnabled: true
    )

    // Kept as a source-compatible alias for existing setup and diagnostics.
    static let maVoTarget = cellDockFullTarget

    static let maVoTargetWithoutADB = ModemUSBConfiguration(
        vendorID: 0x2C7C,
        productID: 0x0125,
        diagnosticEnabled: true,
        nmeaEnabled: true,
        atPortEnabled: true,
        modemEnabled: true,
        networkEnabled: true,
        adbEnabled: false,
        audioEnabled: true
    )

    var isSafeDJISource: Bool {
        vendorID == 0x2CA3 && productID == 0x4006 &&
            diagnosticEnabled && nmeaEnabled && atPortEnabled && modemEnabled && networkEnabled &&
            !adbEnabled && !audioEnabled
    }

    var isCellDockTarget: Bool {
        self == Self.cellDockFullTarget
    }

    var isSafeQuectelSource: Bool {
        vendorID == 0x2C7C && productID == 0x0125 && atPortEnabled
    }

    var supportsNativeQuectelRuntime: Bool {
        self == Self.maVoTargetWithoutADB
    }

    var isSafeIdentityConversionSource: Bool {
        isSafeDJISource || self == Self.maVoTargetWithoutADB || isCellDockTarget
    }

    var identity: String {
        String(format: "%04X:%04X", vendorID, productID)
    }

    var compactDescription: String {
        "\(identity) · diag=\(diagnosticEnabled ? 1 : 0) · nmea=\(nmeaEnabled ? 1 : 0) · " +
            "at=\(atPortEnabled ? 1 : 0) · modem=\(modemEnabled ? 1 : 0) · " +
            "net=\(networkEnabled ? 1 : 0) · adb=\(adbEnabled ? 1 : 0) · audio=\(audioEnabled ? 1 : 0)"
    }

    var usbcfgValueDescription: String {
        "\(identity),\(usbcfgFlagValues)"
    }

    var usbcfgWriteCommand: String {
        let identifiers = String(format: "0x%04X,0x%04X", vendorID, productID)
        return "AT+QCFG=\"USBCFG\",\(identifiers),\(usbcfgFlagValues)"
    }

    private var usbcfgFlagValues: String {
        [
            diagnosticEnabled,
            nmeaEnabled,
            atPortEnabled,
            modemEnabled,
            networkEnabled,
            adbEnabled,
            audioEnabled
        ]
        .map { $0 ? "1" : "0" }
        .joined(separator: ",")
    }
}

/// Decides which modules may use AT+QUIMSLOT. Single-slot modules such as the
/// EG25 can still answer the command, so support is gated on the firmware
/// identity first and the command is never sent to other modules.
enum SIMSlotSwitchingPolicy {
    static let slotCount = 2
    static let dualSlotFirmwarePrefixes = ["RM520N"]

    static func firmwareMayHaveDualSlots(_ firmwareVersion: String?) -> Bool {
        guard let identity = firmwareVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              !identity.isEmpty else {
            return false
        }
        return dualSlotFirmwarePrefixes.contains { identity.hasPrefix($0.uppercased()) }
    }

    static func isSupported(firmwareVersion: String?, reportedSlot: Int?) -> Bool {
        guard firmwareMayHaveDualSlots(firmwareVersion),
              let reportedSlot else {
            return false
        }
        return (1 ... slotCount).contains(reportedSlot)
    }
}

/// Decides when to ask for 5G registration. AT+CEREG? only covers LTE/EPS,
/// so a 5G SA-registered RM520N reports "not registered" there. Other
/// firmware never receives AT+C5GREG?.
enum NR5GRegistrationPolicy {
    static let firmwarePrefixes = ["RM520N"]

    static func shouldQueryC5GREG(
        firmwareVersion: String?,
        epsRegistration: CellularRegistrationState
    ) -> Bool {
        guard !epsRegistration.hasService,
              let identity = firmwareVersion?
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .uppercased(),
              !identity.isEmpty else {
            return false
        }
        return firmwarePrefixes.contains { identity.hasPrefix($0.uppercased()) }
    }

    /// The 5G state replaces the EPS state only when +C5GREG parsed.
    static func effectiveRegistration(
        eps: CellularRegistrationState,
        nr: CellularRegistrationState?
    ) -> CellularRegistrationState {
        nr ?? eps
    }
}

/// How long a module that was told to restart may take to bring its USB and
/// AT interface back before CellDock reports a failure.
enum ModuleRestartPolicy {
    /// The 45 seconds were measured on the QDC507. A 5G module such as the
    /// RM520N-GL boots a larger system and regularly needs longer, so the same
    /// limit reported a failed restart while the module was still starting.
    static func reconnectWindow(usbIdentity: String?) -> TimeInterval {
        usbIdentity?.uppercased() == "2C7C:0801" ? 90 : 45
    }

    /// The network recovery waits a little longer than the AT session does,
    /// because the ECM interface appears after the AT port.
    static func networkRecoveryWindow(usbIdentity: String?) -> TimeInterval {
        reconnectWindow(usbIdentity: usbIdentity) + 15
    }

    /// How long a module may stay on the bus after AT+CFUN=1,1 before it is
    /// treated as one that ignored the restart. An AT port that still opens
    /// inside this time belongs to the instance that is shutting down and must
    /// not be initialized. The QDC507 drops off within 5 seconds; an
    /// RM520N-GL was measured at 5.6 seconds, which made the 5-second limit
    /// reconnect to the dying module.
    static func shutdownGrace(usbIdentity: String?) -> TimeInterval {
        usbIdentity?.uppercased() == "2C7C:0801" ? 20 : 5
    }
}

/// Decisions around a call whose existence could not be confirmed.
enum CallRecoveryPolicy {
    /// AT+CLCC is read before a freshly opened module is initialized. When it
    /// fails while a restart is expected, the failure is the module going
    /// down or still booting. Treating it as "a call may exist" parked the
    /// service in call recovery, bound to the instance that was about to
    /// disappear.
    static func unreadableCallStateMeansRestart(isExpectingModuleRestart: Bool) -> Bool {
        isExpectingModuleRestart
    }

    /// What a module that just opened at the expected USB location is to a
    /// call the service is still holding.
    enum ReopenedModule: Equatable {
        /// No call was being held. Initialize it like any attached module.
        case fresh
        /// The same USB enumeration answered again, so the call may still be
        /// up on it. Reconcile over AT+CLCC.
        case sameInstance
        /// A new enumeration answered where the call's module used to be.
        case replacedInstance
    }

    /// A call lives on one USB enumeration of its module. Once a different
    /// enumeration answers at that location, the instance that carried the
    /// call has left the bus: nothing can reach the call, or the cleanup
    /// still owed to that instance, ever again. Holding the call open then
    /// protects nothing and left the AT session down until the app was
    /// restarted, with the call missing from the history.
    ///
    /// The call is therefore over. The new enumeration is never taken for
    /// its continuation: it is opened as a freshly attached module, which
    /// includes the check for a call it may itself be carrying.
    static func reopenedModule(wasHoldingCall: Bool, isSameInstance: Bool) -> ReopenedModule {
        guard wasHoldingCall else { return .fresh }
        return isSameInstance ? .sameInstance : .replacedInstance
    }
}

/// Rules for handing an SMS to the module.
enum SMSSubmissionPolicy {
    /// How long to wait for +CMGS or +CMS ERROR after the PDU was written.
    /// Quectel documents a network-bound maximum of 120 seconds for AT+CMGS.
    /// Giving up earlier abandons a command the module is still executing:
    /// the AT port then stays busy, the session has to be torn down, and the
    /// real result (usually a +CMS ERROR that explains the failure) is lost.
    static let confirmationTimeoutMilliseconds: Int32 = 150_000

    /// Whether the module has any service to submit on. Only a definite
    /// "no service" in every domain blocks the send; a failed or unknown
    /// query must not, because the registration commands themselves can fail
    /// on firmware where SMS still works.
    static func canSubmit(
        packet: CellularRegistrationState,
        voice: CellularRegistrationState
    ) -> Bool {
        if packet.hasService || voice.hasService { return true }
        return !(packet.isDefinitelyWithoutService && voice.isDefinitelyWithoutService)
    }
}

extension CellularRegistrationState {
    /// The module answered and said it is not on a network. `.unknown`,
    /// `.unavailable` and `.queryFailed` are deliberately excluded.
    var isDefinitelyWithoutService: Bool {
        switch self {
        case .notRegistered, .searching, .denied:
            return true
        case .unavailable, .registered, .unknown, .roaming, .queryFailed:
            return false
        }
    }
}

struct ModemSnapshot: Equatable {
    var state: ModemConnectionState = .disconnected
    var lifecyclePhase: ModemLifecyclePhase = .normal
    var usbIdentity: String?
    var usbLocationID: UInt32?
    var usbRegistryID: UInt64?
    var usbVendorName: String?
    var usbProductName: String?
    var hardwareFamily: ModemHardwareFamily = .unknown
    var firmwareVersion: String?
    var voiceCapability: ModemVoiceCapability = .unknown
    var operatorName: String?
    var accessTechnology: String?
    var signalDBm: Int?
    var signalDetail: String?
    var simState: SIMState = .unavailable
    var simLastError: String?
    /// EPS/packet-domain registration reported by AT+CEREG?.
    var registrationState: CellularRegistrationState = .unavailable
    /// Circuit-switched voice-domain registration reported by AT+CREG?.
    var voiceRegistrationState: CellularRegistrationState = .unavailable
    var simPhoneNumber: String?
    var simICCID: String?
    var simIMSI: String?
    var moduleIMEI: String?
    var usbNetMode: Int?
    var imsMode: Int?
    /// Quectel AT+QCFG="ims" VoLTE_cap. A value of 1 means a VoLTE
    /// session is available, not merely that IMS was enabled in settings.
    var volteSessionAvailable: Bool?
    /// AT+QCALLCFG="voice_disable" as reported, on firmware that has it. 1 is
    /// what a data-only RM520N-GL ships with and makes ATD answer NO CARRIER;
    /// 2 is the value Quectel support gives for enabling calls.
    var voiceDisableSetting: Int?
    /// Whether an IMS PDN is up (the IMS APN context is active). It shows
    /// that IMS is running, not that IMS registration succeeded.
    var imsBearerActive: Bool?
    var usbConfiguration: ModemUSBConfiguration?
    var endpointDescription: String?
    var lastError: String?
    /// Active SIM slot (1-based) reported by AT+QUIMSLOT? on dual-slot modules.
    var simSlot: Int?
    /// True only for known dual-slot firmware that also answered AT+QUIMSLOT?.
    var simSlotSwitchingSupported: Bool = false

    var signalBars: Int {
        guard let signalDBm else { return 0 }
        switch signalDBm {
        case ...(-121): return 0
        case -120...(-111): return 1
        case -110...(-101): return 2
        case -100...(-91): return 3
        default: return 4
        }
    }

    var isConnected: Bool {
        state == .connected
    }

    var simReady: Bool {
        simState == .ready
    }

    /// Why this SIM cannot place a call right now, or nil when it is ready.
    /// Shared by every dialer so they cannot disagree about the SIM.
    var dialBlockedBySIMText: String? {
        switch simState {
        case .ready: return nil
        case .pinRequired: return L10n.tr("需要 SIM PIN 后才能拨号")
        case .pukRequired: return L10n.tr("需要 SIM PUK 后才能拨号")
        case .absent: return L10n.tr("插入 SIM 卡后才能拨号")
        case .queryFailed: return L10n.tr("确认 SIM 状态后才能拨号")
        case .unavailable, .initializing: return L10n.tr("正在等待 SIM 卡就绪")
        }
    }

    var voiceServiceAvailability: VoiceServiceAvailability {
        guard simReady else { return .unavailable }
        if volteSessionAvailable == true {
            return .available
        }
        if voiceDisableSetting == 1 {
            // A firmware setting, not a state: it holds with or without
            // registration and no other reading can argue with it.
            return .disabledByFirmware
        }

        // CREG only reports network registration; it does not prove that the
        // subscription authorizes voice calls. Some LTE modules also report
        // CREG registered/roaming for data-only SIMs. Missing CNUM/MSISDN is
        // likewise only supporting information and is intentionally ignored.
        guard registrationState.hasService else { return .unknown }

        guard volteSessionAvailable == false else { return .unknown }

        // VoLTE is not ready. Say why, as far as the module lets us tell: a
        // SIM is only suspected once IMS is known to be switched on and still
        // has no bearer.
        switch imsMode {
        case 2:
            return .imsDisabled
        case 0:
            // IMS follows the carrier configuration (MBN). A bearer means the
            // MBN enabled it; without one it was never brought up.
            return imsBearerActive == true ? .volteNotReady : .imsDisabled
        default:
            return imsBearerActive == true ? .volteNotReady : .likelyDataOnly
        }
    }

    /// One line for a dialer when a call is unlikely to connect, nil when
    /// there is nothing to warn about. Shared so every dialer says the same.
    var voiceServiceCautionText: String? {
        switch voiceServiceAvailability {
        case .disabledByFirmware:
            return L10n.tr("该模组的固件已关闭语音通话，目前仅支持数据。")
        case .likelyDataOnly:
            return L10n.tr("该 SIM 可能仅支持数据，未检测到可用语音服务。")
        case .imsDisabled:
            return L10n.tr("模组未开启 IMS，请在 SIM 页开启“接收来电”。")
        case .volteNotReady:
            return L10n.tr("模组未报告 VoLTE 就绪，通话可能无法接通。")
        case .available, .unknown, .unavailable:
            return nil
        }
    }

    /// Whether the firmware's voice switch can be offered, and where it
    /// stands: nil when this module has no such switch or reports a value
    /// whose meaning is not known.
    var firmwareVoiceCallsEnabled: Bool? {
        VoiceCallSwitchPolicy.isEnabled(setting: voiceDisableSetting)
    }

    /// AT+QCFG="ims" 1 forces IMS on. 0 leaves it to the carrier
    /// configuration and 2 forces it off, so neither is "switched on".
    var incomingCallsForcedOn: Bool? {
        imsMode.map { $0 == 1 }
    }

    /// Whether carrier calls can reach the module as far as it reports: IMS
    /// forced on, or left to the carrier configuration with voice available.
    var incomingCallsEffective: Bool {
        switch imsMode {
        case 1: return true
        case 0: return voiceServiceAvailability == .available
        default: return false
        }
    }

    var operationalState: ModemOperationalState {
        switch lifecyclePhase {
        case .restarting:
            return .restarting
        case .reconnecting:
            return .reconnecting
        case .normal:
            break
        }

        switch state {
        case .disconnected:
            return .absent
        case .connecting:
            return usbIdentity == nil ? .enumerating : .initializing
        case .error:
            return .failed
        case .connected:
            break
        }

        switch initialSetupState {
        case .ready:
            return .ready
        case .inspecting:
            return .initializing
        case .needsIdentityConversion, .needsECM, .needsECMSwitch, .unsupportedIdentity,
             .unsupportedUSBConfiguration, .unsupportedUSBNetMode:
            return .configurationRequired
        case .insertModule:
            return .absent
        case .failed:
            return .failed
        }
    }

    var initialSetupState: ModemInitialSetupState {
        switch state {
        case .disconnected:
            return .insertModule
        case .connecting:
            return .inspecting
        case .error:
            return .failed(lastError ?? L10n.tr("模块连接异常"))
        case .connected:
            break
        }

        guard let usbIdentity else { return .inspecting }
        let normalizedIdentity = usbIdentity.uppercased()
        if normalizedIdentity == "2CA3:4006" {
            guard let usbConfiguration else {
                return .unsupportedIdentity(normalizedIdentity)
            }
            if usbConfiguration.isSafeIdentityConversionSource {
                return .needsIdentityConversion
            }
            return .unsupportedUSBConfiguration(usbConfiguration.compactDescription)
        }
        if normalizedIdentity == "2C7C:0801" {
            // RM520N-GL: CellDock never writes USBCFG to this module, so
            // any USBCFG is accepted. Only ECM (usbnet 1) works on macOS;
            // from another net mode the switch is offered, and usbnet is
            // the one thing it writes.
            guard let usbNetMode else { return .inspecting }
            return usbNetMode == 1 ? .ready : .needsECMSwitch(usbNetMode)
        }
        guard normalizedIdentity == "2C7C:0125" else {
            return .unsupportedIdentity(normalizedIdentity)
        }
        guard let usbConfiguration else { return .inspecting }
        let supportsRequiredRuntime = usbConfiguration.isCellDockTarget || (
            hardwareFamily == .quectelNativeVoice &&
                usbConfiguration.supportsNativeQuectelRuntime
        )
        guard supportsRequiredRuntime else {
            return .unsupportedUSBConfiguration(usbConfiguration.compactDescription)
        }
        guard let usbNetMode else { return .inspecting }
        switch usbNetMode {
        case 0:
            return .needsECM
        case 1:
            return .ready
        default:
            return .unsupportedUSBNetMode(usbNetMode)
        }
    }
}

enum ModemInitialSetupState: Equatable {
    case insertModule
    case inspecting
    case needsIdentityConversion
    case needsECM
    /// An RM520N-GL in another network mode. Only usbnet has to change; the
    /// associated value is the mode it is in now.
    case needsECMSwitch(Int)
    case ready
    case unsupportedIdentity(String)
    case unsupportedUSBConfiguration(String)
    case unsupportedUSBNetMode(Int)
    case failed(String)
}

struct CellularNetworkStatus: Equatable {
    var serviceID: String?
    var serviceName: String?
    var higherPriorityServiceName: String?
    var bsdName: String?
    var isEnabled = false
    var isActive = false
    var isLinkActive = false
    var isPrioritized = false
    var isDemoted = false
    var isSystemPrimary = false
    var isHardwarePresent = false
    var ipv4Address: String?
    var ipv4Router: String?
    var ipv6Address: String?
    /// Resolver addresses currently published for this exact network service.
    /// For DHCP-backed ECM services these originate from the active lease.
    var dnsServers: [String] = []
    var lastError: String?
    var issue: CellularNetworkIssue?

    var isAvailable: Bool {
        serviceID != nil
    }
}

/// Something worth reporting about how a live cellular interface coexists with
/// the other connected modules. Only `.duplicateAddress` is an actual fault.
enum CellularNetworkIssue: Equatable {
    /// Two modules hold the identical IPv4 address. ARP ownership becomes
    /// ambiguous and either interface can stop working, so this needs attention.
    case duplicateAddress(String)
    /// Two modules sit behind the same gateway. QDC507 firmware always exposes
    /// 192.168.225.1/24 on its ECM side, so this is simply the normal shape of a
    /// multi-module setup, exactly like a Mac with Wi-Fi and Ethernet on one LAN.
    /// macOS scopes every service's default route to its own interface, so
    /// routing and internet access are unaffected. The only consequence is that
    /// an unbound connection to the gateway address cannot pick a module.
    case sharedSubnet(String)

    /// Whether the condition needs the user's attention. Informational entries
    /// must never light up the global "configuration problem" indicator, or the
    /// warning would be permanently on for every multi-module setup.
    var isWarning: Bool {
        switch self {
        case .duplicateAddress: return true
        case .sharedSubnet: return false
        }
    }

    var localizedTitle: String {
        switch self {
        case .duplicateAddress: return L10n.tr("地址冲突")
        case .sharedSubnet: return L10n.tr("共享网段")
        }
    }

    var localizedDetail: String {
        switch self {
        case let .duplicateAddress(address):
            return L10n.tr("其他模组使用了相同的 IP 地址 %@，两个接口都可能无法工作。", address)
        case let .sharedSubnet(router):
            return L10n.tr("与其他模组共用网关 %@。上网不受影响；仅当按 IP 直连时无法区分模组。", router)
        }
    }
}

/// Detects address collisions across simultaneously connected modules. Only
/// interfaces that are enabled, present, and already hold an IPv4 lease can
/// collide, so anything else is reported as conflict-free.
enum CellularNetworkConflictPolicy {
    static func issues(
        forStatusesByLocationID statuses: [UInt32: CellularNetworkStatus]
    ) -> [UInt32: CellularNetworkIssue] {
        let candidates = statuses.filter {
            $0.value.isEnabled && $0.value.isHardwarePresent && $0.value.ipv4Address != nil
        }
        guard candidates.count > 1 else { return [:] }

        var issues: [UInt32: CellularNetworkIssue] = [:]
        var locationsByAddress: [String: [UInt32]] = [:]
        for (locationID, status) in candidates {
            guard let address = status.ipv4Address else { continue }
            locationsByAddress[address, default: []].append(locationID)
        }
        for (address, locationIDs) in locationsByAddress where locationIDs.count > 1 {
            for locationID in locationIDs {
                issues[locationID] = .duplicateAddress(address)
            }
        }

        var locationsByRouter: [String: [UInt32]] = [:]
        for (locationID, status) in candidates where issues[locationID] == nil {
            guard let router = status.ipv4Router else { continue }
            locationsByRouter[router, default: []].append(locationID)
        }
        for (router, locationIDs) in locationsByRouter where locationIDs.count > 1 {
            for locationID in locationIDs {
                issues[locationID] = .sharedSubnet(router)
            }
        }
        return issues
    }
}

enum CellularNetworkPresentationPolicy {
    static func effectiveEnabled(
        actualEnabled: Bool,
        pendingEnabled: Bool?
    ) -> Bool {
        pendingEnabled ?? actualEnabled
    }
}

extension CellularNetworkMode {
    static let defaultConnectionMode: CellularNetworkMode = .standby

    var localizedTitle: String {
        switch self {
        case .off: return L10n.tr("完全关闭")
        case .standby: return L10n.tr("保持连接")
        case .preferred: return L10n.tr("蜂窝优先")
        }
    }

    var localizedDetail: String {
        switch self {
        case .off: return L10n.tr("停用蜂窝网络服务")
        case .standby: return L10n.tr("接口保持可用，其他网络优先")
        case .preferred: return L10n.tr("使用蜂窝网络作为主要网络")
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "power"
        case .standby: return "rectangle.connected.to.line.below"
        case .preferred: return "antenna.radiowaves.left.and.right"
        }
    }
}

enum CellularDataConnectionPolicy {
    static func state(
        modem: ModemSnapshot,
        network: CellularNetworkStatus,
        isPresentedEnabled: Bool,
        isChangingNetwork: Bool,
        isRecovering: Bool,
        isRetryingLink: Bool = true
    ) -> CellularDataConnectionState {
        guard isPresentedEnabled else { return .disabled }
        if isRecovering { return .recovering }
        if isChangingNetwork { return .starting }

        switch modem.operationalState {
        case .ready, .configurationRequired:
            break
        case .failed:
            return .failed
        case .absent, .enumerating, .initializing, .restarting, .reconnecting:
            return .waitingForModem
        }

        if network.isActive {
            return modem.simState == .ready && modem.registrationState.hasService
                ? .available
                : .interfaceReady
        }
        if network.lastError != nil { return .failed }
        // An enabled service without carrier is a broken link, not a connection
        // in progress. Reporting it as `starting` left the UI claiming "正在连接"
        // forever, because nothing downstream ever populates `lastError`.
        if network.isEnabled, !network.isLinkActive {
            return .linkDown(isRetrying: isRetryingLink)
        }
        return .starting
    }
}

enum NetworkAddressClassifier {
    static func isUsableIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { component -> Int? in
            guard !component.isEmpty,
                  component.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let value = Int(component),
                  (0 ... 255).contains(value) else {
                return nil
            }
            return value
        }
        guard values.count == 4 else { return false }
        if values[0] == 0 || values[0] == 127 || values[0] >= 224 { return false }
        if values[0] == 169 && values[1] == 254 { return false }
        return true
    }
}

enum CellularDNSStateParser {
    static func serverAddresses(from dictionary: [String: Any]?) -> [String] {
        guard let addresses = dictionary?["ServerAddresses"] as? [String] else { return [] }
        var seen: Set<String> = []
        return addresses.compactMap { address in
            let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}

enum CellularNetworkPriorityPolicy {
    static func shouldAutoPromote(
        network: CellularNetworkStatus,
        modem: ModemSnapshot,
        desiredMode: CellularNetworkMode = .preferred,
        isChangingNetwork: Bool,
        attemptedServiceID: String?
    ) -> Bool {
        guard let serviceID = network.serviceID else { return false }
        return desiredMode == .preferred &&
            network.isEnabled &&
            network.isHardwarePresent &&
            !network.isPrioritized &&
            modem.isConnected &&
            modem.usbNetMode == 1 &&
            !isChangingNetwork &&
            attemptedServiceID != serviceID
    }
}

enum CellularNetworkStartupPolicy {
    static func isApplied(
        _ mode: CellularNetworkMode,
        to network: CellularNetworkStatus
    ) -> Bool {
        switch mode {
        case .off:
            return !network.isEnabled
        case .standby:
            return network.isEnabled && network.isDemoted
        case .preferred:
            return network.isEnabled && network.isPrioritized
        }
    }

    static func shouldRestore(
        network: CellularNetworkStatus,
        modem: ModemSnapshot,
        isChangingNetwork: Bool,
        restorePending: Bool,
        restoreInFlight: Bool,
        desiredMode: CellularNetworkMode? = .preferred
    ) -> Bool {
        guard let desiredMode else { return false }
        let modeIsApplied = isApplied(desiredMode, to: network)
        return restorePending &&
            !restoreInFlight &&
            !isChangingNetwork &&
            !modeIsApplied &&
            network.isHardwarePresent &&
            modem.isConnected &&
            modem.usbNetMode == 1
    }
}

final class CellularNetworkingPreferenceStore {
    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String?

    init(
        defaults: UserDefaults = .standard,
        key: String = "CellularNetworkingModeByModule.v2",
        legacyKey: String? = "CellularNetworkingPreferencesByModule.v1"
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyKey = legacyKey
    }

    func preferredMode(forModule identity: String) -> CellularNetworkMode? {
        if let rawValue = defaults.dictionary(forKey: key)?[identity] as? Int,
           let mode = CellularNetworkMode(rawValue: rawValue) {
            return mode
        }
        guard let legacyKey,
              let enabled = defaults.dictionary(forKey: legacyKey)?[identity] as? Bool else {
            return nil
        }
        // The v1 flag bundled two meanings that are now separate: "keep this
        // module connected" and "make it the default route". Only the first is
        // restored. Cellular priority is an exclusive, route-hijacking state, so
        // claiming it on the user's behalf during a migration would be a
        // surprise on a multi-module Mac; re-selecting it costs one click.
        return enabled ? .standby : .off
    }

    func setPreferredMode(_ mode: CellularNetworkMode, forModule identity: String) {
        var preferences = defaults.dictionary(forKey: key) ?? [:]
        preferences[identity] = mode.rawValue
        defaults.set(preferences, forKey: key)
    }
}

enum ModuleVoiceInitializationRetryPolicy {
    private static let delays: [TimeInterval] = [2, 5, 10, 30, 60]

    static func delay(forCompletedAttempts attempts: Int) -> TimeInterval? {
        guard delays.indices.contains(attempts) else { return nil }
        return delays[attempts]
    }

    static func busyMessage(
        ownerName: String?,
        processID: Int32?,
        retryAttempt: Int?
    ) -> String? {
        let trimmedOwner = ownerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let retryAttempt {
            if let owner = trimmedOwner, !owner.isEmpty, let processID, processID > 0 {
                return L10n.tr(
                    "模块控制接口正被 %@（PID %@）占用；CellDock 将自动重试（%lld/5）。",
                    owner,
                    String(processID),
                    Int64(retryAttempt)
                )
            }
            return L10n.tr(
                "模块控制接口正被其他 ADB 客户端占用；CellDock 将自动重试（%lld/5）。",
                Int64(retryAttempt)
            )
        }
        if let owner = trimmedOwner, !owner.isEmpty, let processID, processID > 0 {
            return L10n.tr(
                "模块控制接口正被 %@（PID %@）占用，可点击「结束占用并重试」或手动退出该进程。",
                owner,
                String(processID)
            )
        }
        return nil
    }
}

struct ConcatenationInfo: Hashable {
    let reference: Int
    let referenceBits: Int
    let total: Int
    let sequence: Int
}

struct DecodedPDU {
    let sender: String
    let body: String
    let timestamp: Date?
    let concatenation: ConcatenationInfo?
    let dataCodingScheme: UInt8
    let rawPDU: String
}

struct ModemStoredPDU {
    let index: Int
    let status: Int
    let declaredLength: Int?
    let rawPDU: String
    let storage: String?
}

struct ModemPDUReference: Codable, Hashable {
    let storage: String
    let index: Int
    let rawPDU: String

    init?(storedPDU: ModemStoredPDU) {
        guard let storage = storedPDU.storage?.uppercased(),
              ["SM", "ME", "MT"].contains(storage),
              storedPDU.index >= 0 else {
            return nil
        }
        self.storage = storage
        index = storedPDU.index
        rawPDU = storedPDU.rawPDU.uppercased()
    }
}

enum SMSDeletionPlanner {
    static func orderedTargets(from references: [ModemPDUReference]) -> [ModemPDUReference] {
        var seen: Set<ModemPDUReference> = []
        return references
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.storage != rhs.storage { return lhs.storage < rhs.storage }
                if lhs.index != rhs.index { return lhs.index > rhs.index }
                return lhs.rawPDU < rhs.rawPDU
            }
    }

    static func isBareEmptyCMGR(_ lines: [String], index: Int) -> Bool {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty && $0 != "AT+CMGR=\(index)" } == ["OK"]
    }
}

struct ModemMessageLocation: Hashable {
    let storage: String
    let index: Int
}

struct ModemURCBatch {
    var messageLocations: [ModemMessageLocation] = []
    var directPDUs: [String] = []
}

/// Frames modem URCs as a byte stream rather than assuming one USB read is one event.
/// A direct `+CMT` consists of a header line followed by one PDU line, so that header
/// must also survive across reads and across an intervening AT command response.
struct ModemURCStreamFramer {
    private var pendingLine = ""
    private var pendingDirectCMTHeader: String?
    private var pendingDirectCMTIgnoredLines = 0

    mutating func consume(_ text: String) -> ModemURCBatch {
        guard !text.isEmpty else { return ModemURCBatch() }

        pendingLine += text
        let normalized = pendingLine
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let endedAtLineBoundary = pendingLine.last == "\r" || pendingLine.last == "\n"
        var lines = normalized.components(separatedBy: "\n")
        if endedAtLineBoundary {
            pendingLine = ""
        } else {
            pendingLine = lines.popLast() ?? ""
            if pendingLine.utf8.count > 16 * 1_024 {
                pendingLine = String(pendingLine.suffix(4 * 1_024))
            }
        }

        var batch = ModemURCBatch()
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let header = pendingDirectCMTHeader {
                if line.hasPrefix("+CMT:") {
                    // A new direct-message header supersedes an older malformed
                    // or incomplete one.
                    pendingDirectCMTHeader = line
                    pendingDirectCMTIgnoredLines = 0
                    continue
                }
                if let pdu = ATResponseParser.parseDirectCMT(
                    "\(header)\r\n\(line)\r\n"
                ).first,
                   (try? SMSPDUDecoder.decode(pdu)) != nil {
                    batch.directPDUs.append(pdu)
                    pendingDirectCMTHeader = nil
                    pendingDirectCMTIgnoredLines = 0
                    continue
                }
                // Command responses and other URCs can be interleaved between the
                // header and PDU. Keep the header for a bounded number of complete
                // lines, and only accept a PDU that fully decodes as SMS-DELIVER.
                pendingDirectCMTIgnoredLines += 1
                if pendingDirectCMTIgnoredLines >= 32 {
                    pendingDirectCMTHeader = nil
                    pendingDirectCMTIgnoredLines = 0
                }
            }

            if line.hasPrefix("+CMTI:") {
                batch.messageLocations += ATResponseParser.parseCMTI(line).map {
                    ModemMessageLocation(storage: $0.storage, index: $0.index)
                }
            } else if line.hasPrefix("+CMT:") {
                pendingDirectCMTHeader = line
                pendingDirectCMTIgnoredLines = 0
            }
        }
        return batch
    }

    mutating func reset() {
        pendingLine = ""
        pendingDirectCMTHeader = nil
        pendingDirectCMTIgnoredLines = 0
    }
}

struct MessageStorageSyncTracker {
    private var synchronizedStorages: Set<String> = []

    mutating func markSuccessfulPoll(of storage: String) -> Bool {
        synchronizedStorages.insert(storage.uppercased()).inserted
    }

    mutating func reset() {
        synchronizedStorages.removeAll()
    }
}

/// Keeps concatenated SMS parts that arrive in separate `+CMT`/`+CMTI` events.
/// Complete CMGL snapshots can use the same path; exact duplicate parts replace their
/// stored modem reference without creating duplicate messages.
struct BufferedSMSAssembler {
    private struct GroupKey: Hashable {
        let sender: String
        let reference: Int
        let referenceBits: Int
        let total: Int
        let dataCodingScheme: UInt8
    }

    private struct Fragment {
        var storedPDUs: [ModemStoredPDU]
        let decoded: DecodedPDU
        let receivedAt: Date

        mutating func addReference(_ stored: ModemStoredPDU) {
            guard !storedPDUs.contains(where: {
                $0.storage == stored.storage &&
                    $0.index == stored.index &&
                    $0.rawPDU.caseInsensitiveCompare(stored.rawPDU) == .orderedSame
            }) else {
                return
            }
            storedPDUs.append(stored)
        }
    }

    private struct FragmentIdentity: Hashable {
        let storage: String?
        let index: Int
        let rawPDU: String
    }

    private struct Cluster {
        var fragmentsBySequence: [Int: Fragment] = [:]

        var mostRecentReceipt: Date {
            fragmentsBySequence.values.map(\.receivedAt).max() ?? .distantPast
        }

        var mostRecentMessageDate: Date? {
            fragmentsBySequence.values.compactMap { $0.decoded.timestamp }.max()
        }
    }

    private var groups: [GroupKey: [Cluster]] = [:]
    private var firstSeenByFragment: [FragmentIdentity: Date] = [:]
    private let retentionInterval: TimeInterval = 24 * 60 * 60
    private let groupingWindow: TimeInterval = 12 * 60 * 60

    mutating func ingest(_ storedPDUs: [ModemStoredPDU], now: Date = Date()) -> [SMSMessage] {
        removeExpiredFragments(now: now)
        var singlePDUs: [ModemStoredPDU] = []
        var completedMessages: [SMSMessage] = []

        for stored in storedPDUs {
            guard let decoded = try? SMSPDUDecoder.decode(stored.rawPDU) else { continue }
            guard let concatenation = decoded.concatenation else {
                singlePDUs.append(stored)
                continue
            }

            let key = GroupKey(
                sender: decoded.sender,
                reference: concatenation.reference,
                referenceBits: concatenation.referenceBits,
                total: concatenation.total,
                dataCodingScheme: decoded.dataCodingScheme
            )
            var clusters = groups[key] ?? []
            let identity = FragmentIdentity(
                storage: stored.storage?.uppercased(),
                index: stored.index,
                rawPDU: decoded.rawPDU
            )
            if firstSeenByFragment[identity] == nil,
               firstSeenByFragment.count >= 4096,
               let oldest = firstSeenByFragment.min(by: { $0.value < $1.value })?.key {
                firstSeenByFragment.removeValue(forKey: oldest)
            }
            let firstSeen = firstSeenByFragment[identity] ?? now
            firstSeenByFragment[identity] = firstSeen
            guard now.timeIntervalSince(firstSeen) <= retentionInterval else {
                continue
            }
            let fragment = Fragment(storedPDUs: [stored], decoded: decoded, receivedAt: firstSeen)

            if let duplicateCluster = clusters.firstIndex(where: { cluster in
                cluster.fragmentsBySequence.values.contains {
                    $0.decoded.rawPDU.caseInsensitiveCompare(decoded.rawPDU) == .orderedSame
                }
            }) {
                clusters[duplicateCluster].fragmentsBySequence[concatenation.sequence]?
                    .addReference(stored)
            } else {
                let messageDate = decoded.timestamp ?? now
                let candidates = clusters.indices.filter { index in
                    let cluster = clusters[index]
                    guard cluster.fragmentsBySequence[concatenation.sequence] == nil else {
                        return false
                    }
                    let clusterDate = cluster.mostRecentMessageDate ?? cluster.mostRecentReceipt
                    return abs(messageDate.timeIntervalSince(clusterDate)) <= groupingWindow
                }
                if let best = candidates.min(by: { lhs, rhs in
                    let leftDate = clusters[lhs].mostRecentMessageDate ?? clusters[lhs].mostRecentReceipt
                    let rightDate = clusters[rhs].mostRecentMessageDate ?? clusters[rhs].mostRecentReceipt
                    return abs(messageDate.timeIntervalSince(leftDate)) <
                        abs(messageDate.timeIntervalSince(rightDate))
                }) {
                    clusters[best].fragmentsBySequence[concatenation.sequence] = fragment
                } else {
                    var cluster = Cluster()
                    cluster.fragmentsBySequence[concatenation.sequence] = fragment
                    clusters.append(cluster)
                }
            }

            var retainedClusters: [Cluster] = []
            for cluster in clusters {
                let requiredSequences = Set(1 ... concatenation.total)
                guard Set(cluster.fragmentsBySequence.keys) == requiredSequences else {
                    retainedClusters.append(cluster)
                    continue
                }
                let ordered = (1 ... concatenation.total).compactMap {
                    cluster.fragmentsBySequence[$0]?.storedPDUs.first
                }
                var assembled = SMSPDUDecoder.assemble(ordered, now: now)
                if assembled.isEmpty {
                    retainedClusters.append(cluster)
                } else {
                    let completedStoredPDUs = (1 ... concatenation.total)
                        .compactMap { cluster.fragmentsBySequence[$0] }
                        .flatMap(\.storedPDUs)
                    let references = completedStoredPDUs
                        .compactMap(ModemPDUReference.init(storedPDU:))
                    for index in assembled.indices {
                        assembled[index].replaceModemReferences(with: references)
                    }
                    for completed in completedStoredPDUs {
                        firstSeenByFragment.removeValue(forKey: FragmentIdentity(
                            storage: completed.storage?.uppercased(),
                            index: completed.index,
                            rawPDU: completed.rawPDU.uppercased()
                        ))
                    }
                    completedMessages += assembled
                }
            }
            if retainedClusters.isEmpty {
                groups.removeValue(forKey: key)
            } else {
                groups[key] = retainedClusters
            }
        }

        let singles = SMSPDUDecoder.assemble(singlePDUs, now: now)
        return (singles + completedMessages).sorted { $0.timestamp > $1.timestamp }
    }

    mutating func reset() {
        groups.removeAll()
        firstSeenByFragment.removeAll()
    }

    private mutating func removeExpiredFragments(now: Date) {
        for key in Array(groups.keys) {
            let retained = (groups[key] ?? []).compactMap { cluster -> Cluster? in
                var cluster = cluster
                cluster.fragmentsBySequence = cluster.fragmentsBySequence.filter {
                    now.timeIntervalSince($0.value.receivedAt) <= retentionInterval
                }
                return cluster.fragmentsBySequence.isEmpty ? nil : cluster
            }
            if retained.isEmpty {
                groups.removeValue(forKey: key)
            } else {
                groups[key] = retained
            }
        }
    }
}

enum SMSDirection: String, Codable, Equatable {
    case incoming
    case outgoing
}

enum SMSDeliveryState: String, Codable, Equatable {
    case sending
    case sent
    case failed
    case uncertain
}

struct SMSMessage: Identifiable, Codable, Equatable {
    static let interruptedDeliveryDetailCode = "CellDock.SMSDelivery.Interrupted"

    var id: String
    var moduleID: CellularModuleID? = nil
    var modemIndices: [Int]
    var modemStorage: String? = nil
    var modemReferences: [ModemPDUReference]? = nil
    let sender: String
    let body: String
    var timestamp: Date
    let rawPDUs: [String]
    var isRead: Bool
    var readAt: Date? = nil
    var firstSeenAt: Date
    var direction: SMSDirection? = nil
    var deliveryState: SMSDeliveryState? = nil
    var deliveryDetail: String? = nil
    /// SIM slot that was active when CellDock first saw this message. Nil for
    /// single-slot modules and for messages stored before slot tracking.
    var simSlot: Int? = nil

    var isOutgoing: Bool {
        direction == .outgoing
    }

    mutating func assignModule(_ moduleID: CellularModuleID) {
        guard self.moduleID != moduleID else { return }
        self.moduleID = moduleID
        let prefix = "\(moduleID.rawValue)|"
        if !id.hasPrefix(prefix) {
            id = prefix + id
        }
    }

    var peerAddress: String {
        sender
    }

    var preview: String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? L10n.tr("（空短信）") : collapsed
    }

    var verificationCode: String? {
        SMSVerificationCodeExtractor.extract(from: body)
    }

    var localizedDeliveryDetail: String? {
        guard let deliveryDetail else { return nil }
        if deliveryDetail == Self.interruptedDeliveryDetailCode ||
            deliveryDetail == "App 上次退出前未能确认发送结果，请先核对后再决定是否重发。" {
            return L10n.tr("App 上次退出前未能确认发送结果，请先核对后再决定是否重发。")
        }
        return deliveryDetail
    }

    var effectiveModemReferences: [ModemPDUReference] {
        if let modemReferences {
            return modemReferences
        }
        guard let storage = modemStorage?.uppercased(),
              modemIndices.count == rawPDUs.count else {
            return []
        }
        return zip(modemIndices, rawPDUs).compactMap { index, rawPDU in
            ModemPDUReference(
                storedPDU: ModemStoredPDU(
                    index: index,
                    status: 0,
                    declaredLength: nil,
                    rawPDU: rawPDU,
                    storage: storage
                )
            )
        }
    }

    mutating func replaceModemReferences(with references: [ModemPDUReference]) {
        var seen: Set<ModemPDUReference> = []
        let unique = references.filter { seen.insert($0).inserted }
        modemReferences = unique
        modemIndices = unique.map(\.index)
        let storages = Set(unique.map(\.storage))
        modemStorage = storages.count == 1 ? storages.first : nil
    }

    mutating func clearModemReferences() {
        modemReferences = []
        modemIndices = []
        modemStorage = nil
    }
}

struct SMSDeletionConfirmationState {
    private(set) var pendingMessageID: SMSMessage.ID?

    var isPresented: Bool { pendingMessageID != nil }

    mutating func request(_ message: SMSMessage) {
        pendingMessageID = message.id
    }

    mutating func cancel() {
        pendingMessageID = nil
    }

    func resolve(in messages: [SMSMessage]) -> SMSMessage? {
        guard let pendingMessageID else { return nil }
        return messages.first { $0.id == pendingMessageID }
    }

    mutating func reconcile(with messages: [SMSMessage]) {
        guard pendingMessageID != nil, resolve(in: messages) == nil else { return }
        pendingMessageID = nil
    }

    mutating func takeConfirmedMessageID(id: SMSMessage.ID) -> SMSMessage.ID? {
        guard pendingMessageID == id else { return nil }
        pendingMessageID = nil
        return id
    }
}

struct SMSMessageMergeResult {
    let messages: [SMSMessage]
    let newlyDiscovered: [SMSMessage]
}

enum SMSMessageMerger {
    static func merge(
        existing: [SMSMessage],
        incoming: [SMSMessage],
        limit: Int = 500
    ) -> SMSMessageMergeResult {
        var byID: [SMSMessage.ID: SMSMessage] = [:]
        for message in existing where byID[message.id] == nil {
            byID[message.id] = message
        }
        var newlyDiscovered: [SMSMessage] = []

        for var candidate in incoming {
            if let previous = byID[candidate.id] {
                candidate.isRead = previous.isRead
                candidate.readAt = previous.readAt
                candidate.timestamp = previous.timestamp
                candidate.firstSeenAt = previous.firstSeenAt
                // Messages kept in module storage survive a slot switch; keep
                // the slot recorded when the message was first seen.
                candidate.simSlot = previous.simSlot
                candidate.replaceModemReferences(
                    with: previous.effectiveModemReferences + candidate.effectiveModemReferences
                )
                byID[candidate.id] = candidate
            } else {
                byID[candidate.id] = candidate
                newlyDiscovered.append(candidate)
            }
        }

        let merged = byID.values
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp { return lhs.firstSeenAt > rhs.firstSeenAt }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(max(0, limit))
            .map { $0 }
        let retainedIDs = Set(merged.map(\.id))
        return SMSMessageMergeResult(
            messages: merged,
            newlyDiscovered: newlyDiscovered
                .filter { retainedIDs.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
        )
    }
}

enum ModemMessageStorageCapabilities {
    static func readableStorages(from response: String) -> [String] {
        guard let line = ATResponseParser.normalizedLines(response)
            .first(where: { $0.hasPrefix("+CPMS:") }),
              let opening = line.firstIndex(of: "("),
              let closing = line[opening...].firstIndex(of: ")") else {
            return []
        }

        let firstGroup = line[line.index(after: opening) ..< closing]
        var result: [String] = []
        var token = ""
        var insideQuotes = false
        for character in firstGroup {
            if character == "\"" {
                if insideQuotes {
                    let storage = token.uppercased()
                    if ["SM", "ME", "MT"].contains(storage), !result.contains(storage) {
                        result.append(storage)
                    }
                    token = ""
                }
                insideQuotes.toggle()
            } else if insideQuotes {
                token.append(character)
            }
        }
        return result
    }
}

enum ModemActionResult: Equatable {
    case success(String? = nil)
    case failure(String)
}

enum CellularNetworkFailureReason: Equatable {
    case linkInactive
    case dhcpTimeout
    case other

    /// The helper only reports these two reasons from the DHCP stage, which runs
    /// after the service order and enabled states have already been committed.
    /// The app must therefore persist the requested modes even though the link
    /// is not up yet; otherwise the UI keeps showing the previous modes and the
    /// committed configuration is silently lost on the next launch.
    var configurationWasApplied: Bool {
        switch self {
        case .linkInactive, .dhcpTimeout:
            return true
        case .other:
            return false
        }
    }
}

enum CellularNetworkActionResult: Equatable {
    case success(String? = nil)
    case failure(String, reason: CellularNetworkFailureReason)

    var displayResult: ModemActionResult {
        switch self {
        case let .success(message):
            return .success(message)
        case let .failure(message, _):
            return .failure(message)
        }
    }

    var failureReason: CellularNetworkFailureReason? {
        guard case let .failure(_, reason) = self else { return nil }
        return reason
    }
}
