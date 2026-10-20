import Foundation

enum PreferredCallMediaBackend: Equatable {
    case qdcModuleBridge
    case qpcmv
    case none
}

enum CallATParser {
    static func normalizedDialNumber(_ value: String) -> String? {
        guard !value.contains(where: { $0.isNewline || ($0.isWhitespace && $0 != " ") }) else {
            return nil
        }
        let compact = value.filter { $0 != " " && !"-()".contains($0) }
        guard !compact.isEmpty, compact.count <= 32 else { return nil }
        for (offset, character) in compact.enumerated() {
            if "0123456789".contains(character) { continue }
            if character == "+", offset == 0 { continue }
            return nil
        }
        guard compact.contains(where: { "0123456789".contains($0) }) else { return nil }
        return compact
    }

    static func normalizedDTMFTone(_ value: String) -> String? {
        guard value.utf8.count == 1, let byte = value.utf8.first else { return nil }
        guard (48 ... 57).contains(byte) || byte == 42 || byte == 35 else { return nil }
        return value
    }

    static func dtmfCommand(for value: String) -> String? {
        guard let tone = normalizedDTMFTone(value) else { return nil }
        return "AT+VTS=\"\(tone)\""
    }

    static func parseCLCC(_ line: String) -> ModemCallInfo? {
        guard let colon = line.firstIndex(of: ":"),
              line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() == "+CLCC" else {
            return nil
        }
        let fields = splitCSV(String(line[line.index(after: colon)...]))
        guard fields.count >= 5,
              let index = Int(fields[0]),
              let rawDirection = Int(fields[1]),
              let rawStatus = Int(fields[2]),
              let status = ModemCallStatus(rawValue: rawStatus),
              let mode = Int(fields[3]),
              let multiparty = Int(fields[4]),
              rawDirection == 0 || rawDirection == 1 else {
            return nil
        }
        let number = fields.count > 5 ? unquoted(fields[5]) : nil
        return ModemCallInfo(
            index: index,
            direction: rawDirection == 0 ? .outgoing : .incoming,
            status: status,
            isVoice: mode == 0,
            isMultiparty: multiparty != 0,
            number: number?.isEmpty == false ? number : nil
        )
    }

    static func parseEvents(inLine rawLine: String) -> [ModemCallEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercase = line.uppercased()
        if uppercase == "RING" || uppercase.hasPrefix("+CRING:") {
            return [.ring]
        }
        if uppercase.hasPrefix("+CLIP:"),
           let colon = line.firstIndex(of: ":") {
            let fields = splitCSV(String(line[line.index(after: colon)...]))
            if let first = fields.first {
                let number = unquoted(first)
                if !number.isEmpty { return [.callerID(number)] }
            }
            return []
        }
        if let info = parseCLCC(line), info.isVoice {
            return [.callInfo(info)]
        }
        if uppercase == "CONNECT" || uppercase == "MO CONNECTED" {
            return [.connected]
        }
        switch uppercase {
        case "NO CARRIER": return [.ended(.unknown, evidence: .modemResult(uppercase))]
        case "BUSY": return [.ended(.busy, evidence: .modemResult(uppercase))]
        case "NO ANSWER": return [.ended(.noAnswer, evidence: .modemResult(uppercase))]
        case "NO DIALTONE", "NO DIAL TONE": return [.ended(.noDialTone, evidence: .modemResult(uppercase))]
        default: break
        }
        if uppercase.hasPrefix("+QPCMV:"),
           let colon = line.firstIndex(of: ":") {
            let first = line[line.index(after: colon)...]
                .split(separator: ",", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if first == "0" { return [.pcmFlowReady(false)] }
            if first == "1" { return [.pcmFlowReady(true)] }
        }
        return []
    }

    static func parseCLCCResponse(_ response: String) -> [ModemCallInfo] {
        normalizedLines(response).compactMap(parseCLCC).filter(\.isVoice)
    }

    static func testResponseSupportsRawPCM(_ response: String) -> Bool {
        normalizedLines(response).contains { line in
            guard line.uppercased().hasPrefix("+QPCMV:") else { return false }
            let compact = line.replacingOccurrences(of: " ", with: "")
            var groups: [String] = []
            var groupStart: String.Index?
            for index in compact.indices {
                if compact[index] == "(" {
                    groupStart = compact.index(after: index)
                } else if compact[index] == ")", let start = groupStart {
                    groups.append(String(compact[start ..< index]))
                    groupStart = nil
                }
            }
            guard groups.count >= 2 else { return false }
            return groups[1].split(separator: ",").contains { token in
                if token == "0" { return true }
                let bounds = token.split(separator: "-", maxSplits: 1)
                guard bounds.count == 2,
                      let lower = Int(bounds[0]),
                      let upper = Int(bounds[1]) else {
                    return false
                }
                return lower <= 0 && 0 <= upper
            }
        }
    }

    static func preferredMediaBackend(
        hardwareFamily: ModemHardwareFamily,
        supportsRawPCM: Bool,
        hasUSBLocation: Bool
    ) -> PreferredCallMediaBackend {
        guard hasUSBLocation else { return .none }
        switch hardwareFamily {
        case .baiwangInjectedVoice:
            return .qdcModuleBridge
        case .quectelNativeVoice:
            return supportsRawPCM ? .qpcmv : .none
        case .unknown:
            return .none
        }
    }

    private static func normalizedLines(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitCSV(_ value: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                field.append(character)
            } else if character == ",", !quoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
        }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\"" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}

struct CallURCStreamFramer {
    private var pendingLine = ""

    mutating func consume(_ text: String) -> [ModemCallEvent] {
        guard !text.isEmpty else { return [] }
        pendingLine += text
        let normalized = pendingLine
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let endedAtBoundary = pendingLine.last == "\r" || pendingLine.last == "\n"
        var lines = normalized.components(separatedBy: "\n")
        if endedAtBoundary {
            pendingLine = ""
        } else {
            pendingLine = lines.popLast() ?? ""
            if pendingLine.utf8.count > 4_096 {
                pendingLine = String(pendingLine.suffix(1_024))
            }
        }
        return lines.flatMap(CallATParser.parseEvents)
    }

    mutating func reset() {
        pendingLine = ""
    }
}
