import SwiftUI

/// Inspector tab for a meeting: the room, the calendar event, who was there, and what happened when.
struct MeetingInfo: View {
    let transcript: Transcript
    let context: MeetingContext
    let seek: (Double) -> Void
    @State private var fullAgenda = false
    /// Found in the chat once per change, not on every render.
    @State private var links: [Formats.Link] = []

    var body: some View {
        let c = context
        let people = Formats.people(c)
        let bots = people.filter(\.bot)
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting").font(.subheadline.bold()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text(c.title ?? transcript.title).font(.headline).textSelection(.enabled)
                if let room = room(c) {
                    if let link = c.url.flatMap(URL.init(string:)) {
                        Link(destination: link) { Label(room, systemImage: "video") }.help("Open \(c.url ?? "")")
                    } else {
                        Label(room, systemImage: "video").textSelection(.enabled)
                    }
                }
                if let lang = c.captionLanguage {
                    field("Caption language", Locale.current.localizedString(forLanguageCode: lang).map { "\($0) (\(lang))" } ?? lang)
                }
                ForEach(Array(bots.enumerated()), id: \.offset) { _, b in
                    Label("\(b.name) was also in this call", systemImage: "record.circle").font(.callout).foregroundStyle(.orange)
                }
            }
            .padding(12).glassCard(14)

            SeriesCard(transcript: transcript)

            if let cal = c.calendar, cal.title != nil || cal.organizer != nil || cal.notes != nil {
                Text("Calendar").font(.subheadline.bold()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    if let t = cal.title { field("Event", t) }
                    if let o = cal.organizer { field("Organizer", o) }
                    if let start = cal.start {
                        field("Scheduled", start.formatted(date: .abbreviated, time: .shortened) + (cal.end.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                    }
                    if let notes = cal.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agenda").font(.caption).foregroundStyle(.secondary)
                            Text(notes).lineLimit(fullAgenda ? nil : 6).textSelection(.enabled)
                            if notes.count > 280 || notes.split(separator: "\n").count > 6 {
                                Button(fullAgenda ? "Show less" : "Show more") { fullAgenda.toggle() }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
                .padding(12).glassCard(14)
            }

            if !people.isEmpty {
                Text("Participants · \(people.count)").font(.subheadline.bold()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    let presenters = presenters(c)
                    ForEach(Array(people.enumerated()), id: \.offset) { _, p in ParticipantRow(person: p, presenter: presenters.contains(p.name)) }
                }
                .padding(12).glassCard(14)
            }

            if !links.isEmpty {
                Text("Links & emails · \(links.count)").font(.subheadline.bold()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(links, id: \.self) { l in LinkRow(link: l, seek: seek) }
                }
                .padding(12).glassCard(14)
            }

            let events = c.events.sorted { $0.t < $1.t }
            if !events.isEmpty {
                Text("Timeline").font(.subheadline.bold()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        Button { seek(e.t) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Fmt.clock(e.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                Image(systemName: Self.symbol(e.kind)).font(.caption).foregroundStyle(Self.tint(e.kind)).frame(width: 16)
                                Text(Self.describe(e)).font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Play from \(Fmt.clock(e.t))")
                    }
                }
                .padding(12).glassCard(14)
            }
        }
        .onChange(of: context.events, initial: true) { links = Formats.links(context) }
    }

    /// "Google Meet · abc-defg-hij"
    private func room(_ c: MeetingContext) -> String? {
        let parts = [Formats.platformName(c.platform), c.meetingCode].compactMap { $0 }
        return parts.isEmpty ? c.url : parts.joined(separator: " · ")
    }

    private func presenters(_ c: MeetingContext) -> Set<String> {
        var names = Set(c.events.filter { $0.kind == .presentingStarted }.compactMap(\.who))
        for p in c.participants where p.presentation {
            names.insert(p.name.replacingOccurrences(of: " (Presentation)", with: "").trimmingCharacters(in: .whitespaces))
        }
        return names
    }

    private func field(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    static func symbol(_ k: MeetingEvent.Kind) -> String {
        switch k {
        case .joined: "person.badge.plus"
        case .left: "person.badge.minus"
        case .presentingStarted, .presentingStopped: "rectangle.on.rectangle"
        case .chat: "bubble.left.fill"
        case .muted, .selfMuted: "mic.slash"
        case .unmuted, .selfUnmuted: "mic"
        case .handRaised: "hand.raised"
        case .notetakerJoined: "record.circle"
        case .waiting: "hourglass"
        case .ended: "phone.down"
        case .reaction: "face.smiling"
        case .screenShareStarted, .screenShareStopped: "rectangle.inset.filled.and.person.filled"
        case .joinedElsewhere: "iphone"
        case .captionsOn, .captionsOff: "captions.bubble"
        }
    }

    static func describe(_ e: MeetingEvent) -> String {
        let who = e.who ?? "Someone"
        switch e.kind {
        case .joined: return "\(who) joined"
        case .left: return "\(who) left"
        case .presentingStarted: return "\(who) started presenting"
        case .presentingStopped: return "\(who) stopped presenting"
        case .chat: return "\(who): \(e.text ?? "")"
        case .muted: return "\(who) muted"
        case .unmuted: return "\(who) unmuted"
        case .selfMuted: return "You muted your microphone"
        case .selfUnmuted: return "You unmuted your microphone"
        case .handRaised: return e.text == "lowered" ? "\(who) lowered a hand" : "\(who) raised a hand"
        case .notetakerJoined: return "\(e.who ?? "A notetaker") joined"
        case .waiting: return "\(who) is waiting to be let in"
        case .ended: return "The meeting ended"
        case .reaction: return e.text.map { $0.isEmpty ? "\(who) reacted" : "\(who) reacted \($0)" } ?? "\(who) reacted"
        case .screenShareStarted: return "\(who) started sharing their screen"
        case .screenShareStopped: return "\(who) stopped sharing their screen"
        case .joinedElsewhere: return e.who.map { "\($0) also joined from another device" } ?? "You joined from another device"
        case .captionsOn: return "Captions turned on"
        case .captionsOff: return "Captions turned off: speakers can't be named from them"
        }
    }

    static func tint(_ k: MeetingEvent.Kind) -> Color {
        switch k {
        case .chat: .teal
        case .reaction: .yellow
        case .captionsOff: .orange
        default: .secondary
        }
    }
}

/// "Series: N meetings" with the previous and next meeting of the same series.
private struct SeriesCard: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript

    var body: some View {
        if let group = state.seriesGroups.first(where: { $0.value.contains(transcript.id) }), let i = group.value.firstIndex(of: transcript.id) {
            let key = group.key, ids = group.value
            // Newest first: the previous meeting is the next id.
            let older = ids.indices.contains(i + 1) ? meeting(ids[i + 1]) : nil
            let newer = i > 0 ? meeting(ids[i - 1]) : nil
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { state.navigate(.series(key)) } label: { Label("Series: \(ids.count) meetings", systemImage: "repeat") }
                        .buttonStyle(.link).help("Show every meeting of this series")
                    Spacer()
                    Text("\(ids.count - i) of \(ids.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    step(older, "Previous", "chevron.left")
                    step(newer, "Next", "chevron.right")
                }
            }
            .padding(12).glassCard(14)
        }
    }

    private func meeting(_ id: String) -> Transcript? { state.transcripts.first { $0.id == id } }

    private func step(_ t: Transcript?, _ title: String, _ symbol: String) -> some View {
        Button { if let t { state.open(t) } } label: {
            VStack(alignment: title == "Next" ? .trailing : .leading, spacing: 2) {
                Label(title, systemImage: symbol).font(.caption.weight(.semibold))
                Text(t.map { $0.createdAt.formatted(date: .abbreviated, time: .omitted) } ?? "–").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: title == "Next" ? .trailing : .leading)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).inset()
        .disabled(t == nil)
        .help(t.map { "\($0.title), \($0.createdAt.formatted(date: .abbreviated, time: .shortened))" } ?? "No \(title.lowercased()) meeting")
    }
}

/// A link or email address from the chat: who sent it, when, and Copy / Open.
private struct LinkRow: View {
    @Environment(AppState.self) private var state
    let link: Formats.Link
    let seek: (Double) -> Void

    var body: some View {
        let email = link.url.scheme == "mailto"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: email ? "envelope" : "link").font(.caption).foregroundStyle(.teal).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.label).font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Button { seek(link.t) } label: {
                    Text("\(link.who ?? "Chat") · \(Fmt.clock(link.t))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Play from \(Fmt.clock(link.t))")
            }
            Spacer(minLength: 4)
            Button { state.copy(email ? link.label : link.url.absoluteString) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(email ? "Copy address" : "Copy link").accessibilityLabel(email ? "Copy address" : "Copy link")
            Button { NSWorkspace.shared.open(link.url) } label: { Image(systemName: email ? "square.and.pencil" : "arrow.up.right.square") }
                .buttonStyle(.borderless).help(email ? "Write an email" : "Open in browser").accessibilityLabel(email ? "Write an email" : "Open link")
        }
    }
}

private struct ParticipantRow: View {
    let person: MeetingParticipant
    let presenter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(SpeakerColor.of(person.name)).frame(width: 8, height: 8)
                Text(person.name).lineLimit(1).textSelection(.enabled)
                if person.isSelf { Tag(text: "You", color: .accentColor) }
                if person.external { Tag(text: "Guest", color: .orange).help("From outside your organisation") }
                if person.bot { Tag(text: "Bot", color: .purple).help("Another notetaker") }
                if presenter { Tag(text: "Presenter", color: .green) }
                Spacer(minLength: 0)
            }
            if let times = times { Text(times).font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 14) }
            if let email = person.email { Text(email).font(.caption).foregroundStyle(.tertiary).padding(.leading, 14).textSelection(.enabled) }
        }
        .help(person.email ?? person.name)
    }

    private var times: String? {
        let parts = [person.joinedAt.map { "joined \(Fmt.clock($0))" }, person.leftAt.map { "left \(Fmt.clock($0))" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
