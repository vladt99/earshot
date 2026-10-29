import Foundation
import Security

/// Local REST API. Loopback only, bearer-token protected, browser origins rejected.
/// The token and base URL are published in ~/Library/Application Support/Earshot/api.json.
enum API {
    static var token = ""
    private static var server: HTTPServer?

    static func start() {
        token = loadOrCreateToken()
        let port = Settings.port
        let server = HTTPServer(port: port, admit: admit) { await handle($0) }
        do {
            try server.start { error in
                // api.json only advertises a server that actually owns the port.
                if error == nil { writeInfo(port: port) } else { removeInfo() }
                Task { @MainActor in
                    AppState.shared.serverError = error
                    AppState.shared.serverRunning = error == nil
                }
            }
            self.server = server
        } catch {
            Task { @MainActor in AppState.shared.serverError = "API server failed: \(error)" }
        }
    }

    // MARK: - Routing

    private static let uploadRoutes: Set<[String]> = [["v1", "audio", "transcriptions"], ["v1", "audio", "translations"], ["v1", "jobs"]]

    /// Runs on the headers alone, so strangers never get a 100 Continue or a buffered body.
    static func admit(_ req: HTTPRequest) -> HTTPServer.Admission {
        // DNS-rebinding and drive-by protection: only loopback hosts, never browser pages.
        guard ["127.0.0.1", "localhost", "[::1]", ""].contains(hostName(req.headers["host"] ?? "")) else {
            return .reject(.error(403, "Host not allowed"))
        }
        // Local tools send neither; browsers always send one or the other (including "Origin: null").
        if req.headers["origin"] != nil { return .reject(.error(403, "Browser origins are not allowed")) }
        if let site = req.headers["sec-fetch-site"], site.lowercased() != "none" { return .reject(.error(403, "Browser requests are not allowed")) }

        let parts = req.path.split(separator: "/").map(String.init)
        if !(req.method == "GET" && parts == ["health"]) {
            let auth = req.headers["authorization"] ?? ""
            let presented = auth.lowercased().hasPrefix("bearer ") ? String(auth.dropFirst(7)) : (req.headers["x-api-key"] ?? "")
            guard !presented.isEmpty, constantTimeEquals(presented, token) else {
                return .reject(.error(401, "Missing or invalid token. Read it from \(Paths.apiInfo.path)"))
            }
        }
        let upload = req.method == "POST" && uploadRoutes.contains(parts)
        return .accept(maxBody: upload ? HTTPServer.maxBody : HTTPServer.smallBody,
                       stream: req.method == "GET" && parts == ["v1", "events"])
    }

    private static func hostName(_ host: String) -> String {
        let h = host.lowercased()
        if h.hasPrefix("["), let end = h.firstIndex(of: "]") { return String(h[...end]) }
        return h.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    static func handle(_ req: HTTPRequest) async -> HTTPResponse {
        if case .reject(let r) = admit(req) { return r }
        let parts = req.path.split(separator: "/").map(String.init)
        // Only /health is open; `/` gives the same answer to authenticated callers.
        if req.method == "GET", parts == ["health"] || parts.isEmpty { return await health() }

        do {
            switch (req.method, parts) {
            case ("GET", ["v1", "status"]): return await status()

            case ("GET", ["v1", "models"]): return models()
            case ("POST", ["v1", "models", "download"]): return try await download(req)
            case ("DELETE", let p) where p.count == 3 && p[0] == "v1" && p[1] == "models": return try await deleteModel(p[2])

            case ("POST", ["v1", "audio", "transcriptions"]): return try await transcribeSync(req, translate: false)
            case ("POST", ["v1", "audio", "translations"]): return try await transcribeSync(req, translate: true)

            case ("POST", ["v1", "jobs"]):
                let input = try await TranscriptionInput.parse(req)
                return .json(encode(await Jobs.shared.submit(input.job)), status: 202)
            case ("GET", ["v1", "jobs"]): return .json(["data": await Jobs.shared.all().map(encode)])
            case ("GET", let p) where p.count == 3 && p[0] == "v1" && p[1] == "jobs":
                guard var job = await Jobs.shared.get(p[2]) else { throw APIError(404, "No such job") }
                if req.query["wait"] == "true" { job = await Jobs.shared.wait(p[2]) ?? job }
                return .json(encode(job))

            case ("GET", ["v1", "transcripts"]):
                let list = Store.shared.list(limit: Int(req.query["limit"] ?? "") ?? 50,
                                             offset: Int(req.query["offset"] ?? "") ?? 0,
                                             query: req.query["q"].flatMap { $0.isEmpty ? nil : $0 },
                                             origin: req.query["origin"])
                return .json(["data": list.map(Formats.summary)])
            case ("GET", let p) where p.count == 3 && p[0] == "v1" && p[1] == "transcripts":
                guard let t = Store.shared.get(p[2]) else { throw APIError(404, "No such transcript") }
                return Formats.render(t, as: req.query["format"] ?? "verbose_json")
            case ("POST", let p) where p.count == 4 && p[0] == "v1" && p[1] == "transcripts" && p[3] == "translate":
                guard let t = Store.shared.get(p[2]) else { throw APIError(404, "No such transcript") }
                guard let target = req.jsonObject["target"] as? String else { throw APIError(400, "Body must be {\"target\": \"ro\"}") }
                let translated = try await Translator.translate(t, to: target)
                return Formats.render(translated, as: (req.jsonObject["response_format"] as? String) ?? "verbose_json")
            case ("POST", let p) where p.count == 4 && p[0] == "v1" && p[1] == "transcripts" && p[3] == "speakers":
                // Rename a speaker ("Speaker 1" → "Ana"); for meetings this also teaches Earshot Ana's voice.
                guard let t = Store.shared.get(p[2]) else { throw APIError(404, "No such transcript") }
                let body = req.jsonObject
                guard let from = body["from"] as? String, let to = (body["to"] as? String)?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
                    throw APIError(400, "Body must be {\"from\": \"Speaker 1\", \"to\": \"Name\"}")
                }
                await MainActor.run {
                    AppState.shared.addPerson(to)
                    AppState.shared.renameSpeaker(in: t, from: from, to: to)
                }
                return Formats.render(Store.shared.get(p[2]) ?? t, as: "verbose_json")
            case ("POST", ["v1", "import", "url"]):
                let body = req.jsonObject
                guard let link = body["url"] as? String else { throw APIError(400, "Body must be {\"url\": \"https://…\"}") }
                let (file, title) = try await URLImport.fetch(link)
                let fields = body.compactMapValues { $0 is NSNull ? nil : "\($0)" }
                var options = TranscriptionInput.options(from: fields)
                options.diarize = (body["diarize"] as? Bool) ?? Settings.diarizeFiles
                let job = await Jobs.shared.submit(JobRequest(file: file, title: title, origin: "youtube", options: options,
                                                              deleteFileAfter: true, sourcePath: link))
                return .json(encode(job), status: 202)
            case ("DELETE", let p) where p.count == 3 && p[0] == "v1" && p[1] == "transcripts":
                guard let t = Store.shared.get(p[2]) else { throw APIError(404, "No such transcript") }
                let permanent = req.query["permanent"] == "true"
                await MainActor.run { permanent ? AppState.shared.deleteForever(t) : AppState.shared.softDelete(t) }
                return .json(["deleted": true, "id": p[2], "permanent": permanent])

            case ("GET", ["v1", "events"]):
                let filter = req.query["filter"].map { Set($0.split(separator: ",").map(String.init)) }
                return .events(EventBus.shared.subscribe(filter: filter))

            case ("GET", ["v1", "meetings"]):
                let list = Store.shared.list(limit: Int(req.query["limit"] ?? "") ?? 50, offset: Int(req.query["offset"] ?? "") ?? 0,
                                             query: req.query["q"].flatMap { $0.isEmpty ? nil : $0 }, origin: "meeting")
                return .json(["data": list.map(Formats.summary)])
            case ("GET", ["v1", "meetings", "current"]): return await currentMeeting(format: req.query["format"])
            case ("GET", ["v1", "meetings", "detected"]):
                let d = await MainActor.run { MeetingDetector.shared.detect() }
                let detected: Any = d.map { m -> [String: Any] in
                    ["app": m.appName, "app_bundle_id": m.appBundleID, "platform": m.platform,
                     "title": m.title, "url": (m.url as Any?) ?? NSNull()]
                } ?? NSNull()
                return .json(["detected": detected])
            case ("POST", ["v1", "meetings", "start"]):
                let body = req.jsonObject
                let snap = try await MainActor.run {
                    try MeetingController.shared.start(app: body["app"] as? String, title: body["title"] as? String,
                                                       mic: (body["mic"] as? Bool) ?? true)
                }
                return .json(MeetingController.payload(snap), status: 201)
            case ("POST", ["v1", "meetings", "stop"]):
                let running = await MainActor.run { AppState.shared.meeting != nil }
                guard let t = await MeetingController.shared.stop() else {
                    guard running else { throw APIError(409, "No meeting in progress") }
                    throw APIError(500, await MainActor.run { AppState.shared.lastError } ?? "The meeting could not be saved")
                }
                var d = Formats.verbose(t)
                // The live transcript; the polished one follows as `meeting.finalized` (SSE/webhook).
                d["polishing"] = Settings.polishAfterMeeting
                return .json(d)
            case ("POST", ["v1", "meetings", "current", "keep"]):
                // Live Captions → saved as a meeting when they stop.
                let m = try await MainActor.run { () throws -> MeetingSnapshot in
                    guard let m = AppState.shared.meeting else { throw APIError(409, "No meeting in progress") }
                    AppState.shared.keepLiveCaptions()
                    return m
                }
                return .json(["id": m.id, "live_captions": m.isLiveCaptions, "saved": true])
            case ("POST", ["v1", "meetings", "current", "bookmark"]), ("POST", ["v1", "meetings", "current", "notes"]):
                let body = req.jsonObject
                let kind = parts[3] == "bookmark" ? "bookmark" : "note"
                guard kind == "bookmark" || !((body["text"] as? String) ?? "").isEmpty else { throw APIError(400, "Body must be {\"text\": \"…\"}") }
                guard let note = await MainActor.run(body: { MeetingController.shared.addNote(body["text"] as? String, kind: kind) }) else {
                    throw APIError(409, "No meeting in progress")
                }
                return .json(Formats.note(note), status: 201)

            case ("GET", ["v1", "search"]):
                guard let q = req.query["q"], !q.isEmpty else { throw APIError(400, "Pass ?q=words") }
                let hits = Store.shared.search(q, limit: Int(req.query["limit"] ?? "") ?? 20, origin: req.query["origin"])
                return .json(["query": q, "data": hits.map { h -> [String: Any] in
                    var d = Formats.summary(h.transcript)
                    d["snippet"] = h.snippet
                    d["matches"] = h.segments.map { s -> [String: Any] in
                        var m: [String: Any] = ["start": Formats.num(s.start), "end": Formats.num(s.end), "text": s.text]
                        m["speaker"] = s.speaker
                        return m
                    }
                    return d
                }])

            case ("GET", ["v1", "voices"]):
                return .json(["data": Store.shared.voices().keys.sorted()])
            case ("DELETE", let p) where p.count == 3 && p[0] == "v1" && p[1] == "voices":
                Store.shared.forgetVoice(p[2])
                return .json(["deleted": true, "name": p[2]])
            case ("POST", let p) where p.count == 4 && p[0] == "v1" && p[1] == "meetings" && p[3] == "retranscribe":
                let t = try await MeetingController.shared.retranscribe(p[2])
                return Formats.render(t, as: req.query["format"] ?? "verbose_json")

            case ("GET", ["v1", "settings"]): return .json(SettingsAPI.current())
            case ("PATCH", ["v1", "settings"]), ("POST", ["v1", "settings"]):
                try await SettingsAPI.apply(req.jsonObject)
                return .json(SettingsAPI.current())

            case ("GET", ["v1", "dictation"]): return await dictationState()
            case ("POST", ["v1", "dictation", "start"]):
                try await Dictation.start()
                return await dictationState()
            case ("POST", ["v1", "dictation", "stop"]):
                let body = req.jsonObject
                let job = try await Dictation.stop(options: TranscriptionInput.options(from: body.mapValues { "\($0)" }),
                                                   save: (body["save"] as? Bool) ?? true, origin: "api")
                return try respond(job, format: (body["response_format"] as? String) ?? req.query["format"] ?? "verbose_json")
            case ("POST", ["v1", "dictation", "cancel"]):
                await Dictation.cancel()
                return await dictationState()

            default:
                return .error(404, "No route for \(req.method) \(req.path)")
            }
        } catch let e as APIError {
            return .error(e.status, e.message)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    // MARK: - Handlers

    private static func health() async -> HTTPResponse {
        let loaded = await Engine.shared.loadedModel
        return .json(["ok": true, "name": "Earshot", "version": appVersion, "loaded_model": (loaded as Any?) ?? NSNull()])
    }

    private static func status() async -> HTTPResponse {
        let loaded = await Engine.shared.loadedModel
        let active = await Jobs.shared.activeCount
        return await MainActor.run {
            let s = AppState.shared
            return .json([
                "version": appVersion,
                "base_url": "http://127.0.0.1:\(Settings.port)",
                "engine": ["state": s.engineState, "loaded_model": (loaded as Any?) ?? NSNull(),
                           "speech_model": Engine.modelID(for: Settings.language)] as [String: Any],
                "language": Settings.language ?? "auto",
                "downloads": s.downloads,
                "jobs_active": active,
                "dictation": ["recording": Dictation.isRecording,
                              "seconds": s.recordingStarted.map { Date().timeIntervalSince($0) } ?? 0],
            ])
        }
    }

    private static func models() -> HTTPResponse {
        .json(["object": "list", "data": ModelCatalog.all.map { m in
            let bytes = ModelCatalog.installedBytes(m)
            return ["id": m.id, "object": "model", "name": m.name, "purpose": m.purpose, "kind": m.kind.rawValue,
                    "repo": m.repo, "download_bytes": m.bytes, "installed": ModelCatalog.isInstalled(m),
                    "bytes_on_disk": bytes, "path": ModelCatalog.folder(m).path,
                    "active": m.id != ModelCatalog.whisper.id || Engine.usesWhisper(language: Settings.language)] as [String: Any]
        }])
    }

    private static func download(_ req: HTTPRequest) async throws -> HTTPResponse {
        guard let id = req.jsonObject["model"] as? String, let m = ModelCatalog.find(id) else {
            throw APIError(400, "Body must be {\"model\": \"\(ModelCatalog.all.map(\.id).joined(separator: "|"))\"}")
        }
        await MainActor.run { AppState.shared.downloadModel(m.id) }
        return .json(["downloading": m.id, "bytes": m.bytes, "progress_at": "/v1/status"], status: 202)
    }

    private static func deleteModel(_ id: String) async throws -> HTTPResponse {
        guard let m = ModelCatalog.find(id) else { throw APIError(404, "Unknown model '\(id)'") }
        await MainActor.run { AppState.shared.deleteModel(m.id) }
        return .json(["deleted": m.id, "freed_bytes": ModelCatalog.installedBytes(m)])
    }

    private static func transcribeSync(_ req: HTTPRequest, translate: Bool) async throws -> HTTPResponse {
        var input = try await TranscriptionInput.parse(req)
        input.job.options.translate = translate
        var job = await Jobs.shared.run(input.job)
        if translate, let t = job.transcript, t.language != "en" {
            job.transcript = try await Translator.translate(t, to: "en")
        }
        return try respond(job, format: input.format)
    }

    private static func respond(_ job: Job, format: String) throws -> HTTPResponse {
        guard let t = job.transcript else { throw APIError(500, job.error ?? "Transcription failed") }
        return Formats.render(t, as: format)
    }

    private static func currentMeeting(format: String?) async -> HTTPResponse {
        guard let m = await MainActor.run(body: { AppState.shared.meeting }) else { return .json(["active": false]) }
        if format == "text" || format == "txt" { return .text(Formats.speakerText(m.lines)) }
        var d = MeetingController.payload(m)
        d["active"] = true
        d["text"] = Formats.speakerText(m.lines)
        d["segments"] = m.lines.map { ["start": Formats.num($0.start), "end": Formats.num($0.end), "text": $0.text, "speaker": $0.speaker ?? ""] }
        d["partial"] = m.hypotheses.filter { !$0.value.isEmpty }
        d["notes"] = m.notes.map(Formats.note)
        d["warning"] = m.warning ?? NSNull()
        d["reading_captions"] = m.readingCaptions
        d["self_muted"] = m.selfMuted
        d["live_captions"] = m.isLiveCaptions
        d["saved"] = await MainActor.run { AppState.shared.willSave(m) }
        d["context"] = m.context.map { Formats.context($0) } ?? NSNull()
        return .json(d)
    }

    private static func dictationState() async -> HTTPResponse {
        await MainActor.run {
            .json(["recording": Dictation.isRecording,
                   "seconds": AppState.shared.recordingStarted.map { Date().timeIntervalSince($0) } ?? 0])
        }
    }

    // MARK: - Helpers

    static func encode(_ job: Job) -> [String: Any] {
        var d: [String: Any] = ["id": job.id, "status": job.status, "title": job.title,
                                "created_at": Formats.iso(job.createdAt), "saved": job.saved]
        d["started_at"] = job.startedAt.map(Formats.iso)
        d["finished_at"] = job.finishedAt.map(Formats.iso)
        d["error"] = job.error
        d["transcript"] = job.transcript.map(Formats.verbose)
        return d
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func loadOrCreateToken() -> String {
        if let data = try? Data(contentsOf: Paths.apiInfo),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["token"] as? String, t.count >= 32 { return t }
        return randomHex(32)
    }

    /// `count` random bytes as hex, from the system CSPRNG.
    static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            arc4random_buf(&bytes, bytes.count) // same kernel CSPRNG, cannot fail
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeInfo(port: UInt16) {
        let info: [String: Any] = ["base_url": "http://127.0.0.1:\(port)", "port": Int(port), "token": token,
                                   "version": appVersion, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        // Created 0600 from the start (no umask window), then renamed into place.
        let tmp = Paths.apiInfo.deletingLastPathComponent().appendingPathComponent(".api.json.\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        if written != data.count || rename(tmp.path, Paths.apiInfo.path) != 0 { unlink(tmp.path) }
    }

    /// Removes api.json if this process wrote it.
    private static func removeInfo() {
        guard let data = try? Data(contentsOf: Paths.apiInfo),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) else { return }
        try? FileManager.default.removeItem(at: Paths.apiInfo)
    }
}

/// Request → JobRequest. Accepts OpenAI-style multipart uploads or JSON {"path": "/local/file"}.
struct TranscriptionInput {
    var job: JobRequest
    var format: String

    static func parse(_ req: HTTPRequest) async throws -> TranscriptionInput {
        var fields: [String: String]
        let file: URL
        var title: String
        var sourcePath: String?
        var deleteAfter = false
        var upload: (filename: String, data: Data)?

        if req.isMultipart {
            let mp = try req.multipart()
            fields = mp.fields
            guard let part = mp.files["file"] else { throw APIError(400, "Multipart body needs a 'file' part") }
            let ext = (part.filename as NSString).pathExtension
            file = Paths.uploads.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
            upload = part
            title = part.filename
            deleteAfter = true
        } else {
            let body = req.jsonObject
            fields = body.compactMapValues { v in v is NSNull ? nil : "\(v)" }
            if let b = body["save"] as? Bool { fields["save"] = b ? "true" : "false" }
            for key in ["translate", "diarize"] {
                if let b = body[key] as? Bool { fields[key] = b ? "true" : "false" }
            }
            guard let path = fields["path"], !path.isEmpty else {
                throw APIError(400, "Send multipart/form-data with a 'file' part, or JSON {\"path\": \"/absolute/file\"}")
            }
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw APIError(404, "File not found or not readable: \(file.path)")
            }
            title = file.lastPathComponent
            sourcePath = file.path
        }

        let format = fields["response_format"] ?? fields["format"] ?? "json"
        guard Formats.all.contains(format) else {
            throw APIError(400, "response_format must be one of \(Formats.all.joined(separator: ", "))")
        }
        // Written only once the request is known to be valid; removed again if anything below fails.
        var stored: URL?
        defer { if let stored { try? FileManager.default.removeItem(at: stored) } }
        if let upload {
            stored = file
            do { try upload.data.write(to: file) } catch { throw APIError(507, "Could not store the upload: \(error.localizedDescription)") }
        }
        if let t = fields["title"], !t.isEmpty { title = t }
        var options = options(from: fields)
        options.translate = fields["translate"] == "true"
        options.diarize = fields["diarize"].map { $0 == "true" || $0 == "1" } ?? Settings.diarizeFiles
        let save = fields["save"].map { $0 != "false" } ?? true
        let input = TranscriptionInput(
            job: JobRequest(file: file, title: title, origin: "api", options: options,
                            save: save, deleteFileAfter: deleteAfter, sourcePath: sourcePath),
            format: format
        )
        stored = nil
        return input
    }

    /// `model` accepts a full id or a display name; OpenAI's "whisper-1" means "the selected model".
    static func options(from fields: [String: String]) -> TranscribeOptions {
        var model = fields["model"]
        if model == "whisper-1" || model?.isEmpty == true { model = nil }
        var language = fields["language"] ?? Settings.language
        if language == "auto" || language?.isEmpty == true { language = nil }
        return TranscribeOptions(model: model, language: language)
    }
}

/// Read/write the user-facing settings over the API (`GET/PATCH /v1/settings`).
enum SettingsAPI {
    static func current() -> [String: Any] {
        [
            "language": Settings.language ?? "auto",
            "speech_model": Engine.modelID(for: Settings.language),
            "meeting_mode": Settings.meetingMode,
            "auto_stop_after_meeting": Settings.autoStopAfterMeeting,
            "auto_dismiss_meeting_alerts": Settings.autoDismissMeetingAlerts,
            "participants_name": Settings.participantsName,
            "meeting_apps": Settings.meetingApps,
            "diarize_meetings": Settings.diarizeMeetings,
            "diarize_files": Settings.diarizeFiles,
            "echo_cancellation": Settings.echoCancellation,
            "my_name": Settings.myName,
            "use_calendar_titles": Settings.useCalendarTitles,
            "copy_dictation_to_clipboard": Settings.copyDictationToClipboard,
            "watched_folders": Settings.watchedFolders,
            "polish_after_meeting": Settings.polishAfterMeeting,
            "follow_meeting_language": Settings.followMeetingLanguage,
            "respect_mute": Settings.respectMute,
            "keep_live_captions_of_calls": Settings.keepLiveCaptionsOfCalls,
            "txt_header": Settings.txtHeader,
            "auto_name_speakers": Settings.autoNameSpeakers,
            "remember_voices": Settings.rememberVoices,
            "vocabulary": Settings.vocabulary,
            "bookmark_hotkey": Settings.bookmarkHotkey,
            "audio_warnings": Settings.audioWarnings,
            "webhooks": Settings.webhooks,
            "webhook_events": Settings.webhookEvents,
            "auto_export_folder": Settings.autoExportFolder ?? NSNull(),
            "auto_export_formats": Settings.autoExportFormats,
            "port": Int(Settings.port),
        ]
    }

    static func apply(_ b: [String: Any]) async throws {
        if let v = b["language"] as? String { await MainActor.run { AppState.shared.language = v.isEmpty ? "auto" : v } }
        if let v = b["meeting_mode"] as? String {
            guard ["ask", "auto", "off"].contains(v) else { throw APIError(400, "meeting_mode must be ask, auto or off") }
            Settings.meetingMode = v
        }
        if let v = b["auto_stop_after_meeting"] as? Bool { Settings.autoStopAfterMeeting = v }
        if let v = b["auto_dismiss_meeting_alerts"] as? Bool { Settings.autoDismissMeetingAlerts = v }
        if let v = b["participants_name"] as? String, !v.isEmpty { Settings.participantsName = v }
        if let v = b["meeting_apps"] as? [String] { Settings.meetingApps = v }
        if let v = b["diarize_meetings"] as? Bool { Settings.diarizeMeetings = v }
        if let v = b["diarize_files"] as? Bool { Settings.diarizeFiles = v }
        if let v = b["echo_cancellation"] as? Bool { Settings.echoCancellation = v }
        if let v = b["my_name"] as? String, !v.isEmpty { Settings.myName = v }
        if let v = b["use_calendar_titles"] as? Bool { Settings.useCalendarTitles = v }
        if let v = b["copy_dictation_to_clipboard"] as? Bool { Settings.copyDictationToClipboard = v }
        if let v = b["polish_after_meeting"] as? Bool { Settings.polishAfterMeeting = v }
        if let v = b["follow_meeting_language"] as? Bool { Settings.followMeetingLanguage = v }
        if let v = b["respect_mute"] as? Bool { Settings.respectMute = v }
        if let v = b["keep_live_captions_of_calls"] as? Bool { Settings.keepLiveCaptionsOfCalls = v }
        if let v = b["txt_header"] as? Bool { Settings.txtHeader = v }
        if let v = b["auto_name_speakers"] as? Bool { Settings.autoNameSpeakers = v }
        if let v = b["remember_voices"] as? Bool { Settings.rememberVoices = v }
        if let v = b["audio_warnings"] as? Bool { Settings.audioWarnings = v }
        if let v = b["vocabulary"] as? [String] {
            Settings.vocabulary = v
            Task { try? await Engine.shared.prepareVocabulary() }
        }
        if let v = b["bookmark_hotkey"] as? Bool {
            Settings.bookmarkHotkey = v
            await MainActor.run { BookmarkHotkey.shared.update() }
        }
        if let v = b["webhooks"] as? [String] {
            guard v.allSatisfy({ ["http", "https"].contains(URL(string: $0)?.scheme ?? "") }) else { throw APIError(400, "webhooks must be http(s) URLs") }
            Settings.webhooks = v
        }
        if let v = b["webhook_events"] as? [String] { Settings.webhookEvents = v }
        if b.keys.contains("auto_export_folder") {
            Settings.autoExportFolder = (b["auto_export_folder"] as? String).flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        }
        if let v = b["auto_export_formats"] as? [String] { Settings.autoExportFormats = v.filter { ["txt", "srt", "vtt", "md", "json"].contains($0) } }
        if let v = b["watched_folders"] as? [String] {
            Settings.watchedFolders = v.map { ($0 as NSString).expandingTildeInPath }
            await MainActor.run { FolderWatcher.shared.reload() }
        }
    }
}
