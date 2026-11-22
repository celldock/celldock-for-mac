import Foundation
import Network
import OSLog

private let socksUDPLogger = Logger(
    subsystem: "app.celldock.mac",
    category: "SOCKSUDPRelay"
)

enum SOCKSUDPRelayError: Error {
    case invalidListenerPort
    case clientMismatch
    case tooManyDestinations
    case destinationUnavailable
}

/// One RFC 1928 UDP association. The client-facing UDP socket is intentionally
/// separate from every upstream socket: upstream descriptors are pinned to the
/// selected egress interface, while the client datagrams arrive over ECM/LAN.
final class SOCKSUDPRelay {
    var onFailure: ((Error) -> Void)?
    /// Payload bytes delivered to the client and to destinations. Called on
    /// the relay's queue.
    var onTraffic: ((_ downloaded: Int, _ uploaded: Int) -> Void)?
    /// The destination of the latest client datagram, with the address it was
    /// sent to when that is known. Called on the relay's queue.
    var onDestination: ((_ address: SOCKSAddress, _ port: UInt16, _ resolved: SOCKSAddress?) -> Void)?

    private struct Destination: Hashable {
        let address: SOCKSAddress
        let port: UInt16
    }

    /// Upstream sockets kept per association. Reaching the limit recycles the
    /// destination that has been silent the longest; it used to reject every
    /// new destination for the rest of the association, which broke clients
    /// that talk to many peers over one association (WebRTC, DNS, QUIC).
    static let maximumUpstreams = 64

    private final class Upstream {
        let destination: Destination
        let socket: BoundSocket
        let readSource: DispatchSourceRead
        var lastUsed = DispatchTime.now()

        init(destination: Destination, socket: BoundSocket, readSource: DispatchSourceRead) {
            self.destination = destination
            self.socket = socket
            self.readSource = readSource
        }

        func stop() {
            readSource.cancel()
        }
    }

    private let bsdName: String
    private let dnsServers: [String]
    private let expectedClientHost: NWEndpoint.Host?
    private let upstreamProxy: VoWiFiUpstreamProxySnapshot?
    /// When set, the client-facing UDP socket is bound to this address only.
    /// VoWiFi relays use it so the association is not reachable from the very
    /// network the relay egresses to.
    private let listenAddress: String?
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var client: NWConnection?
    private var upstreams: [Destination: Upstream] = [:]
    private var upstreamAssociation: SOCKS5UpstreamAssociation?
    private var didCompleteStart = false
    private var stopped = false

    init(
        bsdName: String,
        dnsServers: [String],
        expectedClientHost: NWEndpoint.Host?,
        upstreamProxy: VoWiFiUpstreamProxySnapshot? = nil,
        listenAddress: String? = nil,
        queue: DispatchQueue
    ) {
        self.bsdName = bsdName
        self.dnsServers = dnsServers
        self.expectedClientHost = expectedClientHost
        self.upstreamProxy = upstreamProxy
        self.listenAddress = listenAddress
        self.queue = queue
    }

    func start(completion: @escaping (Result<UInt16, Error>) -> Void) {
        if let upstreamProxy {
            let association = SOCKS5UpstreamAssociation(
                configuration: upstreamProxy,
                bsdName: bsdName,
                dnsServers: dnsServers,
                queue: queue
            )
            upstreamAssociation = association
            association.onDatagram = { [weak self] data in self?.forwardToClient(data) }
            association.onFailure = { [weak self] error in self?.fail(error) }
            association.start { [weak self] result in
                guard let self, !self.stopped else { return }
                switch result {
                case .success: self.startListener(completion: completion)
                case let .failure(error): completion(.failure(error)); self.stop()
                }
            }
            return
        }
        startListener(completion: completion)
    }

    private func startListener(completion: @escaping (Result<UInt16, Error>) -> Void) {
        do {
            let listener: NWListener
            if let listenAddress {
                let parameters = NWParameters.udp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(listenAddress),
                    port: .any
                )
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: .udp, on: .any)
            }
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard !self.didCompleteStart else { return }
                    self.didCompleteStart = true
                    guard let port = listener.port?.rawValue else {
                        completion(.failure(SOCKSUDPRelayError.invalidListenerPort))
                        self.stop()
                        return
                    }
                    completion(.success(port))
                case let .failed(error):
                    if !self.didCompleteStart {
                        self.didCompleteStart = true
                        completion(.failure(error))
                    } else {
                        self.fail(error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptClient(connection)
            }
            listener.start(queue: queue)
        } catch {
            didCompleteStart = true
            completion(.failure(error))
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onTraffic = nil
        onDestination = nil
        listener?.cancel()
        listener = nil
        client?.cancel()
        client = nil
        let active = Array(upstreams.values)
        upstreams.removeAll()
        active.forEach { $0.stop() }
        upstreamAssociation?.stop()
        upstreamAssociation = nil
    }

    private func acceptClient(_ connection: NWConnection) {
        guard !stopped, client == nil, matchesExpectedClient(connection.endpoint) else {
            connection.cancel()
            return
        }
        client = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case let .failed(error) = state { self.fail(error) }
        }
        connection.start(queue: queue)
        receiveClientDatagram()
    }

    private func matchesExpectedClient(_ endpoint: NWEndpoint) -> Bool {
        guard let expectedClientHost else { return true }
        guard case let .hostPort(host, _) = endpoint else { return false }
        return host == expectedClientHost
    }

    private func receiveClientDatagram() {
        guard let client, !stopped else { return }
        client.receiveMessage { [weak self] content, _, _, error in
            guard let self, !self.stopped else { return }
            if let error {
                self.fail(error)
                return
            }
            if let content, !content.isEmpty {
                do {
                    try self.forwardClientDatagram(content)
                } catch {
                    socksUDPLogger.info(
                        "Dropping SOCKS UDP datagram error=\(String(describing: error), privacy: .private(mask: .hash))"
                    )
                }
            }
            self.receiveClientDatagram()
        }
    }

    private func forwardClientDatagram(_ content: Data) throws {
        let datagram = try SOCKSProtocol.decodeUDPDatagram(content)
        if let upstreamAssociation {
            try upstreamAssociation.send(content)
            onDestination?(datagram.address, datagram.port, nil)
            onTraffic?(0, datagram.payload.count)
            return
        }
        let destinations = try resolvedDestinations(for: datagram.address, port: datagram.port)
        var lastError: Error = SOCKSUDPRelayError.destinationUnavailable
        for destination in destinations {
            do {
                let upstream = try upstream(for: destination)
                let written = try upstream.socket.write(datagram.payload)
                guard written == datagram.payload.count else {
                    throw BoundSocketError.systemCall(operation: "send UDP", code: EWOULDBLOCK)
                }
                onDestination?(datagram.address, datagram.port, destination.address)
                onTraffic?(0, written)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func forwardToClient(_ content: Data) {
        guard let client, !stopped else { return }
        // Count the payload only, as for direct destinations.
        let payloadCount = (try? SOCKSProtocol.decodeUDPDatagram(content).payload.count) ?? content.count
        onTraffic?(payloadCount, 0)
        client.send(
            content: content,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error { self?.queue.async { self?.fail(error) } }
            }
        )
    }

    private func resolvedDestinations(
        for address: SOCKSAddress,
        port: UInt16
    ) throws -> [Destination] {
        switch address {
        case .ipv4, .ipv6:
            return [Destination(address: address, port: port)]
        case let .domain(domain):
            let addresses = SOCKSDNSResolver().resolveAddresses(
                domain: domain,
                dnsServers: dnsServers,
                bsdName: bsdName
            )
            guard !addresses.isEmpty else { throw SOCKSUDPRelayError.destinationUnavailable }
            return addresses.map { Destination(address: $0, port: port) }
        }
    }

    private func upstream(for destination: Destination) throws -> Upstream {
        if let existing = upstreams[destination] {
            existing.lastUsed = DispatchTime.now()
            return existing
        }
        if upstreams.count >= Self.maximumUpstreams,
           let idlest = upstreams.values.min(by: { $0.lastUsed < $1.lastUsed }) {
            remove(idlest)
        }
        let family: BoundSocketFamily = switch destination.address {
        case .ipv4: .ipv4
        case .ipv6: .ipv6
        case .domain: throw SOCKSUDPRelayError.destinationUnavailable
        }
        let socket = try BoundSocket(family: family, kind: .udp, bsdName: bsdName)
        try socket.connect(to: destination.address, port: destination.port)
        try socket.setNonBlocking()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: socket.fileDescriptor,
            queue: queue
        )
        let upstream = Upstream(destination: destination, socket: socket, readSource: source)
        source.setEventHandler { [weak self, weak upstream] in
            guard let self, let upstream else { return }
            self.drain(upstream)
        }
        source.setCancelHandler { [socket] in socket.close() }
        upstreams[destination] = upstream
        source.activate()
        return upstream
    }

    private func drain(_ upstream: Upstream) {
        guard let client, !stopped else { return }
        do {
            while true {
                switch try upstream.socket.read(maximumBytes: 65_507) {
                case let .data(payload):
                    upstream.lastUsed = DispatchTime.now()
                    onTraffic?(payload.count, 0)
                    let wire = try SOCKSProtocol.encodeUDPDatagram(SOCKSUDPDatagram(
                        address: upstream.destination.address,
                        port: upstream.destination.port,
                        payload: payload
                    ))
                    client.send(
                        content: wire,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            if let error { self?.queue.async { self?.fail(error) } }
                        }
                    )
                case .wouldBlock:
                    return
                case .endOfStream:
                    remove(upstream)
                    return
                }
            }
        } catch {
            remove(upstream)
        }
    }

    private func remove(_ upstream: Upstream) {
        upstreams[upstream.destination] = nil
        upstream.stop()
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        onFailure?(error)
        stop()
    }
}
