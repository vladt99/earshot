import SwiftUI

/// Inspector tab for a meeting: the room, the calendar event, who was there, and what happened when.
struct MeetingInfo: View {
    let transcript: Transcript
    let context: MeetingContext
    let seek: (Double) -> Void
    @State private var fullAgenda = false

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

            let events = c.events.sorted { $0.t < $1.t }
            if !events.isEmpty {
                Text("Timeline").font(.subheadline.bold()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                        Button { seek(e.t) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Fmt.clock(e.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                                Image(systemName: Self.symbol(e.kind)).font(.caption).foregroundStyle(e.kind == .chat ? .teal : .secondary).frame(width: 16)
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
        case .handRaised: return "\(who) raised a hand"
        case .notetakerJoined: return "\(e.who ?? "A notetaker") joined"
        case .waiting: return "\(who) is waiting to be let in"
        case .ended: return "The meeting ended"
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
