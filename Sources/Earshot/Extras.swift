import AppKit
import Foundation
import Translation

// MARK: - Watched folders

/// Transcribes new audio/video files dropped into watched folders and writes `<name>.txt` + `<name>.srt`
/// next to them. Files present when a folder is added are skipped.
@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()
    static let mediaExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac", "aac", "ogg", "opus",
                                               "mp4", "mov", "m4v", "webm", "mkv"]
    private var timer: Timer?
    private var seen: [String: Set<String>] = [:]
    /// path → size at last poll; a file is taken only once its size stops changing (finished copying).
    private var pendingSizes: [String: Int] = [:]

    func reload() {
        timer?.invalidate()
        seen = [:]
        for folder in Settings.watchedFolders { seen[folder] = Set(files(in: folder)) }
        guard !Settings.watchedFolders.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in FolderWatcher.shared.poll() }
        }
    }

    private func poll() {
        for folder in Settings.watchedFolders {
            for path in files(in: folder) where !(seen[folder]?.contains(path) ?? false) {
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
            let base = url.deletingPathExtension()
            try? Formats.speakerText(t.segments).write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            try? Formats.srt(t).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
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

    /// Downloads the audio of a web page (YouTube etc., via yt-dlp) or a direct media URL; returns (file, title).
    static func fetch(_ string: String) async throws -> (URL, String) {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { throw APIError(400, "Not an http(s) URL") }
        let ext = url.pathExtension.lowercased()
        if FolderWatcher.mediaExtensions.contains(ext) {
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { throw APIError(502, "Download failed") }
            let dest = Paths.uploads.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.moveItem(at: tmp, to: dest)
            return (dest, url.lastPathComponent)
        }
        guard let ytdlp = ytDlpCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw APIError(501, "Importing pages like YouTube needs yt-dlp: brew install yt-dlp")
        }
        let id = UUID().uuidString
        let template = Paths.uploads.appendingPathComponent("\(id).%(ext)s").path
        let output = try await run(ytdlp, ["-f", "bestaudio/best", "--no-playlist", "--print", "after_move:%(title)s",
                                           "-o", template, string])
        let title = output.split(separator: "\n").last.map(String.init) ?? url.host ?? "Download"
        guard let file = try FileManager.default.contentsOfDirectory(at: Paths.uploads, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix(id) }) else { throw APIError(502, "yt-dlp produced no file") }
        return (file, title)
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
        guard url.scheme == "earshot" else { return }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let route = [url.host ?? "", url.path].joined()
        let state = AppState.shared
        switch route {
        case "meeting/start":
            do { try MeetingController.shared.start(app: q["app"], title: q["title"], mic: q["mic"] != "false") }
            catch { state.lastError = (error as? APIError)?.message ?? error.localizedDescription }
        case "meeting/stop": state.stopMeeting()
        case "meeting/toggle": state.meeting == nil ? state.startMeeting() : state.stopMeeting()
        case "dictation/toggle", "dictate": state.toggleDictation()
        case "transcribe": if let p = q["path"] { state.transcribe(files: [URL(fileURLWithPath: (p as NSString).expandingTildeInPath)]) }
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
}
