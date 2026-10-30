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
                Label(state.downloads[state.speechModel.id].map { "Downloading \(Int($0 * 100))%" }
                      ?? (state.speechModelReady ? state.speechModelShortName : "No model"), systemImage: "waveform.badge.mic")
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
                Menu {
                    CheckForUpdatesButton()
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button).buttonStyle(.glass).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More")
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
    @AppStorage("meetingMode") private var meetingMode = "ask"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = state.meeting {
                let saved = state.willSave(m)
                HStack {
                    if saved { Circle().fill(.red).frame(width: 8, height: 8) } else { Image(systemName: "captions.bubble").foregroundStyle(.orange) }
                    Text(saved ? m.title : "Live Captions").font(.callout.bold()).lineLimit(1)
                    Spacer()
                    Text(saved ? "Recording" : "Not saved").font(.caption.weight(.semibold)).foregroundStyle(saved ? .red : .orange)
                }
                SessionBanner(meeting: m, compact: true)
                Text(lastParagraph(m) ?? "Listening…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
                HStack {
                    Button("Show Live") { MeetingPanel.shared.show() }.buttonStyle(.glass)
                    Spacer()
                    if m.stopping {
                        Text("Saving…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Stop") { state.stopMeeting() }.buttonStyle(.glassProminent).tint(.red)
                    }
                }
            } else if let d = state.detectedMeeting {
                Label("Meeting detected in \(d.appName)", systemImage: "phone.bubble").font(.callout).lineLimit(1)
                HStack {
                    Button("Transcribe") { state.startMeeting() }.buttonStyle(.glassProminent)
                    Button("Ignore") { state.ignoreDetected() }.buttonStyle(.glass)
                }
            } else {
                Text("Meetings").font(.callout.bold())
                Text(meetingMode == "auto" ? "Calls are recorded automatically." :
                        meetingMode == "off" ? "Meeting detection is off." : "You'll be asked when a call starts.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Start Now") { state.startMeeting() }.buttonStyle(.glass)
                    Button("Live Captions") { state.toggleLiveCaptions() }.buttonStyle(.glass)
                }
                .disabled(state.recordingKind != nil)
                .help(state.recordingKind != nil ? "Stop the \(state.recordingKind == "voicememo" ? "voice memo" : "dictation") first" : "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: state.meeting.map { state.willSave($0) ? .red : .orange })
    }

    private func lastParagraph(_ m: MeetingSnapshot) -> String? {
        let tail = Array(m.lines.suffix(30))
        guard let p = Formats.paragraphs(tail).last else { return nil }
        return "\(tail[p[0]].speaker.map { "\($0): " } ?? "")\(p.map { tail[$0].text }.joined(separator: " "))"
    }
}
