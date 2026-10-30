import Testing
@testable import Earshot

struct SpeakerPipelineTests {
    private func spans(_ turns: [SpeakerTurn]) -> [String] { turns.map { "\($0.speaker) \($0.start)-\($0.end)" } }

    @Test func rangeFromRoster() {
        var c = MeetingContext()
        c.participants = [
            MeetingParticipant(name: "Sam", isSelf: true, joinedAt: 0),
            MeetingParticipant(name: "Alice", joinedAt: 0),
            MeetingParticipant(name: "Bob", joinedAt: 0),
            MeetingParticipant(name: "Carol", joinedAt: 200),                 // joined after the recording
            MeetingParticipant(name: "Note Bot", bot: true, joinedAt: 0),
        ]
        c.captions = [CaptionTurn(start: 1, end: 2, speaker: "Alice", text: "a"), CaptionTurn(start: 5, end: 6, speaker: "Alice", text: "b"),
                      CaptionTurn(start: 8, end: 9, speaker: "Bob", text: "c"),
                      CaptionTurn(start: 10, end: 11, speaker: "Dave", text: "d"), CaptionTurn(start: 12, end: 13, speaker: "Dave", text: "e"),
                      CaptionTurn(start: 14, end: 15, speaker: "Sam", isSelf: true, text: "f")]
        let r = SpeakerPipeline.range(c, duration: 100)
        #expect(r?.min == 2)   // Alice and Dave captioned twice; Bob once
        #expect(r?.max == 3)   // Alice, Bob, Dave
        #expect(SpeakerPipeline.range(nil, duration: 100) == nil)
        #expect(SpeakerPipeline.range(MeetingContext(), duration: 100) == nil)
    }

    @Test func joinedTurns() {
        let t = SpeakerPipeline.joined([(5.5, 8, "A"), (0, 5, "A"), (10, 12, "A"), (12.5, 13, "B")])
        #expect(spans(t) == ["A 0.0-8.0", "A 10.0-12.0", "B 12.5-13.0"])
    }

    @Test func smoothFlicker() {
        #expect(spans(SpeakerPipeline.smooth([(0, 5, "A"), (5.2, 6, "B"), (6.3, 10, "A")])) == ["A 0.0-10.0"])
        // Long enough to be real.
        #expect(spans(SpeakerPipeline.smooth([(0, 5, "A"), (5.2, 7.5, "B"), (7.8, 10, "A")])) == ["A 0.0-5.0", "B 5.2-7.5", "A 7.8-10.0"])
        // Not between the same speaker.
        #expect(SpeakerPipeline.smooth([(0, 5, "A"), (5.2, 6, "B"), (6.3, 10, "C")]).count == 3)
    }

    @Test func tidyMergesSameVoice() {
        let turns: [SpeakerTurn] = [(0, 20, "A"), (21, 40, "B"), (41, 60, "C")]
        let emb: [String: [Float]] = ["A": [1, 0, 0], "B": [0.95, 0.1, 0], "C": [0, 0, 1]]
        let (out, voices) = SpeakerPipeline.tidy(turns, embeddings: emb)
        #expect(Set(out.map(\.speaker)).count == 2)
        #expect(voices.count == 2)
        #expect(out.first { $0.start == 41 }?.speaker == "C")
    }

    @Test func tidyAbsorbsTinyClusters() {
        let turns: [SpeakerTurn] = [(0, 30, "A"), (30.5, 32, "T"), (33, 60, "B")]
        let emb: [String: [Float]] = ["A": [1, 0, 0], "B": [0, 1, 0], "T": [0.3, 0.5, 0.81]]
        let (out, voices) = SpeakerPipeline.tidy(turns, embeddings: emb)
        #expect(out.map(\.speaker) == ["A", "B"])   // T sounds more like B, and joins B's turn
        #expect(voices["T"] == nil)
        #expect(Set(SpeakerPipeline.tidy(turns, embeddings: emb, absorb: false).0.map(\.speaker)) == ["A", "B", "T"])
    }

    @Test func talk() {
        #expect(SpeakerPipeline.talk([(0, 5, "A"), (6, 8, "B"), (9, 10, "A")]) == ["A": 6, "B": 2])
    }

    @Test func attributeSentences() {
        let words = [word(" Hello", 0, 0.4), word(" there.", 0.5, 0.9), word(" How", 1.2, 1.4), word(" are", 1.5, 1.7), word(" you?", 1.8, 2.1)]
        let segs = SpeakerPipeline.attribute(words, turns: [(0, 1.0, "A"), (1.1, 2.5, "B")])
        #expect(segs.map(\.text) == ["Hello there.", "How are you?"])
        #expect(segs.map(\.speaker) == ["A", "B"])
        #expect(segs.map(\.start) == [0, 1.2])
        #expect(segs.map(\.end) == [0.9, 2.1])
    }

    @Test func attributeIgnoresFlickerInsideSentence() {
        let texts = [" We", " will", " ship", " it", " on", " Friday."]
        let words = texts.enumerated().map { word($1, Double($0) * 0.4, Double($0) * 0.4 + 0.3) }
        let segs = SpeakerPipeline.attribute(words, turns: [(0, 0.75, "A"), (0.8, 1.1, "B"), (1.15, 2.5, "A")])
        #expect(segs.count == 1)
        #expect(segs.first?.speaker == "A")
        #expect(segs.first?.text == "We will ship it on Friday.")
    }

    @Test func attributeSplitsAtPause() {
        let words = [word(" first", 0, 0.3), word(" part", 0.4, 0.7), word(" second", 2.0, 2.3), word(" part", 2.4, 2.7)]
        #expect(SpeakerPipeline.attribute(words, turns: [(0, 3, "A")]).map(\.text) == ["first part", "second part"])
    }

    @Test func attributeDropsHallucinations() {
        let words = [word(" Thank", 0, 0.3), word(" you.", 0.4, 0.7), word(" Real", 2, 2.3), word(" words.", 2.4, 2.7)]
        #expect(SpeakerPipeline.attribute(words, turns: [(0, 3, "A")]).map(\.text) == ["Real words."])
    }

    @Test func merge() {
        let m = SpeakerPipeline.merge([seg(0, 2, "A", "one"), seg(2.5, 4, "A", "two"), seg(4.2, 5, "B", "three"), seg(5.5, 6, "A", "four")])
        #expect(m.map(\.text) == ["one two", "three", "four"])
        #expect(m[0].end == 4)
        #expect(SpeakerPipeline.merge([seg(0, 20, "A"), seg(20.5, 35, "A")]).count == 2)    // over the 30 s cap
        #expect(SpeakerPipeline.merge([seg(0, 2, nil), seg(2.1, 3, nil)]).count == 2)       // no speaker, no merge
        var fav = seg(2.5, 4, "A")
        fav.favorite = true
        #expect(SpeakerPipeline.merge([seg(0, 2, "A"), fav]).count == 2)
    }

    @Test func captionLag() {
        let words = [word(" alpha", 10, 10.3), word(" bravo", 10.5, 10.8), word(" charlie", 11, 11.3), word(" delta", 11.5, 11.8)]
        let captions = [CaptionTurn(start: 11.5, end: 13, speaker: "Alice", text: "alpha bravo charlie delta")]
        let lag = SpeakerPipeline.captionLag(captions, words: words)
        #expect(lag >= 1 && lag <= 2.5)
        #expect(SpeakerPipeline.captionLag([], words: words) == 1)
        #expect(SpeakerPipeline.captionLag([CaptionTurn(start: 0, end: 1, speaker: "Alice", text: "unrelated text")], words: words) == 1)
    }

    @Test func mutedIntervals() {
        var c = MeetingContext()
        c.events = [MeetingEvent(t: 30, kind: .unmuted, who: "Alice"), MeetingEvent(t: 10, kind: .muted, who: "Alice"),
                    MeetingEvent(t: 50, kind: .muted, who: "Bob")]
        let m = SpeakerPipeline.mutedIntervals(c)
        #expect(m["alice"]?.map { [$0.0, $0.1] } == [[10, 30]])
        #expect(m["bob"]?.first?.1 == .infinity)
    }

    @Test func fromCaptions() {
        var c = MeetingContext()
        c.participants = [MeetingParticipant(name: "Alice"), MeetingParticipant(name: "Bob"), MeetingParticipant(name: "Sam", isSelf: true)]
        c.captions = [CaptionTurn(start: 1, end: 19, speaker: "Alice", text: "x"), CaptionTurn(start: 21, end: 39, speaker: "Bob", text: "y"),
                      CaptionTurn(start: 41, end: 59, speaker: "Sam", isSelf: true, text: "z")]
        let turns: [SpeakerTurn] = [(0, 20, "S0"), (20, 40, "S1"), (40, 60, "S2")]
        #expect(SpeakerPipeline.fromCaptions(turns: turns, context: c, words: []) == ["S0": "Alice", "S1": "Bob"])
        // Muted the whole time S1 talked: S1 can't be Bob.
        c.events = [MeetingEvent(t: 15, kind: .muted, who: "Bob"), MeetingEvent(t: 45, kind: .unmuted, who: "Bob")]
        #expect(SpeakerPipeline.fromCaptions(turns: turns, context: c, words: []) == ["S0": "Alice"])
        #expect(SpeakerPipeline.fromCaptions(turns: [], context: c, words: []).isEmpty)
    }

    @Test func assignUnique() {
        let names = SpeakerNaming.assignUnique([("S0", "Alice", 5), ("S1", "Alice", 9), ("S0", "Bob", 3)])
        #expect(names == ["S1": "Alice", "S0": "Bob"])
    }

    @Test func cosine() {
        #expect(SpeakerNaming.cosine([1, 0], [1, 0]) == 1)
        #expect(SpeakerNaming.cosine([1, 0], [0, 1]) == 0)
        #expect(SpeakerNaming.cosine([1], [1, 2]) == 0)
    }
}
