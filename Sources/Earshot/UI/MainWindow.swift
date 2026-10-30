import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case home, queue, transcriptions, meetings, dictations, deleted
    case folder(String), person(String), transcript(String), series(String)
}

/// Main window: a floating glass sidebar on the left, the selected page on the right, all over the desktop
/// wallpaper. Titles, search and the record / model / language menus live in the window toolbar.
struct MainWindow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 220)
                .panel()
                .padding([.leading, .bottom], 10)
                .padding(.top, 4)
            Page()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background { Backdrop() }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $state.search, placement: .toolbar, prompt: "Search transcripts")
        .toolbar { MainToolbar() }
        .fileImporter(isPresented: $state.showImporter, allowedContentTypes: [.audio, .movie, .audiovisualContent],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { state.transcribe(files: urls) }
        }
        .sheet(isPresented: $state.showAppAudioPicker) { AppAudioPicker() }
    }

    private var title: String {
        switch state.route {
        case .home: "Overview"
        case .queue: "Queue"
        case .transcriptions: "Transcriptions"
        case .meetings: "Meetings"
        case .dictations: "Dictations"
        case .deleted: "Recently Deleted"
        case .folder(let id): state.folders.first { $0.id == id }?.name ?? "Folder"
        case .person(let name): name
        case .series(let key): state.seriesGroups[key].map { Series.name($0, in: state.transcripts) } ?? "Series"
        case .transcript: state.currentTranscript?.title ?? "Transcript"
        }
    }

    private var subtitle: String {
        if let m = state.meeting { return state.willSave(m) ? "Recording \(m.isLiveCaptions ? "Live Captions" : m.title)" : "Live Captions — not saved" }
        if case .transcript = state.route, let t = state.currentTranscript {
            return t.createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Earshot"
    }
}

private struct Page: View {
    @Environment(AppState.self) private var state
    @AppStorage("meetingMode") private var meetingMode = "ask"

    var body: some View {
        switch state.route {
        case .transcript(let id):
            if let t = state.transcripts.first(where: { $0.id == id }) ?? state.deleted.first(where: { $0.id == id }) {
                TranscriptDetail(transcript: t).id(t.id)
                    .padding([.horizontal, .bottom], 10)
            } else {
                EmptyStateView(symbol: "doc", title: "Not Found", message: "This transcript was deleted.")
            }
        default:
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.route {
        case .home: HomeView()
        case .queue: QueueView()
        case .transcriptions:
            LibraryList(items: state.transcripts.filter { !["meeting", "dictation"].contains($0.origin) },
                        empty: ("text.alignleft", "No Transcripts", "Open a file or start a recording to get started.", nil))
        case .meetings:
            VStack(alignment: .leading, spacing: 8) {
                if state.search.isEmpty { SeriesStrip() }
                LibraryList(items: state.transcripts.filter { $0.origin == "meeting" },
                            empty: ("person.2.wave.2", "No Meetings Yet", "Earshot notices when a call starts in Meet, Zoom, Teams and others.",
                                    meetingMode == "off" ? ("Enable Meeting Alerts", { meetingMode = "ask"; state.toast("Meeting alerts enabled") }) : nil))
            }
        case .dictations:
            LibraryList(items: state.transcripts.filter { $0.origin == "dictation" },
                        empty: ("character.cursor.ibeam", "No Dictations Yet", "Text you dictate will appear here.",
                                ("Set Up Dictation", { state.openSettings("Dictation") })))
        case .deleted: DeletedList()
        case .folder(let id):
            LibraryList(items: state.transcripts.filter { $0.folderID == id },
                        empty: ("folder", "Empty Folder", "Drag transcripts here or use “Move to Folder”.", nil))
        case .person(let name):
            LibraryList(items: state.transcripts.filter { $0.segments.contains { $0.speaker == name } },
                        empty: ("person", "No Transcripts", "\(name) hasn't been assigned to a speaker yet.", nil))
        case .series(let key):
            let ids = Set(state.seriesGroups[key] ?? [])
            LibraryList(items: state.transcripts.filter { ids.contains($0.id) },
                        empty: ("repeat", "No Meetings", "This series has no meetings left.", nil))
        case .transcript: EmptyView()
        }
    }
}

/// Meetings page: recurring meetings (two or more of one calendar series or title), newest first.
private struct SeriesStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Each series' newest meeting, looked up once (not per comparison).
        let ids = Set(state.seriesGroups.values.compactMap(\.first))
        let newest = Dictionary(state.transcripts.lazy.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = state.seriesGroups.sorted { a, b in
            (a.value.first.flatMap { newest[$0]?.createdAt } ?? .distantPast) > (b.value.first.flatMap { newest[$0]?.createdAt } ?? .distantPast)
        }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Series", detail: "\(groups.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8, alignment: .top)], spacing: 8) {
                    ForEach(groups, id: \.key) { key, ids in
                        let latest = ids.first.flatMap { newest[$0] }
                        Button { state.navigate(.series(key)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "repeat").foregroundStyle(.tint).frame(width: 28, height: 28)
                                    .background(.fill.quaternary, in: ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(latest.map { $0.context?.calendar?.title ?? $0.title } ?? "Series").font(.headline).lineLimit(1)
                                    Text("\(ids.count) meetings" + (latest.map { " · last " + $0.createdAt.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .card(padding: 10, interactive: true)
                    }
                }
            }
        }
    }
}

// MARK: - Toolbar

private struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var state

    var body: some ToolbarContent {
        if case .transcript = state.route {
            ToolbarItem(placement: .navigation) {
                Button { state.back() } label: { Label("Back", systemImage: "chevron.backward") }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let m = state.meeting {
                let saved = state.willSave(m)
                Button { MeetingPanel.shared.show() } label: {
                    Label(saved ? "Recording" : "Live Captions (not saved)", systemImage: saved ? "record.circle.fill" : "captions.bubble")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(saved ? .red : .orange)
                }
                .help(saved ? "Recording — show the live transcript" : "Live Captions are shown, not saved. Show them")
                if m.isLiveCaptions, !saved, !m.stopping {
                    Button { state.keepLiveCaptions() } label: { Label("Save as Meeting", systemImage: "square.and.arrow.down") }
                        .help("Keep these Live Captions: they're saved to Meetings when they stop")
                }
                if m.stopping {
                    Button {} label: { Label(saved ? "Saving…" : "Stopping…", systemImage: "hourglass") }
                        .disabled(true)
                        .help(saved ? "Saving the meeting" : "Stopping Live Captions")
                } else {
                    Button(role: .destructive) { state.stopMeeting() } label: { Label("Stop", systemImage: "stop.fill") }
                        .tint(.red)
                        .help(saved ? "Stop and save the meeting" : "Stop Live Captions (nothing is saved)")
                }
            } else {
                RecordMenu()
            }
            Button { state.showImporter = true } label: { Label("Open Files", systemImage: "folder.badge.plus") }
                .help("Transcribe audio or video files")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            ModelMenu()
            LanguageMenu()
        }
    }
}

private struct RecordMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Only one recording at a time: starting another would silently reuse (or stop) the running one.
        let dictating = state.recordingKind == "dictation"
        let busy = state.recordingKind != nil || state.meeting != nil
        Menu {
            Section("Meeting") {
                ForEach(MeetingApp.known.filter { !$0.isBrowser || $0.bundleID == "com.google.Chrome" }, id: \.bundleID) { app in
                    Button(app.bundleID == "com.google.Chrome" ? "Google Meet (Chrome)" : app.name) { state.startMeeting(app: app.bundleID) }
                        .disabled(busy)
                }
            }
            Section {
                Button(state.recordingKind == "voicememo" ? "Stop Voice Memo" : "Voice Memo", systemImage: "mic") { state.toggleVoiceMemo() }
                    .disabled(dictating || state.meeting != nil)
                Button("App Audio…", systemImage: "app.badge") { state.showAppAudioPicker = true }.disabled(busy)
                Button("Podcast (Mic + System)", systemImage: "person.2.wave.2") { state.startPodcast() }.disabled(busy)
                Button("Live Captions", systemImage: "captions.bubble") { state.toggleLiveCaptions() }.disabled(busy)
            }
            if busy {
                Section { Text(dictating ? "Dictation is running" : "A recording is running") }
            }
        } label: {
            Label("Record", systemImage: state.recordingKind == nil ? "record.circle" : "stop.circle.fill")
        }
        .help("Start a recording")
    }
}

private struct ModelMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let model = state.speechModel
        Menu {
            ForEach([ModelCatalog.parakeet, ModelCatalog.whisper]) { m in
                if m.id == model.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
            }
            Text("English and Auto Detect use Parakeet, other languages Whisper")
            Divider()
            Button("Manage Models…") { state.openSettings("Local Models") }
        } label: {
            Label(state.downloads[model.id].map { "Downloading \(Int($0 * 100))%" }
                  ?? (state.speechModelReady ? state.speechModelShortName : "No model"), systemImage: "waveform.badge.mic")
                .labelStyle(.titleAndIcon)
        }
        .help("Speech model")
    }
}

struct LanguageMenu: View {
    @Environment(AppState.self) private var state
    static let languages: [(String, String)] = [("auto", "Auto Detect"), ("en", "English"), ("nl", "Dutch"), ("fr", "French"),
                                                ("de", "German"), ("it", "Italian"), ("pl", "Polish"), ("pt", "Portuguese"),
                                                ("ro", "Romanian"), ("es", "Spanish"), ("sv", "Swedish"), ("uk", "Ukrainian")]
    static let whisperNote = "Languages other than English use Whisper (\(ModelCatalog.whisper.sizeText) download)"

    var body: some View {
        Menu {
            ForEach(Self.languages, id: \.0) { code, name in
                Button { state.language = code } label: {
                    if state.language == code { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Text(Self.whisperNote)
            if let p = state.downloads[ModelCatalog.whisper.id] { Text("Downloading Whisper… \(Int(p * 100))%") }
        } label: {
            Label(Self.languages.first { $0.0 == state.language }?.1 ?? state.language, systemImage: "globe")
                .labelStyle(.titleAndIcon)
        }
        .help("Transcription language")
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppState.self) private var state
    @Namespace private var selection
    @State private var newFolder = false
    @State private var folderName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row("Overview", "square.grid.2x2", .home)
                row("Queue", "checklist", .queue, badge: state.activeJobs)

                if !state.openIDs.isEmpty {
                    SectionLabel(text: "Open")
                    ForEach(state.openIDs, id: \.self) { id in
                        if let t = state.transcripts.first(where: { $0.id == id }) {
                            row(t.title, "doc.text", .transcript(id), closable: id)
                        }
                    }
                }

                SectionLabel(text: "Library")
                row("Meetings", "person.2.wave.2", .meetings, live: state.meeting.map(state.willSave) ?? false)
                row("Transcriptions", "text.alignleft", .transcriptions)
                row("Dictations", "character.cursor.ibeam", .dictations)
                row("Recently Deleted", "trash", .deleted)

                HStack {
                    SectionLabel(text: "Folders")
                    Button { newFolder = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).padding(.trailing, 10).padding(.top, 10)
                        .help("New folder")
                        .accessibilityLabel("New folder")
                }
                ForEach(state.folders) { f in
                    row(f.name, "folder", .folder(f.id))
                        .contextMenu { Button("Delete Folder", role: .destructive) { state.deleteFolder(f) } }
                        .dropDestination(for: String.self) { ids, _ in
                            ids.forEach { state.move($0, to: f.id) }
                            return true
                        }
                }

                if !state.people.isEmpty {
                    SectionLabel(text: "People")
                    ForEach(state.people) { p in
                        row(p.name, "person.crop.circle", .person(p.name))
                            .contextMenu { Button("Remove", role: .destructive) { state.deletePerson(p) } }
                    }
                }
            }
            .padding(8)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) { SidebarStatus() }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { state.createFolder(folderName); folderName = "" }
            Button("Cancel", role: .cancel) { folderName = "" }
        }
    }

    private func row(_ title: String, _ icon: String, _ route: Route, badge: Int = 0, live: Bool = false, closable: String? = nil) -> some View {
        SidebarRow(title: title, icon: icon, badge: badge, live: live, selected: state.route == route, ns: selection,
                   onClose: closable.map { id in { state.close(id) } }) {
            withAnimation(.bouncy(duration: 0.4, extraBounce: 0.1)) { state.navigate(route) }
        }
    }
}

/// One selection background that slides between rows.
private struct SidebarRow: View {
    let title: String
    let icon: String
    let badge: Int
    let live: Bool
    let selected: Bool
    let ns: Namespace.ID
    let onClose: (() -> Void)?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if live { PulseDot(color: .red, pulsing: true, size: 6) }
                if badge > 0 { Text("\(badge)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .fontWeight(selected ? .semibold : .regular)
            .padding(.leading, 10)
            .padding(.trailing, onClose == nil ? 10 : 28)
            .padding(.vertical, 7)
            .contentShape(.rect)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.fill.secondary)
                        .matchedGeometryEffect(id: "selection", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        // A sibling of the row button, not inside its label, so the click can't reach the row's action.
        .overlay(alignment: .trailing) {
            if let onClose, hover || selected {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 10)
                    .help("Close")
                    .accessibilityLabel("Close \(title)")
            }
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// Bottom of the sidebar: what's running, the model, the local API, and Settings.
private struct SidebarStatus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let m = state.meeting {
                let saved = state.willSave(m)
                Button { MeetingPanel.shared.show() } label: {
                    HStack(spacing: 6) {
                        if saved { PulseDot(color: .red, pulsing: true, size: 7) } else { Image(systemName: "captions.bubble").foregroundStyle(.orange) }
                        TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                            Text("\(saved ? m.appName : "Live Captions, not saved") · \(Fmt.clock(ctx.date.timeIntervalSince(m.startedAt)))").monospacedDigit()
                        }
                        Spacer()
                    }
                    .font(.caption.weight(.medium))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if let p = state.downloads[state.speechModel.id] {
                status("Speech model", "\(Int(p * 100))%")
                LevelBar(value: p, height: 4)
            } else {
                status("Speech model", state.speechModelReady ? "Ready" : "Not downloaded", color: state.speechModelReady ? .green : .orange)
            }
            status("Local API", state.serverRunning ? ":\(Settings.port)" : "Off", color: state.serverRunning ? .green : .red)
            Divider()
            HStack {
                Button { state.openSettings(nil) } label: { Label("Settings", systemImage: "gearshape") }
                Spacer()
                Button { state.openSupport() } label: { Image(systemName: "questionmark.circle") }
                    .help("Help")
                    .accessibilityLabel("Help")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
    }

    private func status(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.caption)
    }
}
