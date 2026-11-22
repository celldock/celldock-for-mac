import Foundation

enum ADBWire {
    static let maxPayload = 4_096

    static let auth = command("AUTH")
    static let clse = command("CLSE")
    static let cnxn = command("CNXN")
    static let okay = command("OKAY")
    static let open = command("OPEN")
    static let wrte = command("WRTE")

    struct Message: Equatable {
        let command: UInt32
        let argument0: UInt32
        let argument1: UInt32
        let payload: Data
    }

    struct CheckedShellResult: Equatable {
        let output: String
        let status: Int
    }

    enum ProtocolError: AppLocalizedError {
        case invalidHeader
        case invalidPayload
        case missingExitMarker

        var errorDescription: String? {
            switch self {
            case .invalidHeader: return L10n.tr("ADB 消息头无效。")
            case .invalidPayload: return L10n.tr("ADB 消息负载无效。")
            case .missingExitMarker: return L10n.tr("模块 shell 没有返回退出状态。")
            }
        }
    }

    static func command(_ text: String) -> UInt32 {
        let bytes = Array(text.utf8)
        precondition(bytes.count == 4)
        return UInt32(bytes[0]) |
            UInt32(bytes[1]) << 8 |
            UInt32(bytes[2]) << 16 |
            UInt32(bytes[3]) << 24
    }

    static func checksum(_ payload: Data) -> UInt32 {
        payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    static func encodeHeader(
        command: UInt32,
        argument0: UInt32,
        argument1: UInt32,
        payload: Data
    ) -> Data {
        var header = Data()
        header.reserveCapacity(24)
        header.appendLittleEndian(command)
        header.appendLittleEndian(argument0)
        header.appendLittleEndian(argument1)
        header.appendLittleEndian(UInt32(payload.count))
        header.appendLittleEndian(checksum(payload))
        header.appendLittleEndian(command ^ UInt32.max)
        return header
    }

    static func decodeHeader(_ header: Data, payload: Data) throws -> Message {
        guard header.count == 24,
              let command = header.littleEndianUInt32(at: 0),
              let argument0 = header.littleEndianUInt32(at: 4),
              let argument1 = header.littleEndianUInt32(at: 8),
              let length = header.littleEndianUInt32(at: 12),
              let expectedChecksum = header.littleEndianUInt32(at: 16),
              let magic = header.littleEndianUInt32(at: 20),
              magic == command ^ UInt32.max else {
            throw ProtocolError.invalidHeader
        }
        guard length == payload.count,
              payload.count <= maxPayload,
              expectedChecksum == checksum(payload) else {
            throw ProtocolError.invalidPayload
        }
        return Message(
            command: command,
            argument0: argument0,
            argument1: argument1,
            payload: payload
        )
    }

    static func syncPacket(identifier: String, payload: Data) -> Data {
        precondition(identifier.utf8.count == 4)
        var packet = Data(identifier.utf8)
        packet.appendLittleEndian(UInt32(payload.count))
        packet.append(payload)
        return packet
    }

    static func syncHeader(identifier: String, value: UInt32) -> Data {
        precondition(identifier.utf8.count == 4)
        var packet = Data(identifier.utf8)
        packet.appendLittleEndian(value)
        return packet
    }

    static func checkedShellCommand(_ command: String, token: String) -> String {
        let safeToken = token.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        precondition(!safeToken.isEmpty)
        // Isolate the script because probes use `exit` for early returns. In a
        // brace group that exits the ADB shell before the marker is emitted.
        return "( \(command); ); __celldock_status=$?; printf '\\n__CELLDOCK_STATUS_\(safeToken)_%u__\\n' \"$__celldock_status\""
    }

    static func parseCheckedShellOutput(
        _ raw: String,
        token: String
    ) throws -> CheckedShellResult {
        let prefix = "__CELLDOCK_STATUS_\(token)_"
        guard let marker = raw.range(of: prefix, options: .backwards),
              let suffix = raw[marker.upperBound...].range(of: "__"),
              let status = Int(raw[marker.upperBound ..< suffix.lowerBound]) else {
            throw ProtocolError.missingExitMarker
        }
        let output = String(raw[..<marker.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CheckedShellResult(output: output, status: status)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset]) |
                UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 |
                UInt32(bytes[offset + 3]) << 24
        }
    }
}
