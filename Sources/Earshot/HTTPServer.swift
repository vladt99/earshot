import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    /// Lower-cased header names.
    var headers: [String: String]
    var body: Data

    var jsonObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    var isMultipart: Bool { headers["content-type"]?.lowercased().hasPrefix("multipart/form-data") ?? false }

    /// Parses multipart/form-data into text fields and file parts.
    func multipart() throws -> (fields: [String: String], files: [String: (filename: String, data: Data)]) {
        guard let ct = headers["content-type"],
              let b = ct.components(separatedBy: "boundary=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        else { throw APIError(400, "Missing multipart boundary") }
        let delimiter = Data("--\(b)".utf8)
        let crlf2 = Data("\r\n\r\n".utf8)
        var fields: [String: String] = [:]
        var files: [String: (String, Data)] = [:]

        var cursor = body.startIndex
        guard let first = body.range(of: delimiter, in: cursor..<body.endIndex) else { throw APIError(400, "Malformed multipart body") }
        cursor = first.upperBound
        while let next = body.range(of: delimiter, in: cursor..<body.endIndex) {
            var part = body[cursor..<next.lowerBound]
            // Each part is "\r\n<headers>\r\n\r\n<data>\r\n"
            if part.starts(with: Data("\r\n".utf8)) { part = part.dropFirst(2) }
            if part.suffix(2) == Data("\r\n".utf8) { part = part.dropLast(2) }
            if let split = part.range(of: crlf2) {
                let head = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
                let data = Data(part[split.upperBound...])
                let disposition = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-disposition") } ?? ""
                if let name = Self.param("name", in: disposition) {
                    if let filename = Self.param("filename", in: disposition) {
                        files[name] = (filename, data)
                    } else {
                        fields[name] = String(decoding: data, as: UTF8.self)
                    }
                }
            }
            cursor = next.upperBound
            if body[cursor...].starts(with: Data("--".utf8)) { break }
        }
        return (fields, files)
    }

    private static func param(_ key: String, in header: String) -> String? {
        for piece in header.components(separatedBy: ";") {
            let kv = piece.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("\(key)=") {
                return String(kv.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    /// When set, the response is streamed (Server-Sent Events) until the stream ends or the client leaves.
    var stream: AsyncStream<Data>?

    static func events(_ stream: AsyncStream<Data>) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/event-stream", body: Data(), stream: stream)
    }

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data + Data("\n".utf8))
    }

    static func text(_ s: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, contentType: contentType, body: Data(s.utf8))
    }

    /// OpenAI-style error envelope.
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": ["message": message, "code": status]], status: status)
    }

    func serialized() -> Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        if stream == nil {
            head += "Content-Length: \(body.count)\r\n"
        } else {
            head += "Cache-Control: no-cache\r\n"
        }
        head += "Connection: close\r\n"
        head += "Server: Earshot/\(appVersion)\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Minimal HTTP/1.1 server on the loopback interface. One request per connection.
final class HTTPServer: @unchecked Sendable {
    static let maxBody = 1 << 30 // 1 GiB; prefer {"path": …} for big local files

    let port: UInt16
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "earshot.http")

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start(onState: @escaping @Sendable (String?) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [handler, queue] conn in
            HTTPConnection(conn, queue: queue, handler: handler).start()
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(nil)
            case .failed(let e): onState("API server failed: \(e)")
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() { listener?.cancel() }
}

private final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()
    private var head: (request: HTTPRequest, bodyStart: Int, length: Int)?
    private var sentContinue = false

    init(_ conn: NWConnection, queue: DispatchQueue, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.conn = conn
        self.queue = queue
        self.handler = handler
    }

    func start() {
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            if error != nil { conn.cancel(); return }
            process(eof: done)
        }
    }

    private func process(eof: Bool) {
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if eof || buffer.count > 64 * 1024 { finish(.error(400, "Bad request")) } else { receive() }
                return
            }
            guard let parsed = parseHead(String(decoding: buffer[..<end.lowerBound], as: UTF8.self)) else {
                finish(.error(400, "Bad request")); return
            }
            if parsed.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                finish(.error(411, "Chunked uploads are not supported; send Content-Length")); return
            }
            let length = Int(parsed.headers["content-length"] ?? "0") ?? 0
            if length > HTTPServer.maxBody { finish(.error(413, "Body too large")); return }
            head = (parsed, end.upperBound, length)
        }
        guard let head else { return }
        if buffer.count - head.bodyStart >= head.length {
            var req = head.request
            req.body = buffer.subdata(in: head.bodyStart..<(head.bodyStart + head.length))
            buffer = Data()
            Task { [self] in finish(await handler(req)) }
        } else if eof {
            conn.cancel()
        } else {
            // curl waits for this before sending large multipart uploads.
            if !sentContinue, head.request.headers["expect"]?.lowercased() == "100-continue" {
                sentContinue = true
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            receive()
        }
    }

    private func parseHead(_ text: String) -> HTTPRequest? {
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return HTTPRequest(method: String(parts[0]).uppercased(), path: comps?.path ?? "/", query: query, headers: headers, body: Data())
    }

    private func finish(_ response: HTTPResponse) {
        guard let stream = response.stream else {
            conn.send(content: response.serialized(), completion: .contentProcessed { [conn] _ in conn.cancel() })
            return
        }
        conn.send(content: response.serialized(), completion: .contentProcessed { _ in })
        let pump = Task { [conn] in
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    conn.send(content: Data(": ping\n\n".utf8), completion: .contentProcessed { _ in })
                }
            }
            for await chunk in stream {
                conn.send(content: chunk, completion: .contentProcessed { _ in })
            }
            heartbeat.cancel()
            conn.cancel()
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: pump.cancel()
            default: break
            }
        }
        // Detect the client hanging up (a read returning EOF).
        watchForClose(pump)
    }

    private func watchForClose(_ pump: Task<Void, Never>) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] _, _, done, error in
            if done || error != nil { pump.cancel(); conn.cancel() } else { watchForClose(pump) }
        }
    }
}
