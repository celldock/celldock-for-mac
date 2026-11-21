import Darwin
import Foundation

/// A single RFC 1928 UDP ASSOCIATE session to a user-configured SOCKS5 server.
/// Both its TCP control channel and UDP socket are created through BoundSocket,
/// so neither can silently escape the active Wi-Fi interface.
final class SOCKS5UpstreamAssociation {
    var onDatagram: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let configuration: VoWiFiUpstreamProxySnapshot
    private let bsdName: String
    private let dnsServers: [String]
    private let queue: DispatchQueue
    private var control: BoundSocket?
    private var datagramSocket: BoundSocket?
    private var controlSource: DispatchSourceRead?
    private var datagramSource: DispatchSourceRead?
    private var stopped = false

    init(
        configuration: VoWiFiUpstreamProxySnapshot,
        bsdName: String,
        dnsServers: [String],
        queue: DispatchQueue
    ) {
        self.configuration = configuration
        self.bsdName = bsdName
        self.dnsServers = dnsServers
        self.queue = queue
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                try self.connect()
                completion(.success(()))
            } catch {
                self.stop()
                completion(.failure(error))
            }
        }
    }

    func send(_ datagram: Data) throws {
        guard !stopped, let datagramSocket else {
            throw VoWiFiUpstreamProxyError.unavailable
        }
        let written = try datagramSocket.write(datagram)
        guard written == datagram.count else {
            throw BoundSocketError.systemCall(operation: "send SOCKS UDP", code: EWOULDBLOCK)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        controlSource?.cancel()
        controlSource = nil
        datagramSource?.cancel()
        datagramSource = nil
        control?.close()
        control = nil
        datagramSocket?.close()
        datagramSocket = nil
    }

    private func connect() throws {
        let proxyAddresses = resolvedAddresses(configuration.host)
        guard !proxyAddresses.isEmpty else { throw VoWiFiUpstreamProxyError.invalidAddress }
        var lastError: Error = VoWiFiUpstreamProxyError.unavailable
        for proxyAddress in proxyAddresses {
            do {
                try connect(to: proxyAddress)
                return
            } catch {
                lastError = error
                control?.close()
                control = nil
                datagramSocket?.close()
                datagramSocket = nil
            }
        }
        throw lastError
    }

    private func connect(to proxyAddress: SOCKSAddress) throws {
        let family = try socketFamily(for: proxyAddress)
        let control = try BoundSocket(family: family, kind: .tcp, bsdName: bsdName)
        self.control = control
        try control.setTimeout(seconds: 8)
        try control.connect(to: proxyAddress, port: configuration.port, timeoutSeconds: 8)

        var methods: [UInt8] = [SOCKSAuthenticationMethod.none.rawValue]
        if configuration.username != nil { methods.append(SOCKSAuthenticationMethod.usernamePassword.rawValue) }
        try control.sendAll(Data([0x05, UInt8(methods.count)] + methods))
        let selection = try control.receiveExactly(2)
        guard selection[selection.startIndex] == 0x05 else {
            throw VoWiFiUpstreamProxyError.invalidResponse
        }
        switch selection[selection.startIndex + 1] {
        case SOCKSAuthenticationMethod.none.rawValue:
            break
        case SOCKSAuthenticationMethod.usernamePassword.rawValue:
            try authenticate(control)
        case SOCKSAuthenticationMethod.noAcceptableMethods.rawValue:
            throw VoWiFiUpstreamProxyError.noAcceptableAuthentication
        default:
            throw VoWiFiUpstreamProxyError.noAcceptableAuthentication
        }

        let unspecified: SOCKSAddress = family == .ipv4
            ? .ipv4([0, 0, 0, 0])
            : .ipv6(Array(repeating: 0, count: 16))
        let request = try encodeUDPAssociate(address: unspecified)
        try control.sendAll(request)
        let reply = try receiveReply(control)
        guard reply.code == SOCKSReply.succeeded.rawValue else {
            throw VoWiFiUpstreamProxyError.udpAssociateRejected(reply.code)
        }

        var relayAddress = reply.address
        if isUnspecified(relayAddress) { relayAddress = proxyAddress }
        if case let .domain(domain) = relayAddress {
            guard let resolved = resolvedAddresses(domain).first else {
                throw VoWiFiUpstreamProxyError.invalidAddress
            }
            relayAddress = resolved
        }
        let relayFamily = try socketFamily(for: relayAddress)
        let udp = try BoundSocket(family: relayFamily, kind: .udp, bsdName: bsdName)
        try udp.setTimeout(seconds: 8)
        try udp.connect(to: relayAddress, port: reply.port)
        try udp.clearTimeouts()
        try udp.setNonBlocking()
        try control.clearTimeouts()
        try control.setNonBlocking()
        datagramSocket = udp
        installSources(control: control, udp: udp)
    }

    private func authenticate(_ socket: BoundSocket) throws {
        guard let username = configuration.username,
              let password = configuration.password else {
            throw VoWiFiUpstreamProxyError.missingCredentials
        }
        let user = Array(username.utf8)
        let pass = Array(password.utf8)
        guard !user.isEmpty, user.count <= 255, !pass.isEmpty, pass.count <= 255 else {
            throw VoWiFiUpstreamProxyError.missingCredentials
        }
        try socket.sendAll(Data([0x01, UInt8(user.count)] + user + [UInt8(pass.count)] + pass))
        let reply = try socket.receiveExactly(2)
        guard reply[reply.startIndex] == 0x01, reply[reply.startIndex + 1] == 0 else {
            throw VoWiFiUpstreamProxyError.authenticationRejected
        }
    }

    private func installSources(control: BoundSocket, udp: BoundSocket) {
        let controlSource = DispatchSource.makeReadSource(fileDescriptor: control.fileDescriptor, queue: queue)
        controlSource.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                switch try control.read(maximumBytes: 1) {
                case .wouldBlock: return
                case .data, .endOfStream: self.fail(VoWiFiUpstreamProxyError.unavailable)
                }
            } catch { self.fail(error) }
        }
        self.controlSource = controlSource

        let datagramSource = DispatchSource.makeReadSource(fileDescriptor: udp.fileDescriptor, queue: queue)
        datagramSource.setEventHandler { [weak self] in self?.drainDatagrams() }
        self.datagramSource = datagramSource
        controlSource.activate()
        datagramSource.activate()
    }

    private func drainDatagrams() {
        guard let datagramSocket, !stopped else { return }
        do {
            while true {
                switch try datagramSocket.read(maximumBytes: 65_507) {
                case let .data(data):
                    _ = try SOCKSProtocol.decodeUDPDatagram(data)
                    onDatagram?(data)
                case .wouldBlock:
                    return
                case .endOfStream:
                    fail(VoWiFiUpstreamProxyError.unavailable)
                    return
                }
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        onFailure?(error)
        stop()
    }

    private func resolvedAddresses(_ host: String) -> [SOCKSAddress] {
        if let address = numericAddress(host) { return [address] }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "localhost." {
            return [.ipv4([127, 0, 0, 1])]
        }
        return SOCKSDNSResolver().resolveAddresses(
            domain: host,
            dnsServers: dnsServers,
            bsdName: bsdName
        )
    }

    private func numericAddress(_ host: String) -> SOCKSAddress? {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: &ipv4) { .ipv4(Array($0)) }
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: &ipv6) { .ipv6(Array($0)) }
        }
        return nil
    }

    private func socketFamily(for address: SOCKSAddress) throws -> BoundSocketFamily {
        switch address {
        case .ipv4: return .ipv4
        case .ipv6: return .ipv6
        case .domain: throw VoWiFiUpstreamProxyError.invalidAddress
        }
    }

    private func encodeUDPAssociate(address: SOCKSAddress) throws -> Data {
        var result = Data([0x05, SOCKSCommand.udpAssociate.rawValue, 0x00])
        let encoded = try SOCKSProtocol.encodeReply(.succeeded, boundAddress: address, boundPort: 0)
        result.append(encoded.dropFirst(3))
        return result
    }

    private func receiveReply(_ socket: BoundSocket) throws -> (code: UInt8, address: SOCKSAddress, port: UInt16) {
        let header = try socket.receiveExactly(4)
        guard header[header.startIndex] == 0x05, header[header.startIndex + 2] == 0 else {
            throw VoWiFiUpstreamProxyError.invalidResponse
        }
        let address: SOCKSAddress
        switch header[header.startIndex + 3] {
        case 0x01:
            address = .ipv4(Array(try socket.receiveExactly(4)))
        case 0x04:
            address = .ipv6(Array(try socket.receiveExactly(16)))
        case 0x03:
            let lengthData = try socket.receiveExactly(1)
            let length = Int(lengthData[lengthData.startIndex])
            guard length > 0,
                  let domain = String(data: try socket.receiveExactly(length), encoding: .utf8) else {
                throw VoWiFiUpstreamProxyError.invalidResponse
            }
            address = .domain(domain)
        default:
            throw VoWiFiUpstreamProxyError.invalidResponse
        }
        let portData = try socket.receiveExactly(2)
        let port = UInt16(portData[portData.startIndex]) << 8 | UInt16(portData[portData.startIndex + 1])
        let code = header[header.startIndex + 1]
        // RFC 1928 failure replies commonly carry 0.0.0.0:0. Preserve their
        // reply code so the UI can report the real reason instead of folding
        // a valid rejection into "invalid response".
        guard code != SOCKSReply.succeeded.rawValue || port > 0 else {
            throw VoWiFiUpstreamProxyError.invalidResponse
        }
        return (code, address, port)
    }

    private func isUnspecified(_ address: SOCKSAddress) -> Bool {
        switch address {
        case let .ipv4(bytes): return bytes.allSatisfy { $0 == 0 }
        case let .ipv6(bytes): return bytes.allSatisfy { $0 == 0 }
        case .domain: return false
        }
    }
}
