import Foundation
#if canImport(CellDockNetworkIPC)
import CellDockNetworkIPC
#endif

/// How a module's dead ECM link can be repaired without the user unplugging it.
enum CellularLinkRepairStrategy: Equatable {
    /// QDC507: the module's internal bridge is repaired over ADB, and the
    /// module is restarted with AT+CFUN=1,1 once that ladder is exhausted.
    case moduleBridge
    /// RM520N-GL: nothing inside the module is reachable and resetting the
    /// Mac-side interface does not revive its carrier (measured after a system
    /// sleep), so the network configuration is re-applied once, in case only
    /// DHCP is missing, and then the module is restarted.
    case moduleRestart
}

enum CellularLinkRecoveryPolicy {
    static let maximumAttempts = 3

    /// The one soft step of the restart strategy cannot repair a dead carrier,
    /// so repeating it would only postpone the restart.
    static let moduleRestartMaximumAttempts = 1

    /// USB identities whose link CellDock repairs automatically. The QDC507
    /// ladder (bridge repair over ADB, then AT+CFUN=1,1) is verified on that
    /// module only, so the RM520N-GL gets its own strategy rather than
    /// inheriting commands meant for different firmware.
    static func repairStrategy(for modem: ModemSnapshot) -> CellularLinkRepairStrategy? {
        switch modem.usbIdentity?.uppercased() {
        case "2C7C:0125": return .moduleBridge
        case "2C7C:0801": return .moduleRestart
        default: return nil
        }
    }

    /// Whether `ModemService.recoverCellularNetworkLink` (the ADB bridge
    /// repair) applies to this module.
    static func supportsModuleRepair(_ modem: ModemSnapshot) -> Bool {
        repairStrategy(for: modem) == .moduleBridge
    }

    /// Whether any automatic link recovery exists for this module. Modules
    /// without one must never be reported as "retrying".
    static func supportsAutomaticRecovery(_ modem: ModemSnapshot) -> Bool {
        repairStrategy(for: modem) != nil
    }

    static func maximumAttempts(for strategy: CellularLinkRepairStrategy) -> Int {
        switch strategy {
        case .moduleBridge: return maximumAttempts
        case .moduleRestart: return moduleRestartMaximumAttempts
        }
    }

    static func maximumAttempts(for modem: ModemSnapshot) -> Int {
        repairStrategy(for: modem).map(maximumAttempts(for:)) ?? maximumAttempts
    }

    /// Recovery is evaluated per module. A module the user asked to keep
    /// connected deserves the same repair path as the preferred one; only a
    /// module that is meant to be off is left alone.
    static func shouldAttempt(
        network: CellularNetworkStatus,
        modem: ModemSnapshot,
        desiredMode: CellularNetworkMode = .preferred,
        hasCall: Bool,
        isChangingNetwork: Bool,
        isInFlight: Bool,
        completedAttempts: Int,
        isSystemAsleep: Bool = false
    ) -> Bool {
        supportsAutomaticRecovery(modem) &&
            desiredMode.isEnabled &&
            network.isEnabled &&
            network.isHardwarePresent &&
            !network.isActive &&
            modem.isConnected &&
            modem.usbNetMode == 1 &&
            !hasCall &&
            !isChangingNetwork &&
            !isInFlight &&
            // Repairing a link while the Mac is going to sleep only burns the
            // attempt budget: USB is suspended again before it can finish.
            !isSystemAsleep &&
            completedAttempts < maximumAttempts(for: modem)
    }

    static func shouldRestartModule(
        network: CellularNetworkStatus,
        modem: ModemSnapshot,
        desiredMode: CellularNetworkMode = .preferred,
        hasCall: Bool,
        completedAttempts: Int,
        alreadyRestarted: Bool
    ) -> Bool {
        supportsAutomaticRecovery(modem) &&
            completedAttempts >= maximumAttempts(for: modem) &&
            !alreadyRestarted &&
            desiredMode.isEnabled &&
            network.isEnabled &&
            modem.isConnected &&
            modem.usbNetMode == 1 &&
            !hasCall
    }

    /// The helper cannot see the module's internal bridge state, so a carrier
    /// that is up does not prove the data path forwards. Any enabled module
    /// whose interface is not carrying traffic still needs preparing.
    static func needsLinkPreparation(_ network: CellularNetworkStatus) -> Bool {
        !network.isEnabled || !network.isLinkActive
    }

    /// Whether automatic repair still has something left to try for a module.
    /// Drives the difference between "正在自动重试" and "已停止自动重试", so the user
    /// knows whether waiting is pointless and manual action is needed.
    static func isRetrying(
        completedAttempts: Int,
        hasRestarted: Bool,
        maximumAttempts: Int = CellularLinkRecoveryPolicy.maximumAttempts
    ) -> Bool {
        completedAttempts < maximumAttempts || !hasRestarted
    }

    /// Per-module form: a module without any repair strategy is never
    /// retrying, however small its attempt count is. Reporting "正在自动重试"
    /// for it left the user waiting for a recovery that could not happen.
    static func isRetrying(
        modem: ModemSnapshot,
        completedAttempts: Int,
        hasRestarted: Bool
    ) -> Bool {
        guard let strategy = repairStrategy(for: modem) else { return false }
        return isRetrying(
            completedAttempts: completedAttempts,
            hasRestarted: hasRestarted,
            maximumAttempts: maximumAttempts(for: strategy)
        )
    }

    /// A power cycle re-enumerates USB, so it is the last resort.
    ///
    /// Only a DHCP timeout justifies skipping the soft-recovery ladder: the link
    /// is already carrying traffic, so more link repair cannot help. An inactive
    /// link may simply be slow to come up — a module rejoining its internal
    /// bridge needs about 26 seconds — and every backoff step buys it more time.
    /// Escalating on the first inactive link made the three-attempt ladder dead
    /// code and power cycled healthy-but-slow modules.
    static func shouldEscalateToRestart(
        reason: CellularNetworkFailureReason,
        completedAttempts: Int,
        maximumAttempts: Int = CellularLinkRecoveryPolicy.maximumAttempts
    ) -> Bool {
        switch reason {
        case .dhcpTimeout:
            return true
        case .linkInactive:
            return completedAttempts >= maximumAttempts
        case .other:
            return false
        }
    }

    /// A power cycle re-enumerates USB, so it must stay rare. A chronically
    /// faulty module often blips active for a few seconds after a restart, and
    /// treating that as "healthy again" would re-arm the restart path forever.
    static let restartCooldown: TimeInterval = 600

    static func canClearRestartGuard(lastRestart: Date?, now: Date) -> Bool {
        guard let lastRestart else { return true }
        return now.timeIntervalSince(lastRestart) >= restartCooldown
    }

    /// USB is resumed a moment after the system reports the wake, and a link
    /// that is coming back by itself needs a few seconds to show its carrier.
    /// Recovery waits this long so a healthy module is not restarted for
    /// being slow.
    static let wakeSettleInterval: TimeInterval = 15

    static func hasSettledAfterWake(lastWake: Date?, now: Date) -> Bool {
        guard let lastWake else { return true }
        return now.timeIntervalSince(lastWake) >= wakeSettleInterval
    }

    /// Whether the once-only restart guard may be lifted outside the moment a
    /// healthy status happens to be published, for example after a wake.
    ///
    /// The cooldown alone is not enough. A module whose link never came back
    /// after its restart was not helped by it: a SIM without a data plan or
    /// without coverage would otherwise be restarted again after every wake,
    /// and each restart takes calls and SMS offline for about a minute.
    static func canLiftRestartGuard(
        lastRestart: Date?,
        now: Date,
        linkRecoveredSinceRestart: Bool
    ) -> Bool {
        linkRecoveredSinceRestart && canClearRestartGuard(lastRestart: lastRestart, now: now)
    }

    static func delayNanoseconds(completedAttempts: Int) -> UInt64 {
        switch completedAttempts {
        case ...0: return 3_000_000_000
        case 1: return 15_000_000_000
        default: return 30_000_000_000
        }
    }
}
