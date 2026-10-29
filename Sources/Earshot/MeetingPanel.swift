import AppKit
import SwiftUI
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Floating, non-activating window with the live transcript (or the "call detected" prompt).
@MainActor
final class MeetingPanel {
    static let shared = MeetingPanel()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Earshot Live"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isOpaque = false
            p.backgroundColor = .clear
            // Only the header drags the panel, so selecting transcript text doesn't move it.
            p.isMovableByWindowBackground = false
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                p.standardWindowButton(button)?.isHidden = true
            }
            // Blur what's behind the panel (other apps), like a desktop widget.
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 22
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            let host = NSHostingView(rootView: LiveMeetingView().environment(AppState.shared))
            host.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            p.contentView = blur
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: screen.maxX - 440, y: screen.maxY - 380))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Safe to call any number of times, in any state.
    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

struct LiveMeetingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let m = state.meeting {
                header(m)
                SessionBanner(meeting: m)
                if let stopAt = state.stoppingAt {
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("Meeting ended. Stopping in \(max(0, Int(stopAt.timeIntervalSince(ctx.date).rounded())))s…")
                                .font(.callout)
                        }
                        Spacer()
                        Button("Keep recording") { state.keepRecording() }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                if let warning = m.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                if m.captionsNeedAccess {
                    HStack {
                        Label("Speaker names need Accessibility access", systemImage: "captions.bubble").font(.caption)
                        Spacer()
                        Button("Settings…") { state.openSettings("Note Taker") }.controlSize(.small)
                    }
                    .padding(8)
                    .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                transcript(m)
                if !m.stopping { NoteBar() }
            } else if let d = state.detectedMeeting {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Meeting detected in \(d.appName)", systemImage: "phone.bubble").font(.headline)
                    Text(d.title).font(.subheadline)
                    Text("\(d.appName) is using the microphone. Transcribe live? Records \(d.appName)'s audio (others) and your microphone (you).")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Transcribe") { state.startMeeting() }.buttonStyle(.glassProminent)
                        Button("Ignore") { state.ignoreDetected() }.buttonStyle(.glass)
                        Spacer()
                        Button("Always") { Settings.meetingMode = "auto"; state.startMeeting() }
                    }
                }
                Spacer()
            } else {
                ContentUnavailableView("No meeting", systemImage: "waveform",
                                       description: Text("Join a call in Chrome (Google Meet), Zoom, Teams… and it shows up here."))
                HStack {
                    Spacer()
                    Button("Start manually") { state.startMeeting() }
                    Button("Close") { MeetingPanel.shared.hide() }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 200)
        .ignoresSafeArea()
        .preferredColorScheme(AppState.shared.colorScheme)
    }

    private func header(_ m: MeetingSnapshot) -> some View {
        let saved = state.willSave(m)
        return HStack {
            if saved {
                PulseDot(color: .red, pulsing: !m.stopping, size: 9).help("Recording")
            } else {
                Image(systemName: "captions.bubble").foregroundStyle(.secondary).help("Live Captions — not saved")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(m.isLiveCaptions && !saved ? "Live Captions" : m.title).font(.headline).lineLimit(1)
                TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                    Text("\(saved ? (m.isLiveCaptions ? "Recording" : m.platform) : "Not saved") · \(Duration.seconds(ctx.date.timeIntervalSince(m.startedAt)).formatted(.time(pattern: .hourMinuteSecond)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(saved ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            Spacer()
            let people = m.people
            if !people.isEmpty {
                Label("\(people.count)", systemImage: "person.2.fill").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(people.map { $0.name + ($0.bot ? " (bot)" : $0.external ? " (guest)" : "") }.joined(separator: "\n"))
                    .accessibilityLabel("\(people.count) participants")
            }
            if m.selfMuted {
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange).help("You're muted — your mic isn't recorded")
            }
            if m.readingCaptions {
                Image(systemName: "captions.bubble.fill").foregroundStyle(.secondary)
                    .help("Reading Meet captions to name speakers")
            }
            GlassEffectContainer {
                HStack(spacing: 6) {
                    Button("Copy") { state.copy(Formats.speakerText(m.lines)) }.buttonStyle(.glass)
                    if m.stopping {
                        Label(saved ? "Saving…" : "Stopping…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Stop") { state.stopMeeting() }.buttonStyle(.glassProminent).tint(.red)
                            .help(saved ? "Stop and save" : "Stop Live Captions (nothing is saved)")
                    }
                    Button { MeetingPanel.shared.hide() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .help(m.stopping ? "Close" : saved ? "Hide (keeps recording)" : "Hide (Live Captions keep running)")
                        .accessibilityLabel(m.stopping ? "Close" : "Hide live transcript")
                }
                .controlSize(.small)
            }
        }
        .background(WindowDragArea())
    }

    private func transcript(_ m: MeetingSnapshot) -> some View {
        let chats = Formats.chats(m.context)
        let blocks = LiveBlock.make(m.lines, notes: m.notes, chats: chats)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { b in
                        switch b.kind {
                        case .note(let n): NoteLine(note: n)
                        case .chat(let e): ChatLine(event: e) {}
                        case .speech(let speaker, let text, let start):
                            LineView(speaker: speaker ?? "", text: text, time: start, partial: false)
                        }
                    }
                    ForEach(m.hypotheses.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }, id: \.key) { speaker, text in
                        LineView(speaker: speaker, text: text, time: nil, partial: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .textSelection(.enabled)
            }
            .onChange(of: m.lines.count + m.notes.count + chats.count + m.hypotheses.values.joined().count) { proxy.scrollTo("bottom") }
        }
    }
}

/// The live transcript as paragraphs (same rules as the saved one), with notes and chat in time order.
struct LiveBlock: Identifiable {
    enum Kind { case speech(String?, String, Double), note(Note), chat(MeetingEvent) }
    var id: String
    var t: Double
    var kind: Kind

    static func make(_ lines: [Segment], notes: [Note], chats: [MeetingEvent]) -> [LiveBlock] {
        var out = Formats.paragraphs(lines, breaks: notes.map(\.time) + chats.map(\.t)).map { p in
            LiveBlock(id: "p\(p[0])", t: lines[p[0]].start,
                      kind: .speech(lines[p[0]].speaker, p.map { lines[$0].text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "), lines[p[0]].start))
        }
        out += notes.map { LiveBlock(id: "n" + $0.id, t: $0.time, kind: .note($0)) }
        out += chats.enumerated().map { LiveBlock(id: "c\($0.offset)", t: $0.element.t, kind: .chat($0.element)) }
        return out.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
    }
}

/// What happens to this session: Live Captions that vanish on Stop (with "Save as meeting"), Live Captions that will be
/// kept, and your mute state.
struct SessionBanner: View {
    @Environment(AppState.self) private var state
    let meeting: MeetingSnapshot
    var compact = false

    var body: some View {
        let m = meeting
        VStack(alignment: .leading, spacing: 6) {
            if m.isLiveCaptions, !m.stopping {
                if state.willSave(m) {
                    Label(state.keptSessions.contains(m.id) ? "Will be saved as a meeting when you stop" :
                            "A call is on: these Live Captions will be saved as a meeting", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    HStack(spacing: 8) {
                        Label("Live Captions (not saved)", systemImage: "captions.bubble").font(.caption.weight(.semibold))
                            .help("Live Captions only show text on screen. Nothing is kept when they stop.")
                        Spacer(minLength: 4)
                        Button("Save as meeting") { state.keepLiveCaptions() }
                            .buttonStyle(.glassProminent).controlSize(.small)
                            .help("Keep this session: it's saved to Meetings when it stops")
                    }
                    .padding(8)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if m.selfMuted {
                Label("Muted — your mic isn't recorded", systemImage: "mic.slash.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    .padding(compact ? 0 : 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(compact ? .clear : .orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Type a note (⏎) or drop a bookmark (⌃⌘B works from any app).
private struct NoteBar: View {
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("Add a note…", text: $text)
                .textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
                .onSubmit {
                    let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !note.isEmpty else { return }
                    MeetingController.shared.addNote(note)
                    text = ""
                }
            Button { MeetingController.shared.addNote(nil, kind: "bookmark") } label: { Image(systemName: "bookmark.fill") }
                .buttonStyle(.glass).help("Bookmark this moment (⌃⌘B)")
                .accessibilityLabel("Bookmark this moment")
        }
    }
}

/// Drags the window from the area behind it (the panel's header).
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct NoteLine: View {
    let note: Note

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: note.kind == "bookmark" ? "bookmark.fill" : "note.text").foregroundStyle(.yellow)
            Text(note.text).font(.callout.weight(.medium))
            Text(Formats.clock(note.time)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

private struct LineView: View {
    let speaker: String
    let text: String
    let time: Double?
    let partial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(speaker).font(.caption.bold()).foregroundStyle(SpeakerColor.of(speaker))
                if let time { Text(Formats.stamp(time, sep: ".").dropLast(4)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            Text(text).foregroundStyle(partial ? .secondary : .primary).italic(partial)
        }
    }
}

enum SpeakerColor {
    static func of(_ speaker: String) -> Color {
        if speaker == Settings.myName { return .accentColor }
        let palette: [Color] = [.orange, .green, .pink, .purple, .teal, .brown, .indigo, .red]
        let n = speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[n % palette.count]
    }
}
