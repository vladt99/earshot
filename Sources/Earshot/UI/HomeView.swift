import SwiftUI
import UniformTypeIdentifiers

/// Overview: what's happening now, a few numbers, quick ways to start, and the latest transcripts.
struct HomeView: View {
    @Environment(AppState.self) private var state
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !state.lostGrants.isEmpty { PermissionsCard() }
            NowCard()
            if !state.speechReady || ModelCatalog.speech.contains(where: { state.downloads[$0.id] != nil }) {
                SetupCard()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .top)], spacing: 10) {
                MeetingsStat()
                LibraryStat()
                QueueStat()
                APIStat()
            }
            SectionTitle(title: "Start")
            QuickStart()
            let recent = state.filtered(state.transcripts)
            SectionTitle(title: "Recent", detail: recent.isEmpty ? nil : "\(recent.count) transcripts")
            if recent.isEmpty {
                EmptyStateView(symbol: "waveform.badge.plus", title: "No Transcripts",
                               message: "Join a call, drop a file here, or start a voice memo.",
                               action: state.recordingKind == nil && state.meeting == nil ? ("Start Voice Memo", { state.toggleVoiceMemo() }) : nil)
                    .card()
            } else {
                TranscriptGroups(items: Array(recent.prefix(40)))
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Card.radius, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .overlay(Text("Drop to transcribe").font(.title2.bold()))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { Task { @MainActor in state.transcribe(files: [u]) } }
                }
            }
            return true
        }
    }
}

/// The live meeting or recording, or what Earshot is waiting for.
private struct NowCard: View {
    @Environment(AppState.self) private var state
    @AppStorage("meetingMode") private var meetingMode = "ask"

    var body: some View {
        Group {
            if let m = state.meeting {
                let saved = state.willSave(m)
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(title: saved ? "Recording \(m.appName)" : "Live Captions — not saved", icon: saved ? "record.circle" : "captions.bubble") {
                        if !m.people.isEmpty {
                            Tag(text: "\(m.people.count) in call", color: .secondary)
                                .help(m.people.map(\.name).joined(separator: "\n"))
                        }
                        if m.selfMuted { Tag(text: "Muted", color: .orange).help("You're muted — your mic isn't recorded") }
                        if m.readingCaptions { Tag(text: "Names from captions", color: .green) }
                        TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                            Text(Fmt.clock(ctx.date.timeIntervalSince(m.startedAt))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        if saved { PulseDot(color: .red, pulsing: true) } else { Image(systemName: "captions.bubble").foregroundStyle(.orange) }
                        Text(m.title).font(.title3.weight(.semibold)).lineLimit(1)
                    }
                    SessionBanner(meeting: m, compact: true)
                    let recent = Formats.paragraphs(Array(m.lines.suffix(40))).suffix(2)
                    let tail = Array(m.lines.suffix(40))
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, p in
                        Text("\(tail[p[0]].speaker.map { "\($0): " } ?? "")\(p.map { tail[$0].text }.joined(separator: " "))")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: false).truncationMode(.head)
                    }
                    if m.lines.isEmpty { Text("Listening…").font(.callout).foregroundStyle(.secondary) }
                    if let w = m.warning { Label(w, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                    MeetHints(meeting: m, compact: true)
                    GlassEffectContainer {
                        HStack(spacing: 6) {
                            Button("Live Transcript") { MeetingPanel.shared.show() }
                            if m.stopping {
                                Button("Saving…") {}.disabled(true)
                            } else {
                                Button("Bookmark") { MeetingController.shared.addNote(nil, kind: "bookmark") }
                                Button("Stop") { state.stopMeeting() }.tint(.red)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(tint: saved ? .red : .orange)
            } else if let started = state.recordingStarted {
                HStack(spacing: 10) {
                    PulseDot(color: .red, pulsing: true)
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Text("Recording \(state.recordingKind == "voicememo" ? "voice memo" : "dictation") · \(Fmt.clock(ctx.date.timeIntervalSince(started)))")
                            .font(.headline).monospacedDigit()
                    }
                    Spacer()
                    Button("Stop & Transcribe") { state.recordingKind == "voicememo" ? state.toggleVoiceMemo() : state.toggleDictation() }
                        .buttonStyle(.glassProminent).tint(.red)
                }
                .card(tint: .red)
            } else {
                HStack(spacing: 10) {
                    PulseDot(color: meetingMode == "off" ? .gray : .green, pulsing: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meetingMode == "off" ? "Meeting alerts are off" : meetingMode == "auto" ? "Waiting for a call to record" : "Waiting for a call")
                            .font(.headline)
                        Text(meetingMode == "off"
                             ? "Start a recording from the toolbar, or turn alerts on in Settings → Record Meetings."
                             : "Earshot notices when Meet, Zoom, Teams, Webex, Slack or FaceTime start using the microphone.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .card()
            }
        }
        .animation(.smooth, value: state.meeting?.id)
    }
}

private struct MeetingsStat: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: .now)
        let meetings = state.transcripts.filter { $0.origin == "meeting" && week?.contains($0.createdAt) == true }
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Meetings this week", icon: "person.2.wave.2")
            BigNumber(text: "\(meetings.count)")
            Text(Fmt.hours(meetings.compactMap(\.duration).reduce(0, +)) + " recorded").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct LibraryStat: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Library", icon: "books.vertical")
            BigNumber(text: "\(state.transcripts.count)")
            Text(Fmt.hours(state.transcripts.compactMap(\.duration).reduce(0, +)) + " of audio").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct QueueStat: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Button { state.navigate(.queue) } label: {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(title: "Queue", icon: "checklist") {
                    if state.activeJobs > 0 { ProgressView().controlSize(.small) }
                }
                BigNumber(text: "\(state.activeJobs)", color: state.activeJobs > 0 ? .orange : .primary)
                Text(state.activeJobs > 0 ? "transcribing now" : state.engineState).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .card(interactive: true)
    }
}

private struct APIStat: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Local API", icon: "network") {
                PulseDot(color: state.serverRunning ? .green : .red, pulsing: false, size: 6)
            }
            Text(state.baseURL).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
            Text("\(Settings.webhooks.count) webhook\(Settings.webhooks.count == 1 ? "" : "s") · MCP server included").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Integrations…") { state.openSettings("Integrations") }
                .buttonStyle(.glass).controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// Buttons for the common ways to start, plus a field for links.
private struct QuickStart: View {
    @Environment(AppState.self) private var state
    @State private var url = ""

    var body: some View {
        // One recording at a time: starting another would silently reuse (or stop) the running one.
        let busyReason: String? = state.meeting != nil ? "A meeting is being recorded" :
            state.recordingKind == "dictation" ? "Dictation is running" :
            state.recordingKind == "voicememo" ? "A voice memo is recording" : nil
        VStack(alignment: .leading, spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(state.homeShortcuts, id: \.self) { id in
                        let name = MeetingApp.find(id)?.name ?? id
                        Button { state.startMeeting(app: id) } label: {
                            Label(id == "com.google.Chrome" ? "Google Meet" : name, systemImage: "video")
                        }
                        .disabled(busyReason != nil)
                        .help(busyReason.map { "\($0); stop it first" } ?? "Record a meeting in \(name)")
                        .contextMenu {
                            Button("Remove Shortcut", role: .destructive) { state.homeShortcuts.removeAll { $0 == id } }
                        }
                    }
                    Button { state.toggleVoiceMemo() } label: {
                        Label(state.recordingKind == "voicememo" ? "Stop Memo" : "Voice Memo",
                              systemImage: state.recordingKind == "voicememo" ? "stop.circle.fill" : "mic")
                    }
                    .disabled(busyReason != nil && state.recordingKind != "voicememo")
                    .help(state.recordingKind == "voicememo" ? "Stop and transcribe the voice memo"
                          : busyReason.map { "\($0); stop it first" } ?? "Record a voice memo")
                    Button { state.showImporter = true } label: { Label("Open Files", systemImage: "folder.badge.plus") }
                    Button { state.showAppAudioPicker = true } label: { Label("App Audio", systemImage: "app.badge") }
                        .disabled(busyReason != nil)
                        .help(busyReason.map { "\($0); stop it first" } ?? "Record what an app plays")
                    Menu {
                        ForEach(MeetingApp.known.filter { !state.homeShortcuts.contains($0.bundleID) }, id: \.bundleID) { app in
                            Button(app.name) { state.homeShortcuts.append(app.bundleID) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a meeting app shortcut")
                }
                .buttonStyle(.glass)
            }
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a YouTube, audio or video link", text: $url)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                if !url.isEmpty { Button("Transcribe", action: submit).buttonStyle(.glassProminent).controlSize(.small) }
            }
            .inset()
        }
        .card()
    }

    private func submit() {
        state.importURL(url)
        url = ""
    }
}

/// First launch: speech models downloading.
/// After an update macOS forgets Earshot's permissions (each ad hoc signed build is a new app to it).
private struct PermissionsCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Permissions", icon: "lock.shield")
            Text("Earshot was updated — macOS needs your permission again").font(.headline)
            Text("macOS treats each new version as a new app, so it forgot what you allowed before.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(state.lostGrants, id: \.self) { g in
                HStack {
                    Label(g == .microphone ? "Microphone" : "Accessibility", systemImage: g == .microphone ? "mic" : "accessibility")
                    Text(g == .microphone ? "records your side of calls" : "reads Meet for names, captions and mute")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow…") { state.restoreGrant(g) }.buttonStyle(.glass).controlSize(.small)
                }
            }
            HStack {
                Label("System Audio Recording", systemImage: "speaker.wave.2")
                Text("can't be checked: allow it again if calls record only your voice").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open…") { AppState.openPrivacyPane("Privacy_ScreenCapture") }.buttonStyle(.glass).controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Dismiss") { state.dismissLostGrants() }.buttonStyle(.glass).controlSize(.small)
            }
        }
        .card(tint: .orange)
    }
}

private struct SetupCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Setting up", icon: "arrow.down.circle")
            Text("Downloading the on-device speech models once (about 525 MB). Transcription starts as soon as Parakeet v3 is ready.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(ModelCatalog.speech) { m in
                HStack {
                    Text(m.name).frame(width: 190, alignment: .leading)
                    if let p = state.downloads[m.id] {
                        LevelBar(value: p)
                    } else if (state.modelBytes[m.id] ?? 0) > 0 {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                    } else {
                        Text("Waiting…").foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(m.sizeText).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                }
            }
        }
        .card(tint: .blue)
    }
}

/// Pick a running app whose audio to record.
struct AppAudioPicker: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let busy = state.meeting != nil || state.recordingKind != nil
        VStack(alignment: .leading, spacing: 12) {
            Text("Record App Audio").font(.title2.bold())
            Text("Records and transcribes everything the app plays. Your microphone is not recorded.").foregroundStyle(.secondary)
            if busy {
                Label("Another recording is running. Stop it first.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(spacing: 6) {
                    Button { state.startAppAudio(nil, name: "System Audio"); dismiss() } label: {
                        Label("All System Audio", systemImage: "speaker.wave.3").frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .buttonStyle(.plain).card(padding: 0, interactive: true).disabled(busy)
                    ForEach(apps, id: \.processIdentifier) { app in
                        Button { state.startAppAudio(app.bundleIdentifier, name: app.localizedName ?? "App"); dismiss() } label: {
                            HStack {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                Text(app.localizedName ?? app.bundleIdentifier ?? "")
                                Spacer()
                            }
                            .padding(8)
                        }
                        .buttonStyle(.plain).card(padding: 0, interactive: true).disabled(busy)
                    }
                }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction) }
        }
        .padding(22).frame(width: 420, height: 520)
    }
}

/// Export many transcripts at once.
struct BatchExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let items: [Transcript]
    @State private var formats: Set<String> = ["txt"]
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Batch Export").font(.title2.bold())
            Text("\(items.count) transcripts").foregroundStyle(.secondary)
            HStack {
                ForEach(["txt", "srt", "vtt", "md", "json"], id: \.self) { f in
                    Toggle(f.uppercased(), isOn: Binding(get: { formats.contains(f) }, set: { if $0 { formats.insert(f) } else { formats.remove(f) } }))
                        .toggleStyle(.button)
                }
            }
            if let result { Text(result).foregroundStyle(.green) }
            HStack {
                Spacer()
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Choose Folder & Export") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        let n = PostProcess.export(items, to: url, formats: Array(formats))
                        result = "Exported \(n) files to \(url.lastPathComponent)"
                    }
                }
                .buttonStyle(.glassProminent).disabled(formats.isEmpty || items.isEmpty)
            }
        }
        .padding(22).frame(width: 460)
    }
}
