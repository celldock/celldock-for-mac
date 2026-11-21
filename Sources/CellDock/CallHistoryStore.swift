import Combine
import Foundation

struct CallHistoryRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let direction: CallDirection
    let number: String
    var moduleID: CellularModuleID? = nil
    let startedAt: Date
    let connectedAt: Date?
    let endedAt: Date
    let endReason: CallEndReason?
    var recordingID: UUID?
    var missedCallAcknowledged: Bool? = nil
    /// SIM slot active on a dual-slot module when the call started.
    var simSlot: Int? = nil

    var duration: TimeInterval {
        guard let connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }

    var wasAnswered: Bool {
        connectedAt != nil
    }

    var isMissed: Bool {
        direction == .incoming && !wasAnswered && endReason != .localHangup
    }

    var isUnacknowledgedMissed: Bool {
        isMissed && missedCallAcknowledged == false
    }
}

@MainActor
final class CallHistoryStore: ObservableObject {
    @Published private(set) var records: [CallHistoryRecord] = []
    @Published private(set) var currentCallID: UUID?

    private struct PendingCall {
        let id: UUID
        var direction: CallDirection
        var number: String
        var moduleID: CellularModuleID?
        let startedAt: Date
        var connectedAt: Date?
        var recordingID: UUID?
        var simSlot: Int?
    }

    private let fileURL: URL
    private var pendingCalls: [String: PendingCall] = [:]

    private func pendingKey(for moduleID: CellularModuleID?) -> String {
        moduleID?.rawValue ?? "legacy-primary"
    }

    func currentCallID(for moduleID: CellularModuleID?) -> UUID? {
        pendingCalls[pendingKey(for: moduleID)]?.id
    }

    var unacknowledgedMissedCallCount: Int {
        records.lazy.filter(\.isUnacknowledgedMissed).count
    }

    init(fileManager: FileManager = .default) {
        let directory = AppDataDirectory.userApplicationSupport(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("calls.json")
        load()
    }

    @discardableResult
    func consume(
        previous: CallSnapshot,
        current: CallSnapshot,
        simSlot: Int? = nil,
        now: Date = Date()
    ) -> CallHistoryRecord? {
        let key = pendingKey(for: current.moduleID ?? previous.moduleID)
        if pendingCalls[key] == nil, current.hasCall {
            let callID = UUID()
            pendingCalls[key] = PendingCall(
                id: callID,
                direction: current.direction ?? .outgoing,
                number: current.number ?? "",
                moduleID: current.moduleID,
                startedAt: current.startedAt ?? now,
                connectedAt: current.phase == .active ? (current.startedAt ?? now) : nil,
                recordingID: nil,
                simSlot: simSlot
            )
            if currentCallID == nil { currentCallID = callID }
        }

        if current.hasCall, var pendingCall = pendingCalls[key] {
            if let direction = current.direction { pendingCall.direction = direction }
            if let number = current.number, !number.isEmpty { pendingCall.number = number }
            if let moduleID = current.moduleID { pendingCall.moduleID = moduleID }
            if current.phase == .active, pendingCall.connectedAt == nil {
                pendingCall.connectedAt = current.startedAt ?? now
            }
            pendingCalls[key] = pendingCall
        }

        guard previous.hasCall,
              !current.hasCall,
              let pendingCall = pendingCalls[key] else { return nil }
        let endReason = current.lastEndReason ?? previous.lastEndReason
        let isMissed = pendingCall.direction == .incoming &&
            pendingCall.connectedAt == nil &&
            endReason != .localHangup
        let record = CallHistoryRecord(
            id: pendingCall.id,
            direction: pendingCall.direction,
            number: pendingCall.number,
            moduleID: pendingCall.moduleID,
            startedAt: pendingCall.startedAt,
            connectedAt: pendingCall.connectedAt,
            endedAt: now,
            endReason: endReason,
            recordingID: pendingCall.recordingID,
            missedCallAcknowledged: isMissed ? false : nil,
            simSlot: pendingCall.simSlot
        )
        records.insert(record, at: 0)
        if records.count > 1_000 {
            records.removeLast(records.count - 1_000)
        }
        pendingCalls.removeValue(forKey: key)
        if currentCallID == pendingCall.id {
            currentCallID = pendingCalls.values.first?.id
        }
        save()
        return record
    }

    func delete(_ record: CallHistoryRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func deleteAll() {
        records.removeAll()
        save()
    }

    func acknowledgeMissedCalls() {
        guard records.contains(where: \.isUnacknowledgedMissed) else { return }
        records = records.map { record in
            guard record.isUnacknowledgedMissed else { return record }
            var acknowledged = record
            acknowledged.missedCallAcknowledged = true
            return acknowledged
        }
        save()
    }

    func attachRecording(_ recordingID: UUID, toCallID callID: UUID) {
        if let entry = pendingCalls.first(where: { $0.value.id == callID }) {
            var pendingCall = entry.value
            pendingCall.recordingID = recordingID
            pendingCalls[entry.key] = pendingCall
            return
        }
        guard let index = records.firstIndex(where: { $0.id == callID }) else { return }
        records[index].recordingID = recordingID
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([CallHistoryRecord].self, from: data) else { return }
        records = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
