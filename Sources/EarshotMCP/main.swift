import Foundation

// Earshot MCP server (stdio, JSON-RPC 2.0, one message per line).
// A thin client of the local REST API: it reads the base URL and token from
// ~/Library/Application Support/Earshot/api.json, so Earshot must be running.
//
//   claude mcp add earshot -- /Applications/Earshot.app/Contents/MacOS/earshot-mcp

let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
let serverVersion = "0.12.0"

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
    // `path` is already percent-encoded (see `segment`).
    guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw Failure.message("Bad base_url in api.json") }
    parts.percentEncodedPath = (parts.percentEncodedPath.hasSuffix("/") ? String(parts.percentEncodedPath.dropLast()) : parts.percentEncodedPath) + "/" + path
    if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    guard let url = parts.url else { throw Failure.message("Bad request path") }
    var req = URLRequest(url: url, timeoutInterval: 600)
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

/// One URL path segment ("/", "?", "#", "%" escaped).
func segment(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%;"))) ?? ""
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
         description: "Most recent recorded meetings: id, title, date, duration, preview, participants, platform, meeting code and link, and series_id for recurring meetings. Pass series (a series_id, or a meeting title) to list every meeting of one recurring series.",
         properties: ["limit": ["type": "integer", "description": "How many (default 20)"],
                      "series": ["type": "string", "description": "A series_id from this list, or a title such as \"Weekly sync\""]],
         required: []) { a in
        var q = ["limit": "\((a["limit"] as? Int) ?? 20)"]
        q["series"] = string(a, "series")
        return pretty(try await request("GET", "v1/meetings", query: q))
    },
    Tool(name: "speaker_lines",
         description: "What one person said across all meetings, newest first: meeting id, title, date, start and end (seconds into the meeting) and text. The name matches case- and accent-insensitively and through meeting participants (a first name or email finds their lines). Use list_speakers for the names Earshot knows.",
         properties: ["name": ["type": "string", "description": "Person's name as in transcripts, a first name, or an email"],
                      "query": ["type": "string", "description": "Only lines containing all of these words"],
                      "since": ["type": "string", "description": "Only meetings on or after this date (YYYY-MM-DD)"],
                      "limit": ["type": "integer", "description": "Max lines (default 50)"]],
         required: ["name"]) { a in
        var q = ["limit": "\((a["limit"] as? Int) ?? 50)"]
        q["q"] = string(a, "query")
        q["since"] = string(a, "since")
        return pretty(try await request("GET", "v1/speakers/" + segment(string(a, "name") ?? "") + "/lines", query: q))
    },
    Tool(name: "list_speakers",
         description: "Every named speaker in the library with how many meetings they spoke in, their number of lines and when they were last heard. Unnamed labels (Speaker 1, 2, …) are left out.",
         properties: [:], required: []) { _ in
        pretty(try await request("GET", "v1/speakers"))
    },
    Tool(name: "get_transcript",
         description: "One transcript by id. format \"text\" gives a header (title, date, meeting room, calendar event, participants) and speaker paragraphs; \"json\" gives segments with timestamps, speakers, notes and the meeting context (participants with guest/bot flags, room, calendar event with its series_id, and a timeline of joins, leaves, chat, reactions, screen sharing and captions on/off).",
         properties: ["id": ["type": "string"], "format": ["type": "string", "enum": ["text", "json"]]],
         required: ["id"]) { a in
        let r = try await request("GET", "v1/transcripts/" + segment(string(a, "id") ?? ""), query: ["format": "verbose_json"])
        guard string(a, "format") != "json", let d = r as? [String: Any] else { return pretty(r) }
        return textView(d)
    },
    Tool(name: "current_meeting",
         description: "The meeting being recorded right now: live transcript so far, notes, warnings, participants and room (context), whether you are muted (self_muted) and whether it is only Live Captions that won't be saved (live_captions, saved). Says so when nothing is recording.",
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

/// Header lines (what, when, where, who) above the speaker paragraphs.
func textView(_ d: [String: Any]) -> String {
    var head = [d["title"] as? String ?? ""]
    if let date = d["created_at"] as? String { head.append("Date: " + date) }
    if let c = d["context"] as? [String: Any] {
        let room = [c["platform_name"] as? String, c["meeting_code"] as? String, c["url"] as? String].compactMap { $0 }
        if !room.isEmpty { head.append("Meeting: " + room.joined(separator: " · ")) }
        if let cal = c["calendar"] as? [String: Any], let title = cal["title"] as? String {
            head.append("Calendar: " + title + ((cal["organizer"] as? String).map { " (organizer: \($0))" } ?? ""))
        }
        let people = (c["participants"] as? [[String: Any]] ?? []).filter { $0["presentation"] as? Bool != true }.map { p in
            (p["name"] as? String ?? "") + (p["bot"] as? Bool == true ? " (bot)" : p["external"] as? Bool == true ? " (guest)" : "")
        }
        if !people.isEmpty { head.append("Participants: " + people.joined(separator: ", ")) }
    }
    let notes = (d["notes"] as? [[String: Any]] ?? []).compactMap { n -> String? in
        guard let text = n["text"] as? String, !text.isEmpty else { return nil }
        return "- " + text
    }
    if !notes.isEmpty { head.append("Notes:\n" + notes.joined(separator: "\n")) }
    return head.joined(separator: "\n") + "\n\n" + (d["text"] as? String ?? "")
}

// MARK: - JSON-RPC loop

let outputLock = NSLock()

/// One write per message, newline-delimited; requests run concurrently, so writes are serialised.
func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    outputLock.withLock { FileHandle.standardOutput.write(data) }
}

func fail(_ id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func dispatch(_ line: String) async {
    guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) else {
        fail(NSNull(), -32700, "Parse error"); return
    }
    guard let msg = value as? [String: Any] else { fail(NSNull(), -32600, "Invalid Request"); return }
    guard let methodValue = msg["method"] else {
        // A response to something we sent (we send nothing, but never answer one).
        if msg["id"] == nil { fail(NSNull(), -32600, "Invalid Request") }
        return
    }
    guard let method = methodValue as? String else { fail(msg["id"] ?? NSNull(), -32600, "Invalid Request"); return }
    await handle(msg, method: method)
}

func handle(_ msg: [String: Any], method: String) async {
    let params = msg["params"] as? [String: Any] ?? [:]
    guard let id = msg["id"] else { return } // notifications (initialized, cancelled) need no reply

    switch method {
    case "initialize":
        let asked = params["protocolVersion"] as? String
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": asked.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0],
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "earshot", "version": serverVersion],
            "instructions": "Meeting transcripts recorded on this Mac by Earshot. Search first, then read a transcript by id. For what one person said, use list_speakers and speaker_lines; for a recurring meeting, list_meetings with series.",
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
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let missing = tool.required.filter { key in
                guard let v = args[key], !(v is NSNull) else { return true }
                return (v as? String)?.isEmpty == true
            }
            guard missing.isEmpty else { throw Failure.message("Missing required argument: \(missing.joined(separator: ", "))") }
            let text = try await tool.call(args)
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]]]])
        } catch {
            let text = (error as? Failure).map { if case .message(let m) = $0 { m } else { "" } } ?? error.localizedDescription
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": true]])
        }
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}

// Each message is handled on its own task, so a long transcribe_file never blocks ping or anything else.
let inFlight = DispatchGroup()
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    inFlight.enter()
    Task.detached {
        await dispatch(line)
        inFlight.leave()
    }
}
inFlight.wait()
