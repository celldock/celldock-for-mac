import CEuiccCore
import Darwin
import Foundation
import OSLog

private let euiccLogger = Logger(subsystem: "app.celldock.mac", category: "EUICC")

private final class EUICCTransportContext {
    unowned let modemService: ModemService
    private let failureLock = NSLock()
    private var storedHTTPFailure: EUICCHTTPFailure?

    init(modemService: ModemService) {
        self.modemService = modemService
    }

    var lastHTTPFailure: EUICCHTTPFailure? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return storedHTTPFailure
    }

    private func recordHTTPFailure(_ failure: EUICCHTTPFailure) {
        failureLock.lock()
        if storedHTTPFailure == nil {
            storedHTTPFailure = failure
        }
        failureLock.unlock()
    }

    func executeAT(
        command: UnsafePointer<CChar>,
        timeout: Int32,
        output: UnsafeMutablePointer<CChar>,
        capacity: Int
    ) -> Int32 {
        let result = modemService.executeEUICCATCommand(
            String(cString: command),
            timeout: Int(timeout),
            capacity: capacity
        )
        let bytes = Array(result.output.utf8)
        guard result.isSuccess, bytes.count < capacity else { return -1 }
        for index in bytes.indices {
            output[index] = CChar(bitPattern: bytes[index])
        }
        output[bytes.count] = 0
        return 0
    }

    func executeHTTP(
        url: UnsafePointer<CChar>,
        headers: UnsafePointer<UnsafePointer<CChar>?>?,
        requestBytes: UnsafePointer<UInt8>?,
        requestLength: UInt32,
        statusCode: UnsafeMutablePointer<UInt32>,
        responseBytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        responseLength: UnsafeMutablePointer<UInt32>
    ) -> Int32 {
        guard let requestURL = URL(string: String(cString: url)),
              requestURL.scheme?.lowercased() == "https",
              requestURL.host != nil else {
            recordHTTPFailure(EUICCHTTPFailure(kind: .invalidRequest))
            return -1
        }

        var requestHeaders: [(name: String, value: String)] = []
        if let headers {
            var index = 0
            while let header = headers[index] {
                let line = String(cString: header)
                if let separator = line.firstIndex(of: ":") {
                    let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: separator)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { requestHeaders.append((name, value)) }
                }
                index += 1
            }
        }
        var requestBody = Data()
        if let requestBytes, requestLength > 0 {
            requestBody = Data(bytes: requestBytes, count: Int(requestLength))
        }

        let receivedData: Data
        let receivedStatus: Int
        switch EUICCHTTPSClient.post(url: requestURL, headers: requestHeaders, body: requestBody, timeout: 90) {
        case let .success(response):
            receivedData = response.body
            receivedStatus = response.status
        case let .failure(failure):
            recordHTTPFailure(failure)
            return -1
        }

        let count = receivedData.count
        let allocationSize = max(count, 1)
        guard let allocation = malloc(allocationSize) else {
            recordHTTPFailure(EUICCHTTPFailure(kind: .outOfMemory))
            return -1
        }
        let destination = allocation.bindMemory(to: UInt8.self, capacity: allocationSize)
        if count > 0 {
            receivedData.copyBytes(to: destination, count: count)
        }
        statusCode.pointee = UInt32(receivedStatus)
        responseBytes.pointee = destination
        responseLength.pointee = UInt32(count)
        return 0
    }
}

private func cellDockEUICCATCallback(
    context: UnsafeMutableRawPointer?,
    command: UnsafePointer<CChar>?,
    timeout: Int32,
    output: UnsafeMutablePointer<CChar>?,
    outputCapacity: Int
) -> Int32 {
    guard let context, let command, let output, outputCapacity > 0 else { return -1 }
    return Unmanaged<EUICCTransportContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .executeAT(command: command, timeout: timeout, output: output, capacity: outputCapacity)
}

private func cellDockEUICCHTTPCallback(
    context: UnsafeMutableRawPointer?,
    url: UnsafePointer<CChar>?,
    headers: UnsafePointer<UnsafePointer<CChar>?>?,
    requestBytes: UnsafePointer<UInt8>?,
    requestLength: UInt32,
    statusCode: UnsafeMutablePointer<UInt32>?,
    responseBytes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    responseLength: UnsafeMutablePointer<UInt32>?
) -> Int32 {
    guard let context, let url, let statusCode, let responseBytes, let responseLength else {
        return -1
    }
    return Unmanaged<EUICCTransportContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .executeHTTP(
            url: url,
            headers: headers,
            requestBytes: requestBytes,
            requestLength: requestLength,
            statusCode: statusCode,
            responseBytes: responseBytes,
            responseLength: responseLength
        )
}

enum EUICCServiceError: LocalizedError {
    case unavailable(String)
    case http(EUICCHTTPFailure, stage: ESIMDownloadStage?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): return message
        case let .http(failure, stage):
            guard let stage else { return failure.userMessage }
            return L10n.tr("%@（失败阶段：%@）", failure.userMessage, stage.localizedName)
        case .invalidResponse: return L10n.tr("eUICC 返回了无法解析的数据。")
        }
    }

    var diagnosticCode: String {
        switch self {
        case .unavailable: return "operation_unavailable"
        case let .http(failure, stage):
            return "stage=\(stage?.rawValue ?? "unknown") \(failure.diagnosticCode)"
        case .invalidResponse: return "invalid_euicc_response"
        }
    }
}

final class EUICCService {
    var onSnapshot: ((EUICCSnapshot) -> Void)?

    private unowned let modemService: ModemService
    private var currentSnapshot = EUICCSnapshot.empty

    init(modemService: ModemService) {
        self.modemService = modemService
    }

    func reset() {
        currentSnapshot = .empty
        onSnapshot?(currentSnapshot)
    }

    func detect() {
        perform(operation: .detecting, classifyDetectionFailure: true) { session, _ in
            try Self.readSnapshot(session)
        }
    }

    func refresh() {
        perform(operation: .refreshing) { session, _ in
            try Self.readSnapshot(session)
        }
    }

    func enable(profile: ESIMProfile) {
        perform(operation: .enabling(profile.iccid)) { session, _ in
            try Self.runProfileAction(session, iccid: profile.iccid, action: celldock_euicc_enable_profile)
            return try Self.readSnapshot(session)
        }
    }

    func disable(profile: ESIMProfile) {
        perform(operation: .disabling(profile.iccid)) { session, _ in
            try Self.runProfileAction(session, iccid: profile.iccid, action: celldock_euicc_disable_profile)
            return try Self.readSnapshot(session)
        }
    }

    func delete(profile: ESIMProfile) {
        perform(operation: .deleting(profile.iccid)) { session, _ in
            try Self.runProfileAction(session, iccid: profile.iccid, action: celldock_euicc_delete_profile)
            return try Self.readSnapshot(session)
        }
    }

    func rename(profile: ESIMProfile, nickname: String) {
        perform(operation: .renaming(profile.iccid)) { session, _ in
            let result = profile.iccid.withCString { iccid in
                nickname.withCString { value in
                    celldock_euicc_set_nickname(session, iccid, value)
                }
            }
            try Self.check(result, session: session)
            return try Self.readSnapshot(session)
        }
    }

    func download(
        activationCode: ESIMActivationCode,
        confirmationCode: String?,
        imei: String?
    ) {
        perform(operation: .downloading) { session, transport in
            let confirmation = confirmationCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let deviceIMEI = imei ?? ""
            let result = activationCode.smdpAddress.withCString { server in
                activationCode.matchingID.withCString { matchingID in
                    confirmation.withCString { confirmationCode in
                        deviceIMEI.withCString { imei in
                            celldock_euicc_download_profile(
                                session,
                                server,
                                matchingID,
                                confirmationCode,
                                imei
                            )
                        }
                    }
                }
            }
            try Self.check(result, session: session, transport: transport)
            return try Self.readSnapshot(session)
        }
    }

    private func perform(
        operation: ESIMOperation,
        classifyDetectionFailure: Bool = false,
        work: @escaping (OpaquePointer, EUICCTransportContext) throws -> EUICCSnapshot
    ) {
        var pending = operation == .detecting ? EUICCSnapshot.empty : currentSnapshot
        pending.cardKind = operation == .detecting ? .probing : .eUICC
        pending.operation = operation
        pending.lastError = nil
        currentSnapshot = pending
        onSnapshot?(pending)

        let modemService = self.modemService
        modemService.performExclusiveEUICCWork({
            let transport = EUICCTransportContext(modemService: modemService)
            let retainedTransport = Unmanaged.passRetained(transport)
            defer { retainedTransport.release() }
            let callbacks = CellDockEUICCCallbacks(
                context: retainedTransport.toOpaque(),
                at_command: cellDockEUICCATCallback,
                http_request: cellDockEUICCHTTPCallback
            )
            guard let session = celldock_euicc_create(callbacks) else {
                throw EUICCServiceError.unavailable(L10n.tr("无法创建 eUICC 会话。"))
            }
            defer { celldock_euicc_destroy(session) }
            return try work(session, transport)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case var .success(snapshot):
                snapshot.cardKind = .eUICC
                snapshot.operation = .idle
                snapshot.lastError = nil
                self.currentSnapshot = snapshot
                euiccLogger.info(
                    "eUICC operation completed operation=\(Self.logName(for: operation), privacy: .public) isdr_source=\(snapshot.isdrAidSource ?? "unknown", privacy: .public)"
                )
                self.onSnapshot?(snapshot)
            case let .failure(error):
                let message = error.localizedDescription
                var snapshot = classifyDetectionFailure ? EUICCSnapshot.empty : self.currentSnapshot
                snapshot.cardKind = classifyDetectionFailure
                    ? Self.cardKind(forDetectionError: message)
                    : .eUICC
                snapshot.operation = .idle
                snapshot.lastError = Self.localized(message)
                self.currentSnapshot = snapshot
                let diagnostic = (error as? EUICCServiceError)?.diagnosticCode
                    ?? "operation_error"
                euiccLogger.error(
                    "eUICC operation failed operation=\(Self.logName(for: operation), privacy: .public) diagnostic=\(diagnostic, privacy: .public)"
                )
                self.onSnapshot?(snapshot)
            }
        }
    }

    private static func readSnapshot(_ session: OpaquePointer) throws -> EUICCSnapshot {
        var jsonPointer: UnsafeMutablePointer<CChar>?
        let result = celldock_euicc_read_snapshot(session, &jsonPointer)
        try check(result, session: session)
        guard let jsonPointer else { throw EUICCServiceError.invalidResponse }
        defer { celldock_euicc_free(jsonPointer) }
        guard let data = String(cString: jsonPointer).data(using: .utf8) else {
            throw EUICCServiceError.invalidResponse
        }
        struct Payload: Decodable {
            let eid: String
            let isdrAidSource: String?
            let profiles: [ESIMProfile]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.eid.count >= 16, payload.eid.allSatisfy(\.isNumber) else {
            throw EUICCServiceError.invalidResponse
        }
        return EUICCSnapshot(
            cardKind: .eUICC,
            eid: payload.eid,
            isdrAidSource: payload.isdrAidSource,
            profiles: payload.profiles
        )
    }

    private static func runProfileAction(
        _ session: OpaquePointer,
        iccid: String,
        action: (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    ) throws {
        let result = iccid.withCString { action(session, $0) }
        try check(result, session: session)
    }

    private static func check(
        _ result: Int32,
        session: OpaquePointer,
        transport: EUICCTransportContext? = nil
    ) throws {
        guard result != CELLDOCK_EUICC_OK else { return }
        let message = celldock_euicc_last_error(session).map(String.init(cString:))
            ?? L10n.tr("eUICC 操作失败。")
        if let failure = transport?.lastHTTPFailure {
            throw EUICCServiceError.http(
                failure,
                stage: ESIMDownloadStage.extract(from: message)
            )
        }
        throw EUICCServiceError.unavailable(localized(message))
    }

    private static func logName(for operation: ESIMOperation) -> String {
        switch operation {
        case .idle: return "idle"
        case .detecting: return "detect"
        case .refreshing: return "refresh"
        case .downloading: return "download"
        case .enabling: return "enable"
        case .disabling: return "disable"
        case .deleting: return "delete"
        case .renaming: return "rename"
        }
    }

    private static func cardKind(forDetectionError message: String) -> SubscriberCardKind {
        let normalized = message.lowercased()
        if normalized.contains("did not expose the euicc") ||
            normalized.contains("valid eid") ||
            message.contains("不是 eUICC") ||
            message.contains("有效 EID") {
            return .physicalSIM
        }
        if normalized.contains("does not expose standard uicc") || message.contains("不支持标准 eUICC") {
            return .unsupported
        }
        return .failed
    }

    private static func localized(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("did not expose the euicc") {
            return L10n.tr("当前卡片不是 eUICC。")
        }
        if normalized.contains("does not expose standard uicc") {
            return L10n.tr("蜂窝模块不支持标准 eUICC 逻辑通道命令。")
        }
        if normalized.contains("valid eid") { return L10n.tr("未能从卡片读取有效 EID。") }
        if normalized.contains("installed esim profiles") { return L10n.tr("无法读取已安装的 eSIM 套餐。") }
        if normalized.contains("enable the esim") { return L10n.tr("无法启用 eSIM 套餐。") }
        if normalized.contains("disable the esim") { return L10n.tr("无法停用 eSIM 套餐。") }
        if normalized.contains("delete the esim") { return L10n.tr("无法删除 eSIM 套餐。") }
        if normalized.contains("rename the esim") { return L10n.tr("无法重命名 eSIM 套餐。") }
        if normalized.contains("download failed") {
            if let stage = ESIMDownloadStage.extract(from: message) {
                return L10n.tr("eSIM 套餐下载失败（阶段：%@）。", stage.localizedName)
            }
            return L10n.tr("eSIM 套餐下载失败。")
        }
        return message
    }
}
