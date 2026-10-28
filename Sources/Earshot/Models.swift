import Foundation

struct Segment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// "Me", "Speaker 1", … (nil when not diarized)
    var speaker: String?
    var favorite: Bool? = nil
}

struct Transcript: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var createdAt: Date
    var title: String
    var sourcePath: String?
    /// "api", "app", "dictation", "meeting", "watch", "youtube"
    var origin: String
    var model: String
    var language: String?
    var duration: Double?
    var processingSeconds: Double
    var text: String
    var segments: [Segment]
    var deletedAt: Date? = nil
    var folderID: String? = nil
    /// Bookmarks and typed notes taken during a meeting, at times on the transcript's clock.
    var notes: [Note]? = nil
}

/// A moment marked during a meeting: `kind` "bookmark" (hotkey/button) or "note" (typed text).
struct Note: Codable, Hashable, Sendable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var time: Double
    var text: String
    var kind: String
}

struct Folder: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

struct Person: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// Every model Earshot can use. Nothing ships with the app: each one downloads on first use.
struct ModelInfo: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case speech, speakers, echo, vocabulary }
    let id: String
    let name: String
    let purpose: String
    let kind: Kind
    /// Download size published on Hugging Face.
    let bytes: Int64
    let repo: String

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

enum ModelCatalog {
    static let parakeet = ModelInfo(id: "parakeet-tdt-v3", name: "Parakeet TDT v3", purpose: "Transcription in 25 European languages",
                                    kind: .speech, bytes: 483_000_000, repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml")
    static let diarizer = ModelInfo(id: "speaker-diarization", name: "Pyannote Community-1", purpose: "Speaker detection",
                                    kind: .speakers, bytes: 22_000_000, repo: "FluidInference/speaker-diarization-coreml")
    static let echo = ModelInfo(id: "localvqe", name: "LocalVQE v1.3", purpose: "Echo cancellation for your microphone",
                                kind: .echo, bytes: 20_000_000, repo: "FluidInference/localvqe-coreml")
    /// Only downloaded once the user adds Custom Vocabulary words.
    static let vocabulary = ModelInfo(id: "parakeet-ctc-110m", name: "Parakeet CTC 110M", purpose: "Custom vocabulary (names, project terms)",
                                      kind: .vocabulary, bytes: 100_000_000, repo: "FluidInference/parakeet-ctc-110m-coreml")
    /// Downloaded on first launch.
    static let speech = [parakeet, diarizer, echo]
    static let all = speech + [vocabulary]

    static func find(_ id: String) -> ModelInfo? { all.first { $0.id == id || $0.repo == id || $0.name == id } }

    /// Where each model lives once downloaded.
    static func folder(_ m: ModelInfo) -> URL {
        // FluidAudio stores most repos without the "-coreml" suffix, but the CTC models keep it.
        let name = String(m.repo.split(separator: "/").last ?? "")
        let full = fluidAudioModels.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: full.path) ? full : fluidAudioModels.appendingPathComponent(name.replacingOccurrences(of: "-coreml", with: ""))
    }

    static var fluidAudioModels: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    static func installedBytes(_ m: ModelInfo) -> Int64 { size(of: folder(m)) }

    static func isInstalled(_ m: ModelInfo) -> Bool {
        // Partial downloads are smaller; consider a model present at 90 % of its published size.
        installedBytes(m) >= m.bytes * 9 / 10
    }

    static func size(of dir: URL) -> Int64 {
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        while let u = e?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Model name for a transcript's `model` field (older transcripts carry Whisper ids).
    static func displayName(_ id: String) -> String {
        if let m = find(id) { return m.name }
        if id.contains("whisper") { return "Whisper (legacy)" }
        return id
    }
}
