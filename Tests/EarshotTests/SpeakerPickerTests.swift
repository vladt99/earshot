import Testing
@testable import Earshot

struct SpeakerPickerTests {
    static let context: MeetingContext = {
        var c = MeetingContext()
        c.participants = [
            MeetingParticipant(name: "Sam", isSelf: true, joinedAt: 0),
            MeetingParticipant(name: "Alice", joinedAt: 0),
            MeetingParticipant(name: "Bea", joinedAt: 0),
            MeetingParticipant(name: "Bob", joinedAt: 0, leftAt: 100),       // left before Speaker 3 talked
            MeetingParticipant(name: "Carol", joinedAt: 0),                  // there, never captioned
            MeetingParticipant(name: "Dave", joinedAt: 300),                 // joined after
            MeetingParticipant(name: "Alice's Fathom Notetaker", bot: true, joinedAt: 0),
            MeetingParticipant(name: "Bea (Presentation)", presentation: true, joinedAt: 0),
        ]
        c.captions = [CaptionTurn(start: 31, end: 35, speaker: "Bea", text: "so the plan"), CaptionTurn(start: 202, end: 206, speaker: "Bea", text: "ok"),
                      CaptionTurn(start: 10, end: 14, speaker: "Alice", text: "hello")]
        return c
    }()

    static let segments = [
        seg(9, 14, "Alice", "Hello everyone."),
        seg(30, 34, "Speaker 2", "So the plan for this week is simple."),
        seg(120, 160, "Speaker 3", "Long update about the release that nobody interrupts."),
        seg(161, 170, "Speaker 3", "More."),
        seg(200, 202, "Speaker 2", "Ok."),
        seg(250, 252, "Speaker 4", "Yes."),
        seg(150, 152, "Me", "Mm."),
    ]

    let ctx = Self.context, segs = Self.segments

    @Test func unassigned() {
        #expect(SpeakerPicker.unassigned(segments: segs, context: ctx) == ["Bea", "Bob", "Carol", "Dave"])
        #expect(SpeakerPicker.unassigned(segments: segs, context: nil) == [])
    }

    @Test func candidates() {
        #expect(SpeakerPicker.candidates(for: "Speaker 2", segments: segs, context: ctx).first == "Bea")
        let c3 = SpeakerPicker.candidates(for: "Speaker 3", segments: segs, context: ctx)
        #expect(c3.prefix(2).sorted() == ["Bea", "Carol"])
        #expect(c3.firstIndex(of: "Bob")! > 1 && c3.firstIndex(of: "Dave")! > 1)
    }

    @Test func prompts() {
        let prompts = SpeakerPicker.prompts(segments: segs, context: ctx)
        #expect(prompts.map(\.label) == ["Speaker 3", "Speaker 2", "Speaker 4"])
        // Speaker 3's 40 s line is overlapped by "Me" at 150; its clean line is the 9 s one, cut to 5 s.
        #expect(prompts[0].clip == SpeakerPicker.Clip(start: 161, end: 166))
        #expect(prompts[0].talk == 49)
        #expect(SpeakerPicker.prompts(segments: segs, context: ctx, skipped: ["Speaker 3"]).map(\.label) == ["Speaker 2", "Speaker 4"])
        #expect(SpeakerPicker.prompts(segments: segs, context: nil).isEmpty)
    }

    @Test func clips() {
        #expect(SpeakerPicker.clip(for: "Speaker 2", segments: segs)?.clip.end == 34)
        #expect(SpeakerPicker.clip(for: "Speaker 4", segments: segs).map { $0.clip.end - $0.clip.start } == 3)
        #expect(SpeakerPicker.clip(for: "Speaker 9", segments: segs) == nil)
    }

    @Test func nobodyLeftToAssign() {
        var full = ctx
        full.participants = full.participants.filter { ["Sam", "Alice"].contains($0.name) }
        #expect(SpeakerPicker.prompts(segments: segs, context: full).isEmpty)
    }

    @Test func livePrompt() {
        #expect(SpeakerPicker.livePrompt(lines: segs, context: ctx, skipped: [])?.label == "Speaker 3")
        #expect(SpeakerPicker.livePrompt(lines: segs, context: ctx, skipped: ["Speaker 3"]) == nil)
    }

    @Test func assignAndMerge() {
        let renamed = segs.map { var s = $0; if s.speaker == "Speaker 3" { s.speaker = "Carol" }; return s }
        #expect(!SpeakerPicker.candidates(for: "Speaker 2", segments: renamed, context: ctx).contains("Carol"))
        let merged = renamed.map { var s = $0; if s.speaker == "Speaker 2" || s.speaker == "Speaker 4" { s.speaker = "Carol" }; return s }
        #expect(Set(merged.compactMap(\.speaker)) == ["Alice", "Carol", "Me"])
        #expect(SpeakerPicker.prompts(segments: merged, context: ctx).isEmpty)
    }

    @Test func unnamedLabels() {
        #expect(SpeakerPicker.isUnnamed("Speaker 12"))
        #expect(!SpeakerPicker.isUnnamed("Speaker"))
        #expect(!SpeakerPicker.isUnnamed("Alice"))
        #expect(!SpeakerPicker.isUnnamed(nil))
    }

    @Test func fromPicks() {
        let turns: [(start: Double, end: Double, speaker: String)] = [(30, 34, "S0"), (120, 140, "S1"), (140, 170, "S2"), (200, 205, "S0"), (9, 14, "S3")]
        let picks = [SpeakerPick(name: "Carol", spans: [[120, 160], [161, 170]]), SpeakerPick(name: "Bea", spans: [[30, 34]])]
        let named = SpeakerPicker.fromPicks(turns: turns, picks: picks)
        #expect(named["S1"] == "Carol")
        #expect(named["S2"] == "Carol")
        #expect(named["S0"] == "Bea")
        #expect(named["S3"] == nil)
    }
}
