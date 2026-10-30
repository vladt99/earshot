import Foundation
import Testing
@testable import Earshot

struct FormatsTests {
    private func transcript(_ segments: [Segment]) -> Transcript {
        Transcript(id: "t1", createdAt: Date(timeIntervalSince1970: 0), title: "Test", origin: "app", model: "test", language: "en",
                   duration: 10, processingSeconds: 1, text: segments.map(\.text).joined(separator: " "), segments: segments)
    }

    @Test func paragraphsBySpeakerAndPause() {
        let s = [seg(0, 5, "A", "One."), seg(6, 10, "A", "Two."), seg(11, 12, "B", "Three."), seg(30, 31, "B", "Four."), seg(32, 33, "A", "Five.")]
        #expect(Formats.paragraphs(s) == [[0, 1], [2], [3], [4]])
        #expect(Formats.paragraphs(s, breaks: [5.5]) == [[0], [1], [2], [3], [4]])
        #expect(Formats.paragraphs([]) == [])
    }

    @Test func longParagraphsEndAtASentence() {
        let sentences = (0..<20).map { seg(Double($0) * 10, Double($0) * 10 + 9, "A", "Sentence.") }
        #expect(Formats.paragraphs(sentences).map(\.count) == [12, 8])
        let runOn = (0..<20).map { seg(Double($0) * 10, Double($0) * 10 + 9, "A", "and then") }
        #expect(Formats.paragraphs(runOn).map(\.count) == [18, 2])
    }

    @Test func speakerText() {
        #expect(Formats.speakerText([seg(0, 1, nil, "Plain"), seg(1, 2, nil, "text.")]) == "Plain text.")
        let s = [seg(0, 1, "Alice", "Hi."), seg(1, 2, "Alice", " How are you? "), seg(3, 4, "Bob", "Fine.")]
        #expect(Formats.speakerText(s) == "Alice: Hi. How are you?\n\nBob: Fine.")
        #expect(Formats.paragraphText([], fallback: "empty") == "empty")
        #expect(Formats.paragraphText([seg(0, 1, nil, "a"), seg(1, 2, "Bob", "b")]) == "Unknown: a\n\nBob: b")
    }

    @Test func endsSentence() {
        #expect(Formats.endsSentence("Done."))
        #expect(Formats.endsSentence("Really?\u{201D}"))
        #expect(Formats.endsSentence("Gata!) "))
        #expect(!Formats.endsSentence("and"))
        #expect(!Formats.endsSentence(""))
    }

    @Test func yamlEscaping() {
        #expect(Formats.yaml("plain") == "\"plain\"")
        #expect(Formats.yaml("a \"b\" \\ c") == #""a \"b\" \\ c""#)
        #expect(Formats.yaml("one\r\ntwo\nthree\rfour\tfive") == #""one\ntwo\nthree\nfour\tfive""#)
        #expect(Formats.yaml("key: value # not a comment") == "\"key: value # not a comment\"")
    }

    @Test func vttEscaping() {
        #expect(Formats.cue("<b> & </b>\nnext") == "&lt;b&gt; &amp; &lt;/b&gt; next")
        let vtt = Formats.vtt(transcript([seg(1.5, 2, "A<B", "x > y"), seg(2, 3.25, nil, "plain")]))
        #expect(vtt == "WEBVTT\n\n00:00:01.500 --> 00:00:02.000\n<v A&lt;B>x &gt; y\n\n00:00:02.000 --> 00:00:03.250\nplain\n")
    }

    @Test func srt() {
        let srt = Formats.srt(transcript([seg(0, 1.2, "Alice", "Hi."), seg(61, 62, nil, "Bye.")]))
        #expect(srt == "1\n00:00:00,000 --> 00:00:01,200\nAlice: Hi.\n\n2\n00:01:01,000 --> 00:01:02,000\nBye.\n")
    }

    @Test func stampsAndClock() {
        #expect(Formats.stamp(3661.25, sep: ".") == "01:01:01.250")
        #expect(Formats.stamp(0.0004, sep: ",") == "00:00:00,000")
        #expect(Formats.clock(42) == "0:42")
        #expect(Formats.clock(723) == "12:03")
        #expect(Formats.clock(3729) == "1:02:09")
    }
}

struct VocabularyGuardTests {
    @Test(arguments: [
        ("Cooper Netties", "Kubernetes"), ("post gress", "Postgres"), ("cuber netis", "Kubernetes"),
        ("sore blin", "Zorblin"), ("zor blin", "Zorblin"),
    ])
    func accepts(_ heard: String, _ term: String) {
        #expect(VocabularyGuard.accepts(original: heard, replacement: term))
    }

    @Test(arguments: [
        ("problem", "Zorblin"), ("sorting", "Zorblin"), ("exactly?", "Zorblin"),
        ("What about the search", "Zorblin"), ("Good morning", "Kubernetes"), ("", "Kubernetes"), ("Kubernetes", ""),
    ])
    func rejects(_ heard: String, _ term: String) {
        #expect(!VocabularyGuard.accepts(original: heard, replacement: term))
    }

    @Test func helpers() {
        #expect(VocabularyGuard.letters("Ça-va, OK?") == "cavaok")
        #expect(VocabularyGuard.phonetic("kubernetes") == VocabularyGuard.phonetic("cubernetis"))
        #expect(VocabularyGuard.similarity("abc", "abc") == 1)
        #expect(VocabularyGuard.similarity("abc", "") == 0)
        #expect(abs(VocabularyGuard.similarity("kitten", "sitting") - (1 - 3.0 / 7)) < 1e-9)
    }
}
