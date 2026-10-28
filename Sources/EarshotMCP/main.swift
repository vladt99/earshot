import Foundation

// Earshot MCP server (stdio, JSON-RPC 2.0, one message per line).
// A thin client of the local REST API: it reads the base URL and token from
// ~/Library/Application Support/Earshot/api.json, so Earshot must be running.
//
//   claude mcp add earshot -- /Applications/Earshot.app/Contents/MacOS/earshot-mcp

let protocolVersion = "2025-06-18"

struct Tool {
    let name: String
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]
    let call: ([String: Any]) async throws -> String
}

enum Failure: Error { case message(String) }

// MARK: - REST client

func apiInfo() throws -> (URL, String) {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Earshot/api.json")
    guard let data = try? Data(contentsOf: url),
          let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let base = (info["base_url"] as? String).flatMap(URL.init(string:)), let token = info["token"] as? String else {
        throw Failure.message("Earshot is not running (no \(url.path)). Open Earshot and try again.")
    }
    return (base, token)
}

func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Any {
    let (base, token) = try apiInfo()
    var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var req = URLRequest(url: parts.url!, timeoutInterval: 600)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let data: Data, response: URLResponse
    do { (data, response) = try await URLSession.shared.data(for: req) } catch {
        throw Failure.message("Could not reach Earshot at \(base): \(error.localizedDescription)")
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) ?? String(decoding: data, as: UTF8.self)
    if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
        let message = ((json as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
        throw Failure.message(message ?? "HTTP \(code)")
    }
    return json
}

func pretty(_ value: Any) -> String {
    if let s = value as? String { return s }
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
}

func string(_ args: [String: Any], _ key: String) -> String? {
    (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
}

// MARK: - Tools

let tools: [Tool] = [
    Tool(name: "search_transcripts",
         description: "Full-text search across all meetings and transcripts (titles, spoken text, notes). Returns ranked hits with a snippet and the matching lines with speaker and timestamp.",
         properties: ["query": ["type": "string", "description": "Words to find; prefixes match (\"budg\" finds \"budget\")"],
                      "limit": ["type": "integer", "description": "Max hits (default 10)"],
                      "meetings_only": ["type": "boolean", "description": "Only meetings"]],
         required: ["query"]) { a in
        var q = ["q": string(a, "query") ?? "", "limit": "\((a["limit"] as? Int) ?? 10)"]
        if a["meetings_only"] as? Bool == true { q["origin"] = "meeting" }
        return pretty(try await request("GET", "v1/search", query: q))
    },
    Tool(name: "list_meetings",
         description: "Most recent recorded meetings: id, title, date, duration, preview.",
         properties: ["limit": ["type": "integer", "description": "How many (default 20)"]],
         required: []) { a in
        pretty(try await request("GET", "v1/meetings", query: ["limit": "\((a["limit"] as? Int) ?? 20)"]))
    },
    Tool(name: "get_transcript",
         description: "One transcript by id. format \"text\" gives speaker-labelled plain text; \"json\" gives segments with timestamps, speakers and notes.",
         properties: ["id": ["type": "string"], "format": ["type": "string", "enum": ["text", "json"]]],
         required: ["id"]) { a in
        let format = string(a, "format") == "json" ? "verbose_json" : "text"
        return pretty(try await request("GET", "v1/transcripts/\(string(a, "id") ?? "")", query: ["format": format]))
    },
    Tool(name: "current_meeting",
         description: "The meeting being recorded right now: live transcript so far, notes, warnings. Says so when nothing is recording.",
         properties: [:], required: []) { _ in
        pretty(try await request("GET", "v1/meetings/current"))
    },
    Tool(name: "start_meeting",
         description: "Start recording and live-transcribing a meeting. app: bundle id of the meeting app (e.g. com.google.Chrome for Google Meet, us.zoom.xos) or \"system\" for all audio; omitted = the detected meeting.",
         properties: ["app": ["type": "string"], "title": ["type": "string"]],
         required: []) { a in
        var body: [String: Any] = [:]
        body["app"] = string(a, "app")
        body["title"] = string(a, "title")
        return pretty(try await request("POST", "v1/meetings/start", body: body))
    },
    Tool(name: "stop_meeting",
         description: "Stop the running meeting and save it. The polished transcript follows about a minute later.",
         properties: [:], required: []) { _ in
        let r = try await request("POST", "v1/meetings/stop")
        guard let d = r as? [String: Any] else { return pretty(r) }
        return pretty(["id": d["id"] ?? "", "title": d["title"] ?? "", "polishing": d["polishing"] ?? false, "text": d["text"] ?? ""])
    },
    Tool(name: "add_meeting_note",
         description: "Add a note to the running meeting at the current moment, or a bookmark when text is omitted.",
         properties: ["text": ["type": "string"]], required: []) { a in
        let text = string(a, "text")
        return pretty(try await request("POST", text == nil ? "v1/meetings/current/bookmark" : "v1/meetings/current/notes",
                                        body: text.map { ["text": $0] } ?? [:]))
    },
    Tool(name: "transcribe_file",
         description: "Transcribe a local audio or video file on this Mac (waits for the result).",
         properties: ["path": ["type": "string", "description": "Absolute path"], "speakers": ["type": "boolean", "description": "Label speakers"]],
         required: ["path"]) { a in
        let r = try await request("POST", "v1/audio/transcriptions",
                                  body: ["path": string(a, "path") ?? "", "diarize": a["speakers"] as? Bool ?? false, "response_format": "verbose_json"])
        guard let d = r as? [String: Any] else { return pretty(r) }
        return pretty(["id": d["id"] ?? "", "text": d["text"] ?? "", "duration": d["duration"] ?? 0])
    },
]

// MARK: - JSON-RPC loop

func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func handle(_ msg: [String: Any]) async {
    let id = msg["id"]
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    guard let id else { return } // notifications (initialized, cancelled) need no reply

    switch method {
    case "initialize":
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": (params["protocolVersion"] as? String) ?? protocolVersion,
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "earshot", "version": "0.8.0"],
            "instructions": "Meeting transcripts recorded on this Mac by Earshot. Search first, then read a transcript by id.",
        ]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools.map { t in
            ["name": t.name, "description": t.description,
             "inputSchema": ["type": "object", "properties": t.properties, "required": t.required]]
        }]])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        guard let tool = tools.first(where: { $0.name == name }) else {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool \(name)"]])
            return
        }
        do {
            let text = try await tool.call(params["arguments"] as? [String: Any] ?? [:])
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]]]])
        } catch {
            let text = (error as? Failure).map { if case .message(let m) = $0 { m } else { "" } } ?? error.localizedDescription
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    await handle(msg)
}
