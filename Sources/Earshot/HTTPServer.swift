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
                let data = part[split.upperBound...] // a slice: no copy of big (file-mapped) uploads
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
    static let maxBody = 1 << 30 // 1 GiB, upload routes only; prefer {"path": …} for big local files
    static let smallBody = 1 << 20
    static let maxConnections = 32
    static let maxStreams = 16

    /// Decided as soon as the headers arrive, before any of the body is read.
    enum Admission: Sendable {
        case reject(HTTPResponse)
        case accept(maxBody: Int, stream: Bool)
    }

    let port: UInt16
    fileprivate let admit: @Sendable (HTTPRequest) -> Admission
    fileprivate let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    fileprivate let queue = DispatchQueue(label: "earshot.http")
    // Confined to `queue`.
    fileprivate var connections = 0
    fileprivate var streams = 0

    init(port: UInt16, admit: @escaping @Sendable (HTTPRequest) -> Admission,
         handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.admit = admit
        self.handler = handler
    }

    /// `onState(nil)` once the port is bound, `onState(message)` when it fails.
    func start(onState: @escaping @Sendable (String?) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [self] conn in
            guard connections < Self.maxConnections else { HTTPConnection.refuse(conn, queue: queue); return }
            connections += 1
            HTTPConnection(conn, server: self).start()
        }
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: onState(nil)
            case .failed(let e):
                onState("API server failed: \(e)")
                listener?.cancel()
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
    private let server: HTTPServer
    private var queue: DispatchQueue { server.queue }
    // Everything below is confined to `queue`.
    private var buffer = Data()
    private var head: HTTPRequest?
    private var length = 0
    private var received = 0
    private var bodyFile: URL?
    private var bodyHandle: FileHandle?
    private var sentContinue = false
    private var isStream = false
    private var isClosed = false
    private var responded = false
    private var timer: DispatchSourceTimer?
    /// Header read: 10 s; body: 30 s without progress; response write: 60 s.
    private var deadline = DispatchTime.now() + .seconds(10)
    private var pump: Task<Void, Never>?

    init(_ conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    static func refuse(_ conn: NWConnection, queue: DispatchQueue) {
        conn.start(queue: queue)
        conn.send(content: HTTPResponse.error(503, "Too many connections").serialized(), completion: .contentProcessed { _ in conn.cancel() })
        queue.asyncAfter(deadline: .now() + 5) { conn.cancel() }
    }

    func start() {
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: closed()
            default: break
            }
        }
        conn.start(queue: queue)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [self] in if DispatchTime.now() > deadline { conn.cancel() } }
        t.resume()
        timer = t
        receive()
    }

    private func closed() {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        pump?.cancel()
        dropBodyFile()
        if isStream { server.streams -= 1 } else { server.connections -= 1 }
        conn.stateUpdateHandler = nil
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, eof, error in
            guard !isClosed, !responded else { return }
            if error != nil { conn.cancel(); return }
            process(data, eof: eof)
        }
    }

    private func process(_ data: Data?, eof: Bool) {
        if head == nil {
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if eof || buffer.count > 64 * 1024 { respond(.error(400, "Bad request")) } else { receive() }
                return
            }
            let rest = Data(buffer[end.upperBound...])
            let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            buffer = Data()
            guard let parsed = parseHead(text) else { respond(.error(400, "Bad request")); return }
            let (req, lengths) = parsed
            // Auth, Host and Origin are checked before anything else is read or a 100 Continue goes out.
            let limit: Int
            switch server.admit(req) {
            case .reject(let r): respond(r); return
            case .accept(let max, let stream):
                limit = max
                if stream {
                    guard server.streams < HTTPServer.maxStreams else { respond(.error(503, "Too many event streams")); return }
                    server.connections -= 1
                    server.streams += 1
                    isStream = true
                }
            }
            if let te = req.headers["transfer-encoding"], te.lowercased() != "identity" {
                respond(.error(411, "Chunked uploads are not supported; send Content-Length")); return
            }
            guard let n = Self.contentLength(lengths) else { respond(.error(400, "Invalid Content-Length")); return }
            guard n <= limit else { respond(.error(413, "Body too large")); return }
            head = req
            length = n
            deadline = .now() + 30
            if n > HTTPServer.smallBody {
                // Big uploads go to disk, not RAM.
                let file = Paths.uploads.appendingPathComponent("body-" + UUID().uuidString)
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                      let h = try? FileHandle(forWritingTo: file) else { respond(.error(507, "Could not buffer the upload")); return }
                bodyFile = file
                bodyHandle = h
            } else {
                buffer.reserveCapacity(n)
            }
            if !rest.isEmpty, !append(rest) { return }
        } else if let data, !data.isEmpty {
            guard append(data) else { return }
            deadline = .now() + 30
        }
        if received >= length { complete(); return }
        if eof { conn.cancel(); return }
        // curl waits for this before sending large multipart uploads.
        if !sentContinue, head?.headers["expect"]?.lowercased() == "100-continue" {
            sentContinue = true
            conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }
        receive()
    }

    private func append(_ data: Data) -> Bool {
        let chunk = data.prefix(length - received)
        received += chunk.count
        guard let h = bodyHandle else { buffer.append(chunk); return true }
        do { try h.write(contentsOf: chunk) } catch {
            respond(.error(507, "Could not buffer the upload"))
            return false
        }
        return true
    }

    private func complete() {
        guard var req = head else { return }
        deadline = .distantFuture // transcribing can take minutes
        if let file = bodyFile {
            try? bodyHandle?.close()
            bodyHandle = nil
            // Mapped, so a 1 GiB upload isn't read into memory; the mapping outlives the unlink.
            req.body = (try? Data(contentsOf: file, options: .alwaysMapped)) ?? Data()
            dropBodyFile()
        } else {
            req.body = buffer
        }
        buffer = Data()
        let handler = server.handler
        Task { [self] in
            let response = await handler(req)
            queue.async { [self] in respond(response) }
        }
    }

    private func dropBodyFile() {
        try? bodyHandle?.close()
        bodyHandle = nil
        if let f = bodyFile { try? FileManager.default.removeItem(at: f) }
        bodyFile = nil
    }

    /// One Content-Length, digits only; nil means 400.
    private static func contentLength(_ values: [String]) -> Int? {
        guard values.count <= 1 else { return nil }
        guard let v = values.first else { return 0 }
        guard !v.isEmpty, v.utf8.count <= 18, v.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(v)
    }

    private func parseHead(_ text: String) -> (HTTPRequest, [String])? {
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        var lengths: [String] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { lengths.append(value) }
            headers[name] = value
        }
        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let req = HTTPRequest(method: String(parts[0]).uppercased(), path: comps?.path ?? "/", query: query, headers: headers, body: Data())
        return (req, lengths)
    }

    private func respond(_ response: HTTPResponse) {
        guard !isClosed, !responded else { return }
        responded = true
        guard let stream = response.stream else {
            deadline = .now() + 60
            conn.send(content: response.serialized(), completion: .contentProcessed { [conn] _ in conn.cancel() })
            return
        }
        deadline = .distantFuture
        conn.send(content: response.serialized(), completion: .contentProcessed { _ in })
        let gate = SendGate()
        pump = Task { [conn] in
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    // A client that hasn't read anything for a minute is gone.
                    if gate.stalled(longerThan: 60) { conn.cancel(); return }
                    if !gate.busy { await Self.send(Data(": ping\n\n".utf8), on: conn, gate) }
                }
            }
            // Each send is awaited, so a slow reader backs up into the stream's bounded buffer
            // (oldest events dropped) instead of growing the connection's queue.
            for await chunk in stream {
                await Self.send(chunk, on: conn, gate)
                if Task.isCancelled { break }
            }
            heartbeat.cancel()
            conn.cancel()
        }
        // Detect the client hanging up (a read returning EOF).
        watchForClose()
    }

    private static func send(_ data: Data, on conn: NWConnection, _ gate: SendGate) async {
        gate.begin()
        defer { gate.end() }
        let once = Once()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                once.set(c)
                conn.send(content: data, completion: .contentProcessed { _ in once.resume() })
            }
        } onCancel: { once.resume() }
    }

    private func watchForClose() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] _, _, done, error in
            if done || error != nil { pump?.cancel(); conn.cancel() } else if !isClosed { watchForClose() }
        }
    }
}

/// Pending SSE writes, to spot a client that stopped reading.
private final class SendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var since: Date?

    var busy: Bool { lock.withLock { pending > 0 } }

    func begin() { lock.withLock { if pending == 0 { since = Date() }; pending += 1 } }
    func end() { lock.withLock { pending -= 1; if pending == 0 { since = nil } } }
    func stalled(longerThan seconds: TimeInterval) -> Bool {
        lock.withLock { since.map { Date().timeIntervalSince($0) > seconds } ?? false }
    }
}

/// Resumes a continuation exactly once (send completion or task cancellation, whichever comes first).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func set(_ c: CheckedContinuation<Void, Never>) {
        let resumeNow = lock.withLock { () -> Bool in
            if done { return true }
            continuation = c
            return false
        }
        if resumeNow { c.resume() }
    }

    func resume() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            done = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}
