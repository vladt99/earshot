import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var engineState = "Idle"
    var loadedModel: String?
    var language: String = Settings.language ?? "auto" {
        didSet { Settings.language = language == "auto" ? nil : language }
    }
    /// Bytes on disk per model id (0 = not downloaded).
    var modelBytes: [String: Int64] = [:]
    var downloads: [String: Double] = [:]
    var recordingStarted: Date?
    var transcripts: [Transcript] = []
    var activeJobs = 0
    var lastError: String?
    var meeting: MeetingSnapshot?
    var detectedMeeting: DetectedMeeting?
    /// Auto-stop countdown after the meeting app released the mic.
    var stoppingAt: Date?
    /// Meetings being re-transcribed after Stop (or by hand).
    var polishing: Set<String> = []
    var serverRunning = false
    var serverError: String?

    // Main window
    var route: Route = .home
    private var history: [Route] = []
    var openIDs: [String] = []
    var search = ""
    var folders: [Folder] = []
    var people: [Person] = []
    var deleted: [Transcript] = []
    var jobs: [Job] = []
    /// "dictation" or "voicememo" while the microphone recorder runs.
    var recordingKind: String?
    var backgroundVersion = 0
    var appearance = Settings.appearance {
        didSet { Settings.appearance = appearance }
    }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    var settingsPage = "General"
    var showBatchExport = false
    var showImporter = false
    var showAppAudioPicker = false
    var homeShortcuts: [String] = Settings.homeShortcuts {
        didSet { Settings.homeShortcuts = homeShortcuts }
    }
    var openWindowAction: ((String) -> Void)?
    var openSettingsAction: (() -> Void)?

    var currentTranscript: Transcript? {
        if case .transcript(let id) = route { return transcripts.first { $0.id == id } ?? deleted.first { $0.id == id } }
        return nil
    }

    var baseURL: String { "http://127.0.0.1:\(Settings.port)" }
    var isRecording: Bool { recordingStarted != nil }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    func bootstrap() {
        reloadTranscripts()
        refreshModelStatus()
        BookmarkHotkey.shared.update()
        Task { await MeetingRecovery.run() }
        // First launch after install: download the speech models (≈ 525 MB).
        Task { await Engine.shared.prepareSpeechModels() }
    }

    func refreshModelStatus() {
        Task.detached {
            var sizes: [String: Int64] = [:]
            for m in ModelCatalog.all { sizes[m.id] = ModelCatalog.isInstalled(m) ? ModelCatalog.installedBytes(m) : 0 }
            await MainActor.run { AppState.shared.modelBytes = sizes }
        }
    }

    var speechReady: Bool { (modelBytes[ModelCatalog.parakeet.id] ?? 0) > 0 }

    /// Download a model now (Settings → Local Models / AI).
    func downloadModel(_ id: String) {
        guard downloads[id] == nil, let m = ModelCatalog.find(id) else { return }
        downloads[id] = 0
        Task {
            do {
                switch m.kind {
                case .speech: _ = try await Engine.shared.ensureLoaded()
                case .speakers: _ = try await Engine.shared.diarize(samples: [Float](repeating: 0, count: 16_000))
                case .echo: await EchoCanceller.prepareModel()
                case .vocabulary: try await Engine.shared.prepareVocabulary(force: true)
                }
            } catch {
                lastError = "Download failed: \((error as? APIError)?.message ?? error.localizedDescription)"
            }
            downloads[id] = nil
            refreshModelStatus()
        }
    }

    func deleteModel(_ id: String) {
        guard let m = ModelCatalog.find(id) else { return }
        Task {
            if m.kind == .speech { await Engine.shared.unload() }
            if m.kind == .vocabulary { await Engine.shared.resetVocabulary() }
            try? FileManager.default.removeItem(at: ModelCatalog.folder(m))
            refreshModelStatus()
        }
    }

    // MARK: Navigation

    func navigate(_ r: Route) {
        guard r != route else { return }
        history.append(route)
        route = r
    }

    func back() { route = history.popLast() ?? .home }

    func open(_ t: Transcript) {
        if !openIDs.contains(t.id) { openIDs.append(t.id) }
        if openIDs.count > 6 { openIDs.removeFirst() }
        navigate(.transcript(t.id))
        showMainWindow()
    }

    func close(_ id: String) {
        openIDs.removeAll { $0 == id }
        if route == .transcript(id) { back() }
    }

    func showMainWindow() {
        openWindowAction?("main")
        NSApp.activate()
    }

    func openSettings(_ page: String?) {
        if let page { settingsPage = page }
        openSettingsAction?()
        NSApp.activate()
    }

    func openSupport() { NSWorkspace.shared.open(URL(string: "https://github.com/vladt99/earshot#readme")!) }

    func toast(_ message: String) { Notifier.post("Earshot", body: message) }

    /// Search box filter for lists.
    func filtered(_ items: [Transcript]) -> [Transcript] {
        guard !search.isEmpty else { return items }
        if searchCache.query != search {
            searchCache = (search, Set(Store.shared.search(search, limit: 500).map(\.transcript.id)))
        }
        let hits = searchCache.ids
        return items.filter { hits.contains($0.id) || $0.title.localizedCaseInsensitiveContains(search) }
    }

    /// Full-text hits for the current search box text (diacritics- and case-insensitive, word prefixes).
    @ObservationIgnored private var searchCache: (query: String, ids: Set<String>) = ("", [])

    // MARK: Library

    func reloadLibrary() {
        Store.shared.purgeExpired()
        transcripts = Store.shared.list(limit: 500)
        deleted = Store.shared.list(limit: 500, deleted: true)
        folders = Store.shared.folders()
        people = Store.shared.people()
    }

    func softDelete(_ t: Transcript) {
        Store.shared.setDeleted(t.id, true)
        openIDs.removeAll { $0 == t.id }
        if route == .transcript(t.id) { back() }
        reloadLibrary()
    }

    func restore(_ t: Transcript) {
        Store.shared.setDeleted(t.id, false)
        reloadLibrary()
    }

    func deleteForever(_ t: Transcript) {
        Store.shared.delete(t.id)
        reloadLibrary()
    }

    func emptyTrash() {
        deleted.forEach { Store.shared.delete($0.id) }
        reloadLibrary()
    }

    func createFolder(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Store.shared.saveFolder(Folder(id: UUID().uuidString.lowercased(), name: name))
        reloadLibrary()
    }

    func deleteFolder(_ f: Folder) {
        Store.shared.deleteFolder(f.id)
        if route == .folder(f.id) { route = .home }
        reloadLibrary()
    }

    func move(_ transcriptID: String, to folderID: String?) {
        Store.shared.setFolder(transcriptID, folderID)
        reloadLibrary()
    }

    func addPerson(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !people.contains(where: { $0.name == name }) else { return }
        Store.shared.savePerson(Person(id: UUID().uuidString.lowercased(), name: name))
        reloadLibrary()
    }

    func deletePerson(_ p: Person) {
        Store.shared.deletePerson(p.id)
        reloadLibrary()
    }

    /// Assign a person to a speaker label throughout one transcript.
    func renameSpeaker(in t: Transcript, from old: String?, to new: String) {
        var t = Store.shared.get(t.id) ?? t
        if let old, let folder = t.sourcePath.map(URL.init(fileURLWithPath:)) { MeetingVoices.renamed(in: folder, from: old, to: new) }
        t.segments = t.segments.map { var s = $0; if s.speaker == old { s.speaker = new }; return s }
        t.text = Formats.speakerText(t.segments)
        Store.shared.insert(t)
        didSave(t)
    }

    func toggleFavorite(_ t: Transcript, _ index: Int) {
        var t = Store.shared.get(t.id) ?? t
        guard t.segments.indices.contains(index) else { return }
        t.segments[index].favorite = !(t.segments[index].favorite ?? false)
        Store.shared.insert(t)
        didSave(t)
    }

    func save(_ t: Transcript, format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.title).\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PostProcess.export([t], to: url.deletingLastPathComponent(), formats: [format])
        let written = url.deletingLastPathComponent().appendingPathComponent("\(t.title.replacingOccurrences(of: "/", with: "-")).\(format)")
        if written != url { try? FileManager.default.moveItem(at: written, to: url) }
    }

    func setBackground(_ url: URL?) {
        if let url {
            let dest = Paths.support.appendingPathComponent("background.\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
            Settings.backgroundImage = dest.path
        } else {
            Settings.backgroundImage = nil
        }
        backgroundVersion += 1
    }

    // MARK: Recording modes (Home tiles)

    func toggleVoiceMemo() {
        Task {
            do {
                if recordingKind != nil {
                    _ = try await Dictation.stop(options: TranscribeOptions(model: nil, language: Settings.language), origin: recordingKind ?? "voicememo")
                } else {
                    try await Dictation.start(kind: "voicememo")
                }
            } catch {
                lastError = (error as? APIError)?.message ?? error.localizedDescription
            }
        }
    }

    func startAppAudio(_ bundleID: String?, name: String) {
        startSession { try MeetingController.shared.start(app: bundleID ?? "system", title: "App Audio — \(name)", platform: "App Audio",
                                                           appName: name, mic: false, origin: "appaudio") }
    }

    func startPodcast() {
        if meeting?.platform == "Podcast" { return stopMeeting() }
        startSession { try MeetingController.shared.start(app: "system", title: "Podcast \(Date().formatted(date: .abbreviated, time: .shortened))",
                                                           platform: "Podcast", appName: "System audio", mic: true, origin: "podcast") }
    }

    func toggleLiveCaptions() {
        if meeting?.platform == "Live Captions" { return stopMeeting() }
        startSession { try MeetingController.shared.start(app: "system", title: "Live Captions", platform: "Live Captions",
                                                           appName: "System audio", mic: true, origin: "captions", save: false) }
    }

    private func startSession(_ body: () throws -> MeetingSnapshot) {
        do { _ = try body() } catch {
            lastError = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    func reloadTranscripts() { reloadLibrary() }


    func didSave(_ t: Transcript) {
        searchCache = ("", [])
        if let i = transcripts.firstIndex(where: { $0.id == t.id }) {
            transcripts[i] = t
        } else {
            transcripts.insert(t, at: 0)
        }
    }

    func didDelete(_ id: String) {
        transcripts.removeAll { $0.id == id }
    }

    func delete(_ t: Transcript) { softDelete(t) }

    func transcribe(files: [URL]) {
        let options = TranscribeOptions(model: nil, language: Settings.language)
        for url in files {
            Task {
                _ = await Jobs.shared.submit(JobRequest(file: url, title: url.lastPathComponent, origin: "app",
                                                        options: options, sourcePath: url.path))
            }
        }
    }

    func toggleDictation() {
        Task {
            do {
                if isRecording {
                    let job = try await Dictation.stop(options: TranscribeOptions(model: nil, language: Settings.language), origin: recordingKind ?? "dictation")
                    if let e = job.error { lastError = e }
                } else {
                    try await Dictation.start(kind: "dictation")
                }
            } catch let e as APIError {
                lastError = e.message
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func startMeeting(app: String? = nil) {
        do {
            try MeetingController.shared.start(app: app, title: nil)
        } catch let e as APIError {
            lastError = e.message
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopMeeting() {
        Task { _ = await MeetingController.shared.stop() }
    }

    func keepRecording() { MeetingController.shared.keepRecording() }

    func retranscribe(_ t: Transcript) {
        Task {
            do { _ = try await MeetingController.shared.retranscribe(t.id) } catch {
                lastError = (error as? APIError)?.message ?? error.localizedDescription
            }
        }
    }

    func ignoreDetected() {
        if let d = detectedMeeting { MeetingDetector.shared.ignore(d) }
        detectedMeeting = nil
        MeetingPanel.shared.hide()
    }

    func importURL(_ link: String) {
        let link = link.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { return }
        Task {
            do {
                let (file, title) = try await URLImport.fetch(link)
                _ = await Jobs.shared.submit(JobRequest(file: file, title: title, origin: "youtube",
                                                        options: TranscribeOptions(model: nil, language: Settings.language, diarize: Settings.diarizeFiles),
                                                        deleteFileAfter: true, sourcePath: link))
            } catch {
                lastError = (error as? APIError)?.message ?? error.localizedDescription
            }
        }
    }

    func translate(_ t: Transcript, to lang: String) {
        Task {
            do {
                var translated = try await Translator.translate(t, to: lang)
                translated.id = UUID().uuidString.lowercased()
                translated.title = "\(t.title) [\(lang)]"
                translated.createdAt = Date()
                Store.shared.insert(translated)
                didSave(translated)
            } catch {
                lastError = (error as? APIError)?.message ?? error.localizedDescription
            }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
