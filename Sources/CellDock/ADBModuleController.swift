import CModemBridge
import Foundation
import IOKit

final class ADBModuleController {
    struct ShellResult {
        let output: String
        let status: Int
    }

    enum ControllerError: AppLocalizedError {
        case openFailed(String)
        case interfaceBusy
        case transport(String)
        case protocolViolation(String)
        case authenticationRequired
        case outputTooLarge
        case remoteFailure(String)

        var errorDescription: String? {
            switch self {
            case let .openFailed(message): return message
            case .interfaceBusy:
                return L10n.tr(
                    "模块控制接口正被 adb、Android Studio 或另一份 CellDock 占用；CellDock 已请求对方释放，但对方仍在使用。"
                )
            case let .transport(message): return message
            case let .protocolViolation(message): return message
            case .authenticationRequired:
                return L10n.tr("模块 ADB 要求认证，无法自动控制通话组件。")
            case .outputTooLarge: return L10n.tr("模块 ADB 返回内容过大。")
            case let .remoteFailure(message): return message
            }
        }
    }

    private let locationID: UInt32
    private let operationLock = NSLock()
    private var connection: Connection?

    init(locationID: UInt32) {
        self.locationID = locationID
    }

    deinit {
        connection?.close()
    }

    func shellChecked(_ command: String, timeout: TimeInterval = 15) throws -> ShellResult {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let wrapped = ADBWire.checkedShellCommand(command, token: token)
        let raw = try shell(wrapped, timeout: timeout)
        let parsed = try ADBWire.parseCheckedShellOutput(raw, token: token)
        return ShellResult(output: parsed.output, status: parsed.status)
    }

    func shell(_ command: String, timeout: TimeInterval = 15) throws -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        let connection = try connectedTransport()
        do {
            let stream = try connection.openService("shell:\(command)")
            var output = Data()
            let deadline = Date().addingTimeInterval(timeout)

            while Date() < deadline {
                let message = try connection.receive(deadline: deadline)
                switch message.command {
                case ADBWire.wrte:
                    guard message.argument0 == stream.remoteID,
                          message.argument1 == stream.localID else {
                        throw ControllerError.protocolViolation(L10n.tr("ADB shell 流标识不匹配。"))
                    }
                    output.append(message.payload)
                    guard output.count <= 1_048_576 else {
                        throw ControllerError.outputTooLarge
                    }
                    try connection.send(
                        command: ADBWire.okay,
                        argument0: stream.localID,
                        argument1: stream.remoteID
                    )
                case ADBWire.clse:
                    guard message.argument1 == stream.localID,
                          message.argument0 == 0 || message.argument0 == stream.remoteID else {
                        throw ControllerError.protocolViolation(L10n.tr("ADB shell 关闭消息无效。"))
                    }
                    if message.argument0 != 0 {
                        try connection.send(
                            command: ADBWire.clse,
                            argument0: stream.localID,
                            argument1: stream.remoteID
                        )
                    }
                    return String(decoding: output, as: UTF8.self)
                case ADBWire.okay:
                    guard message.argument0 == stream.remoteID,
                          message.argument1 == stream.localID,
                          message.payload.isEmpty else {
                        throw ControllerError.protocolViolation(L10n.tr("ADB shell 确认消息无效。"))
                    }
                default:
                    throw ControllerError.protocolViolation(
                        L10n.tr(
                            "ADB shell 收到未知消息 command=0x%08X arg0=%u arg1=%u。",
                            message.command,
                            message.argument0,
                            message.argument1
                        )
                    )
                }
            }
            throw ControllerError.transport(L10n.tr("等待模块 shell 超时。"))
        } catch {
            invalidate(connection)
            throw error
        }
    }

    func push(
        _ data: Data,
        to remotePath: String,
        mode: UInt32 = 0o100755,
        modifiedAt: UInt32 = UInt32(Date().timeIntervalSince1970)
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !remotePath.isEmpty,
              !remotePath.contains(","),
              !remotePath.contains("\0") else {
            throw ControllerError.protocolViolation(L10n.tr("ADB push 目标路径无效。"))
        }
        let connection = try connectedTransport()
        var streamClosed = false
        do {
            let stream = try connection.openService("sync:")

            let sendName = Data("\(remotePath),\(mode)".utf8)
            try connection.writeStream(
                ADBWire.syncPacket(identifier: "SEND", payload: sendName),
                stream: stream
            )

            let chunkCapacity = ADBWire.maxPayload - 8
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkCapacity, data.count)
                let chunk = data.subdata(in: offset ..< end)
                try connection.writeStream(
                    ADBWire.syncPacket(identifier: "DATA", payload: chunk),
                    stream: stream
                )
                offset = end
            }
            try connection.writeStream(
                ADBWire.syncHeader(identifier: "DONE", value: modifiedAt),
                stream: stream
            )

            var response = Data()
            let deadline = Date().addingTimeInterval(20)
            while response.count < 8 {
                let message = try connection.receive(deadline: deadline)
                if message.command == ADBWire.wrte {
                    guard message.argument0 == stream.remoteID,
                          message.argument1 == stream.localID else {
                        throw ControllerError.protocolViolation(L10n.tr("ADB sync 流标识不匹配。"))
                    }
                    response.append(message.payload)
                    try connection.send(
                        command: ADBWire.okay,
                        argument0: stream.localID,
                        argument1: stream.remoteID
                    )
                } else if message.command == ADBWire.clse {
                    throw ControllerError.protocolViolation(L10n.tr("ADB sync 提前关闭。"))
                }
            }

            let identifier = String(decoding: response.prefix(4), as: UTF8.self)
            let value = UInt32(response[4]) |
                UInt32(response[5]) << 8 |
                UInt32(response[6]) << 16 |
                UInt32(response[7]) << 24
            var remoteFailure: ControllerError?
            if identifier == "FAIL" {
                let length = Int(value)
                guard length <= 1_048_576 else { throw ControllerError.outputTooLarge }
                while response.count < 8 + length {
                    let message = try connection.receive(deadline: deadline)
                    guard message.command == ADBWire.wrte,
                          message.argument0 == stream.remoteID,
                          message.argument1 == stream.localID else {
                        throw ControllerError.protocolViolation(L10n.tr("ADB sync FAIL 消息不完整。"))
                    }
                    response.append(message.payload)
                    try connection.send(
                        command: ADBWire.okay,
                        argument0: stream.localID,
                        argument1: stream.remoteID
                    )
                }
                let message = String(decoding: response[8 ..< 8 + length], as: UTF8.self)
                remoteFailure = .remoteFailure(L10n.tr("模块拒绝文件传输：%@", message))
            } else {
                guard identifier == "OKAY", value == 0 else {
                    throw ControllerError.protocolViolation(L10n.tr("ADB sync 返回无效状态。"))
                }
            }
            try connection.closeStream(
                stream,
                deadline: Date().addingTimeInterval(5)
            )
            streamClosed = true
            if let remoteFailure { throw remoteFailure }
        } catch {
            if !streamClosed {
                invalidate(connection)
            }
            throw error
        }
    }

    func pull(_ remotePath: String, maximumSize: Int = 64 * 1_024 * 1_024) throws -> Data {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !remotePath.isEmpty,
              !remotePath.contains("\0"),
              maximumSize > 0 else {
            throw ControllerError.protocolViolation(L10n.tr("ADB pull 路径或大小限制无效。"))
        }

        let connection = try connectedTransport()
        var streamClosed = false
        do {
            let stream = try connection.openService("sync:")
            try connection.writeStream(
                ADBWire.syncPacket(identifier: "RECV", payload: Data(remotePath.utf8)),
                stream: stream
            )

            var pending = Data()
            var output = Data()
            var finished = false
            let deadline = Date().addingTimeInterval(30)

            while !finished, Date() < deadline {
                let message = try connection.receive(deadline: deadline)
                guard message.command == ADBWire.wrte,
                      message.argument0 == stream.remoteID,
                      message.argument1 == stream.localID else {
                    throw ControllerError.protocolViolation(
                        L10n.tr("ADB pull 流提前关闭或标识不匹配。")
                    )
                }
                pending.append(message.payload)
                try connection.send(
                    command: ADBWire.okay,
                    argument0: stream.localID,
                    argument1: stream.remoteID
                )

                parsePackets: while pending.count >= 8 {
                    let identifier = String(decoding: pending.prefix(4), as: UTF8.self)
                    let value = Int(UInt32(pending[4]) |
                        UInt32(pending[5]) << 8 |
                        UInt32(pending[6]) << 16 |
                        UInt32(pending[7]) << 24)

                    switch identifier {
                    case "DATA":
                        guard value <= maximumSize,
                              output.count <= maximumSize - value else {
                            throw ControllerError.outputTooLarge
                        }
                        guard pending.count >= 8 + value else { break parsePackets }
                        output.append(pending[8 ..< 8 + value])
                        pending = Data(pending.dropFirst(8 + value))
                    case "DONE":
                        guard value == 0 else {
                            throw ControllerError.protocolViolation(L10n.tr("ADB pull DONE 状态无效。"))
                        }
                        pending = Data(pending.dropFirst(8))
                        guard pending.isEmpty else {
                            throw ControllerError.protocolViolation(
                                L10n.tr("ADB pull DONE 后仍有多余数据。")
                            )
                        }
                        finished = true
                    case "FAIL":
                        guard value <= 1_048_576 else {
                            throw ControllerError.outputTooLarge
                        }
                        guard pending.count >= 8 + value else { break parsePackets }
                        let detail = String(decoding: pending[8 ..< 8 + value], as: UTF8.self)
                        throw ControllerError.remoteFailure(L10n.tr("模块拒绝读取文件：%@", detail))
                    default:
                        throw ControllerError.protocolViolation(
                            L10n.tr("ADB pull 返回未知 sync 数据包。")
                        )
                    }

                    if pending.count < 8 || finished { break }
                }
            }

            guard finished else {
                throw ControllerError.transport(L10n.tr("等待模块 ADB pull 数据超时。"))
            }
            try connection.closeStream(stream, deadline: Date().addingTimeInterval(5))
            streamClosed = true
            return output
        } catch {
            if !streamClosed {
                invalidate(connection)
            }
            throw error
        }
    }

    private func connectedTransport() throws -> Connection {
        if let connection, connection.isOpen { return connection }
        if let connection {
            self.connection = nil
            connection.close()
        }
        let candidate = try Connection(locationID: locationID)
        do {
            try candidate.connect()
        } catch {
            candidate.close()
            throw error
        }
        connection = candidate
        return candidate
    }

    private func invalidate(_ candidate: Connection) {
        guard connection === candidate else { return }
        connection = nil
        candidate.close()
    }

    private final class Connection {
        struct Stream {
            let localID: UInt32
            let remoteID: UInt32
        }

        private let transport: OpaquePointer
        private var remoteMaxPayload = ADBWire.maxPayload
        private var nextLocalID: UInt32 = 1
        private var closed = false

        init(locationID: UInt32) throws {
            guard let transport = celldock_voice_create() else {
                throw ControllerError.openFailed(L10n.tr("无法初始化模块 ADB USB 通道。"))
            }
            let result = celldock_voice_open_control_interface_for_location(transport, locationID, 6)
            guard result == CELLDOCK_MODEM_OK else {
                let raw = String(cString: celldock_voice_last_error(transport))
                celldock_voice_destroy(transport)
                if result == kIOReturnExclusiveAccess {
                    throw ControllerError.interfaceBusy
                }
                throw ControllerError.openFailed(
                    raw.isEmpty ? L10n.tr("无法打开模块 ADB interface 6。") : raw
                )
            }
            self.transport = transport
        }

        func close() {
            guard !closed else { return }
            closed = true
            celldock_voice_destroy(transport)
        }

        var isOpen: Bool {
            !closed && celldock_voice_is_open(transport) != 0
        }

        func connect() throws {
            var banner = Data("host::CellDock".utf8)
            banner.append(0)
            let deadline = Date().addingTimeInterval(8)
            var staleMessages = 0

            func sendConnect() throws {
                try send(
                    command: ADBWire.cnxn,
                    argument0: 0x01000001,
                    argument1: UInt32(ADBWire.maxPayload),
                    payload: banner
                )
            }

            try sendConnect()
            while Date() < deadline {
                let response = try receive(deadline: deadline)
                if response.command == ADBWire.auth {
                    throw ControllerError.authenticationRequired
                }
                if response.command == ADBWire.cnxn, response.argument1 > 0 {
                    remoteMaxPayload = min(Int(response.argument1), ADBWire.maxPayload)
                    return
                }

                // A process can be interrupted after the device queued a WRTE/CLSE
                // for its old stream. The USB gadget keeps those packets across a
                // host-side interface reopen, so explicitly close that stale stream
                // before retrying CNXN instead of consuming it as the handshake.
                if response.command == ADBWire.wrte ||
                    response.command == ADBWire.okay ||
                    response.command == ADBWire.clse {
                    staleMessages += 1
                    guard staleMessages <= 64 else {
                        throw ControllerError.protocolViolation(
                            L10n.tr("ADB 旧流无法清理。")
                        )
                    }
                    if response.argument0 != 0, response.argument1 != 0 {
                        try send(
                            command: ADBWire.clse,
                            argument0: response.argument1,
                            argument1: response.argument0
                        )
                    }
                    try sendConnect()
                    continue
                }
                throw ControllerError.protocolViolation(
                    L10n.tr(
                        "模块未接受 ADB CNXN（command=0x%08X）。",
                        response.command
                    )
                )
            }
            throw ControllerError.transport(L10n.tr("等待模块接受 ADB CNXN 超时。"))
        }

        func openService(_ service: String) throws -> Stream {
            var payload = Data(service.utf8)
            payload.append(0)
            guard payload.count <= remoteMaxPayload else {
                throw ControllerError.protocolViolation(L10n.tr("ADB 服务命令过长。"))
            }
            let localID = allocateLocalID()
            try send(
                command: ADBWire.open,
                argument0: localID,
                argument1: 0,
                payload: payload
            )
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                let response = try receive(deadline: deadline)
                if response.command == ADBWire.okay,
                   response.argument0 != 0,
                   response.argument1 == localID,
                   response.payload.isEmpty {
                    return Stream(localID: localID, remoteID: response.argument0)
                }
                if response.command == ADBWire.cnxn, response.argument1 > 0 {
                    remoteMaxPayload = min(Int(response.argument1), ADBWire.maxPayload)
                    continue
                }
                if response.command == ADBWire.clse,
                   response.argument1 == localID {
                    throw ControllerError.protocolViolation(L10n.tr("模块拒绝 ADB 服务。"))
                }
                if response.command == ADBWire.wrte ||
                    response.command == ADBWire.okay ||
                    response.command == ADBWire.clse {
                    if response.argument0 != 0, response.argument1 != 0 {
                        try send(
                            command: ADBWire.clse,
                            argument0: response.argument1,
                            argument1: response.argument0
                        )
                    }
                    continue
                }
                throw ControllerError.protocolViolation(L10n.tr("模块拒绝 ADB 服务。"))
            }
            throw ControllerError.transport(L10n.tr("等待模块打开 ADB 服务超时。"))
        }

        func writeStream(_ data: Data, stream: Stream) throws {
            guard data.count <= remoteMaxPayload else {
                throw ControllerError.protocolViolation(L10n.tr("ADB sync 数据块过大。"))
            }
            try send(
                command: ADBWire.wrte,
                argument0: stream.localID,
                argument1: stream.remoteID,
                payload: data
            )
            let response = try receive(deadline: Date().addingTimeInterval(10))
            guard response.command == ADBWire.okay,
                  response.argument0 == stream.remoteID,
                  response.argument1 == stream.localID,
                  response.payload.isEmpty else {
                throw ControllerError.protocolViolation(L10n.tr("模块未确认 ADB 数据块。"))
            }
        }

        func closeStream(_ stream: Stream, deadline: Date) throws {
            try send(
                command: ADBWire.clse,
                argument0: stream.localID,
                argument1: stream.remoteID
            )
            while Date() < deadline {
                let response = try receive(deadline: deadline)
                if response.command == ADBWire.clse,
                   response.argument0 == stream.remoteID,
                   response.argument1 == stream.localID,
                   response.payload.isEmpty {
                    return
                }
                if response.command == ADBWire.wrte,
                   response.argument0 == stream.remoteID,
                   response.argument1 == stream.localID {
                    try send(
                        command: ADBWire.okay,
                        argument0: stream.localID,
                        argument1: stream.remoteID
                    )
                    continue
                }
                throw ControllerError.protocolViolation(L10n.tr("ADB sync 关闭响应无效。"))
            }
            throw ControllerError.transport(L10n.tr("等待模块关闭 ADB sync 流超时。"))
        }

        private func allocateLocalID() -> UInt32 {
            let allocated = nextLocalID
            nextLocalID &+= 1
            if nextLocalID == 0 { nextLocalID = 1 }
            return allocated
        }

        func send(
            command: UInt32,
            argument0: UInt32,
            argument1: UInt32,
            payload: Data = Data()
        ) throws {
            let header = ADBWire.encodeHeader(
                command: command,
                argument0: argument0,
                argument1: argument1,
                payload: payload
            )
            try write(header)
            if !payload.isEmpty { try write(payload) }
        }

        func receive(deadline: Date) throws -> ADBWire.Message {
            let header = try readExactly(24, deadline: deadline)
            guard let length = headerLittleEndianUInt32(header, at: 12),
                  length <= ADBWire.maxPayload else {
                throw ControllerError.protocolViolation(L10n.tr("ADB 消息长度无效。"))
            }
            let payload = try readExactly(Int(length), deadline: deadline)
            do {
                return try ADBWire.decodeHeader(header, payload: payload)
            } catch {
                throw ControllerError.protocolViolation(error.localizedDescription)
            }
        }

        private func write(_ data: Data) throws {
            let result = data.withUnsafeBytes { rawBuffer -> Int32 in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                return celldock_voice_write(
                    transport,
                    2_000,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            guard result == CELLDOCK_MODEM_OK else {
                throw ControllerError.transport(lastTransportError(L10n.tr("ADB USB 写入失败。")))
            }
        }

        private func readExactly(_ count: Int, deadline: Date) throws -> Data {
            if count == 0 { return Data() }
            var output = Data(count: count)
            var used = 0
            while used < count, Date() < deadline {
                let received = output.withUnsafeMutableBytes { rawBuffer -> Int32 in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    return celldock_voice_read(
                        transport,
                        100,
                        bytes.baseAddress?.advanced(by: used),
                        count - used
                    )
                }
                guard celldock_voice_is_open(transport) != 0 else {
                    throw ControllerError.transport(lastTransportError(L10n.tr("ADB USB 已断开。")))
                }
                if received > 0 { used += Int(received) }
            }
            guard used == count else {
                throw ControllerError.transport(L10n.tr("等待模块 ADB 数据超时。"))
            }
            return output
        }

        private func lastTransportError(_ fallback: String) -> String {
            let raw = String(cString: celldock_voice_last_error(transport))
            return raw.isEmpty ? fallback : raw
        }

        private func headerLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                return UInt32(bytes[offset]) |
                    UInt32(bytes[offset + 1]) << 8 |
                    UInt32(bytes[offset + 2]) << 16 |
                    UInt32(bytes[offset + 3]) << 24
            }
        }
    }

    static func isInterfaceBusyError(_ error: Error) -> Bool {
        guard let controllerError = error as? ControllerError else { return false }
        if case .interfaceBusy = controllerError { return true }
        return false
    }
}
