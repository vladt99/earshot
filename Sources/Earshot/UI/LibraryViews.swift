import SwiftUI

/// A list of transcripts (Meetings, Transcriptions, Dictations, a folder or a person), grouped by day.
struct LibraryList: View {
    @Environment(AppState.self) private var state
    let items: [Transcript]
    let empty: (String, String, String, (String, () -> Void)?)

    var body: some View {
        let shown = state.filtered(items)
        if shown.isEmpty {
            EmptyStateView(symbol: empty.0, title: empty.1, message: empty.2, action: empty.3.map { (title: $0.0, run: $0.1) })
                .card()
        } else {
            TranscriptGroups(items: shown)
        }
    }
}

struct TranscriptGroups: View {
    @Environment(AppState.self) private var state
    let items: [Transcript]

    var body: some View {
        let groups = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.createdAt) }
            .sorted { $0.key > $1.key }
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.key) { day, list in
                SectionTitle(title: Fmt.dayHeading(day), detail: "\(list.count)")
                ForEach(list) { t in TranscriptRow(t: t) }
            }
        }
    }
}

struct TranscriptRow: View {
    @Environment(AppState.self) private var state
    let t: Transcript

    var body: some View {
        Button { state.open(t) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.icon(t.origin)).font(.system(size: 16)).foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.fill.quaternary, in: ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(t.title).font(.headline).lineLimit(1)
                        Spacer()
                        Text(t.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(t.text.replacingOccurrences(of: "\n", with: " ")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 8) {
                        if let d = t.duration { Label(Fmt.clock(d), systemImage: "clock") }
                        let speakers = Set(t.segments.compactMap(\.speaker))
                        if !speakers.isEmpty { Label("\(speakers.count)", systemImage: "person.2") }
                        if let f = t.folderID, let folder = state.folders.first(where: { $0.id == f }) { Label(folder.name, systemImage: "folder") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(interactive: true)
        .draggable(t.id)
        .contextMenu {
            Button("Open") { state.open(t) }
            Menu("Move to Folder") {
                ForEach(state.folders) { f in Button(f.name) { state.move(t.id, to: f.id) } }
                if t.folderID != nil { Divider(); Button("Remove from Folder") { state.move(t.id, to: nil) } }
            }
            Button("Copy Transcript") { state.copy(t.text) }
            Divider()
            Button("Delete", role: .destructive) { state.softDelete(t) }
        }
    }

    static func icon(_ origin: String) -> String {
        switch origin {
        case "meeting": return "person.2.wave.2"
        case "dictation": return "character.cursor.ibeam"
        case "voicememo": return "mic"
        case "appaudio": return "app.badge"
        case "podcast": return "person.2.wave.2.fill"
        case "watch": return "folder"
        case "youtube": return "play.rectangle"
        default: return "waveform"
        }
    }
}

struct DeletedList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Items are permanently deleted after 30 days.").foregroundStyle(.secondary)
                Spacer()
                if !state.deleted.isEmpty {
                    Button("Empty Trash", role: .destructive) { state.emptyTrash() }.buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 4)
            if state.deleted.isEmpty {
                EmptyStateView(symbol: "trash", title: "No Deleted Items", message: "Deleted transcripts stay here for 30 days.").card()
            } else {
                ForEach(state.deleted) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.title).font(.headline)
                            Text(t.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        GlassEffectContainer {
                            HStack(spacing: 6) {
                                Button("Restore") { state.restore(t) }
                                Button("Delete", role: .destructive) { state.deleteForever(t) }
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .card()
                }
            }
        }
    }
}

/// Active and recent transcription jobs.
struct QueueView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.jobs.isEmpty {
                EmptyStateView(symbol: "checklist", title: "Nothing in the Queue", message: "Files you transcribe show up here while they run.").card()
            } else {
                ForEach(state.jobs, id: \.id) { job in
                    HStack(spacing: 12) {
                        switch job.status {
                        case "running": ProgressView().controlSize(.small)
                        case "queued": Image(systemName: "clock").foregroundStyle(.secondary)
                        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        default: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading) {
                            Text(job.title).font(.headline).lineLimit(1)
                            Text(job.error ?? job.status.capitalized).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        if let t = job.transcript, job.saved { Button("Open") { state.open(t) }.buttonStyle(.glass) }
                    }
                    .card()
                }
            }
        }
    }
}
