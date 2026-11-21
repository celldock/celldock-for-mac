import Darwin
import Foundation

/// Client-side snippets that let another app (Surge, Clash/Mihomo, or any
/// SOCKS5 client) use one of CellDock's local SOCKS5 proxies.
enum SOCKSProxyClientSnippetFormat: String, CaseIterable, Identifiable, Sendable {
    case address
    case surge
    case clash

    var id: Self { self }
}

struct SOCKSProxyClientConfig: Equatable, Sendable {
    static let maskedPassword = "••••••••"
    /// Name used when the proxy itself has no usable name yet.
    static let fallbackName = "CellDock"

    let name: String
    let host: String
    let port: UInt16
    /// `nil` when the proxy accepts unauthenticated connections.
    let credentials: Credentials?

    struct Credentials: Equatable, Sendable {
        let username: String
        let password: String
    }

    init(name: String, host: String, port: UInt16, credentials: Credentials?) {
        self.name = name
        self.host = host
        self.port = port
        self.credentials = credentials
    }

    init(configuration: SOCKSProxyConfiguration, host: String, password: String) {
        let credentials: Credentials?
        switch configuration.authentication {
        case .none:
            credentials = nil
        case let .usernamePassword(username):
            credentials = Credentials(username: username, password: password)
        }
        self.init(
            name: configuration.name,
            host: host,
            port: configuration.port,
            credentials: credentials
        )
    }

    /// The listener address clients connect to. Loopback proxies are only
    /// reachable as 127.0.0.1; LAN proxies use this Mac's private IPv4
    /// address when one is known.
    static func host(
        for scope: SOCKSProxyConfiguration.ListenScope,
        lanAddress: String?
    ) -> String {
        switch scope {
        case .loopback: return "127.0.0.1"
        case .lan: return lanAddress ?? "0.0.0.0"
        }
    }

    func snippet(_ format: SOCKSProxyClientSnippetFormat, revealPassword: Bool = true) -> String {
        switch format {
        case .address: return url
        case .surge: return surgeLine(revealPassword: revealPassword)
        case .clash: return clashYAML(revealPassword: revealPassword)
        }
    }

    /// `socks5://username@host:port`. Never contains the password.
    var url: String {
        var userInfo = ""
        if let credentials {
            userInfo = Self.percentEncodedUserInfo(credentials.username) + "@"
        }
        return "socks5://\(userInfo)\(Self.urlHost(host)):\(port)"
    }

    /// One line for Surge's `[Proxy]` section.
    func surgeLine(revealPassword: Bool = true) -> String {
        var fields = [
            "socks5",
            host,
            String(port),
        ]
        if let credentials {
            fields.append(Self.surgeValue(credentials.username))
            fields.append(
                revealPassword ? Self.surgeValue(credentials.password) : Self.maskedPassword
            )
        }
        fields.append("udp-relay=true")
        return "\(Self.surgeName(name)) = \(fields.joined(separator: ", "))"
    }

    /// One entry for the `proxies:` list of a Clash/Mihomo YAML profile.
    func clashYAML(revealPassword: Bool = true) -> String {
        var lines = [
            "- name: \(Self.yamlScalar(Self.cleanedName(name)))",
            "  type: socks5",
            "  server: \(Self.yamlScalar(host))",
            "  port: \(port)",
        ]
        if let credentials {
            lines.append("  username: \(Self.yamlScalar(credentials.username))")
            lines.append(
                "  password: \(revealPassword ? Self.yamlScalar(credentials.password) : Self.maskedPassword)"
            )
        }
        lines.append("  udp: true")
        return lines.joined(separator: "\n")
    }

    // MARK: - Escaping

    /// Collapses control characters and surrounding whitespace so a name can
    /// never break out of a single line.
    static func cleanedName(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallbackName : cleaned
    }

    /// Surge splits a proxy line on the first `=` and then on commas, and
    /// treats lines starting with `#` or `;` as comments. Those characters
    /// are replaced with full-width look-alikes rather than quoted, because
    /// Surge has no escape for them in the proxy-name position.
    static func surgeName(_ name: String) -> String {
        var result = cleanedName(name)
            .replacingOccurrences(of: ",", with: "，")
            .replacingOccurrences(of: "=", with: "＝")
        if let first = result.first, first == "#" || first == ";" || first == "[" {
            let replacement: Character = first == "#" ? "＃" : first == ";" ? "；" : "［"
            result.replaceSubrange(result.startIndex...result.startIndex, with: [replacement])
        }
        return result
    }

    /// Surge accepts double-quoted parameter values; quote any credential
    /// that would otherwise be split or trimmed.
    static func surgeValue(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { character in
            character == "," || character == "=" || character == "\"" ||
                character.isWhitespace
        }
        return needsQuotes ? "\"\(value)\"" : value
    }

    private static let yamlReservedWords: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "null", "~", "y", "n",
    ]

    /// Emits a YAML plain scalar when that is unambiguous and a double-quoted,
    /// escaped scalar otherwise.
    static func yamlScalar(_ value: String) -> String {
        // A leading digit is only safe for dotted values such as IPv4
        // addresses, which YAML cannot read as a number.
        let startsUnsafely = value.first.map { first in
            first == "." || first == "-" || first == "+" ||
                (first.isNumber && value.filter { $0 == "." }.count < 2)
        } ?? true
        let plainSafe = !value.isEmpty &&
            !yamlReservedWords.contains(value.lowercased()) &&
            !startsUnsafely &&
            value.allSatisfy { character in
                character.isLetter || character.isNumber ||
                    character == "_" || character == "-" || character == "."
            }
        if plainSafe { return value }

        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\x%02X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }

    private static func percentEncodedUserInfo(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func urlHost(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}

// MARK: - Local network address

enum LocalNetworkAddress {
    /// True for RFC 1918 private IPv4 addresses.
    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        default: return false
        }
    }

    /// Picks the address to advertise: en0 first, then other `en*`
    /// interfaces in name order, and only private IPv4 addresses.
    static func preferredLANAddress(from candidates: [(interface: String, address: String)]) -> String? {
        let eligible = candidates.filter {
            $0.interface.hasPrefix("en") && isPrivateIPv4($0.address)
        }
        if let en0 = eligible.first(where: { $0.interface == "en0" }) {
            return en0.address
        }
        return eligible
            .sorted { $0.interface.localizedStandardCompare($1.interface) == .orderedAscending }
            .first?.address
    }

    /// The Mac's current private IPv4 address on an Ethernet/Wi-Fi interface.
    static func currentLANIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(interface: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let socketAddress = entry.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            candidates.append((
                interface: String(cString: entry.pointee.ifa_name),
                address: String(cString: buffer)
            ))
        }
        return preferredLANAddress(from: candidates)
    }
}

// MARK: - Password generation

enum SOCKSProxyPasswordGenerator {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    /// Random alphanumeric password. `SystemRandomNumberGenerator` is backed
    /// by the system CSPRNG on macOS.
    static func generate(length: Int = 16) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
