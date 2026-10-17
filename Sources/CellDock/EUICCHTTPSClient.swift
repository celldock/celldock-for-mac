import Foundation
import Network
import Security

/// Minimal HTTP/1.1 POST client for ES9+ (LPA to SM-DP+) requests.
///
/// URLSession cannot be used here: App Transport Security insists on system trust
/// even when a delegate accepts the server, and SM-DP+ TLS certificates are commonly
/// issued by the GSMA root CI. Network.framework lets this one connection verify the
/// server with `EUICCServerTrust` while the rest of the app keeps ATS defaults.
enum EUICCHTTPSClient {
    struct Response: Equatable {
        let status: Int
        let body: Data
    }

    static let maximumResponseBodyLength = 8 * 1_024 * 1_024
    private static let maximumHeaderLength = 64 * 1_024

    static func post(
        url: URL,
        headers: [(name: String, value: String)],
        body: Data,
        timeout: TimeInterval
    ) -> Result<Response, EUICCHTTPFailure> {
        guard let request = makeRequest(url: url, headers: headers, body: body),
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            return .failure(EUICCHTTPFailure(kind: .invalidRequest))
        }

        let queue = DispatchQueue(label: "app.celldock.mac.euicc-https")
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(securityOptions, "http/1.1")
        sec_protocol_options_set_verify_block(securityOptions, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess else {
                complete(false)
                return
            }
            complete(EUICCServerTrust.evaluate(trust, host: host) != nil)
        }, queue)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 30
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: NWParameters(tls: tlsOptions, tcp: tcpOptions)
        )

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: Result<Response, EUICCHTTPFailure>?
        func finish(_ result: Result<Response, EUICCHTTPFailure>) {
            lock.lock()
            let isFirst = outcome == nil
            if isFirst { outcome = result }
            lock.unlock()
            guard isFirst else { return }
            connection.cancel()
            semaphore.signal()
        }

        var buffer = Data()
        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                data, _, isComplete, error in
                if let data { buffer.append(data) }
                guard buffer.count <= maximumHeaderLength + maximumResponseBodyLength else {
                    finish(.failure(EUICCHTTPFailure(kind: .responseTooLarge)))
                    return
                }
                switch parseResponse(buffer, isComplete: isComplete) {
                case let .complete(response):
                    finish(response.body.count <= maximumResponseBodyLength
                        ? .success(response)
                        : .failure(EUICCHTTPFailure(kind: .responseTooLarge)))
                case .invalid:
                    finish(.failure(EUICCHTTPFailure(kind: .invalidResponse)))
                case .incomplete:
                    if let error {
                        finish(.failure(failure(for: error)))
                    } else if isComplete {
                        finish(.failure(EUICCHTTPFailure(kind: .invalidResponse)))
                    } else {
                        receiveNext()
                    }
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error { finish(.failure(failure(for: error))) }
                })
                receiveNext()
            case let .waiting(error), let .failed(error):
                finish(.failure(failure(for: error)))
            default:
                break
            }
        }
        connection.start(queue: queue)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            finish(.failure(EUICCHTTPFailure(
                kind: .timedOut,
                domain: NSURLErrorDomain,
                code: URLError.Code.timedOut.rawValue
            )))
        }
        lock.lock()
        defer { lock.unlock() }
        return outcome ?? .failure(EUICCHTTPFailure(kind: .invalidResponse))
    }

    static func makeRequest(
        url: URL,
        headers: [(name: String, value: String)],
        body: Data
    ) -> Data? {
        guard url.scheme?.lowercased() == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.host, !host.isEmpty else {
            return nil
        }
        if host.contains(":") { host = "[\(host)]" }
        if let port = components.port, port != 443 { host += ":\(port)" }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?\(query)" }

        let reservedHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]
        var lines = [
            "POST \(target) HTTP/1.1",
            "Host: \(host)",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        for header in headers where !reservedHeaders.contains(header.name.lowercased()) {
            let line = "\(header.name): \(header.value)"
            guard !line.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
            lines.append(line)
        }
        var request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        request.append(body)
        return request
    }

    enum ParseResult: Equatable {
        case incomplete
        case invalid
        case complete(Response)
    }

    /// Parses one HTTP/1.1 response, skipping interim 1xx responses. `isComplete`
    /// means the server closed the connection, which ends a body without a length.
    static func parseResponse(_ data: Data, isComplete: Bool) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        var start = data.startIndex
        while true {
            guard let headerEnd = data.range(of: separator, in: start..<data.endIndex) else {
                return data.count - start > maximumHeaderLength ? .invalid : .incomplete
            }
            guard let head = String(data: data[start..<headerEnd.lowerBound], encoding: .utf8) else {
                return .invalid
            }
            let lines = head.components(separatedBy: "\r\n")
            let statusParts = lines[0].split(separator: " ", maxSplits: 2)
            guard statusParts.count >= 2,
                  statusParts[0].hasPrefix("HTTP/1."),
                  let status = Int(statusParts[1]),
                  (100...599).contains(status) else {
                return .invalid
            }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { return .invalid }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let bodyStart = headerEnd.upperBound
            if (100...199).contains(status) {
                start = bodyStart
                continue
            }
            let body = data[bodyStart...]
            if status == 204 || status == 304 {
                return .complete(Response(status: status, body: Data()))
            }
            if fields["transfer-encoding"]?.lowercased().contains("chunked") == true {
                return parseChunked(body, status: status)
            }
            if let lengthField = fields["content-length"] {
                guard let length = Int(lengthField), length >= 0 else { return .invalid }
                guard length <= maximumResponseBodyLength else { return .invalid }
                guard body.count >= length else { return isComplete ? .invalid : .incomplete }
                return .complete(Response(status: status, body: Data(body.prefix(length))))
            }
            return isComplete ? .complete(Response(status: status, body: Data(body))) : .incomplete
        }
    }

    private static func parseChunked(_ data: Data.SubSequence, status: Int) -> ParseResult {
        let lineEnd = Data("\r\n".utf8)
        var body = Data()
        var index = data.startIndex
        while true {
            guard let sizeEnd = data.range(of: lineEnd, in: index..<data.endIndex) else {
                return .incomplete
            }
            guard let sizeLine = String(data: data[index..<sizeEnd.lowerBound], encoding: .utf8),
                  let size = Int(
                      sizeLine.split(separator: ";", maxSplits: 1).first?
                          .trimmingCharacters(in: .whitespaces) ?? "",
                      radix: 16
                  ),
                  size >= 0,
                  body.count + size <= maximumResponseBodyLength else {
                return .invalid
            }
            let chunkStart = sizeEnd.upperBound
            if size == 0 {
                // Trailers, if any, end with an empty line.
                guard data.range(of: Data("\r\n".utf8), in: chunkStart..<data.endIndex) != nil else {
                    return .incomplete
                }
                return .complete(Response(status: status, body: body))
            }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else {
                return .incomplete
            }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            guard data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)].elementsEqual(lineEnd) else {
                return .invalid
            }
            body.append(data[chunkStart..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }

    static func failure(for error: NWError) -> EUICCHTTPFailure {
        switch error {
        case let .tls(status):
            return EUICCHTTPFailure(kind: .tlsTrust, domain: "NWError.tls", code: Int(status))
        case let .posix(code) where code == .ETIMEDOUT:
            return EUICCHTTPFailure(
                kind: .timedOut,
                domain: NSURLErrorDomain,
                code: URLError.Code.timedOut.rawValue
            )
        case let .posix(code):
            return EUICCHTTPFailure(kind: .transport, domain: "NWError.posix", code: Int(code.rawValue))
        case let .dns(code):
            return EUICCHTTPFailure(kind: .transport, domain: "NWError.dns", code: Int(code))
        default:
            return EUICCHTTPFailure(kind: .transport, domain: "NWError")
        }
    }
}
