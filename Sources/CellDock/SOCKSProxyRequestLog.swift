import Darwin
import Foundation

/// The SOCKS command a client asked for. `nil` on a record means the session
/// ended before it sent a request (a failed login, a handshake timeout).
enum SOCKSProxyRequestCommand: String, Equatable, Sendable {
    case tcpConnect
    case udpAssociate
}

/// How a proxied request ended, or that it is still running.
enum SOCKSProxyRequestOutcome: String, Equatable, Sendable, CaseIterable {
    case inProgress
    case completed
    /// The user ended the request from the request list.
    case disconnected
    case connectionRefused
    case timedOut
    case resolutionFailed
    case networkUnreachable
    case hostUnreachable
    case authenticationFailed
    case handshakeTimedOut
    case sessionLimitReached
    /// Any other failure, such as an unsupported command or a UDP relay that
    /// could not open its socket.
    case failed

    var isFailure: Bool {
        switch self {
        case .inProgress, .completed, .disconnected: return false
        default: return true
        }
    }

    /// Maps an error from name resolution or the upstream TCP handshake.
    static func upstreamFailure(_ error: Error) -> SOCKSProxyRequestOutcome {
        if error is SOCKSDNSError { return .resolutionFailed }
        if let error = error as? BoundSocketError, case let .systemCall(_, code) = error {
            switch code {
            case ECONNREFUSED: return .connectionRefused
            case ETIMEDOUT: return .timedOut
            case ENETUNREACH, ENETDOWN: return .networkUnreachable
            case EHOSTUNREACH, EHOSTDOWN: return .hostUnreachable
            default: break
            }
        }
        return .hostUnreachable
    }
}

/// One client session of a proxy. Destinations and client addresses stay in
/// memory only; they are never written to the log or to disk.
struct SOCKSProxyRequestRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    /// `ip:port` of the connecting client.
    let client: String
    var command: SOCKSProxyRequestCommand?
    /// `host:port` the client asked for. For UDP this is the latest
    /// destination of the association.
    var target: String?
    /// The address actually used for `target`.
    var resolvedAddress: String?
    /// Distinct destinations seen by a UDP association.
    var destinationCount: Int = 0
    /// Bytes delivered to the client.
    var downloadedBytes: UInt64 = 0
    /// Bytes delivered to the destination.
    var uploadedBytes: UInt64 = 0
    var outcome: SOCKSProxyRequestOutcome = .inProgress

    init(id: UUID = UUID(), startedAt: Date = Date(), client: String) {
        self.id = id
        self.startedAt = startedAt
        self.client = client
    }

    var isActive: Bool { outcome == .inProgress }

    var totalBytes: UInt64 { downloadedBytes &+ uploadedBytes }

    func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    /// A connection that closed before asking for anything (a port probe or
    /// a client that gave up) carries no information worth keeping.
    var isWorthKeeping: Bool {
        !(target == nil && command == nil && outcome == .completed)
    }

    func matches(query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return [target, resolvedAddress, client]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(needle) }
    }
}

/// Fixed-capacity history, newest first. Old entries fall off the end.
struct SOCKSProxyRequestHistory: Equatable, Sendable {
    static let defaultCapacity = 1_000

    let capacity: Int
    private var storage: [SOCKSProxyRequestRecord] = []
    /// Index of the oldest entry once the buffer is full.
    private var head = 0

    init(capacity: Int = SOCKSProxyRequestHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(self.capacity, 64))
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    mutating func append(_ record: SOCKSProxyRequestRecord) {
        if storage.count < capacity {
            storage.append(record)
        } else {
            storage[head] = record
            head = (head + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        head = 0
    }

    /// Newest first.
    var records: [SOCKSProxyRequestRecord] {
        guard storage.count == capacity, head != 0 else { return storage.reversed() }
        return (storage[head...] + storage[..<head]).reversed()
    }
}

struct SOCKSProxyRequestSnapshot: Equatable, Sendable {
    /// Oldest first, as sessions were accepted.
    var active: [SOCKSProxyRequestRecord]
    /// Newest first.
    var history: [SOCKSProxyRequestRecord]
    /// Bytes this proxy delivered since CellDock started, finished and running
    /// requests together. Unaffected by clearing the history.
    var totalDownloadedBytes: UInt64
    var totalUploadedBytes: UInt64

    static let empty = SOCKSProxyRequestSnapshot(
        active: [],
        history: [],
        totalDownloadedBytes: 0,
        totalUploadedBytes: 0
    )
}

/// Turns the proxy's cumulative byte totals into a per-second rate.
struct SOCKSProxyTrafficRateTracker: Equatable {
    private var previous: (download: UInt64, upload: UInt64, uptime: TimeInterval)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.previous?.download == rhs.previous?.download &&
            lhs.previous?.upload == rhs.previous?.upload &&
            lhs.previous?.uptime == rhs.previous?.uptime
    }

    mutating func reset() { previous = nil }

    /// Returns nil for the first sample, which only sets the baseline.
    mutating func rate(
        downloaded: UInt64,
        uploaded: UInt64,
        uptime: TimeInterval
    ) -> NetworkThroughput? {
        defer { previous = (downloaded, uploaded, uptime) }
        guard let previous else { return nil }
        let elapsed = uptime - previous.uptime
        guard elapsed > 0 else { return nil }
        // Totals never shrink; if they appear to, the proxy log was replaced
        // and the sample is meaningless rather than negative.
        let download = downloaded >= previous.download ? downloaded - previous.download : 0
        let upload = uploaded >= previous.upload ? uploaded - previous.upload : 0
        return NetworkThroughput(
            downloadBytesPerSecond: Double(download) / elapsed,
            uploadBytesPerSecond: Double(upload) / elapsed
        )
    }
}

/// The live record of one session. Byte counts are added on the session's
/// queue while the request list reads them from the main thread, so every
/// access goes through the lock.
final class SOCKSProxyRequestTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var record: SOCKSProxyRequestRecord
    /// Bounded so that a UDP association spraying packets at random hosts
    /// cannot grow it without limit; past the bound only the count stops.
    private var udpDestinations: Set<String> = []
    private static let maximumTrackedDestinations = 4_096

    init(record: SOCKSProxyRequestRecord) {
        self.record = record
    }

    var current: SOCKSProxyRequestRecord {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    var id: UUID { record.id }

    func setRequest(
        command: SOCKSProxyRequestCommand,
        target: String?,
        resolvedAddress: String? = nil
    ) {
        lock.lock()
        record.command = command
        record.target = target
        record.resolvedAddress = resolvedAddress
        lock.unlock()
    }

    func setResolvedAddress(_ address: String) {
        lock.lock()
        record.resolvedAddress = address
        lock.unlock()
    }

    func noteUDPDestination(target: String, resolvedAddress: String?) {
        lock.lock()
        record.target = target
        if let resolvedAddress { record.resolvedAddress = resolvedAddress }
        if udpDestinations.count < Self.maximumTrackedDestinations {
            udpDestinations.insert(target)
            record.destinationCount = udpDestinations.count
        }
        lock.unlock()
    }

    func addDownloaded(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        record.downloadedBytes &+= UInt64(count)
        lock.unlock()
    }

    func addUploaded(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        record.uploadedBytes &+= UInt64(count)
        lock.unlock()
    }

    /// The first outcome wins; later calls only happen while tearing down.
    @discardableResult
    func finish(_ outcome: SOCKSProxyRequestOutcome, at date: Date = Date()) -> SOCKSProxyRequestRecord {
        lock.lock()
        defer { lock.unlock() }
        if record.outcome == .inProgress {
            record.outcome = outcome == .inProgress ? .completed : outcome
            record.endedAt = date
        }
        return record
    }
}

/// History and running totals of one proxy. It outlives the listener, so a
/// proxy that restarts after a link drop keeps its history; it is dropped
/// only with the proxy itself or when CellDock quits.
final class SOCKSProxyRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var history: SOCKSProxyRequestHistory
    private var recordsHistory: Bool
    private var finishedDownloaded: UInt64 = 0
    private var finishedUploaded: UInt64 = 0

    init(
        capacity: Int = SOCKSProxyRequestHistory.defaultCapacity,
        recordsHistory: Bool = true
    ) {
        history = SOCKSProxyRequestHistory(capacity: capacity)
        self.recordsHistory = recordsHistory
    }

    var isRecordingHistory: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return recordsHistory
        }
        set {
            lock.lock()
            recordsHistory = newValue
            lock.unlock()
        }
    }

    func archive(_ record: SOCKSProxyRequestRecord) {
        lock.lock()
        defer { lock.unlock() }
        finishedDownloaded &+= record.downloadedBytes
        finishedUploaded &+= record.uploadedBytes
        if recordsHistory, record.isWorthKeeping {
            history.append(record)
        }
    }

    func clearHistory() {
        lock.lock()
        history.removeAll()
        lock.unlock()
    }

    /// Builds a snapshot from the history and the given running sessions.
    /// Callers that also own the running sessions must hold their own lock
    /// around this call and the archiving of a finished session, so that a
    /// session is never counted twice or missed in the totals.
    func snapshot(active trackers: [SOCKSProxyRequestTracker]) -> SOCKSProxyRequestSnapshot {
        lock.lock()
        let history = history.records
        var downloaded = finishedDownloaded
        var uploaded = finishedUploaded
        lock.unlock()
        let active = trackers.map(\.current).sorted { $0.startedAt < $1.startedAt }
        for record in active {
            downloaded &+= record.downloadedBytes
            uploaded &+= record.uploadedBytes
        }
        return SOCKSProxyRequestSnapshot(
            active: active,
            history: history,
            totalDownloadedBytes: downloaded,
            totalUploadedBytes: uploaded
        )
    }
}

enum SOCKSProxyRequestFormatting {
    static func host(_ address: SOCKSAddress) -> String {
        switch address {
        case let .domain(domain):
            return domain
        case let .ipv4(bytes):
            return bytes.map(String.init).joined(separator: ".")
        case let .ipv6(bytes):
            guard bytes.count == 16 else { return "::" }
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: bytes) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil else {
                return "::"
            }
            return String(cString: buffer)
        }
    }

    static func endpoint(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func endpoint(_ address: SOCKSAddress, port: UInt16) -> String {
        endpoint(host: host(address), port: port)
    }
}
