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
            p.isMovableByWindowBackground = true
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

    func hide() { panel?.orderOut(nil) }
}

struct LiveMeetingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let m = state.meeting {
                header(m)
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
                transcript(m)
                NoteBar()
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
        HStack {
            Circle().fill(.red).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(m.title).font(.headline).lineLimit(1)
                TimelineView(.periodic(from: m.startedAt, by: 1)) { ctx in
                    Text("\(m.platform) · \(Duration.seconds(ctx.date.timeIntervalSince(m.startedAt)).formatted(.time(pattern: .hourMinuteSecond)))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if m.readingCaptions {
                Image(systemName: "captions.bubble.fill").foregroundStyle(.secondary)
                    .help("Reading Meet captions to name speakers")
            }
            GlassEffectContainer {
                HStack(spacing: 6) {
                    Button("Copy") { state.copy(Formats.speakerText(m.lines)) }.buttonStyle(.glass)
                    Button("Stop") { state.stopMeeting() }.buttonStyle(.glassProminent).tint(.red)
                    Button { MeetingPanel.shared.hide() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .help("Hide (keeps recording)")
                }
                .controlSize(.small)
            }
        }
    }

    private func transcript(_ m: MeetingSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(m.lines.enumerated()), id: \.offset) { _, line in
                        ForEach(m.notes.filter { n in n.time < line.start && !m.lines.contains { $0.start < line.start && $0.start > n.time } }) { n in
                            NoteLine(note: n)
                        }
                        LineView(speaker: line.speaker ?? "", text: line.text, time: line.start, partial: false)
                    }
                    ForEach(m.notes.filter { n in !m.lines.contains { $0.start > n.time } }) { n in NoteLine(note: n) }
                    ForEach(m.hypotheses.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }, id: \.key) { speaker, text in
                        LineView(speaker: speaker, text: text, time: nil, partial: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .textSelection(.enabled)
            }
            .onChange(of: m.lines.count + m.notes.count + m.hypotheses.values.joined().count) { proxy.scrollTo("bottom") }
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
                    MeetingController.shared.addNote(text)
                    text = ""
                }
            Button { MeetingController.shared.addNote(nil, kind: "bookmark") } label: { Image(systemName: "bookmark.fill") }
                .buttonStyle(.glass).help("Bookmark this moment (⌃⌘B)")
        }
    }
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
