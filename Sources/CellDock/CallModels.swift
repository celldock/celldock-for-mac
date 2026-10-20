import Foundation

enum CallPhase: String, Equatable {
    case unavailable
    case idle
    case incoming
    case dialing
    case alerting
    case active
    case ending
    case recovering
    case error
}

enum CallDirection: String, Codable, Equatable {
    case outgoing
    case incoming
}

enum CallEndReason: String, Codable, Equatable {
    case localHangup
    // Retained for decoding existing call history; generic release indications
    // do not establish that the remote user pressed Hang Up.
    case remoteHangup
    case unknown
    case busy
    case noAnswer
    case noDialTone
    case deviceDisconnected
    case failed

    var localizedDescription: String {
        switch self {
        case .localHangup: return L10n.tr("通话已结束")
        case .remoteHangup: return L10n.tr("对方已挂断")
        case .unknown: return L10n.tr("通话已结束，原因未知")
        case .busy: return L10n.tr("对方忙线")
        case .noAnswer: return L10n.tr("无人接听")
        case .noDialTone: return L10n.tr("网络未提供拨号音")
        case .deviceDisconnected: return L10n.tr("模块已拔出，通话结束")
        case .failed: return L10n.tr("通话失败")
        }
    }
}

struct CallEndEvidence: Codable, Equatable {
    enum Source: String, Codable {
        case localAction
        case modemResultCode
        case callListEmpty
        case deviceDisconnected
        case internalFailure
    }

    let source: Source
    var code: String? = nil

    static func modemResult(_ code: String) -> Self {
        Self(source: .modemResultCode, code: code)
    }
}

struct UACMediaSnapshot: Equatable {
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputTotalSamples: UInt64 = 0
    var inputSignalSamples: UInt64 = 0
    var inputPeakPCM16: UInt32 = 0
    var inputSignalThresholdPCM16: UInt32 = 0
}

struct CallSnapshot: Equatable {
    var moduleID: CellularModuleID?
    var phase: CallPhase = .unavailable
    var direction: CallDirection?
    var number: String?
    var voiceOverUSBSupported = false
    var audioActive = false
    var muted = false
    var startedAt: Date?
    var lastEndReason: CallEndReason?
    var lastEndEvidence: CallEndEvidence?
    var lastError: String?
    var controlInterfaceBusy = false
    var mediaCleanupPending = false
    var uacMedia: UACMediaSnapshot?

    var hasCall: Bool {
        switch phase {
        case .incoming, .dialing, .alerting, .active, .ending, .recovering:
            return true
        case .unavailable, .idle, .error:
            return false
        }
    }

    var canDial: Bool {
        phase == .idle && voiceOverUSBSupported && !mediaCleanupPending
    }

    var canSendDTMF: Bool {
        phase == .active
    }

    mutating func recordEnd(_ reason: CallEndReason, evidence: CallEndEvidence) {
        // ATH can produce a delayed NO CARRIER after local cleanup completes.
        if lastEndEvidence?.source == .localAction, evidence.source != .localAction { return }
        if reason == .unknown {
            if let previous = lastEndReason, previous != .unknown, previous != .failed { return }
            if lastEndEvidence?.source == .modemResultCode, evidence.source == .callListEmpty { return }
        }
        lastEndReason = reason
        lastEndEvidence = evidence
    }

    // Re-probing the same module after call cleanup must not erase the result
    // before API clients can observe it. Active call/media state is still reset.
    mutating func resetForInitialization(
        phase: CallPhase,
        voiceOverUSBSupported: Bool,
        lastError: String? = nil,
        controlInterfaceBusy: Bool = false
    ) {
        self = Self(
            phase: phase,
            voiceOverUSBSupported: voiceOverUSBSupported,
            lastEndReason: lastEndReason,
            lastEndEvidence: lastEndEvidence,
            lastError: lastError,
            controlInterfaceBusy: controlInterfaceBusy
        )
    }

    mutating func clearEnd() {
        lastEndReason = nil
        lastEndEvidence = nil
    }
}

enum ModemCallStatus: Int, Equatable {
    case active = 0
    case held = 1
    case dialing = 2
    case alerting = 3
    case incoming = 4
    case waiting = 5
}

struct ModemCallInfo: Equatable {
    let index: Int
    let direction: CallDirection
    let status: ModemCallStatus
    let isVoice: Bool
    let isMultiparty: Bool
    let number: String?
}

enum ModemCallEvent: Equatable {
    case ring
    case callerID(String)
    case callInfo(ModemCallInfo)
    case connected
    case ended(CallEndReason, evidence: CallEndEvidence)
    case pcmFlowReady(Bool)
}
