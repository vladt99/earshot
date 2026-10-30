import AppKit
import Foundation

/// Applied to every finished transcript: Ignored Segments, Find & Replace, Auto-Export, finish sound.
enum PostProcess {
    static func apply(_ t: Transcript) -> Transcript {
        var t = t
        let ignored = Set(Settings.ignoredSegments.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let rules = Settings.findReplace.filter { $0.count == 2 && !$0[0].isEmpty }.compactMap(replacement)
        guard !ignored.isEmpty || !rules.isEmpty else { return t }
        t.segments = t.segments
            .filter { !ignored.contains($0.text.lowercased().trimmingCharacters(in: .whitespaces)) }
            .map { s in
                var s = s
                for (regex, template) in rules {
                    s.text = regex.stringByReplacingMatches(in: s.text, range: NSRange(s.text.startIndex..., in: s.text), withTemplate: template)
                }
                return s
            }
        t.text = Formats.speakerText(t.segments)
        return t
    }

    /// Whole words only ("AI" leaves "said" alone), case-insensitive, both sides taken literally.
    private static func replacement(_ pair: [String]) -> (NSRegularExpression, String)? {
        let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: pair[0]) + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return (regex, NSRegularExpression.escapedTemplate(for: pair[1]))
    }

    static func finished(_ t: Transcript) {
        if Settings.playSoundWhenFinished { Task { @MainActor in NSSound(named: "Glass")?.play() } }
        guard let folder = Settings.autoExportFolder else { return }
        var names: [String] = []
        export([t], to: URL(fileURLWithPath: folder), formats: Settings.autoExportFormats) { names.append($0) }
        if t.origin == "meeting", let daily = Settings.obsidianDailyNote, !daily.isEmpty,
           let file = names.first(where: { $0.hasSuffix(".md") }).map({ String($0.dropLast(3)) }) ?? names.first {
            appendToDailyNote(t, link: file, folder: dailyNoteFolder(daily))
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// The daily notes folder: "~/…" expanded, and a relative path taken from the home folder (an app's working
    /// directory is /).
    static func dailyNoteFolder(_ setting: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let path = (setting as NSString).expandingTildeInPath
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : home.appendingPathComponent(path, isDirectory: true)
    }

    /// The line for a meeting, or nil when it is already linked in `existing` (a re-export). Keeps the note's line
    /// endings, and starts on a new line when the note doesn't end with one.
    static func dailyNoteLine(_ entry: String, link: String, id: String, existing: Data?) -> String? {
        let text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let base = link.replacingOccurrences(of: " \(id.prefix(6))", with: "")
        if [link, base, base + " " + id.prefix(6)].contains(where: { text.contains("[[" + $0 + "]]") }) { return nil }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let open = existing.map { !$0.isEmpty && $0.last != 0x0A && $0.last != 0x0D } ?? false
        return (open ? newline : "") + entry + newline
    }

    /// Appends "- [[file]] HH:mm Title (participants)" to <folder>/YYYY-MM-DD.md. Existing text is never rewritten,
    /// and a meeting already linked there (a re-export) is not added twice.
    static func appendToDailyNote(_ t: Transcript, link: String, folder: URL) {
        let url = folder.appendingPathComponent(day.string(from: t.createdAt) + ".md")
        let names = Formats.people(t.context).filter { !$0.bot }.map(\.name)
            .map { Settings.obsidianLinks && Formats.linkable($0) ? Formats.wikilink($0) : $0 }
        let entry = "- [[\(link)]] \(time.string(from: t.createdAt)) \(t.title)" + (names.isEmpty ? "" : " (\(names.joined(separator: ", ")))")
        guard let line = dailyNoteLine(entry, link: link, id: t.id, existing: try? Data(contentsOf: url)) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // O_APPEND: two meetings finishing at once both land, neither overwrites the other.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? h.close() }
            try h.write(contentsOf: Data(line.utf8))
        } catch {
            let message = "Could not add the meeting to the daily note \(url.lastPathComponent): \(error.localizedDescription)"
            Task { @MainActor in AppState.shared.lastError = message }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    static func fileExtension(_ format: String) -> String { format == "text" ? "txt" : format }

    /// The file contents for one export format.
    static func render(_ t: Transcript, format: String) -> Data {
        switch format {
        case "srt": return Data(Formats.srt(t).utf8)
        case "vtt": return Data(Formats.vtt(t).utf8)
        case "md": return Data(Formats.markdown(t).utf8)
        case "json": return (try? JSONSerialization.data(withJSONObject: Formats.verbose(t), options: [.prettyPrinted, .sortedKeys])) ?? Data()
        default: return Data(Formats.plainText(t).utf8)
        }
    }

    /// A title that is safe as a file name: no path separators or control characters, at most 120 characters and
    /// well under the 255-byte name limit.
    static func safeName(_ title: String) -> String {
        var name = String(title.map { $0 == "/" || $0 == ":" ? "-" : $0.isNewline || ($0.unicodeScalars.first?.properties.generalCategory == .control) ? " " : $0 })
            .trimmingCharacters(in: .whitespaces)
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces) }
        while name.utf8.count > 200 { name.removeLast() }
        if name.hasPrefix(".") { name = "-" + name.dropFirst() }
        return name.isEmpty ? "Untitled" : name
    }

    /// Batch Export / Auto-Export: one file per transcript and format. Failures are reported in AppState.lastError.
    @discardableResult
    static func export(_ items: [Transcript], to folder: URL, formats: [String], wrote: (String) -> Void = { _ in }) -> Int {
        var written = 0
        var failed: [String] = []
        let fm = FileManager.default
        for t in items {
            // "2026-10-28 14.30 Weekly sync" sorts by date in a notes folder; a different transcript with the same
            // name in the same minute gets its id appended instead of overwriting.
            let base = "\(stamp.string(from: t.createdAt).replacingOccurrences(of: ":", with: ".")) \(safeName(t.title))"
            for f in formats {
                let body = render(t, format: f)
                var url = folder.appendingPathComponent("\(base).\(fileExtension(f))")
                if fm.fileExists(atPath: url.path), (try? Data(contentsOf: url)) != body {
                    url = folder.appendingPathComponent("\(base) \(t.id.prefix(6)).\(fileExtension(f))")
                }
                do {
                    try body.write(to: url, options: .atomic)
                    written += 1
                    wrote(url.lastPathComponent)
                } catch {
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if !failed.isEmpty {
            let message = "Export failed for \(failed.count) file\(failed.count == 1 ? "" : "s") — \(failed[0])"
            Task { @MainActor in AppState.shared.lastError = message }
        }
        return written
    }
}
