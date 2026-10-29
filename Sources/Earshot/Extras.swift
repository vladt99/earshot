import AppKit
import Foundation
import Translation

// MARK: - Watched folders

/// Transcribes audio/video files in watched folders and writes `<name>.earshot.txt` + `<name>.earshot.srt`
/// next to them (never touching the user's own `<name>.srt`). A file counts as done once its
/// `.earshot.txt` exists, so files dropped while Earshot was closed are picked up at launch.
/// Files already in a folder when it is first watched are skipped.
@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()
    nonisolated static let mediaExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac", "aac", "ogg", "opus",
                                               "mp4", "mov", "m4v", "webm", "mkv"]
    /// folder → when it started being watched.
    private static let sinceKey = "watchedFolderSince"
    private var timer: Timer?
    /// Submitted this session, or skipped.
    private var seen: [String: Set<String>] = [:]
    /// path → size at last poll; a file is taken only once its size stops changing (finished copying).
    private var pendingSizes: [String: Int] = [:]
    private var since: [String: Date] = [:]

    func reload() {
        timer?.invalidate()
        timer = nil
        let folders = Settings.watchedFolders
        seen = seen.filter { folders.contains($0.key) }
        let stored = UserDefaults.standard.dictionary(forKey: Self.sinceKey) as? [String: Double] ?? [:]
        var kept: [String: Double] = [:]
        for folder in folders { kept[folder] = stored[folder] ?? Date().timeIntervalSince1970 }
        UserDefaults.standard.set(kept, forKey: Self.sinceKey)
        since = kept.mapValues { Date(timeIntervalSince1970: $0) }
        guard !folders.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in FolderWatcher.shared.poll() }
        }
        poll()
    }

    static func outputs(for media: URL) -> (txt: URL, srt: URL) {
        let base = media.deletingPathExtension().path
        return (URL(fileURLWithPath: base + ".earshot.txt"), URL(fileURLWithPath: base + ".earshot.srt"))
    }

    private func isDone(_ path: String, folder: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: Self.outputs(for: url).txt.path) { return true }
        guard let start = since[folder] else { return false }
        let v = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return (v?.addedToDirectoryDate ?? v?.creationDate).map { $0 < start } ?? false
    }

    private func poll() {
        for folder in Settings.watchedFolders {
            for path in files(in: folder) where !(seen[folder]?.contains(path) ?? false) {
                if isDone(path, folder: folder) {
                    seen[folder, default: []].insert(path)
                    pendingSizes[path] = nil
                    continue
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                if let last = pendingSizes[path], last == size, size > 0 {
                    pendingSizes[path] = nil
                    seen[folder, default: []].insert(path)
                    process(URL(fileURLWithPath: path))
                } else {
                    pendingSizes[path] = size
                }
            }
        }
    }

    private func process(_ url: URL) {
        Task {
            let options = TranscribeOptions(model: nil, language: Settings.language, diarize: Settings.diarizeFiles)
            let job = await Jobs.shared.run(JobRequest(file: url, title: url.lastPathComponent, origin: "watch",
                                                       options: options, sourcePath: url.path))
            guard let t = job.transcript else { return }
            let out = Self.outputs(for: url)
            // srt first: the txt marks the file as done.
            try? Formats.srt(t).write(to: out.srt, atomically: true, encoding: .utf8)
            try? Formats.speakerText(t.segments).write(to: out.txt, atomically: true, encoding: .utf8)
        }
    }

    private func files(in folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { Self.mediaExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
            .map { (folder as NSString).appendingPathComponent($0) }
    }
}

// MARK: - URL / YouTube import

enum URLImport {
    static let ytDlpCandidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
    static let maxDownload: Int64 = 4 << 30

    /// http(s) URLs only, parsed rather than prefix-matched ("httpx:" is not http).
    static func webURL(_ string: String) -> URL? {
        guard let c = URLComponents(string: string), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty else { return nil }
        return c.url
    }

    /// Downloads the audio of a web page (YouTube etc., via yt-dlp) or a direct media URL; returns (file, title).
    static func fetch(_ string: String) async throws -> (URL, String) {
        guard let url = webURL(string) else { throw APIError(400, "Not an http(s) URL") }
        let ext = url.pathExtension.lowercased()
        if FolderWatcher.mediaExtensions.contains(ext) {
            return (try await download(url, ext: ext), url.lastPathComponent)
        }
        guard let ytdlp = ytDlpCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw APIError(501, "Importing pages like YouTube needs yt-dlp: brew install yt-dlp")
        }
        let id = UUID().uuidString
        let template = Paths.uploads.appendingPathComponent("\(id).%(ext)s").path
        let output = try await run(ytdlp, ["-f", "bestaudio/best", "--no-playlist", "--max-filesize", "4G",
                                           "--print", "after_move:%(title)s", "-o", template, url.absoluteString])
        let title = output.split(separator: "\n").last.map(String.init) ?? url.host ?? "Download"
        guard let file = try FileManager.default.contentsOfDirectory(at: Paths.uploads, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix(id) }) else { throw APIError(502, "yt-dlp produced no file") }
        return (file, title)
    }

    /// Streams a direct media URL to Paths.uploads, at most `maxDownload` bytes; nothing is left behind on failure.
    private static func download(_ url: URL, ext: String) async throws -> URL {
        let tooBig = APIError(413, "The file is larger than \(ByteCountFormatter.string(fromByteCount: maxDownload, countStyle: .file))")
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard code < 400 else { bytes.task.cancel(); throw APIError(502, "Download failed: HTTP \(code)") }
        guard response.expectedContentLength <= maxDownload else { bytes.task.cancel(); throw tooBig }
        let dest = Paths.uploads.appendingPathComponent(UUID().uuidString + "." + ext)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw APIError(507, "Could not store the download") }
        var ok = false
        let handle = try FileHandle(forWritingTo: dest)
        defer {
            try? handle.close()
            if !ok { try? FileManager.default.removeItem(at: dest) }
        }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(1 << 20)
        var total: Int64 = 0
        for try await b in bytes {
            chunk.append(b)
            if chunk.count == 1 << 20 {
                total += Int64(chunk.count)
                guard total <= maxDownload else { bytes.task.cancel(); throw tooBig }
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: chunk)
        ok = true
        return dest
    }

    private static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    cont.resume(throwing: APIError(502, "yt-dlp failed: \(e.suffix(400))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - Translation (Apple on-device Translation framework)

enum Translator {
    /// Translates each segment; Whisper's own `translate` task only targets English, this covers any pair
    /// whose language pack is installed (System Settings → General → Language & Region → Translation Languages).
    static func translate(_ t: Transcript, to target: String) async throws -> Transcript {
        guard #available(macOS 26.0, *) else { throw APIError(501, "Translation to other languages needs macOS 26") }
        guard let source = t.language else { throw APIError(400, "Transcript has no detected language") }
        if source == target { return t }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
        var out = t
        do {
            let requests = t.segments.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: "\($0.offset)") }
            let responses = try await session.translations(from: requests)
            var byIndex: [Int: String] = [:]
            for r in responses { if let i = r.clientIdentifier.flatMap(Int.init) { byIndex[i] = r.targetText } }
            out.segments = t.segments.enumerated().map { i, s in var s = s; s.text = byIndex[i] ?? s.text; return s }
        } catch {
            throw APIError(424, "Translation \(source)→\(target) unavailable (\(error.localizedDescription)). Install the language pair in System Settings → General → Language & Region → Translation Languages.")
        }
        out.text = Formats.speakerText(out.segments)
        out.language = target
        return out
    }
}

// MARK: - URL scheme (Shortcuts, Raycast, Alfred…)

/// earshot://meeting/start[?app=com.google.Chrome|system&title=…]   earshot://meeting/stop
/// earshot://dictation/toggle   earshot://transcribe?path=/abs/file   earshot://open?id=…   earshot://show?page=meetings   earshot://settings?page=…
@MainActor
enum URLScheme {
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "earshot" else { return }
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { first, _ in first })
        let route = [url.host ?? "", url.path].joined()
        let state = AppState.shared
        // Any web page can open an earshot:// link, so whatever starts capture or reads a file asks first.
        switch route {
        case "meeting/start":
            guard confirm(recording: "a meeting") else { return }
            do { try MeetingController.shared.start(app: q["app"], title: q["title"], mic: q["mic"] != "false") }
            catch { state.lastError = (error as? APIError)?.message ?? error.localizedDescription }
        case "meeting/stop": state.stopMeeting()
        case "meeting/toggle":
            if state.meeting != nil { state.stopMeeting() } else if confirm(recording: "a meeting") { state.startMeeting() }
        case "dictation/toggle", "dictate":
            if state.isRecording || confirm(recording: "your microphone (dictation)") { state.toggleDictation() }
        case "transcribe":
            guard let p = q["path"] else { return }
            let file = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard ask("A link asked Earshot to transcribe a file",
                      "“\(file.path)”\n\nOnly allow this if you just clicked an Earshot link or ran a shortcut yourself.") else { return }
            state.transcribe(files: [file])
        case "panel": MeetingPanel.shared.show()
        case "open":
            state.reloadLibrary()
            if let id = q["id"], let t = state.transcripts.first(where: { $0.id == id }) { state.open(t) } else { state.showMainWindow() }
        case "show":
            let routes: [String: Route] = ["home": .home, "queue": .queue, "transcriptions": .transcriptions, "meetings": .meetings,
                                           "dictations": .dictations, "deleted": .deleted]
            state.navigate(routes[q["page"] ?? "home"] ?? .home)
            state.showMainWindow()
        case "settings": state.openSettings(q["page"])
        default: break
        }
    }

    private static func confirm(recording what: String) -> Bool {
        ask("A link asked Earshot to start recording \(what)",
            "Only allow this if you just clicked an Earshot link or ran a shortcut yourself.")
    }

    /// Allow / Don't Allow, with Don't Allow as the default button.
    private static func ask(_ message: String, _ info: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        let allow = alert.addButton(withTitle: "Allow")
        let deny = alert.addButton(withTitle: "Don't Allow")
        allow.keyEquivalent = ""
        deny.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
