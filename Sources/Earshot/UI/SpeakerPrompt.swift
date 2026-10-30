import SwiftUI

/// "Who is this?" for one unnamed voice: play a clip, pick someone from the roster, type a name, or skip.
struct SpeakerPickRow: View {
    let prompt: SpeakerPicker.Prompt
    /// Names other speakers already have: picking one merges the two (one person split in two).
    var named: [String] = []
    var playing = false
    var play: (() -> Void)?
    let pick: (String) -> Void
    let skip: () -> Void
    /// The user is typing a name or pointing at the choices (the live panel holds the prompt still meanwhile).
    var using: ((Bool) -> Void)?
    @State private var typing = false
    @State private var name = ""
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let play {
                    Button(action: play) {
                        Image(systemName: playing ? "stop.fill" : "play.fill").font(.caption).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
                    .help(playing ? "Stop" : "Play a few seconds of this voice")
                    .accessibilityLabel(playing ? "Stop" : "Play \(prompt.label)")
                }
                Circle().fill(SpeakerColor.of(prompt.label)).frame(width: 8, height: 8)
                Text(prompt.label).font(.callout.weight(.semibold))
                Text("talked \(Fmt.clock(prompt.talk))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Skip", action: skip).buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("Leave this voice unnamed")
            }
            if !prompt.sample.isEmpty {
                Text("“\(prompt.sample)”").font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
            }
            ChipFlow(spacing: 6) {
                ForEach(prompt.candidates, id: \.self) { n in
                    Button(n) { pick(n) }.buttonStyle(.glass).controlSize(.small)
                        .help("This is \(n): name the voice and remember it for later meetings")
                }
                if !named.isEmpty {
                    Menu("Same as…") {
                        ForEach(named, id: \.self) { n in Button(n) { pick(n) } }
                    }
                    .menuStyle(.button).buttonStyle(.glass).controlSize(.small).fixedSize()
                    .help("The same person as a speaker who is already named: merges the two")
                }
                Button("Someone else…") { typing = true }.buttonStyle(.glass).controlSize(.small)
            }
            .onHover { hovering = $0 }
            if typing {
                HStack(spacing: 6) {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular, in: Capsule())
                        .onSubmit(assign)
                    Button("Assign", action: assign).buttonStyle(.glassProminent).controlSize(.small)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { typing = false; name = "" }.buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .onChange(of: typing || hovering) { _, on in using?(on) }
        .onDisappear { if typing || hovering { using?(false) } }
    }

    private func assign() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        typing = false
        name = ""
        pick(n)
    }
}

/// Above a meeting's transcript: "2 voices aren't named yet · Name them".
struct SpeakerPromptCard: View {
    @Environment(AppState.self) private var state
    let transcript: Transcript
    let prompts: [SpeakerPicker.Prompt]
    let player: TranscriptPlayer
    @State private var open = false

    var body: some View {
        let named = Array(Set(transcript.segments.compactMap(\.speaker)))
            .filter { !SpeakerPicker.isUnnamed($0) && $0 != Settings.myName && $0 != Settings.participantsName }.sorted()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                Text(prompts.count == 1 ? "1 voice isn't named yet" : "\(prompts.count) voices aren't named yet")
                Text("·").foregroundStyle(.tertiary)
                Button(open ? "Hide" : "Name them") { withAnimation(.snappy) { open.toggle() } }.buttonStyle(.link)
                Spacer()
            }
            .font(.callout)
            if open {
                ForEach(prompts, id: \.label) { p in
                    SpeakerPickRow(prompt: p, named: named, playing: player.clipLabel == p.label && player.playing,
                                   play: p.clip.map { c in { toggle(p.label, c) } },
                                   pick: { state.nameSpeaker(in: transcript, from: p.label, to: $0) },
                                   skip: { state.skipSpeaker(p.label, in: transcript.id) })
                    if p.label != prompts.last?.label { Divider() }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).glassCard(14)
    }

    private func toggle(_ label: String, _ c: SpeakerPicker.Clip) {
        if player.clipLabel == label, player.playing { player.stopClip() } else { player.play(from: c.start, to: c.end, label: label) }
    }
}
