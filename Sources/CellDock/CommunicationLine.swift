import Foundation

/// One of the user's own lines: a module and, on dual-slot modules, the SIM
/// slot that carried a message or call.
struct CommunicationLine: Hashable {
    let moduleID: CellularModuleID
    let simSlot: Int?
}

extension CallHistoryRecord {
    /// The line that carried this call; nil for records stored before calls
    /// were tagged with their module.
    var line: CommunicationLine? {
        moduleID.map { CommunicationLine(moduleID: $0, simSlot: simSlot) }
    }
}

enum LineBadgeText {
    /// "1" for a single-SIM module, "2·1" for slot 1 of module 2.
    static func text(moduleNumber: Int, simSlot: Int?) -> String {
        guard let simSlot else { return String(moduleNumber) }
        return "\(moduleNumber)·\(simSlot)"
    }
}

/// Remembers the colour and number of every module this Mac has seen.
///
/// History rows only store the USB location of the module that carried them.
/// Without this registry a row lost its attribution as soon as the module was
/// unplugged, and a module's colour would follow its position in the list
/// instead of the module itself.
struct ModuleAppearanceRegistry: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var colorIndex: Int
        /// The "模组 N" number the module had when it was last attached.
        var number: Int
        var imei: String?
    }

    struct AttachedModule: Equatable {
        let id: CellularModuleID
        let number: Int
        let imei: String?
    }

    static let colorCount = 6
    static let defaultsKey = "CellDock.ModuleAppearanceRegistry.v1"

    private(set) var entries: [String: Entry] = [:]

    func entry(for moduleID: CellularModuleID) -> Entry? {
        entries[moduleID.rawValue]
    }

    /// Records the attached modules. Returns true when anything changed.
    @discardableResult
    mutating func update(attached: [AttachedModule]) -> Bool {
        let before = entries
        for module in attached {
            let key = module.id.rawValue
            let imei = module.imei.flatMap { $0.isEmpty ? nil : $0 }
            if var entry = entries[key] {
                entry.number = module.number
                if let imei, entry.imei != imei {
                    // The IMEI is read over AT after the module shows up. If the
                    // same module was seen on another port before, keep its colour.
                    if entry.imei == nil,
                       let known = colorIndex(forIMEI: imei, excluding: key) {
                        entry.colorIndex = known
                    }
                    entry.imei = imei
                }
                entries[key] = entry
            } else {
                let known = imei.flatMap { colorIndex(forIMEI: $0, excluding: key) }
                entries[key] = Entry(
                    colorIndex: known ?? nextFreeColorIndex(),
                    number: module.number,
                    imei: imei
                )
            }
        }
        return entries != before
    }

    private func colorIndex(forIMEI imei: String, excluding key: String) -> Int? {
        entries
            .filter { $0.key != key && $0.value.imei == imei }
            .map(\.value.colorIndex)
            .min()
    }

    private func nextFreeColorIndex() -> Int {
        let used = Set(entries.values.map(\.colorIndex))
        if let free = (0 ..< Self.colorCount).first(where: { !used.contains($0) }) {
            return free
        }
        return entries.count % Self.colorCount
    }

    static func load(defaults: UserDefaults = .standard) -> ModuleAppearanceRegistry {
        guard let data = defaults.data(forKey: defaultsKey),
              let registry = try? JSONDecoder().decode(ModuleAppearanceRegistry.self, from: data) else {
            return ModuleAppearanceRegistry()
        }
        return registry
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// How one line is shown: badge text, colour, and whether it can be used now.
struct LineAppearance: Equatable, Identifiable {
    /// nil for old records that were stored without a module.
    let line: CommunicationLine?
    /// "1" or "2·1"; nil when this Mac never recorded the module.
    let badgeText: String?
    /// Index into the module colour palette; nil when the module is not attached.
    let colorIndex: Int?
    /// The attached module behind this line. It differs from `line.moduleID`
    /// when the module has been moved to another USB port.
    let attachedModuleID: CellularModuleID?
    /// True when this exact line can send or dial right now.
    let isLive: Bool
    /// "模组 2 · 卡 1"
    let title: String
    /// Carrier of the line while its SIM is the active one.
    let carrier: String?

    var id: String {
        guard let line else { return "unknown" }
        return "\(line.moduleID.rawValue)|\(line.simSlot.map(String.init) ?? "-")"
    }

    var isAttached: Bool { attachedModuleID != nil }

    /// "模组 2 · 卡 1 · 中国电信"
    var fullTitle: String {
        [title, carrier].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A module the user can pick to send a message or place a call.
struct SendLineOption: Identifiable, Equatable {
    let moduleID: CellularModuleID
    /// The module's line at its currently active SIM slot.
    let appearance: LineAppearance
    let isEligible: Bool
    /// Radio technology when the module is ready, otherwise why it is not.
    let detail: String

    var id: String { moduleID.rawValue }

    var menuTitle: String {
        [appearance.fullTitle, detail].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SendModuleChoice: Equatable {
    let moduleID: CellularModuleID?
    /// True when the line last used with this peer cannot be used now and
    /// another one was chosen instead.
    let fellBack: Bool
}

/// Resolves lines against the attached modules and the appearance registry.
/// Capture one per view update and reuse it for every row.
struct LineAppearanceResolver {
    let modules: [CellularModuleSummary]
    let registry: ModuleAppearanceRegistry

    func appearance(moduleID: CellularModuleID?, simSlot: Int?) -> LineAppearance {
        guard let moduleID else {
            return LineAppearance(
                line: nil,
                badgeText: nil,
                colorIndex: nil,
                attachedModuleID: nil,
                isLive: false,
                title: L10n.tr("未记录线路"),
                carrier: nil
            )
        }
        let line = CommunicationLine(moduleID: moduleID, simSlot: simSlot)
        if let index = attachedIndex(for: moduleID) {
            let module = modules[index]
            let number = index + 1
            let slotIsLive = simSlot == nil ||
                !module.modem.simSlotSwitchingSupported ||
                module.modem.simSlot == simSlot
            return LineAppearance(
                line: line,
                badgeText: LineBadgeText.text(moduleNumber: number, simSlot: simSlot),
                colorIndex: registry.entry(for: module.id)?.colorIndex ?? index,
                attachedModuleID: module.id,
                isLive: slotIsLive && module.isCommunicationEligible,
                title: Self.title(moduleNumber: number, simSlot: simSlot),
                carrier: slotIsLive && module.modem.simReady ? module.carrierName : nil
            )
        }
        if let entry = registry.entry(for: moduleID) {
            return LineAppearance(
                line: line,
                badgeText: LineBadgeText.text(moduleNumber: entry.number, simSlot: simSlot),
                colorIndex: nil,
                attachedModuleID: nil,
                isLive: false,
                title: Self.title(moduleNumber: entry.number, simSlot: simSlot),
                carrier: nil
            )
        }
        return LineAppearance(
            line: line,
            badgeText: nil,
            colorIndex: nil,
            attachedModuleID: nil,
            isLive: false,
            title: L10n.tr("已移除的模组"),
            carrier: nil
        )
    }

    func appearance(for line: CommunicationLine?) -> LineAppearance {
        appearance(moduleID: line?.moduleID, simSlot: line?.simSlot)
    }

    /// The line an attached module is using now: its active SIM slot.
    func currentLine(of module: CellularModuleSummary) -> CommunicationLine {
        CommunicationLine(
            moduleID: module.id,
            simSlot: module.modem.simSlotSwitchingSupported ? module.modem.simSlot : nil
        )
    }

    /// The line a module is using right now, for a call or draft in progress.
    func currentAppearance(moduleID: CellularModuleID?) -> LineAppearance {
        guard let moduleID, let module = modules.first(where: { $0.id == moduleID }) else {
            return appearance(moduleID: moduleID, simSlot: nil)
        }
        return appearance(for: currentLine(of: module))
    }

    /// One entry per attached module, at its active SIM slot.
    var sendOptions: [SendLineOption] {
        modules.map { module in
            SendLineOption(
                moduleID: module.id,
                appearance: appearance(for: currentLine(of: module)),
                isEligible: module.isCommunicationEligible,
                detail: module.isCommunicationEligible
                    ? (module.technologyName ?? "")
                    : module.statusText
            )
        }
    }

    /// The module a reply or callback should use by default: the line last
    /// used with this peer when it is live, otherwise the current module.
    func defaultSendModule(
        lastLine: CommunicationLine?,
        current: CellularModuleID?
    ) -> SendModuleChoice {
        let last = lastLine.map { appearance(for: $0) }
        if let last, last.isLive, let moduleID = last.attachedModuleID {
            return SendModuleChoice(moduleID: moduleID, fellBack: false)
        }
        let options = sendOptions
        let fallback = options.first { $0.moduleID == current && $0.isEligible } ??
            options.first(where: \.isEligible)
        return SendModuleChoice(
            moduleID: fallback?.moduleID,
            fellBack: last != nil && fallback != nil
        )
    }

    private func attachedIndex(for moduleID: CellularModuleID) -> Int? {
        if let index = modules.firstIndex(where: { $0.id == moduleID }) {
            return index
        }
        guard let imei = registry.entry(for: moduleID)?.imei else { return nil }
        return modules.firstIndex { registry.entry(for: $0.id)?.imei == imei }
    }

    private static func title(moduleNumber: Int, simSlot: Int?) -> String {
        let name = L10n.tr("模组 %lld", Int64(moduleNumber))
        guard let simSlot else { return name }
        return name + L10n.tr(" · 卡 %lld", Int64(simSlot))
    }
}

/// The one line whose records the Messages, Recents and Recordings lists
/// show. An online line is an attached module at its active SIM slot and can
/// send and dial; an offline line is history that can only be read.
struct LineScope {
    let resolver: LineAppearanceResolver
    /// nil when no module is attached and no offline line is picked.
    let line: CommunicationLine?
    let isOnline: Bool

    /// The attached module behind an online scope.
    var moduleID: CellularModuleID? {
        isOnline ? line?.moduleID : nil
    }

    var appearance: LineAppearance {
        resolver.appearance(for: line)
    }

    func contains(_ recordLine: CommunicationLine?) -> Bool {
        guard let line else { return true }
        return isOnline
            ? resolver.record(recordLine, isOnOnlineLine: line)
            : recordLine == line
    }
}

extension LineAppearanceResolver {
    /// The lines that can be used right now: each module at its active slot.
    var onlineLines: [CommunicationLine] {
        modules.map { currentLine(of: $0) }
    }

    /// Whether a record belongs to an online line. Records stored before
    /// lines were tagged count for the first module so they stay visible,
    /// and a record without a SIM slot counts for its module's active slot.
    func record(_ recordLine: CommunicationLine?, isOnOnlineLine line: CommunicationLine) -> Bool {
        guard let recordLine else { return line.moduleID == modules.first?.id }
        let moduleID = appearance(for: recordLine).attachedModuleID ?? recordLine.moduleID
        guard moduleID == line.moduleID else { return false }
        return recordLine.simSlot == nil || line.simSlot == nil || recordLine.simSlot == line.simSlot
    }

    func isOnline(_ recordLine: CommunicationLine?) -> Bool {
        onlineLines.contains { record(recordLine, isOnOnlineLine: $0) }
    }

    /// History lines that no attached module is on now: unplugged modules
    /// and SIM slots that are not the active one. Ordered by badge.
    func offlineLines(among recordLines: [CommunicationLine]) -> [CommunicationLine] {
        var seen = Set<CommunicationLine>()
        return recordLines
            .filter { seen.insert($0).inserted && !isOnline($0) }
            .sorted {
                (appearance(for: $0).badgeText ?? "~", $0.moduleID.rawValue) <
                    (appearance(for: $1).badgeText ?? "~", $1.moduleID.rawValue)
            }
    }
}
