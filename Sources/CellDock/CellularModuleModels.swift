import Foundation

struct CellularModuleSummary: Identifiable, Equatable {
    let id: CellularModuleID
    let displayName: String
    let modem: ModemSnapshot
    let network: CellularNetworkStatus
    let cardKind: SubscriberCardKind
    let isActiveSession: Bool
    let isPrimaryData: Bool

    var carrierName: String {
        let carrier = modem.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return carrier?.isEmpty == false ? carrier! : L10n.tr("运营商未识别")
    }

    var localizedDisplayName: String {
        let components = displayName.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count == 2,
              components[0] == "模组",
              let index = Int64(components[1]) else {
            return displayName
        }
        return L10n.tr("模组 %lld", index)
    }

    var technologyName: String? {
        let technology = modem.accessTechnology?.trimmingCharacters(in: .whitespacesAndNewlines)
        return technology?.isEmpty == false ? technology : nil
    }

    var simSuffix: String? {
        guard let iccid = modem.simICCID, iccid.count >= 4 else { return nil }
        return String(iccid.suffix(4))
    }

    var isCommunicationEligible: Bool {
        isActiveSession && modem.isConnected && modem.simReady
    }

    var isDataEligible: Bool {
        isCommunicationEligible && modem.usbNetMode == 1
    }

    /// "卡槽 n" for dual-slot modules; nil keeps single-slot modules unchanged.
    var simSlotTitle: String? {
        guard modem.simSlotSwitchingSupported, let slot = modem.simSlot else { return nil }
        return L10n.tr("卡槽 %lld", Int64(slot))
    }

    var selectorTitle: String {
        [localizedDisplayName, simSlotTitle, modem.simReady ? carrierName : nil, technologyName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// The selector title from the most to the least detailed. A control
    /// that is short of room shows the longest one that fits instead of
    /// cutting the full title off: first without the radio technology, then
    /// with only what identifies the line.
    var selectorTitleVariants: [String] {
        let identity = [localizedDisplayName, simSlotTitle].compactMap { $0 }
        let carrier = modem.simReady ? carrierName : nil
        let candidates = [
            identity + [carrier, technologyName].compactMap { $0 },
            identity + [carrier].compactMap { $0 },
            identity,
        ]
        var variants: [String] = []
        for parts in candidates {
            let title = parts.joined(separator: " · ")
            if variants.last != title { variants.append(title) }
        }
        return variants
    }

    var accessibilitySummary: String {
        var parts = [localizedDisplayName, statusText]
        if modem.simReady {
            parts.append(carrierName)
            if let technologyName { parts.append(technologyName) }
            if let signalDBm = modem.signalDBm {
                parts.append(L10n.tr("信号 %lld dBm", Int64(signalDBm)))
            }
        }
        if isPrimaryData { parts.append(L10n.tr("主上网")) }
        return parts.joined(separator: "，")
    }

    var statusText: String {
        if modem.isConnected && !isActiveSession && modem.simState == .unavailable {
            return L10n.tr("已发现")
        }
        switch modem.simState {
        case .unavailable:
            return modem.isConnected ? L10n.tr("等待 SIM") : L10n.tr("已断开")
        case .initializing: return L10n.tr("正在读取 SIM")
        case .absent: return L10n.tr("未插入 SIM")
        case .pinRequired: return L10n.tr("需要 SIM PIN")
        case .pukRequired: return L10n.tr("需要 SIM PUK")
        case .ready: return isActiveSession ? L10n.tr("已连接") : L10n.tr("SIM 已就绪")
        case .queryFailed: return L10n.tr("SIM 状态异常")
        }
    }
}

struct SIMSlotSwitchProgress: Equatable {
    let moduleID: CellularModuleID
    let previousSlot: Int?
    let targetSlot: Int
}

enum CellularModuleSelectionPolicy {
    static func reconciledManagementSelection(
        current: CellularModuleID?,
        available: [CellularModuleID]
    ) -> CellularModuleID? {
        guard let first = available.first else { return nil }
        guard let current, available.contains(current) else { return first }
        return current
    }
}

enum CommunicationModuleRoutingPolicy {
    static func resolvedModuleID(
        requested: CellularModuleID?,
        current: CellularModuleID?,
        fallback: CellularModuleID
    ) -> CellularModuleID {
        requested ?? current ?? fallback
    }
}

enum MenuBarStatusModuleSelectionPolicy {
    static func resolvedModuleID(
        isCellularNetworkingEnabled: Bool,
        primaryDataModuleID: CellularModuleID?,
        currentCommunicationModuleID: CellularModuleID?,
        modules: [CellularModuleSummary]
    ) -> CellularModuleID? {
        if isCellularNetworkingEnabled,
           let primaryDataModuleID,
           modules.contains(where: { $0.id == primaryDataModuleID }) {
            return primaryDataModuleID
        }

        if let currentCommunicationModuleID,
           let current = modules.first(where: { $0.id == currentCommunicationModuleID }),
           current.isCommunicationEligible {
            return currentCommunicationModuleID
        }

        return modules.first(where: \.isCommunicationEligible)?.id ?? modules.first?.id
    }
}
