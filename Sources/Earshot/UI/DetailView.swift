import AVFoundation
import SwiftUI

/// Plays a transcript's audio. Meetings mix both recordings (others + me) into one timeline.
@MainActor
@Observable
final class TranscriptPlayer {
    private(set) var player: AVPlayer?
    var time: Double = 0
    var duration: Double = 0
    var playing = false
    var rate: Float = 1
    /// The voice whose clip is playing ("Who is this?"); playback pauses at `clipEnd`.
    private(set) var clipLabel: String?
    private var clipEnd: Double?
    private var observer: Any?
    private var stopped = false

    func load(_ t: Transcript) {
        stopped = false
        let urls = AudioRetention.tracks(t)
        guard !urls.isEmpty else { return }
        Task {
            let composition = AVMutableComposition()
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                      let range = try? await track.load(.timeRange),
                      let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try? dest.insertTimeRange(range, of: track, at: .zero)
            }
            guard !stopped else { return }
            let item = AVPlayerItem(asset: composition)
            let p = AVPlayer(playerItem: item)
            duration = composition.duration.seconds.isFinite ? composition.duration.seconds : (t.duration ?? 0)
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] cm in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.time = cm.seconds
                    if let end = self.clipEnd, cm.seconds >= end { self.stopClip() }
                    self.playing = (self.player?.rate ?? 0) > 0
                }
            }
            player = p
        }
    }

    func toggle() {
        guard let player else { return }
        clipEnd = nil
        clipLabel = nil
        if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: rate) }
        playing = player.rate > 0
    }

    /// Plays `from`…`to` once, then pauses.
    func play(from start: Double, to end: Double, label: String) {
        guard let player else { return }
        seek(start)
        clipEnd = end
        clipLabel = label
        player.playImmediately(atRate: rate)
        playing = true
    }

    func stopClip() {
        player?.pause()
        clipEnd = nil
        clipLabel = nil
        playing = false
    }

    func seek(_ s: Double) {
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = s
    }

    func setRate(_ r: Float) {
        rate = r
        if let player, player.rate > 0 { player.rate = r }
    }

    func stop() {
        stopped = true
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        playing = false
    }
}

struct TranscriptDetail: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    @State private var player = TranscriptPlayer()
    @State private var mode = "editor"
    @State private var inspector = true
    @State private var inspectorTab = "transcript"
    @State private var favoritesOnly = false
    @State private var fontSize = Settings.fontSize
    @State private var layout = TranscriptLayout.empty
    @State private var audio = AudioRetention.Audio.none
    /// "Who is this?" prompts, recomputed when the transcript or the skipped voices change (not on every search keystroke).
    @State private var prompts: [SpeakerPicker.Prompt] = []

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    DetailBar(transcript: transcript, mode: $mode, inspector: $inspector)
                    if !layout.terms.isEmpty {
                        SearchMatchBar(matches: layout.matches) { state.search = "" }
                            .padding(.horizontal, 20).padding(.top, 10)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if state.polishing.contains(transcript.id) {
                                    Label("Polishing: re-transcribing both recordings, naming speakers and applying your vocabulary…",
                                          systemImage: "sparkles")
                                        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard(14)
                                }
                                if let notes = transcript.notes, !notes.isEmpty { NotesCard(notes: notes) { player.seek($0) } }
                                if transcript.origin == "meeting", !state.polishing.contains(transcript.id), !prompts.isEmpty {
                                    SpeakerPromptCard(transcript: transcript, prompts: prompts, player: player)
                                }
                                Playhead(transcript: transcript, layout: layout, mode: mode, fontSize: fontSize, player: player, proxy: proxy)
                            }
                            .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 120)
                        }
                        .onChange(of: layout.firstMatch) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                switch audio {
                case .deleted:
                    Label(AudioRetention.deletedNote, systemImage: "waveform.slash")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10).glassCapsule().padding(16)
                        .help("The transcript is kept; the audio was removed to save space (Settings → Storage)")
                case .present, .none: PlaybackBar(player: player).padding(16)
                }
            }
            .panel()

            if inspector {
                Inspector(transcript: transcript, mode: $mode, tab: $inspectorTab, favoritesOnly: $favoritesOnly, fontSize: $fontSize,
                          hasAudio: audio == .present, seek: { player.seek($0) })
                    .frame(width: 320)
                    .panel()
            }
        }
        .onAppear {
            audio = AudioRetention.audio(transcript)
            player.load(transcript)
        }
        // Retention or a delete may have removed the recording since.
        .onChange(of: AudioKey(id: transcript.id, source: transcript.sourcePath, library: state.libraryVersion)) {
            audio = AudioRetention.audio(transcript)
        }
        .onChange(of: PromptKey(segments: transcript.segments, context: transcript.context, skipped: state.skippedSpeakers[transcript.id] ?? []),
                  initial: true) { _, key in
            prompts = transcript.origin == "meeting" ? SpeakerPicker.prompts(segments: key.segments, context: key.context, skipped: key.skipped) : []
        }
        .onDisappear { player.stop() }
        .onChange(of: fontSize) { Settings.fontSize = fontSize }
        .onChange(of: LayoutKey(segments: transcript.segments, chats: Formats.chats(transcript.context), favoritesOnly: favoritesOnly,
                                mode: mode, search: state.search), initial: true) { _, key in
            layout = TranscriptLayout(key)
        }
    }
}

private struct AudioKey: Equatable {
    let id: String
    let source: String?
    let library: Int
}

private struct PromptKey: Equatable {
    let segments: [Segment]
    let context: MeetingContext?
    let skipped: Set<String>
}

private struct LayoutKey: Equatable {
    let segments: [Segment]
    let chats: [MeetingEvent]
    let favoritesOnly: Bool
    let mode: String
    let search: String
}

/// Everything the transcript list needs that depends only on the segments, the filter and the search, so it's
/// built once per change instead of on every playback tick.
struct TranscriptLayout {
    /// A speaker paragraph, or a chat message shown where it was sent.
    struct Block: Identifiable {
        var id: Int
        var items: [(Int, Segment)] = []
        var chat: MeetingEvent?
        var start: Double { chat?.t ?? items.first?.1.start ?? 0 }
    }

    var shown: [(Int, Segment)] = []
    var blocks: [Block] = []
    /// Scroll id (the first segment of its paragraph) per segment index.
    var anchor: [Int: Int] = [:]
    var terms: [String] = []
    var matches = 0
    var firstMatch: Int?
    var version = 0

    static let empty = TranscriptLayout()
    @MainActor private static var counter = 0

    @MainActor fileprivate init(_ key: LayoutKey) {
        Self.counter += 1
        version = Self.counter
        shown = key.segments.enumerated().filter { !key.favoritesOnly || $0.element.favorite == true }.map { ($0.offset, $0.element) }
        let chats = key.favoritesOnly ? [] : key.chats
        let paragraphs = Formats.paragraphs(shown, breaks: chats.map(\.t)) { $0.1 }
        for para in paragraphs {
            for (i, _) in para { anchor[i] = para[0].0 }
        }
        blocks = paragraphs.map { Block(id: $0[0].0, items: $0) }
        if !chats.isEmpty {
            blocks += chats.enumerated().map { Block(id: -1 - $0.offset, chat: $0.element) }
            blocks.sort { $0.start != $1.start ? $0.start < $1.start : $0.chat != nil && $1.chat == nil }
        }
        terms = SearchHighlight.terms(key.search)
        guard !terms.isEmpty else { return }
        for (i, s) in shown {
            let n = SearchHighlight.ranges(in: s.text, terms: terms).count
            if n > 0, firstMatch == nil { firstMatch = anchor[i] }
            matches += n
        }
    }

    private init() {}
}

/// Word-prefix, case- and diacritic-insensitive matching of every search term, like the library's search.
enum SearchHighlight {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "*" }).map(String.init).filter { !$0.isEmpty }
    }

    static func ranges(in text: String, terms: [String]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                let atWordStart = r.lowerBound == text.startIndex || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber)
                if atWordStart { out.append(r) }
                from = r.upperBound
            }
        }
        return out
    }

    static func attributed(_ text: String, terms: [String]) -> AttributedString {
        var a = AttributedString(text)
        guard !terms.isEmpty else { return a }
        for r in ranges(in: text, terms: terms) {
            if let ar = Range<AttributedString.Index>(r, in: a) { a[ar].backgroundColor = .yellow.opacity(0.45) }
        }
        return a
    }
}

/// "N matches · Clear search" above the transcript while the toolbar search is active.
private struct SearchMatchBar: View {
    let matches: Int
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(matches == 0 ? "No matches in the transcript text" : matches == 1 ? "1 match" : "\(matches) matches")
            Text("·").foregroundStyle(.tertiary)
            Button("Clear search", action: clear).buttonStyle(.link)
            Spacer()
        }
        .font(.callout)
    }
}

/// Reads the playback time (10×/s) and hands the list only the index of the segment being played.
private struct Playhead: View {
    let transcript: Transcript
    let layout: TranscriptLayout
    let mode: String
    let fontSize: Double
    let player: TranscriptPlayer
    let proxy: ScrollViewProxy

    var body: some View {
        let current = player.playing ? Self.index(in: transcript.segments, at: player.time + 0.05) : nil
        SegmentList(transcript: transcript, layout: layout, mode: mode, fontSize: fontSize, current: current,
                    seek: { player.seek($0) })
            .equatable()
            .onChange(of: current) { _, i in
                if let i, let id = layout.anchor[i] { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
    }

    /// Last segment starting at or before `t` (segments are in time order).
    static func index(in segments: [Segment], at t: Double) -> Int? {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }
}

private struct SegmentList: View, Equatable {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    let layout: TranscriptLayout
    let mode: String
    let fontSize: Double
    let current: Int?
    let seek: (Double) -> Void

    nonisolated static func == (a: SegmentList, b: SegmentList) -> Bool {
        a.layout.version == b.layout.version && a.mode == b.mode && a.fontSize == b.fontSize && a.current == b.current
            && a.transcript.id == b.transcript.id && a.transcript.segments == b.transcript.segments
    }

    var body: some View {
        let roster = SpeakerPicker.unassigned(segments: transcript.segments, context: transcript.context)
        Group { if mode == "editor" { editor(roster) } else { segments } }
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == Self.seekScheme, let i = Int(url.absoluteString.dropFirst(Self.seekScheme.count + 1)),
                      transcript.segments.indices.contains(i) else { return .systemAction }
                seek(transcript.segments[i].start)
                return .handled
            })
    }

    static let seekScheme = "earshot-seek"

    /// One paragraph as one selectable text; each segment is a link to its own time, so clicking a word plays from there.
    private func paragraph(_ items: [(Int, Segment)]) -> Text {
        var a = AttributedString()
        for (n, (i, s)) in items.enumerated() {
            var piece = SearchHighlight.attributed(s.text.trimmingCharacters(in: .whitespaces), terms: layout.terms)
            piece.link = URL(string: "\(Self.seekScheme):\(i)")
            if i == current {
                piece.foregroundColor = .accentColor
                piece.backgroundColor = Color.accentColor.opacity(0.14)
            }
            if n > 0 { a += AttributedString(" ") }
            a += piece
        }
        return Text(a)
    }

    /// Editor: paragraphs per speaker turn with a speaker chip and timestamp.
    private func editor(_ roster: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(layout.blocks) { block in
                if let chat = block.chat {
                    ChatLine(event: chat, fontSize: fontSize) { seek(chat.t) }.id(block.id)
                } else {
                    let first = block.items[0].1
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SpeakerChip(transcript: transcript, speaker: first.speaker, roster: roster)
                            Button { seek(first.start) } label: {
                                Text(Fmt.clock(first.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).help("Play from here")
                        }
                        paragraph(block.items)
                            .font(.system(size: fontSize))
                            .lineSpacing(5)
                            .tint(.primary)
                            .textSelection(.enabled)
                    }
                    .id(block.id)
                }
            }
        }
    }

    /// Segments: one row per paragraph with timestamp, speaker and favourite star.
    private var segments: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(layout.blocks) { block in
                if let chat = block.chat {
                    ChatLine(event: chat, fontSize: fontSize) { seek(chat.t) }.padding(.horizontal, 10).id(block.id)
                } else {
                    let first = block.items[0].1
                    let starred = block.items.allSatisfy { $0.1.favorite == true }
                    let playing = current.map { c in block.items.contains { $0.0 == c } } ?? false
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button { seek(first.start) } label: {
                            Text(Fmt.clock(first.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                        }
                        .buttonStyle(.plain).help("Play from here")
                        if let who = first.speaker {
                            Text(who).font(.caption.bold()).foregroundStyle(SpeakerColor.of(who)).frame(width: 90, alignment: .leading)
                        }
                        paragraph(block.items).font(.system(size: fontSize)).tint(.primary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { state.toggleFavorite(transcript, block.items.map(\.0)) } label: {
                            Image(systemName: starred ? "star.fill" : "star").foregroundStyle(starred ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(starred ? "Remove from favorites" : "Add to favorites")
                        .accessibilityLabel(starred ? "Remove from favorites" : "Add to favorites")
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background { if playing { RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary) } }
                    .id(block.id)
                }
            }
        }
    }
}

/// A chat message sent during the meeting, set apart from speech.
struct ChatLine: View {
    let event: MeetingEvent
    var fontSize: Double = 14
    let seek: () -> Void

    var body: some View {
        Button(action: seek) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.fill").foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.who ?? "Chat").font(.caption.bold())
                        Text("in chat · \(Fmt.clock(event.t))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(event.text ?? "").font(.system(size: max(11, fontSize - 2))).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Chat message. Click to play from here")
    }
}

private struct DetailBar: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    @Binding var mode: String
    @Binding var inspector: Bool

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Display", selection: $mode) {
                    Text("Editor").tag("editor")
                    Text("Segments").tag("segments")
                }
            } label: {
                Label("Transcript", systemImage: "text.alignleft").padding(.horizontal, 12).frame(height: 34)
            }
            .menuStyle(.button).buttonStyle(.plain).glassCapsule()

            Menu {
                Button("Copy Text") { state.copy(Formats.speakerText(transcript.segments)) }
                Button("Copy SRT") { state.copy(Formats.srt(transcript)) }
                Button("Copy VTT") { state.copy(Formats.vtt(transcript)) }
                Divider()
                ForEach(["txt", "srt", "vtt", "md", "json"], id: \.self) { f in
                    Button("Save as .\(f)…") { state.save(transcript, format: f) }
                }
                if transcript.origin == "meeting", let folder = transcript.sourcePath {
                    Divider()
                    Button("Show Recordings in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                }
            } label: {
                Text("Export").padding(.horizontal, 14).frame(height: 34)
            }
            .menuStyle(.button).buttonStyle(.plain).glassCapsule()

            Spacer()
            Button { inspector.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 34, height: 34) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
                .help(inspector ? "Hide inspector" : "Show inspector")
                .accessibilityLabel(inspector ? "Hide inspector" : "Show inspector")
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }
}

/// "Unknown speaker. Click to assign" chip → assign a person or rename.
private struct SpeakerChip: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    let speaker: String?
    /// People in the meeting no speaker is named after yet.
    var roster: [String] = []
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let inMeeting = Set(roster.map(SpeakerPicker.key))
        Menu {
            if !roster.isEmpty {
                Section("In this meeting") {
                    ForEach(roster, id: \.self) { n in Button(n) { state.nameSpeaker(in: transcript, from: speaker, to: n) } }
                }
                Divider()
            }
            ForEach(state.people.filter { !inMeeting.contains(SpeakerPicker.key($0.name)) && $0.name != speaker }) { p in
                Button(p.name) { state.renameSpeaker(in: transcript, from: speaker, to: p.name) }
            }
            if !state.people.isEmpty { Divider() }
            Button("New Person…") { renaming = true }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(SpeakerColor.of(speaker ?? "")).frame(width: 8, height: 8)
                Text(speaker ?? "Unknown speaker").font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .glassCapsule(tint: SpeakerColor.of(speaker ?? "").opacity(0.25))
        .help(speaker == nil ? "Unknown speaker. Click to assign" : "Click to assign")
        .alert("Who is this?", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Assign") {
                guard !name.isEmpty else { return }
                state.addPerson(name)
                state.renameSpeaker(in: transcript, from: speaker, to: name)
                name = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Right inspector: Copy Transcript, display modes, People, Translate, Font Size, Favorites Only / Info.
private struct Inspector: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    @Binding var mode: String
    @Binding var tab: String
    @Binding var favoritesOnly: Bool
    @Binding var fontSize: Double
    var hasAudio = true
    let seek: (Double) -> Void
    @State private var newSpeaker = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Inspector", selection: $tab) {
                    Label("Transcript", systemImage: "text.alignleft").labelStyle(.iconOnly).tag("transcript")
                    if transcript.context != nil {
                        Label("Meeting", systemImage: "person.2").labelStyle(.iconOnly).tag("meeting")
                    }
                    Label("Info", systemImage: "info.circle").labelStyle(.iconOnly).tag("info")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: transcript.context == nil ? 110 : 160)

                switch tab {
                case "meeting": if let c = transcript.context { MeetingInfo(transcript: transcript, context: c, seek: seek) } else { infoTab }
                case "info": infoTab
                default: transcriptTab
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var transcriptTab: some View {
        Button { state.copy(Formats.speakerText(transcript.segments)) } label: {
            Label("Copy Transcript", systemImage: "doc.on.doc").frame(maxWidth: .infinity).frame(height: 36)
        }
        .buttonStyle(.plain).glassCard(12, interactive: true)

        HStack(spacing: 10) {
            modeCard("Editor", "text.justify.left", "editor")
            modeCard("Segments", "list.bullet.rectangle", "segments")
        }

        Text("People").font(.subheadline.bold()).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Set(transcript.segments.compactMap(\.speaker))).sorted(), id: \.self) { s in
                HStack {
                    Circle().fill(SpeakerColor.of(s)).frame(width: 8, height: 8)
                    Text(s)
                    Spacer()
                    Text("\(transcript.segments.filter { $0.speaker == s }.count)").foregroundStyle(.secondary).font(.caption)
                }
            }
            TextField("Add a speaker...", text: $newSpeaker)
                .textFieldStyle(.plain).padding(10).glassCard(10)
                .onSubmit { state.addPerson(newSpeaker); newSpeaker = "" }
        }
        .padding(12).glassCard(14)

        Menu {
            ForEach(LanguageMenu.languages.dropFirst(), id: \.0) { code, name in
                Button(name) { state.translate(transcript, to: code) }
            }
        } label: {
            HStack {
                Text("Translate…").foregroundStyle(Color(red: 0.55, green: 0.80, blue: 1.0)).font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "globe").foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).glassCard(12, interactive: true)

        VStack(spacing: 10) {
            HStack {
                Text("Font Size")
                Spacer()
                Text("\(Int(fontSize))").monospacedDigit()
                Stepper("Font Size", value: $fontSize, in: 11...32).labelsHidden()
            }
            Divider()
            HStack {
                Text("Favorites Only")
                Spacer()
                Toggle("Favorites Only", isOn: $favoritesOnly).toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(12).glassCard(14)

        // Not offered without a recording: it would only fail.
        if transcript.origin == "meeting", hasAudio || state.polishing.contains(transcript.id) {
            let busy = state.polishing.contains(transcript.id)
            Button { state.retranscribe(transcript) } label: {
                Label(busy ? "Re-transcribing…" : "Re-transcribe Meeting", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity).frame(height: 36)
            }
            .buttonStyle(.plain).glassCard(12, interactive: true).disabled(busy || !hasAudio)
            .help(hasAudio ? "Transcribe both recordings again" : AudioRetention.deletedNote)
        }
        Menu {
            ForEach(state.folders) { f in Button(f.name) { state.move(transcript.id, to: f.id) } }
            if transcript.folderID != nil { Button("Remove from Folder") { state.move(transcript.id, to: nil) } }
        } label: {
            Label("Move to Folder", systemImage: "folder").frame(maxWidth: .infinity).frame(height: 36)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).glassCard(12, interactive: true)
    }

    @ViewBuilder private var infoTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            info("Created", transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
            info("Model", ModelCatalog.displayName(transcript.model))
            info("Language", transcript.language ?? "–")
            info("Duration", transcript.duration.map(Fmt.clock) ?? "–")
            info("Processing", String(format: "%.1fs", transcript.processingSeconds))
            info("Segments", "\(transcript.segments.count)")
            info("Words", "\(transcript.text.split(separator: " ").count)")
            info("Source", transcript.sourcePath ?? transcript.origin)
        }
        .padding(12).glassCard(14)
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }

    private func modeCard(_ title: String, _ symbol: String, _ value: String) -> some View {
        Button { mode = value } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).frame(height: 96)
            .overlay {
                if mode == value { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
        }
        .buttonStyle(.plain).glassCard(14, interactive: true)
    }
}

private struct PlaybackBar: View {
    @Bindable var player: TranscriptPlayer

    var body: some View {
        HStack(spacing: 16) {
            Button { player.toggle() } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain).disabled(player.player == nil)
            .help(player.playing ? "Pause" : "Play")
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 0.1))
                .accessibilityLabel("Playback position")
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Fmt.clock(player.time)) / \(Fmt.clock(player.duration))").font(.callout.monospacedDigit().bold())
                Menu("\(player.rate == 1 ? "1" : String(format: "%.2g", player.rate))×") {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { r in Button("\(String(format: "%.2g", r))×") { player.setRate(r) } }
                }
                .menuStyle(.button).buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .glassCard(26)
    }
}

/// Bookmarks and notes taken during the meeting; click one to play from there.
private struct NotesCard: View {
    let notes: [Note]
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.subheadline.bold()).foregroundStyle(.secondary)
            ForEach(notes.sorted { $0.time < $1.time }) { n in
                Button { seek(n.time) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formats.clock(n.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Image(systemName: n.kind == "bookmark" ? "bookmark.fill" : "note.text").foregroundStyle(.yellow)
                        Text(n.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14).glassCard(14)
    }
}
