import AppKit
import Foundation

/// Applied to every finished transcript: Ignored Segments, Find & Replace, Auto-Export, finish sound.
enum PostProcess {
    static func apply(_ t: Transcript) -> Transcript {
        var t = t
        let ignored = Set(Settings.ignoredSegments.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let pairs = Settings.findReplace.filter { $0.count == 2 && !$0[0].isEmpty }
        guard !ignored.isEmpty || !pairs.isEmpty else { return t }
        t.segments = t.segments
            .filter { !ignored.contains($0.text.lowercased().trimmingCharacters(in: .whitespaces)) }
            .map { s in
                var s = s
                for p in pairs { s.text = s.text.replacingOccurrences(of: p[0], with: p[1], options: .caseInsensitive) }
                return s
            }
        t.text = Formats.speakerText(t.segments)
        return t
    }

    static func finished(_ t: Transcript) {
        if Settings.playSoundWhenFinished { Task { @MainActor in NSSound(named: "Glass")?.play() } }
        guard let folder = Settings.autoExportFolder else { return }
        export([t], to: URL(fileURLWithPath: folder), formats: Settings.autoExportFormats)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    /// Batch Export / Auto-Export: one file per transcript and format.
    @discardableResult
    static func export(_ items: [Transcript], to folder: URL, formats: [String]) -> Int {
        var written = 0
        for t in items {
            // "2026-10-28 14.30 Weekly sync" sorts by date in a notes folder and never collides across meetings.
            let base = "\(stamp.string(from: t.createdAt)) \(t.title)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            for f in formats {
                let body: String
                switch f {
                case "srt": body = Formats.srt(t)
                case "vtt": body = Formats.vtt(t)
                case "md": body = Formats.markdown(t)
                case "json":
                    body = String(data: (try? JSONSerialization.data(withJSONObject: Formats.verbose(t), options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? ""
                default: body = Formats.speakerText(t.segments)
                }
                let url = folder.appendingPathComponent("\(base).\(f == "txt" ? "txt" : f)")
                if (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil { written += 1 }
            }
        }
        return written
    }
}
