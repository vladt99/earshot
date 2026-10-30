import SwiftUI
import UniformTypeIdentifiers

/// Settings: a glass sidebar of pages grouped by area, the page on the right.
struct SettingsWindow: View {
    @Environment(AppState.self) private var state

    static let groups: [(String, [(String, String)])] = [
        ("GENERAL", [("General", "gearshape"), ("Appearance", "paintpalette"), ("Watched Folders", "folder.badge.gearshape"),
                     ("Shortcuts", "command"), ("Storage", "internaldrive"), ("Advanced", "slider.horizontal.3")]),
        ("AUDIO & VIDEO", [("Microphone", "mic"), ("Live Captions", "captions.bubble"), ("Dictation", "character.cursor.ibeam"),
                           ("Record Meetings", "person.2.wave.2"), ("Note Taker", "bookmark")]),
        ("TRANSCRIPTION", [("Local Models", "cpu"), ("Cloud Models", "cloud"), ("People", "person.2"), ("Custom Vocabulary", "textformat.abc"), ("Translation", "character.book.closed"),
                           ("Ignored Segments", "eye.slash"), ("Find & Replace", "arrow.left.arrow.right")]),
        ("EXPORT", [("Export Formats", "doc.text"), ("Batch Export", "square.stack.3d.up"), ("Auto-Export", "tray.and.arrow.down"),
                    ("Integrations", "network")]),
        ("EARSHOT", [("About", "info.circle")]),
    ]

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.groups, id: \.0) { group, pages in
                        SectionLabel(text: group.capitalized)
                        ForEach(pages, id: \.0) { page, symbol in
                            let selected = state.settingsPage == page
                            Button { state.settingsPage = page } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: symbol).frame(width: 20)
                                        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                                    Text(page)
                                    Spacer(minLength: 0)
                                }
                                .fontWeight(selected ? .semibold : .regular)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background { if selected { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.secondary) } }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .frame(width: 220)
            .panel()
            .padding([.leading, .bottom], 10)
            .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsPage(page: state.settingsPage)
                }
                .padding(20).frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .background { Backdrop() }
        .navigationTitle(state.settingsPage)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .preferredColorScheme(state.colorScheme)
    }
}

/// Label on the left, switch on the right edge.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 20)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// A glass group of settings rows.
struct GlassGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline).foregroundStyle(.secondary).padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
        }
    }
}

private struct SettingsPage: View {
    @Environment(AppState.self) private var state
    let page: String
    @State private var tick = 0
    @State private var newItem = ""
    @State private var newReplace = ""
    @State private var batchExport = false

    var body: some View {
        @Bindable var state = state
        let _ = tick
        switch page {
        case "General":
            GlassGroup {
                toggle("Play sound when finished", Settings.playSoundWhenFinished) { Settings.playSoundWhenFinished = $0 }
                SwitchRow(title: "Launch at login", isOn: $state.launchAtLogin)
                if state.launchAtLoginNeedsApproval {
                    HStack {
                        Label("Approve Earshot in System Settings → General → Login Items", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .buttonStyle(.glass)
                    }
                    .font(.callout)
                }
                Picker("Default language", selection: $state.language) {
                    ForEach(LanguageMenu.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                if state.usesWhisper {
                    ModelRow(model: ModelCatalog.whisper)
                }
                note(LanguageMenu.whisperNote + "; English and Auto Detect use Parakeet.")
            }
        case "Appearance":
            GlassGroup(title: "Theme") {
                Picker("Appearance", selection: $state.appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            GlassGroup(title: "Background") {
                HStack(spacing: 14) {
                    if let img = BackdropModel.shared.image {
                        Image(nsImage: img).resizable().scaledToFill().frame(width: 200, height: 124).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Choose Image…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            if panel.runModal() == .OK, let url = panel.url { state.setBackground(url) }
                        }
                        .buttonStyle(.glass)
                        Button("Use Desktop Wallpaper") { state.setBackground(nil) }.buttonStyle(.glass)
                    }
                }
                HStack {
                    Text("Dim")
                    Slider(value: Binding(get: { BackdropModel.shared.dim }, set: { BackdropModel.shared.dim = $0 }), in: 0...0.8)
                        .accessibilityLabel("Dim")
                }
            }
            GlassGroup(title: "Transcript") {
                HStack {
                    Text("Font size")
                    Slider(value: Binding(get: { Settings.fontSize }, set: { Settings.fontSize = $0; tick += 1 }), in: 11...32, step: 1)
                    Text("\(Int(Settings.fontSize))").monospacedDigit()
                }
            }
        case "Watched Folders":
            GlassGroup {
                ForEach(Settings.watchedFolders, id: \.self) { f in
                    HStack {
                        Label(f, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { Settings.watchedFolders.removeAll { $0 == f }; FolderWatcher.shared.reload(); tick += 1 }.buttonStyle(.glass)
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        Settings.watchedFolders.append(url.path)
                        FolderWatcher.shared.reload()
                        tick += 1
                    }
                }
                .buttonStyle(.glass)
                note("New audio/video files are transcribed automatically and a .txt and .srt are written next to them.")
            }
        case "Shortcuts":
            GlassGroup(title: "URL scheme (Shortcuts, Raycast, Alfred)") {
                ForEach(["meeting/start", "meeting/stop", "meeting/toggle", "dictation/toggle", "transcribe?path=/file.m4a", "panel"], id: \.self) {
                    Text("earshot://\($0)").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
        case "Storage":
            StorageSettings()
        case "Advanced":
            GlassGroup {
                LabeledContent("Data folder") { Text(Paths.support.path).textSelection(.enabled).font(.caption) }
                Button("Show in Finder") { NSWorkspace.shared.open(Paths.support) }.buttonStyle(.glass)
            }
        case "Microphone":
            GlassGroup {
                toggle("Echo cancellation", Settings.echoCancellation) { Settings.echoCancellation = $0 }
                LabeledContent("Your speaker name") {
                    TextField("Me", text: Binding(get: { Settings.myName }, set: { Settings.myName = $0.isEmpty ? "Me" : $0 })).frame(width: 200)
                }
                note("Uses the system default input device. Echo cancellation uses FluidAudio LocalVQE with everything the Mac plays as the reference.")
            }
        case "Live Captions":
            GlassGroup {
                note("Live Captions transcribe your microphone and all system audio in a floating window without saving anything.")
                let busy = state.meeting != nil && state.meeting?.platform != "Live Captions"
                Button(state.meeting?.platform == "Live Captions" ? "Stop Live Captions" : "Start Live Captions") { state.toggleLiveCaptions() }
                    .buttonStyle(.glassProminent).disabled(busy)
                    .help(busy ? "Stop the current recording first" : "")
            }
        case "Dictation":
            GlassGroup {
                toggle("Copy dictated text to the clipboard", Settings.copyDictationToClipboard) { Settings.copyDictationToClipboard = $0 }
                let memo = state.recordingKind == "voicememo"
                Button(state.recordingKind == "dictation" ? "Stop Dictation" : "Try Dictation") { state.toggleDictation() }
                    .buttonStyle(.glassProminent).disabled(memo)
                    .help(memo ? "A voice memo is recording; stop it first" : "")
                note("Start and stop dictation from the menu bar, the API (POST /v1/dictation/start|stop) or earshot://dictation/toggle.")
            }
        case "Record Meetings":
            MeetingSettings()
        case "Note Taker":
            NoteTakerSettings()
        case "Custom Vocabulary":
            VocabularySettings()
        case "Local Models":
            LocalModelsPage()
        case "Cloud Models":
            GlassGroup { note("Earshot transcribes on this Mac only, with FluidAudio. Cloud speech services are not used.") }
        case "People":
            GlassGroup {
                ForEach(state.people) { p in
                    HStack {
                        Circle().fill(SpeakerColor.of(p.name)).frame(width: 10, height: 10)
                        Text(p.name)
                        Spacer()
                        Button("Remove") { state.deletePerson(p) }.buttonStyle(.glass)
                    }
                }
                HStack {
                    TextField("Add a person…", text: $newItem).textFieldStyle(.roundedBorder)
                        .onSubmit { state.addPerson(newItem); newItem = "" }
                    Button("Add") { state.addPerson(newItem); newItem = "" }.buttonStyle(.glass)
                }
                note("People can be assigned to speakers in any transcript by clicking the speaker label.")
            }
        case "Translation":
            GlassGroup {
                note("Translate any finished transcript with Translate… in its inspector; the translation is saved as a new transcript. Translating is a separate step on this Mac with Apple's Translation (API: POST /v1/transcripts/{id}/translate). POST /v1/audio/translations translates to English: with Whisper (any language but English) in the same pass, otherwise with Apple's Translation after Parakeet. Install language pairs in System Settings → General → Language & Region → Translation Languages.")
            }
        case "Ignored Segments":
            listEditor(Settings.ignoredSegments, placeholder: "Segment text to ignore, e.g. “Thank you for watching.”") {
                Settings.ignoredSegments = $0
            }
        case "Find & Replace":
            GlassGroup {
                ForEach(Array(Settings.findReplace.enumerated()), id: \.offset) { i, pair in
                    HStack {
                        Text(pair.first ?? ""); Image(systemName: "arrow.right"); Text(pair.last ?? "")
                        Spacer()
                        Button("Remove") { var all = Settings.findReplace; all.remove(at: i); Settings.findReplace = all; tick += 1 }.buttonStyle(.glass)
                    }
                }
                HStack {
                    TextField("Find", text: $newItem).textFieldStyle(.roundedBorder)
                    TextField("Replace with", text: $newReplace).textFieldStyle(.roundedBorder)
                    Button("Add") {
                        guard !newItem.isEmpty else { return }
                        Settings.findReplace.append([newItem, newReplace]); newItem = ""; newReplace = ""; tick += 1
                    }
                    .buttonStyle(.glass)
                }
                note("Applied to every new transcript, e.g. “Ear shot” → “Earshot”.")
            }
        case "Export Formats", "Auto-Export":
            GlassGroup {
                HStack {
                    ForEach(["txt", "srt", "vtt", "md", "json"], id: \.self) { f in
                        Toggle(f.uppercased(), isOn: Binding(get: { Settings.autoExportFormats.contains(f) }, set: {
                            var all = Set(Settings.autoExportFormats); if $0 { all.insert(f) } else { all.remove(f) }
                            Settings.autoExportFormats = Array(all).sorted(); tick += 1
                        }))
                        .toggleStyle(.button)
                    }
                }
                LabeledContent("Auto-export folder") {
                    HStack {
                        Text(Settings.autoExportFolder ?? "Off").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK { Settings.autoExportFolder = panel.url?.path; tick += 1 }
                        }
                        .buttonStyle(.glass)
                        if Settings.autoExportFolder != nil { Button("Off") { Settings.autoExportFolder = nil; tick += 1 }.buttonStyle(.glass) }
                    }
                }
                note("Every finished transcript is also written to this folder in the selected formats.")
            }
            GlassGroup(title: "Obsidian") {
                toggle("Link people for Obsidian", Settings.obsidianLinks) { Settings.obsidianLinks = $0 }
                note("Markdown writes participants and speakers as [[Name]], in the front matter and in front of each paragraph, so every person gets a page of their meetings.")
                LabeledContent("Add meetings to the daily note") {
                    HStack {
                        Text(Settings.obsidianDailyNote ?? "Off").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            panel.message = "Choose the folder with your daily notes (YYYY-MM-DD.md)"
                            if panel.runModal() == .OK { Settings.obsidianDailyNote = panel.url?.path; tick += 1 }
                        }
                        .buttonStyle(.glass)
                        if Settings.obsidianDailyNote != nil { Button("Off") { Settings.obsidianDailyNote = nil; tick += 1 }.buttonStyle(.glass) }
                    }
                }
                note("After Auto-Export, each meeting is added to that day's note as “- [[file]] 14:30 Title (participants)”. Lines are only ever appended; the note is created if it doesn't exist.")
            }
            GlassGroup {
                toggle("Start TXT files with the title, date and participants", Settings.txtHeader) { Settings.txtHeader = $0 }
                note("Text and Markdown keep each speaker's turn in one paragraph; a new one starts when the speaker changes, after a pause of more than 10 seconds, or after about two minutes.")
            }
        case "Batch Export":
            GlassGroup {
                note("Export every transcript in your library at once: pick the formats, then a folder. One file per transcript and format.")
                Button("Export All Transcripts…") { batchExport = true }.buttonStyle(.glassProminent)
            }
            .sheet(isPresented: $batchExport) { BatchExportSheet(items: state.transcripts) }
        case "Integrations":
            GlassGroup(title: "Local API") {
                LabeledContent("Base URL") { Text(state.baseURL).textSelection(.enabled) }
                LabeledContent("Status") { Text(state.serverRunning ? "Running (loopback only)" : (state.serverError ?? "Stopped")) }
                LabeledContent("Discovery file") { Text(Paths.apiInfo.path).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("Copy Token") { state.copy(API.token) }.buttonStyle(.glass)
                    Button("Copy curl Example") {
                        state.copy("curl -s \(state.baseURL)/v1/audio/transcriptions -H \"Authorization: Bearer \(API.token)\" -F file=@meeting.m4a")
                    }
                    .buttonStyle(.glass)
                }
                note("Live meeting events as Server-Sent Events: GET /v1/events?filter=meeting. Full reference in the README.")
            }
            WebhookSettings()
            GlassGroup(title: "MCP server (Claude Code, Claude Desktop)") {
                let command = (Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("earshot-mcp").path) ?? "earshot-mcp"
                Text("claude mcp add earshot -- \"\(command)\"").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("Copy Command") { state.copy("claude mcp add earshot -- \"\(command)\"") }.buttonStyle(.glass)
                note("Lets Claude search your meetings, read transcripts, and start, stop or bookmark a meeting. It talks to the local API with the token from the discovery file.")
            }
        default:
            GlassGroup {
                Text("Earshot \(appVersion)").font(.title2.bold())
                note("On-device meeting and audio transcription for macOS, with a local API for your other apps. Engines: FluidAudio (Parakeet v3, pyannote, LocalVQE) and WhisperKit (Whisper large-v3-turbo).")
                Button("Open README") { state.openSupport() }.buttonStyle(.glass)
            }
            UpdaterSettingsView()
            DiagnosticsSettings()
        }
    }

    private func toggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        SwitchRow(title: title, isOn: Binding(get: { value }, set: { set($0); tick += 1 }))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func listEditor(_ items: [String], placeholder: String, save: @escaping ([String]) -> Void) -> some View {
        GlassGroup {
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item)
                    Spacer()
                    Button("Remove") { save(items.filter { $0 != item }); tick += 1 }.buttonStyle(.glass)
                }
            }
            HStack {
                TextField(placeholder, text: $newItem).textFieldStyle(.roundedBorder)
                Button("Add") { if !newItem.isEmpty { save(items + [newItem]); newItem = ""; tick += 1 } }.buttonStyle(.glass)
            }
            note("Segments whose text matches exactly are removed from new transcripts.")
        }
    }
}

private struct MeetingSettings: View {
    @Environment(AppState.self) private var state
    @AppStorage("meetingMode") private var mode = "ask"
    @State private var apps = Set(Settings.meetingApps)
    @State private var tick = 0

    var body: some View {
        let _ = tick
        GlassGroup {
            Picker("When a meeting is detected", selection: $mode) {
                Text("Show an alert").tag("ask")
                Text("Record automatically").tag("auto")
                Text("Do nothing").tag("off")
            }
            row("Stop recording 10 seconds after a meeting ends. Dismiss the alert to keep recording.", Settings.autoStopAfterMeeting) { Settings.autoStopAfterMeeting = $0 }
            row("Show options before joining a Meet call", Settings.preJoinOverlay) { Settings.preJoinOverlay = $0 }
            explain("On Google Meet's “Ready to join?” screen, pick the language and whether to record, show Live Captions or do nothing. Earshot remembers the choice for that meeting and its series. Needs Accessibility access.")
            row("Automatically dismiss detected meeting alerts after 10 seconds", Settings.autoDismissMeetingAlerts) { Settings.autoDismissMeetingAlerts = $0 }
            row("Speaker detection (Speaker 1, 2, … for the other participants)", Settings.diarizeMeetings) { Settings.diarizeMeetings = $0 }
            row("Smart meeting titles from your calendar", Settings.useCalendarTitles) { Settings.useCalendarTitles = $0 }
            LabeledContent("Name for the other participants") {
                TextField("Meeting Participants", text: Binding(get: { Settings.participantsName }, set: { Settings.participantsName = $0.isEmpty ? "Meeting Participants" : $0 }))
                    .frame(width: 220)
            }
        }
        GlassGroup(title: "During calls") {
            row("Use the meeting's caption language", Settings.followMeetingLanguage) { Settings.followMeetingLanguage = $0 }
            explain("When Google Meet's captions are set to another language, the meeting is transcribed in that language instead of the one picked in Earshot.")
            row("Don't record my microphone while I'm muted", Settings.respectMute) { Settings.respectMute = $0 }
            explain("While you're muted in the meeting app, silence is recorded instead of your microphone, so side conversations stay out of the transcript.")
            row("Save Live Captions of calls as meetings", Settings.keepLiveCaptionsOfCalls) { Settings.keepLiveCaptionsOfCalls = $0 }
            explain("Live Captions started during a call are saved to Meetings when they stop. Other Live Captions are never saved unless you click Save as meeting.")
            row("Turn on Meet captions automatically", Settings.autoEnableCaptions) { Settings.autoEnableCaptions = $0 }
            explain("Switches on Meet's captions (CC) when you join. They show only on your screen and let Earshot name who is speaking.")
            row("Warn when Meet can't be read", Settings.meetHealthWarnings) { Settings.meetHealthWarnings = $0 }
            explain("A note in the live panel when captions are off or Meet's page can't be read, so speaker names don't go missing silently.")
            row("Use names and agenda words as transcription hints", Settings.roomVocabulary) { Settings.roomVocabulary = $0 }
            explain("Participant names, the calendar event and chat words help the speech model spell them right in this meeting.")
            row("Fix name spellings from Meet captions", Settings.captionSpelling) { Settings.captionSpelling = $0 }
            explain("Where a word is uncertain, the spelling Meet's captions used for a name or term at that moment is taken instead.")
        }
        GlassGroup(title: "Apps to observe") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 8) {
                ForEach(MeetingApp.known, id: \.bundleID) { app in
                    Toggle(app.name, isOn: Binding(get: { apps.contains(app.bundleID) }, set: { on in
                        if on { apps.insert(app.bundleID) } else { apps.remove(app.bundleID) }
                        Settings.meetingApps = MeetingApp.known.map(\.bundleID).filter { apps.contains($0) }
                    }))
                }
            }
            Text("A meeting is detected when one of these apps starts using the microphone (the orange dot). For browsers that means any site using the mic, e.g. Google Meet.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { apps = Set(Settings.meetingApps); tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            apps = Set(Settings.meetingApps); tick += 1
        }
    }

    private func row(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        SwitchRow(title: title, isOn: Binding(get: { value }, set: { set($0); tick += 1 }))
    }

    private func explain(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, -8)
    }
}

private struct LocalModelsPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let used = state.modelBytes.values.reduce(0, +)
        GlassGroup(title: "FluidAudio") {
            ForEach(ModelCatalog.all.filter { $0.id != ModelCatalog.whisper.id }) { ModelRow(model: $0) }
        }
        GlassGroup(title: "WhisperKit") {
            ModelRow(model: ModelCatalog.whisper)
            Text(LanguageMenu.whisperNote + ". It downloads the first time one is picked.")
                .font(.callout).foregroundStyle(.secondary)
        }
        GlassGroup {
            LabeledContent("Storage used") { Text(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)).monospacedDigit() }
            HStack {
                Button("Show Speech Models") { NSWorkspace.shared.open(ModelCatalog.fluidAudioModels) }.buttonStyle(.glass)
                if (state.modelBytes[ModelCatalog.whisper.id] ?? 0) > 0 {
                    Button("Show Whisper") { NSWorkspace.shared.open(ModelCatalog.whisperKitModels) }.buttonStyle(.glass)
                }
            }
            Text("Nothing ships with the app. The speech models (≈ 525 MB) download on first launch.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One model: name, purpose, size, status and Download / Delete.
struct ModelRow: View {
    @Environment(AppState.self) private var state
    let model: ModelInfo

    var body: some View {
        let onDisk = state.modelBytes[model.id] ?? 0
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.headline)
                Text(model.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = state.downloads[model.id] {
                ProgressView(value: p).frame(width: 120)
                Text("\(Int(p * 100))%").monospacedDigit().frame(width: 40)
            } else if onDisk > 0 {
                Text(ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file)).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Delete") { state.deleteModel(model.id) }.buttonStyle(.glass)
            } else {
                Text(model.sizeText).foregroundStyle(.secondary).monospacedDigit()
                Button("Download") { state.downloadModel(model.id) }.buttonStyle(.glass)
            }
        }
    }
}

private struct NoteTakerSettings: View {
    @Environment(AppState.self) private var state
    @State private var tick = 0
    @State private var voices = Store.shared.voices().keys.sorted()

    var body: some View {
        let _ = tick
        GlassGroup(title: "After the meeting") {
            row("Polish the transcript after Stop: re-transcribe both recordings in one clean pass (better text and speakers than the live version)",
                Settings.polishAfterMeeting) { Settings.polishAfterMeeting = $0 }
            note("The live transcript is saved right away; the polished one replaces it about a minute later. Auto-Export, webhooks and meeting.finalized wait for it.")
        }
        GlassGroup(title: "Speaker names") {
            row("Name speakers from Google Meet captions", Settings.autoNameSpeakers) { Settings.autoNameSpeakers = $0 }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let trusted = MeetCaptionWatcher.trusted
                // Granted before (or asked for and maybe switched on) but not trusted now: an update with a new
                // signature keeps the old entry in the list without it applying to this build.
                let stale = !trusted && (UserDefaults.standard.bool(forKey: Self.grantedKey) || state.meeting?.captionsNeedAccess == true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(trusted ? .green : .orange)
                        Text(trusted ? "Accessibility access granted" : stale ? "Accessibility access isn't active" : "Needs Accessibility access to read Meet's captions")
                        Spacer()
                        if stale {
                            Button("Open Accessibility Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.glass)
                        } else if !trusted {
                            Button("Grant Access…") { MeetCaptionWatcher.ask() }.buttonStyle(.glass)
                        }
                    }
                    if stale {
                        note("Access isn't active for this version — remove Earshot from the list in System Settings → Privacy & Security → Accessibility and add it again.")
                    } else if !trusted {
                        note("Click Grant Access, then switch on Earshot in the list (it's listed as Earshot, not Note Taker). If it still isn't there, click + under the list and choose Earshot.app. If Earshot is already switched on, an update can leave the old grant inactive: remove it with − and add it again.")
                    }
                }
                .task(id: trusted) { if trusted { UserDefaults.standard.set(true, forKey: Self.grantedKey) } }
            }
            note("Turn on captions (CC) in Meet. Meet shows each caption under the speaker's name; Earshot uses that only to put names on Speaker 1, 2, …. Captions text is not used and nothing leaves your Mac.")
            row("Remember voices and recognise people in later meetings", Settings.rememberVoices) { Settings.rememberVoices = $0 }
            if !voices.isEmpty {
                ForEach(voices, id: \.self) { name in
                    HStack {
                        Image(systemName: "waveform.circle").foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        Button("Forget") { Store.shared.forgetVoice(name); voices = Store.shared.voices().keys.sorted() }.buttonStyle(.glass)
                    }
                }
            }
            note("A voice is saved when captions name a speaker or when you assign a person to a speaker in a transcript.")
        }
        GlassGroup(title: "During the meeting") {
            row("⌃⌘B adds a bookmark from any app", Settings.bookmarkHotkey) {
                Settings.bookmarkHotkey = $0
                BookmarkHotkey.shared.update()
            }
            row("Warn when the microphone or the meeting app goes silent", Settings.audioWarnings) { Settings.audioWarnings = $0 }
            note("Notes typed in the meeting panel and bookmarks are kept with the transcript, exported to Markdown and sent with webhooks.")
        }
    }

    static let grantedKey = "accessibilityGrantedOnce"

    private func row(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        SwitchRow(title: title, isOn: Binding(get: { value }, set: { set($0); tick += 1 }))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct VocabularySettings: View {
    @Environment(AppState.self) private var state
    @State private var words = Settings.vocabulary
    @State private var newWord = ""

    var body: some View {
        GlassGroup {
            Text("Names and terms the speech model gets wrong: people, products, projects (e.g. Kubernetes, Figma, your colleagues' names). They are applied in the final pass of meetings and to file transcriptions.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Add a word or name…", text: $newWord).onSubmit(add)
                Button("Add", action: add).buttonStyle(.glass)
            }
            ForEach(words, id: \.self) { w in
                HStack {
                    Text(w)
                    Spacer()
                    Button { words.removeAll { $0 == w }; save() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        .help("Remove").accessibilityLabel("Remove \(w)")
                }
            }
        }
        GlassGroup(title: "Model") {
            ModelRow(model: ModelCatalog.vocabulary)
            Text("Needs Parakeet CTC 110M (≈ 100 MB). It downloads when you add the first word. Whisper (languages other than English) gets the words as its prompt instead.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !words.contains(w) else { return }
        words.append(w)
        newWord = ""
        save()
    }

    private func save() {
        Settings.vocabulary = words
        if !words.isEmpty, state.downloads[ModelCatalog.vocabulary.id] == nil, (state.modelBytes[ModelCatalog.vocabulary.id] ?? 0) == 0 {
            state.downloadModel(ModelCatalog.vocabulary.id)
        } else {
            Task { try? await Engine.shared.prepareVocabulary() }
        }
    }
}

private struct WebhookSettings: View {
    @State private var urls = Settings.webhooks
    @State private var events = Set(Settings.webhookEvents)
    @State private var newURL = ""
    @State private var secret = Webhooks.secret
    static let choices = ["meeting.finalized", "meeting.saved", "meeting.started", "meeting.note", "meeting.warning", "job.done", "job.failed"]

    var body: some View {
        GlassGroup(title: "Webhooks") {
            Text("POST these events to other apps (a dashboard, a script, an agent). meeting.finalized and job.done include the full transcript.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Signing secret") {
                HStack {
                    Text(secret).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") { AppState.shared.copy(secret) }.buttonStyle(.glass)
                    Button("Rotate") { Webhooks.rotateSecret(); secret = Webhooks.secret }.buttonStyle(.glass)
                        .help("Make a new secret; receivers need the new one")
                }
            }
            Text("Receivers verify X-Earshot-Signature (HMAC-SHA256 of the body) with this secret. Rotating it invalidates the old one.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("http://127.0.0.1:3000/hooks/earshot", text: $newURL).onSubmit(add)
                Button("Add", action: add).buttonStyle(.glass)
            }
            ForEach(urls, id: \.self) { u in
                HStack {
                    Text(u).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button { urls.removeAll { $0 == u }; Settings.webhooks = urls } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        .help("Remove").accessibilityLabel("Remove \(u)")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], alignment: .leading, spacing: 6) {
                ForEach(Self.choices, id: \.self) { e in
                    Toggle(e, isOn: Binding(get: { events.contains(e) }, set: { on in
                        if on { events.insert(e) } else { events.remove(e) }
                        Settings.webhookEvents = Self.choices.filter { events.contains($0) }
                    }))
                }
            }
        }
    }

    private func add() {
        let u = newURL.trimmingCharacters(in: .whitespaces)
        guard let scheme = URL(string: u)?.scheme, ["http", "https"].contains(scheme), !urls.contains(u) else { return }
        urls.append(u)
        newURL = ""
        Settings.webhooks = urls
    }
}

/// Settings → Storage: compression, how long recordings are kept, and what they use on disk.
private struct StorageSettings: View {
    @State private var tick = 0
    @State private var used: Int64?
    @State private var olderThan = 30
    @State private var confirm = false
    @State private var working = false
    @State private var result: String?
    /// A shorter "Keep recordings for" that would delete recordings right away: asked first.
    @State private var shorter: Shorter?

    private struct Shorter: Equatable { var days: Int; var count: Int; var bytes: Int64 }

    var body: some View {
        let _ = tick
        GlassGroup(title: "Recordings") {
            SwitchRow(title: "Compress recordings after the transcript is done",
                      isOn: Binding(get: { Settings.compressRecordings }, set: { Settings.compressRecordings = $0; tick += 1 }))
            Text("Meeting audio is stored as AAC (.m4a) once the final transcript is saved, a fraction of the size. Playback and Re-transcribe still work.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, -8)
            Picker("Keep recordings for", selection: Binding(get: { Settings.keepAudioDays }, set: { days in
                guard days > 0 else { Settings.keepAudioDays = days; tick += 1; return }
                Task {
                    let (count, bytes) = await AudioRetention.preview(olderThan: days)
                    if count == 0 { Settings.keepAudioDays = days; tick += 1 } else { shorter = Shorter(days: days, count: count, bytes: bytes) }
                }
            })) {
                ForEach(AudioRetention.choices, id: \.self) { Text(AudioRetention.label($0)).tag($0) }
            }
            Text("Older recordings are deleted once a day; transcripts, notes and speakers stay. Transcripts with a favourite line keep their audio.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, -8)
        }
        GlassGroup(title: "Disk use") {
            LabeledContent("Recordings") {
                Text(used.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Measuring…").monospacedDigit()
            }
            HStack {
                Picker("Delete all recordings older than", selection: $olderThan) {
                    ForEach(AudioRetention.choices.dropFirst(), id: \.self) { Text(AudioRetention.label($0)).tag($0) }
                }
                .fixedSize()
                Button("Delete…") { confirm = true }.buttonStyle(.glass).disabled(working)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(Paths.meetings) }.buttonStyle(.glass)
            }
            if let result { Text(result).font(.callout).foregroundStyle(.secondary) }
        }
        .confirmationDialog("Delete all recordings older than \(AudioRetention.label(olderThan))?", isPresented: $confirm) {
            Button("Delete Recordings", role: .destructive) {
                working = true
                Task {
                    let (count, bytes) = await AudioRetention.run(olderThan: olderThan)
                    result = count == 0 ? "Nothing to delete." : "Deleted \(count) recording\(count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) freed."
                    working = false
                    await measure()
                }
            }
        } message: {
            Text("Transcripts are kept, and transcripts with a favourite line keep their audio. Deleted recordings can't be played or re-transcribed.")
        }
        .confirmationDialog(shorter.map { "Delete \($0.count) recording\($0.count == 1 ? "" : "s") now?" } ?? "",
                            isPresented: Binding(get: { shorter != nil }, set: { if !$0 { shorter = nil; tick += 1 } }), presenting: shorter) { s in
            Button("Keep for \(AudioRetention.label(s.days)) and Delete", role: .destructive) {
                Settings.keepAudioDays = s.days
                tick += 1
                working = true
                Task {
                    let (count, bytes) = await AudioRetention.run(olderThan: s.days)
                    result = count == 0 ? "Nothing to delete." : "Deleted \(count) recording\(count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) freed."
                    working = false
                    await measure()
                }
            }
        } message: { s in
            Text("\(s.count) recording\(s.count == 1 ? " is" : "s are") older than \(AudioRetention.label(s.days)) (\(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))) and will be deleted now. Transcripts are kept. Deleted recordings can't be played or re-transcribed.")
        }
        .task { await measure() }
    }

    private func measure() async {
        used = await Task.detached(priority: .utility) { AudioRetention.diskUse() }.value
    }
}

/// Settings → About: a plain-text report for bug reports (no token, no transcript text).
private struct DiagnosticsSettings: View {
    @State private var copied = false

    var body: some View {
        GlassGroup(title: "Diagnostics") {
            Text("Copies your Mac, audio devices, permissions, models, the key settings, the last meeting's warnings and the end of the debug log. Names, titles, meeting codes, transcript and chat text, device names and the API token are never included.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy Diagnostics") {
                    Task {
                        let report = await Diagnostics.report()
                        AppState.shared.copy(report)
                        copied = true
                    }
                }
                .buttonStyle(.glass)
                if copied { Label("Copied", systemImage: "checkmark").font(.callout).foregroundStyle(.green) }
            }
        }
    }
}
