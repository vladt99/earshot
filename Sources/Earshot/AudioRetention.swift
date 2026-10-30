import Foundation

/// Keep recordings for N days (`Settings.keepAudioDays`): older meeting, dictation and voice-memo audio is deleted,
/// transcripts stay. Transcripts with a favourite line keep their audio. Files outside Earshot's folders are never touched.
enum AudioRetention {
    static let choices = [0, 7, 30, 90, 365]

    static func label(_ days: Int) -> String { days == 0 ? "Forever" : "\(days) days" }

    /// At launch and every 24 hours.
    @MainActor
    static func schedule() {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if Settings.keepAudioDays > 0 { _ = await run(olderThan: Settings.keepAudioDays) }
                try? await Task.sleep(for: .seconds(86400))
            }
        }
    }

    /// Deletes the recordings older than `days`; returns how many and the bytes freed.
    @discardableResult
    static func run(olderThan days: Int) async -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        for r in candidates(olderThan: days) {
            let url = URL(fileURLWithPath: r.path)
            if await busy(url, r.ids) { continue }
            if let freed = delete(url) { count += 1; bytes += freed }
        }
        if count > 0 { await MainActor.run { AppState.shared.reloadLibrary() } }
        return (count, bytes)
    }

    /// What `run` would delete now: how many recordings and their bytes.
    static func preview(olderThan days: Int) async -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        for r in candidates(olderThan: days) {
            let url = URL(fileURLWithPath: r.path)
            if await busy(url, r.ids) { continue }
            if let n = size(url) { count += 1; bytes += n }
        }
        return (count, bytes)
    }

    private static func candidates(olderThan days: Int) -> [(path: String, ids: [String])] {
        days > 0 ? Store.shared.recordingsOlder(than: Date().addingTimeInterval(-Double(days) * 86400)) : []
    }

    /// A meeting still recording, saving or being re-transcribed keeps its audio.
    private static func busy(_ url: URL, _ ids: [String]) async -> Bool {
        await MainActor.run { MeetingController.shared.owns(url) || ids.contains(where: AppState.shared.polishing.contains) }
    }

    /// The recording's bytes, when there is one of Earshot's to delete.
    private static func size(_ url: URL) -> Int64? {
        switch location(url) {
        case .meeting:
            return MeetingAudio.hasAudio(url) ? Int64(MeetingAudio.size(url)) : nil
        case .media:
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        case .elsewhere:
            return nil
        }
    }

    /// The recording's bytes when something was deleted.
    private static func delete(_ url: URL) -> Int64? {
        guard let size = size(url) else { return nil }
        switch location(url) {
        case .meeting: return (try? MeetingAudio.deleteAudio(folder: url)) != nil ? size : nil
        case .media: return (try? FileManager.default.removeItem(at: url)) != nil ? size : nil
        case .elsewhere: return nil
        }
    }

    enum Location { case meeting, media, elsewhere }

    /// A meeting folder in Paths.meetings, a recording in Paths.media, or a file of the user's.
    static func location(_ url: URL) -> Location {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ root: URL) -> Bool { target.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
        if inside(Paths.meetings) { return .meeting }
        if inside(Paths.media) { return .media }
        return .elsewhere
    }

    enum Audio: Equatable { case present, deleted, none }

    /// Whether a transcript can still be played: `deleted` when Earshot's own recording of it is gone.
    static func audio(_ t: Transcript) -> Audio {
        guard let p = t.sourcePath, !p.hasPrefix("http") else { return .none }
        let url = URL(fileURLWithPath: p)
        switch location(url) {
        case .meeting: return MeetingAudio.hasAudio(url) ? .present : .deleted
        case .media: return FileManager.default.fileExists(atPath: p) ? .present : .deleted
        case .elsewhere: return FileManager.default.fileExists(atPath: p) ? .present : .none
        }
    }

    /// The files to play: both meeting tracks (.wav or .m4a), or the recording itself.
    static func tracks(_ t: Transcript) -> [URL] {
        guard let p = t.sourcePath, !p.hasPrefix("http") else { return [] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { return [] }
        let url = URL(fileURLWithPath: p)
        return isDir.boolValue ? ["others", "me"].compactMap { MeetingAudio.track(url, $0) } : [url]
    }

    /// Bytes used by meeting recordings and dictation / voice-memo files.
    static func diskUse() -> Int64 { ModelCatalog.size(of: Paths.meetings, partial: true) + ModelCatalog.size(of: Paths.media, partial: true) }

    static var deletedNote: String {
        Settings.keepAudioDays > 0 ? "Recording deleted after \(label(Settings.keepAudioDays))" : "Recording deleted"
    }
}
