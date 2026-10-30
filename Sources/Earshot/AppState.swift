import AVFoundation
import AppKit
import ApplicationServices
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
        didSet {
            Settings.language = language == "auto" ? nil : language
            if language != oldValue, Engine.usesWhisper(language: Settings.language) { prepareWhisper() }
        }
    }
    /// Bytes on disk per model id (0 = not downloaded).
    var modelBytes: [String: Int64] = [:]
    var downloads: [String: Double] = [:]
    var recordingStarted: Date?
    var transcripts: [Transcript] = [] {
        didSet {
            let groups = Series.groups(transcripts)
            if groups != seriesGroups { seriesGroups = groups }
        }
    }
    /// Recurring meetings: series key → meeting ids, newest first (see `Series`).
    private(set) var seriesGroups: [String: [String]] = [:]
    var activeJobs = 0
    var lastError: String?
    var meeting: MeetingSnapshot? {
        didSet {
            if let meeting { noteWarnings(meeting) }
            refreshLivePrompt()
        }
    }
    /// The live panel's "Who is this?" for the running meeting: worked out at most every 5 s, off the main actor, and
    /// held still while the user is using it.
    private(set) var livePrompt: SpeakerPicker.Prompt?
    @ObservationIgnored private var livePromptAt = Date.distantPast
    @ObservationIgnored private var livePromptTask: Task<Void, Never>?
    @ObservationIgnored private var livePromptHeld = false
    /// Meet hints the user closed, per meeting id ("captions", or the health message).
    var dismissedHints: [String: Set<String>] = [:]
    var detectedMeeting: DetectedMeeting?
    /// A Meet tab on its pre-join screen: the panel offers the language and what to record.
    var preJoin: PreJoinOffer?
    var showsPreJoin: Bool { preJoin.map { !$0.dismissed } ?? false }
    /// Unnamed voices the user skipped in a transcript's "Who is this?" prompt, per transcript id.
    var skippedSpeakers: [String: Set<String>] = (UserDefaults.standard.dictionary(forKey: "skippedSpeakers") as? [String: [String]] ?? [:])
        .mapValues(Set.init)
    /// Auto-stop countdown after the meeting app released the mic.
    var stoppingAt: Date?
    /// Meetings being re-transcribed after Stop (or by hand).
    var polishing: Set<String> = []
    var serverRunning = false
    var serverError: String?
    /// Live Captions sessions the user asked to keep ("Save as meeting").
    var keptSessions: Set<String> = []

    // Main window
    var route: Route = .home
    private var history: [Route] = []
    var openIDs: [String] = []
    var search = "" {
        didSet { if search != oldValue { scheduleSearch() } }
    }
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

    /// On only while SMAppService reports `.enabled`; refreshed after every change and when the app becomes active.
    var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard !syncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
            refreshLaunchAtLogin()
        }
    }
    /// Registered, but the user still has to allow Earshot in System Settings → General → Login Items.
    var launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @ObservationIgnored private var syncingLaunchAtLogin = false

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        syncingLaunchAtLogin = true
        launchAtLogin = status == .enabled
        syncingLaunchAtLogin = false
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    func bootstrap() {
        reloadTranscripts()
        refreshModelStatus()
        refreshLaunchAtLogin()
        checkGrants(launch: true)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppState.shared.refreshLaunchAtLogin()
                AppState.shared.checkGrants(launch: false)
            }
        }
        BookmarkHotkey.shared.update()
        Task { await Jobs.shared.restore() }
        Task { await MeetingRecovery.run() }
        AudioRetention.schedule()
        // First launch after install: download the speech models (≈ 525 MB).
        Task { await Engine.shared.prepareSpeechModels() }
    }

    // MARK: Permissions after an update

    enum Grant: String, CaseIterable { case microphone, accessibility }

    /// Permissions an update took away (releases are ad hoc signed, so macOS sees each one as a new app); the Overview
    /// asks for them again until they're back or dismissed.
    private(set) var lostGrants: [Grant] = []

    static func granted() -> Set<Grant> {
        var g: Set<Grant> = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { g.insert(.microphone) }
        if AXIsProcessTrusted() { g.insert(.accessibility) }
        return g
    }

    /// `launch`: the first launch of a new build compares with what the last build had (or, from a build that didn't
    /// record it, with everything Earshot uses).
    func checkGrants(launch: Bool) {
        let d = UserDefaults.standard, now = Self.granted()
        func grants(_ key: String) -> Set<Grant> { Set((d.stringArray(forKey: key) ?? []).compactMap(Grant.init)) }
        if launch {
            let last = d.string(forKey: "grantsBuild") ?? d.string(forKey: "askedAccessibilityBuild")
            if let last, last != Settings.appBuild {
                let before = d.object(forKey: "grants") != nil ? grants("grants") : Set(Grant.allCases)
                d.set(before.subtracting(now).map(\.rawValue), forKey: "grantsLost")
            }
            d.set(Settings.appBuild, forKey: "grantsBuild")
        }
        d.set(now.map(\.rawValue), forKey: "grants")
        let lost = grants("grantsLost").subtracting(now)
        d.set(lost.map(\.rawValue), forKey: "grantsLost")
        let list = Grant.allCases.filter(lost.contains)
        if list != lostGrants { lostGrants = list }
    }

    func dismissLostGrants() {
        UserDefaults.standard.removeObject(forKey: "grantsLost")
        lostGrants = []
    }

    /// Asks again where macOS can (a microphone that's "not asked yet"), else opens the System Settings pane.
    func restoreGrant(_ g: Grant) {
        switch g {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in AppState.shared.checkGrants(launch: false) } }
            } else {
                Self.openPrivacyPane("Privacy_Microphone")
            }
        case .accessibility:
            MeetObserver.ask()
        }
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    @ObservationIgnored private var modelScan = 0

    func refreshModelStatus() {
        modelScan += 1
        let scan = modelScan
        Task.detached {
            var sizes: [String: Int64] = [:]
            for m in ModelCatalog.all { sizes[m.id] = ModelCatalog.isInstalled(m) ? ModelCatalog.installedBytes(m) : 0 }
            let result = sizes
            await MainActor.run {
                // A newer scan started meanwhile: its result wins.
                guard AppState.shared.modelScan == scan else { return }
                AppState.shared.modelBytes = result
            }
        }
    }

    var speechReady: Bool { (modelBytes[ModelCatalog.parakeet.id] ?? 0) > 0 }

    /// The current language needs Whisper.
    var usesWhisper: Bool { Engine.usesWhisper(language: language) }
    /// The model the current language transcribes with.
    var speechModel: ModelInfo { usesWhisper ? ModelCatalog.whisper : ModelCatalog.parakeet }
    var speechModelReady: Bool { (modelBytes[speechModel.id] ?? 0) > 0 }
    var speechModelShortName: String { usesWhisper ? "Whisper v3 Turbo" : "Parakeet v3" }

    /// A non-English language was picked: download Whisper (progress in `downloads`) or load it in the background.
    func prepareWhisper() {
        let id = ModelCatalog.whisper.id
        guard downloads[id] == nil else { return }
        if ModelCatalog.isInstalled(ModelCatalog.whisper) { Task { try? await Engine.shared.prepareWhisper() } } else { downloadModel(id) }
    }

    /// Download a model now (Settings → Local Models / AI).
    func downloadModel(_ id: String) {
        guard downloads[id] == nil, let m = ModelCatalog.find(id) else { return }
        downloads[id] = 0
        Task {
            do {
                switch m.kind {
                case .speech where m.id == ModelCatalog.whisper.id: try await Engine.shared.prepareWhisper()
                case .speech: _ = try await Engine.shared.ensureLoaded()
                case .speakers: try await Engine.shared.prepareDiarizer()
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
            switch m.kind {
            case .speech where m.id == ModelCatalog.whisper.id: await Engine.shared.unloadWhisper()
            case .speech: await Engine.shared.unload()
            case .speakers: await Engine.shared.unloadDiarizer()
            case .vocabulary: await Engine.shared.resetVocabulary()
            case .echo: break
            }
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

    /// Search box filter for lists: a set lookup against the last finished search (cheap enough for `body`).
    func filtered(_ items: [Transcript]) -> [Transcript] {
        guard !search.isEmpty else { return items }
        guard searchResults.query == search else {
            // Debounce window: titles only until the full-text results arrive.
            return items.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        let hits = searchResults.ids
        return items.filter { hits.contains($0.id) }
    }

    /// Full-text hits (diacritics- and case-insensitive, word prefixes) plus title matches for `query`.
    private var searchResults: (query: String, ids: Set<String>) = ("", [])
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private func scheduleSearch(delay: Duration = .milliseconds(200)) {
        searchTask?.cancel()
        let q = search
        guard !q.isEmpty else { searchResults = ("", []); return }
        searchTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let fts = await Task.detached(priority: .userInitiated) { Store.shared.searchIDs(q) }.value
            guard !Task.isCancelled, q == search else { return }
            let titles = (transcripts + deleted).filter { $0.title.localizedCaseInsensitiveContains(q) }.map(\.id)
            searchResults = (q, fts.union(titles))
        }
    }

    // MARK: Library

    @ObservationIgnored private var libraryLoad = 0
    /// Bumped by every library reload (views that read files, like a transcript's audio, look again).
    private(set) var libraryVersion = 0
    @ObservationIgnored private var libraryLoading = false

    /// Reads the whole library off the main actor; a newer reload supersedes an older one still running.
    func reloadLibrary() {
        libraryLoad += 1
        let load = libraryLoad
        libraryLoading = true
        Task {
            let (active, trash, folders, people) = await Task.detached(priority: .userInitiated) {
                Store.shared.purgeExpired()
                return (Store.shared.list(limit: nil), Store.shared.list(limit: nil, deleted: true), Store.shared.folders(), Store.shared.people())
            }.value
            guard load == libraryLoad else { return }
            libraryLoading = false
            libraryVersion += 1
            transcripts = active
            deleted = trash
            self.folders = folders
            self.people = people
            if !search.isEmpty { scheduleSearch(delay: .zero) }
        }
    }

    func softDelete(_ t: Transcript) {
        Store.shared.setDeleted(t.id, true)
        openIDs.removeAll { $0 == t.id }
        if route == .transcript(t.id) { back() }
        if let moved = Store.shared.get(t.id) { didSave(moved) }
        reloadLibrary()
    }

    func restore(_ t: Transcript) {
        Store.shared.setDeleted(t.id, false)
        if let moved = Store.shared.get(t.id) { didSave(moved) }
        reloadLibrary()
    }

    /// Removes the transcript, its search entry and the recording Earshot made for it.
    func deleteForever(_ t: Transcript) {
        Store.shared.delete(t.id)
        forget(t.id)
        reloadLibrary()
    }

    /// Everything in Recently Deleted, including items not loaded in the list.
    func emptyTrash() {
        let ids = deleted.map(\.id)
        ids.forEach(forget)
        deleted = []
        Task {
            _ = await Task.detached(priority: .userInitiated) { Store.shared.deleteTrashed() }.value
            reloadLibrary()
        }
    }

    private func forget(_ id: String) {
        transcripts.removeAll { $0.id == id }
        deleted.removeAll { $0.id == id }
        openIDs.removeAll { $0 == id }
        if route == .transcript(id) { back() }
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

    /// "Who is this?": names a speaker throughout one transcript, adds them to People and, for meetings, remembers
    /// the voice. A name another speaker already has merges the two (one person split in two).
    func nameSpeaker(in t: Transcript, from old: String?, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        addPerson(name)
        renameSpeaker(in: t, from: old, to: name)
    }

    func skipSpeaker(_ label: String, in id: String) {
        skippedSpeakers[id, default: []].insert(label)
        if skippedSpeakers.count > 200, let old = skippedSpeakers.keys.first(where: { $0 != id }) { skippedSpeakers[old] = nil }
        UserDefaults.standard.set(skippedSpeakers.mapValues { Array($0).sorted() }, forKey: "skippedSpeakers")
    }

    /// Assign a person to a speaker label throughout one transcript.
    func renameSpeaker(in t: Transcript, from old: String?, to new: String) {
        guard let current = Store.shared.get(t.id) else { return }
        if let old, let folder = current.sourcePath.map(URL.init(fileURLWithPath:)) { MeetingVoices.renamed(in: folder, from: old, to: new) }
        let segments = current.segments.map { var s = $0; if s.speaker == old { s.speaker = new }; return s }
        saveContent(current.id, segments)
    }

    func toggleFavorite(_ t: Transcript, _ index: Int) { toggleFavorite(t, [index]) }

    /// Stars every segment of a paragraph, or unstars them all when they already are.
    func toggleFavorite(_ t: Transcript, _ indices: [Int]) {
        guard var segments = Store.shared.get(t.id)?.segments else { return }
        let valid = indices.filter(segments.indices.contains)
        guard !valid.isEmpty else { return }
        let on = !valid.allSatisfy { segments[$0].favorite == true }
        for i in valid { segments[i].favorite = on ? true : nil }
        saveContent(t.id, segments)
    }

    /// Writes new segments into the stored row only (title, folder, trash state stay as they are on disk).
    private func saveContent(_ id: String, _ segments: [Segment]) {
        guard Store.shared.updateContent(id: id, segments: segments, text: Formats.speakerText(segments)),
              let saved = Store.shared.get(id) else {
            lastError = "Could not save the change to the library"
            return
        }
        didSave(saved)
    }

    func save(_ t: Transcript, format: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(PostProcess.safeName(t.title)).\(PostProcess.fileExtension(format))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PostProcess.render(t, format: format).write(to: url, options: .atomic)
        } catch {
            lastError = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
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

    // MARK: Meet hints and warnings

    func dismissHint(_ hint: String, in meetingID: String) { dismissedHints[meetingID, default: []].insert(hint) }

    func showsHint(_ hint: String, in m: MeetingSnapshot) -> Bool {
        Settings.meetHealthWarnings && !m.stopping && !(dismissedHints[m.id]?.contains(hint) ?? false)
    }

    nonisolated static let warningsKey = "lastMeetingWarnings"
    nonisolated static let captionsWarning = "Captions are off in Meet"
    @ObservationIgnored private var warningsMeeting: String?
    @ObservationIgnored private var warningsSeen: [String] = []

    /// Every warning of the latest meeting, kept (without the title) for Copy Diagnostics.
    private func noteWarnings(_ m: MeetingSnapshot) {
        if warningsMeeting != m.id {
            warningsMeeting = m.id
            warningsSeen = []
            UserDefaults.standard.set([String](), forKey: Self.warningsKey)
        }
        // The captions reminder is one-time: once captions come back on it stays closed for this meeting.
        if !m.captionsOff, warningsSeen.contains(Self.captionsWarning), !(dismissedHints[m.id]?.contains("captions") ?? false) {
            dismissHint("captions", in: m.id)
        }
        let now = [m.warning, m.meetHealth, m.captionsOff ? Self.captionsWarning : nil, m.captionsNeedAccess ? "Captions need Accessibility access" : nil]
            .compactMap { $0 }.filter { !warningsSeen.contains($0) }
        guard !now.isEmpty else { return }
        warningsSeen += now
        UserDefaults.standard.set(Array(warningsSeen.suffix(20)), forKey: Self.warningsKey)
    }


    /// A saved transcript lands in the list matching its trash state.
    func didSave(_ t: Transcript) {
        if t.deletedAt == nil {
            deleted.removeAll { $0.id == t.id }
            upsert(t, into: &transcripts)
        } else {
            transcripts.removeAll { $0.id == t.id }
            upsert(t, into: &deleted)
        }
        // A reload that read the database before this write would drop it: read again.
        if libraryLoading { reloadLibrary() }
        if !search.isEmpty { scheduleSearch() }
    }

    private func upsert(_ t: Transcript, into list: inout [Transcript]) {
        if let i = list.firstIndex(where: { $0.id == t.id }) { list[i] = t } else { list.insert(t, at: 0) }
    }

    func didDelete(_ id: String) {
        transcripts.removeAll { $0.id == id }
        deleted.removeAll { $0.id == id }
    }

    func delete(_ t: Transcript) { softDelete(t) }

    /// Queued in the order given (one task submits them all).
    func transcribe(files: [URL]) {
        let options = TranscribeOptions(model: nil, language: Settings.language, diarize: Settings.diarizeFiles)
        Task {
            for url in files {
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

    /// Turns the running Live Captions into a meeting that is saved when it stops.
    func keepLiveCaptions() {
        guard let m = meeting, m.isLiveCaptions else { return }
        if MeetingController.shared.keepSession() { keptSessions.insert(m.id) }
    }

    /// Live Captions of a call that will be saved anyway (`keepLiveCaptionsOfCalls`).
    func keptAutomatically(_ m: MeetingSnapshot) -> Bool {
        m.isLiveCaptions && Settings.keepLiveCaptionsOfCalls && (m.context != nil || detectedMeeting != nil)
    }

    /// The running session ends up in the library: a recording, or Live Captions that are being kept.
    func willSave(_ m: MeetingSnapshot) -> Bool { !m.isLiveCaptions || m.kept || keptSessions.contains(m.id) || keptAutomatically(m) }

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
        if !showsPreJoin { MeetingPanel.shared.hide() }
    }

    /// Names a live "Speaker N": applied to the lines on screen, to later passes and at polish.
    func nameLiveSpeaker(_ label: String, _ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        addPerson(name)
        MeetingController.shared.session?.nameSpeaker(label, name)
    }

    func skipLiveSpeaker(_ label: String) { MeetingController.shared.session?.skipSpeaker(label) }

    /// Typing a name or pointing at a chip: the prompt doesn't change under the user (a name landing on another voice).
    func holdLivePrompt(_ held: Bool) {
        guard held != livePromptHeld else { return }
        livePromptHeld = held
        if !held { refreshLivePrompt() }
    }

    private func refreshLivePrompt() {
        guard let m = meeting, !m.stopping else {
            if livePrompt != nil { livePrompt = nil }
            livePromptHeld = false
            return
        }
        // Named or skipped: it goes at once (a held prompt too, the user just answered it).
        if let p = livePrompt, m.skippedSpeakers.contains(p.label) || !m.lines.contains(where: { $0.speaker == p.label }) {
            livePrompt = nil
            livePromptHeld = false
        }
        guard !livePromptHeld, livePromptTask == nil else { return }
        let wait = max(0, 5 - Date().timeIntervalSince(livePromptAt))
        livePromptTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self else { return }
            defer { self.livePromptTask = nil }
            guard let m = self.meeting, !m.stopping, !self.livePromptHeld else { return }
            self.livePromptAt = Date()
            let (lines, context, skipped) = (m.lines, m.context, m.skippedSpeakers)
            let p = await Task.detached(priority: .utility) { SpeakerPicker.livePrompt(lines: lines, context: context, skipped: skipped) }.value
            guard self.meeting?.id == m.id, !self.livePromptHeld, p != self.livePrompt else { return }
            self.livePrompt = p
        }
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
                translated.deletedAt = nil
                guard Store.shared.insert(translated) else { throw APIError(500, "Could not save the translation") }
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

extension MeetingSnapshot {
    /// Live Captions: transcribed on screen, not saved unless kept.
    var isLiveCaptions: Bool { platform == "Live Captions" }
    var people: [MeetingParticipant] { Formats.people(context) }
}
