import Foundation

/// Who is asking for the privileged network helper. It decides whether a
/// missing helper may lead to an administrator password prompt.
enum NetworkHelperInstallRequestKind: Equatable {
    /// Status queries and stops. Never installs: a missing helper means there
    /// is nothing to query or stop.
    case passive
    /// Startup restore, link-recovery re-apply, background reconciliation.
    case automatic
    /// The user changed a cellular network mode, re-applied priorities or
    /// started a feature that needs the helper.
    case userInitiated
}

/// What happened the last time the administrator prompt was shown.
enum NetworkHelperInstallOutcome: Equatable {
    case installedAndReady
    case cancelled
    case failed(String)
    /// The installer reported success, but the helper still refused or failed
    /// the connection (for example because the app's signature does not match
    /// the helper's). Prompting again cannot help.
    case installedButUnusable(String)
}

enum NetworkHelperInstallDecision: Equatable {
    case prompt
    case suppressed(NetworkHelperInstallSuppression)
}

enum NetworkHelperInstallSuppression: Equatable {
    case passiveRequest
    /// The user cancelled the prompt, in this session or an earlier one.
    case declined
    case failed(String)
    case installedButUnusable(String)
    /// An installation already succeeded in this session; automatic requests
    /// do not ask again.
    case alreadyAttempted
}

/// Pure rules for issue #15: the helper install prompt must not repeat.
/// Holds no UI and does no I/O; persistence is done by the caller through
/// `declinedHelperBuildVersion`.
struct NetworkHelperInstallPolicy: Equatable {
    let helperBuildVersion: Int
    /// The helper build the user declined to install, persisted across launches.
    private(set) var declinedHelperBuildVersion: Int?
    /// The outcome of the last prompt in this app session.
    private(set) var lastOutcome: NetworkHelperInstallOutcome?

    init(helperBuildVersion: Int, declinedHelperBuildVersion: Int?) {
        self.helperBuildVersion = helperBuildVersion
        self.declinedHelperBuildVersion = declinedHelperBuildVersion
    }

    /// A decline only counts for the helper build it was given for; a newer
    /// helper build is offered again.
    var isDeclined: Bool {
        declinedHelperBuildVersion == helperBuildVersion
    }

    func decision(for kind: NetworkHelperInstallRequestKind) -> NetworkHelperInstallDecision {
        if kind == .passive {
            return .suppressed(.passiveRequest)
        }
        if case let .installedButUnusable(message) = lastOutcome {
            return .suppressed(.installedButUnusable(message))
        }
        if kind == .userInitiated {
            return .prompt
        }
        switch lastOutcome {
        case nil:
            return isDeclined ? .suppressed(.declined) : .prompt
        case .cancelled:
            return .suppressed(.declined)
        case let .failed(message):
            return .suppressed(.failed(message))
        case .installedAndReady:
            return .suppressed(.alreadyAttempted)
        case .installedButUnusable:
            preconditionFailure("handled above")
        }
    }

    mutating func record(
        _ outcome: NetworkHelperInstallOutcome,
        for kind: NetworkHelperInstallRequestKind
    ) {
        lastOutcome = outcome
        switch outcome {
        case .cancelled:
            declinedHelperBuildVersion = helperBuildVersion
        case .installedAndReady:
            if kind == .userInitiated {
                declinedHelperBuildVersion = nil
            }
        case .failed, .installedButUnusable:
            break
        }
    }
}
