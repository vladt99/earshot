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
    private var observer: Any?

    func load(_ t: Transcript) {
        var urls: [URL] = []
        if let p = t.sourcePath {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir) {
                if isDir.boolValue {
                    urls = ["others.wav", "me.wav"].map { URL(fileURLWithPath: p).appendingPathComponent($0) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                } else {
                    urls = [URL(fileURLWithPath: p)]
                }
            }
        }
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
            let item = AVPlayerItem(asset: composition)
            let p = AVPlayer(playerItem: item)
            duration = composition.duration.seconds.isFinite ? composition.duration.seconds : (t.duration ?? 0)
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] cm in
                MainActor.assumeIsolated {
                    self?.time = cm.seconds
                    self?.playing = (self?.player?.rate ?? 0) > 0
                }
            }
            player = p
        }
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: rate) }
        playing = player.rate > 0
    }

    func seek(_ s: Double) {
        player?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = s
    }

    func setRate(_ r: Float) {
        rate = r
        if let player, player.rate > 0 { player.rate = r }
    }

    func stop() { player?.pause() }
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

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    DetailBar(transcript: transcript, mode: $mode, inspector: $inspector)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if state.polishing.contains(transcript.id) {
                                    Label("Polishing: re-transcribing both recordings, naming speakers and applying your vocabulary…",
                                          systemImage: "sparkles")
                                        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard(14)
                                }
                                if let notes = transcript.notes, !notes.isEmpty { NotesCard(notes: notes) { player.seek($0) } }
                                Group {
                                    if mode == "editor" { editor } else { segments }
                                }
                            }
                            .padding(.horizontal, 36).padding(.top, 18).padding(.bottom, 120)
                        }
                        .onChange(of: currentIndex) { _, i in
                            if player.playing, let i { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                        }
                    }
                }
                PlaybackBar(player: player).padding(16)
            }
            .panel()

            if inspector {
                Inspector(transcript: transcript, mode: $mode, tab: $inspectorTab, favoritesOnly: $favoritesOnly, fontSize: $fontSize)
                    .frame(width: 320)
                    .panel()
            }
        }
        .onAppear { player.load(transcript) }
        .onDisappear { player.stop() }
        .onChange(of: fontSize) { Settings.fontSize = fontSize }
    }

    private var shownSegments: [(Int, Segment)] {
        Array(transcript.segments.enumerated()).filter { !favoritesOnly || $0.1.favorite == true }
            .filter { state.search.isEmpty || $0.1.text.localizedCaseInsensitiveContains(state.search) }
    }

    private var currentIndex: Int? {
        transcript.segments.lastIndex { $0.start <= player.time + 0.05 }
    }

    /// Editor: paragraphs per speaker turn with a speaker chip and timestamp.
    private var editor: some View {
        let paragraphs = Self.paragraphs(shownSegments)
        return LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(paragraphs, id: \.first!.0) { para in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SpeakerChip(transcript: transcript, speaker: para.first!.1.speaker)
                        Text(Fmt.clock(para.first!.1.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    para.reduce(Text("")) { acc, item in
                        let (i, s) = item
                        let isNow = i == currentIndex && player.playing
                        return acc + Text(highlight(s.text) + " ").foregroundStyle(isNow ? Color.accentColor : Color.primary)
                    }
                    .font(.system(size: fontSize))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .onTapGesture { player.seek(para.first!.1.start) }
                }
                .id(para.first!.0)
            }
        }
    }

    /// Segments: one row per segment with timestamp, speaker and favourite star.
    private var segments: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(shownSegments, id: \.0) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.clock(s.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    if let who = s.speaker {
                        Text(who).font(.caption.bold()).foregroundStyle(SpeakerColor.of(who)).frame(width: 90, alignment: .leading)
                    }
                    Text(highlight(s.text)).font(.system(size: fontSize)).textSelection(.enabled)
                    Spacer()
                    Button { state.toggleFavorite(transcript, i) } label: {
                        Image(systemName: s.favorite == true ? "star.fill" : "star").foregroundStyle(s.favorite == true ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background { if i == currentIndex && player.playing { RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary) } }
                .contentShape(Rectangle())
                .onTapGesture { player.seek(s.start) }
                .id(i)
            }
        }
    }

    private func highlight(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard !state.search.isEmpty else { return a }
        var range = a.startIndex..<a.endIndex
        while let r = a[range].range(of: state.search, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.45)
            range = r.upperBound..<a.endIndex
        }
        return a
    }

    static func paragraphs(_ segs: [(Int, Segment)]) -> [[(Int, Segment)]] {
        var out: [[(Int, Segment)]] = []
        for item in segs {
            if let last = out.last?.last, last.1.speaker == item.1.speaker, item.1.start - last.1.end < 8, out.last!.count < 12 {
                out[out.count - 1].append(item)
            } else {
                out.append([item])
            }
        }
        return out
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
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }
}

/// "Unknown speaker. Click to assign" chip → assign a person or rename.
private struct SpeakerChip: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    let speaker: String?
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        Menu {
            ForEach(state.people) { p in
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
    @State private var newSpeaker = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $tab) {
                    Image(systemName: "text.alignleft").tag("transcript")
                    Image(systemName: "info.circle").tag("info")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)

                if tab == "transcript" { transcriptTab } else { infoTab }
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
                Stepper("", value: $fontSize, in: 11...32).labelsHidden()
            }
            Divider()
            HStack {
                Text("Favorites Only")
                Spacer()
                Toggle("", isOn: $favoritesOnly).toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(12).glassCard(14)

        if transcript.origin == "meeting" {
            let busy = state.polishing.contains(transcript.id)
            Button { state.retranscribe(transcript) } label: {
                Label(busy ? "Re-transcribing…" : "Re-transcribe Meeting", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity).frame(height: 36)
            }
            .buttonStyle(.plain).glassCard(12, interactive: true).disabled(busy)
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
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 0.1))
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
