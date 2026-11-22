import Foundation
import Network

final class LocalCallAPIServer {
    typealias Handler = (LocalCallAPICommand, @escaping (LocalCallAPIResponse) -> Void) -> Void
    private let queue = DispatchQueue(label: "app.celldock.local-call-api")
    private let token: String
    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private var sessions: [UUID: LocalCallAPISession] = [:]

    init(token: String, port: UInt16 = 7576, handler: @escaping Handler) {
        self.token = token
        self.port = port
        self.handler = handler
    }

    func start(onState: @escaping (String?) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: DispatchQueue.main.async { onState(nil) }
            case .failed(let error): DispatchQueue.main.async { onState(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.listener != nil, self.sessions.count < 16 else {
                connection.cancel()
                return
            }
            let id = UUID()
            let session = LocalCallAPISession(connection: connection, queue: self.queue,
                                             token: self.token, port: self.port, handler: self.handler)
            self.sessions[id] = session
            session.onClose = { [weak self] in self?.sessions[id] = nil }
            session.start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            let sessions = Array(self.sessions.values)
            self.sessions.removeAll()
            sessions.forEach { $0.close() }
        }
    }
}

private final class LocalCallAPISession {
    var onClose: (() -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let token: String
    private let port: UInt16
    private let handler: LocalCallAPIServer.Handler
    private var data = Data()
    private var closed = false
    private var responding = false
    private var timeout: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, token: String, port: UInt16,
         handler: @escaping LocalCallAPIServer.Handler) {
        self.connection = connection
        self.queue = queue
        self.token = token
        self.port = port
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
            if case .cancelled = state { self?.close() }
        }
        connection.start(queue: queue)
        armTimeout(seconds: 5)
        receive()
    }

    private func armTimeout(seconds: Double) {
        timeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.respond(.error(408, "Timed out; query status before retrying a call action"))
        }
        timeout = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, done, error in
            guard let self, !self.closed else { return }
            if let chunk { self.data.append(chunk) }
            do {
                if let command = try LocalCallAPIProtocol.decode(self.data, token: self.token, port: self.port) {
                    self.armTimeout(seconds: 90)
                    DispatchQueue.main.async {
                        guard !self.queue.sync(execute: { self.closed || self.responding }) else { return }
                        self.handler(command) { response in
                            self.queue.async { self.respond(response) }
                        }
                    }
                } else if done || error != nil {
                    self.respond(.error(400, "Incomplete request"))
                } else {
                    self.receive()
                }
            } catch let error as LocalCallAPIHTTPError {
                self.respond(.error(error.status, error.message))
            } catch {
                self.respond(.error(400, "Invalid request"))
            }
        }
    }

    private func respond(_ response: LocalCallAPIResponse) {
        guard !closed, !responding else { return }
        responding = true
        timeout?.cancel()
        // Bound clients that stop reading a response as well as slow uploads.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close() }
        connection.send(content: response.wireData, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        connection.cancel()
        onClose?()
        onClose = nil
    }
}
