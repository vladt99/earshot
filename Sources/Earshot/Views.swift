import SwiftUI

/// Menu bar panel: meeting status, dictation, language, latest transcript.
struct MenuPanel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Earshot").font(.headline)
                Spacer()
                Circle().fill(state.serverRunning ? .green : .red).frame(width: 8, height: 8)
                Text(state.serverRunning ? "API :\(Settings.port)" : "API off").font(.caption).foregroundStyle(.secondary)
            }
            Text(state.activeJobs > 0 ? "\(state.engineState) (\(state.activeJobs) queued)" : state.engineState)
                .font(.caption).foregroundStyle(.secondary)

            MeetingMenuSection()

            Button {
                state.toggleDictation()
            } label: {
                if let started = state.recordingStarted {
                    TimelineView(.periodic(from: started, by: 1)) { ctx in
                        Label("Stop & transcribe  \(Fmt.clock(ctx.date.timeIntervalSince(started)))", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Label("Dictate", systemImage: "mic.fill").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.glassProminent)
            .tint(state.isRecording ? .red : .accentColor)
            .controlSize(.large)

            HStack {
                Label(state.speechReady ? "Parakeet v3" : "No model", systemImage: "waveform.badge.mic")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                LanguageMenu().fixedSize()
            }

            if let latest = state.transcripts.first {
                Button { state.open(latest) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(latest.title).font(.caption.bold()).lineLimit(1)
                        Text(latest.text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .buttonStyle(.plain).card(padding: 0, interactive: true)
            }

            if let e = state.lastError ?? state.serverError {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            HStack {
                Button("Open Earshot") { state.showMainWindow() }.buttonStyle(.glass)
                Button("Settings") { state.openSettings(nil) }.buttonStyle(.glass)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.glass)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
        .preferredColorScheme(AppState.shared.colorScheme)
    }
}

struct MeetingMenuSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = state.meeting {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(m.title).font(.callout.bold()).lineLimit(1)
                }
                Text(m.lines.last.map { "\($0.speaker ?? ""): \($0.text)" } ?? "Listening…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button("Show Live") { MeetingPanel.shared.show() }.buttonStyle(.glass)
                    Spacer()
                    Button("Stop") { state.stopMeeting() }.buttonStyle(.glassProminent).tint(.red)
                }
            } else if let d = state.detectedMeeting {
                Label("Meeting detected in \(d.appName)", systemImage: "phone.bubble").font(.callout).lineLimit(1)
                HStack {
                    Button("Transcribe") { state.startMeeting() }.buttonStyle(.glassProminent)
                    Button("Ignore") { state.ignoreDetected() }.buttonStyle(.glass)
                }
            } else {
                Text("Meetings").font(.callout.bold())
                Text(Settings.meetingMode == "auto" ? "Calls are recorded automatically." :
                        Settings.meetingMode == "off" ? "Meeting detection is off." : "You'll be asked when a call starts.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Start Now") { state.startMeeting() }.buttonStyle(.glass)
                    Button("Live Captions") { state.toggleLiveCaptions() }.buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: state.meeting != nil ? .red : nil)
    }
}
