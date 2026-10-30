import Foundation
import Testing
@testable import Earshot

struct RoomVocabularyTests {
    @Test func clean() {
        #expect(RoomVocabulary.clean("Alice Example (Presentation)") == "Alice Example")
        #expect(RoomVocabulary.clean("Bob  (You)") == "Bob")
    }

    @Test func nameFromEmail() {
        #expect(RoomVocabulary.name(fromEmail: "alice.example@acme.test") == "Alice Example")
        #expect(RoomVocabulary.name(fromEmail: "bob_de_vries@acme.test") == "Bob De Vries")
        #expect(RoomVocabulary.name(fromEmail: "info@acme.test") == nil)
        #expect(RoomVocabulary.name(fromEmail: "room.42@acme.test") == nil)
        #expect(RoomVocabulary.name(fromEmail: "big.room@resource.calendar.google.com") == nil)
        #expect(RoomVocabulary.name(fromEmail: "not-an-address") == nil)
    }

    private var context: MeetingContext {
        var c = MeetingContext()
        c.participants = [
            MeetingParticipant(name: "Alice Example"), MeetingParticipant(name: "You", isSelf: true),
            MeetingParticipant(name: "Alice's Fathom Notetaker", bot: true), MeetingParticipant(name: "Alice Example (Presentation)", presentation: true),
        ]
        c.calendar = CalendarInfo(title: "Zorblin rollout", notes: "<p>Move the Kubernetes cluster</p><br>Join with Google Meet: meet.google.com/abc-defg-hij",
                                  attendees: [.init(name: "Bob Builder", status: "accepted"), .init(name: "Carol Gone", status: "declined"),
                                              .init(email: "dave.sample@acme.test", status: "pending")])
        c.events = [MeetingEvent(t: 10, kind: .chat, who: "Alice Example", text: "the QA2 build is on TestFlight")]
        return c
    }

    @Test func names() {
        #expect(RoomVocabulary.names(context) == ["Alice Example", "Bob Builder", "Dave Sample"])
        #expect(RoomVocabulary.names(nil) == [])
    }

    @Test func terms() {
        let terms = RoomVocabulary.terms(context, custom: ["Postgres", "alice example"])
        #expect(Array(terms.prefix(4)) == ["Postgres", "alice example", "Bob Builder", "Dave Sample"])
        #expect(terms.contains("Zorblin"))
        #expect(terms.contains("Kubernetes"))
        #expect(terms.contains("QA2"))
        #expect(terms.contains("TestFlight"))
        #expect(!terms.contains("Alice"))                        // part of a full name already listed
        #expect(!terms.contains { $0.lowercased().contains("meet") })
        #expect(RoomVocabulary.terms(context, limit: 2).count == 2)
    }

    @Test func customTermsComeFirstAndAreNeverCut() {
        var c = MeetingContext()
        c.participants = (1...45).map { MeetingParticipant(name: "Name\($0) Example") }
        let custom = ["Zorblat", "Kubernetes", "QA2"]
        let terms = RoomVocabulary.terms(c, custom: custom)
        #expect(terms.count == RoomVocabulary.limit)
        #expect(Array(terms.prefix(3)) == custom)
        let many = (1...45).map { "Term\($0)" }
        #expect(RoomVocabulary.terms(c, custom: many) == many)
        let boost = RoomVocabulary.terms(c, custom: custom, limit: RoomVocabulary.boostLimit)
        #expect(boost.count == 48)
        #expect(Array(boost.prefix(3)) == custom)
    }

    @Test func tokens() {
        let t = RoomVocabulary.tokens("Use Node.js and GPT-4. See https://example.com/x today")
        #expect(t.map(\.text) == ["Use", "Node.js", "and", "GPT-4", "See", "today"])
        #expect(t.map(\.initial) == [true, false, false, false, true, true])   // a removed URL breaks the sentence
    }

    @Test func plain() {
        #expect(RoomVocabulary.plain("<p>One</p><b>Two</b>&amp;").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                    == ["One", "Two"])
    }

    @Test func rankKeepsNamesNotSentenceStarts() {
        let ranked = RoomVocabulary.rank([("Hello team, we should ask Zorblat about the Kubernetes cluster", false)])
        #expect(ranked.contains("Zorblat"))
        #expect(ranked.contains("Kubernetes"))
        #expect(!ranked.contains("Hello"))
        #expect(!ranked.contains("cluster"))
    }

    @Test func lexicon() {
        #expect(Lexicon.kind("API") == .strong)
        #expect(Lexicon.kind("GitHub") == .strong)
        #expect(Lexicon.kind("GPT4") == .strong)
        #expect(Lexicon.kind("OK") == .capitalised)
        #expect(Lexicon.kind("Alice") == .capitalised)
        #expect(Lexicon.kind("cluster") == .lower)
        #expect(Lexicon.romanian("ședință"))
        #expect(!Lexicon.romanian("meeting"))
    }
}

struct CaptionSpellingTests {
    private let caption = CaptionTurn(start: 0, end: 3, speaker: "Alice", text: "we deploy to Kubernetes today")

    private func words(_ heard: [(String, Float)]) -> [LiveWord] {
        heard.enumerated().map { i, w in LiveWord(text: w.0, start: Double(i) * 0.5, end: Double(i) * 0.5 + 0.4, confidence: w.1) }
    }

    @Test func captionSpellingWinsForUnsureWords() {
        let heard = words([(" we", 1), (" deploy", 1), (" to", 1), (" cooper", 0.3), (" netties", 0.3), (" today.", 1)])
        let fixed = CaptionSpelling.apply(heard, captions: [caption], lag: 0, terms: ["Kubernetes"])
        #expect(fixed.map(\.text) == [" we", " deploy", " to", " Kubernetes", " today."])
        #expect(fixed[3].start == heard[3].start && fixed[3].end == heard[4].end)
    }

    @Test func confidentDictionaryWordsStay() {
        let heard = words([(" we", 1), (" deploy", 1), (" to", 1), (" production", 1), (" today.", 1)])
        #expect(CaptionSpelling.apply(heard, captions: [caption], lag: 0).map(\.text) == heard.map(\.text))
    }

    @Test func farFromTheCaptionStays() {
        let heard = words([(" cooper", 0.3), (" netties", 0.3)]).map { var w = $0; w.start += 60; w.end += 60; return w }
        #expect(CaptionSpelling.apply(heard, captions: [caption], lag: 0, terms: ["Kubernetes"]).map(\.text) == [" cooper", " netties"])
    }

    @Test func nothingToFixWithoutCaptions() {
        let heard = words([(" cooper", 0.3)])
        #expect(CaptionSpelling.fix(heard, context: MeetingContext()).map(\.text) == [" cooper"])
        #expect(CaptionSpelling.apply(heard, captions: [], lag: 0).map(\.text) == [" cooper"])
    }

    @Test func candidates() {
        let (names, all) = CaptionSpelling.candidates([caption], lag: 1, terms: [])
        #expect(names.map(\.text) == ["Kubernetes"])
        #expect(abs(names[0].time - (3.0 * 4 / 5 - 1)) < 1e-9)
        #expect(all.count == 5)
    }

    @Test func romanianEndingsOfWordsTheCaptionShows() {
        let caption = CaptionTurn(start: 0, end: 3, speaker: "Alice", text: "am pus Docker-ul pe GitHub-ul si Slack-ul")
        let heard = words([(" am", 1), (" pus", 1), (" Docker-ul", 0.3), (" pe", 1), (" GitHub-ul", 0.3), (" si", 1), (" Slack-ul.", 0.3)])
        #expect(CaptionSpelling.apply(heard, captions: [caption], lag: 0, terms: ["Docker", "GitHub", "Slack"]).map(\.text) == heard.map(\.text))
        let bare = CaptionTurn(start: 0, end: 3, speaker: "Alice", text: "am pus Docker pe GitHub si Slack")
        #expect(CaptionSpelling.apply(heard, captions: [bare], lag: 0).map(\.text) == heard.map(\.text))
    }

    @Test func respellingKeepsTheRomanianEnding() {
        let caption = CaptionTurn(start: 0, end: 2, speaker: "Alice", text: "mutam pe Kubernetes azi")
        let heard = words([(" mutam", 1), (" pe", 1), (" Cubernetes-ul,", 0.3), (" azi", 1)])
        #expect(CaptionSpelling.apply(heard, captions: [caption], lag: 0, terms: ["Kubernetes"]).map(\.text)
                == [" mutam", " pe", " Kubernetes-ul,", " azi"])
        #expect(Lexicon.split(" Docker-ul,") == ("docker", "-ul"))
        #expect(Lexicon.split(" build-urile") == ("build", "-urile"))
        #expect(Lexicon.split(" Zorblat.") == ("zorblat", ""))
    }

    @Test func ownMicUsesOwnCaptions() {
        var c = MeetingContext()
        c.captions = [CaptionTurn(start: 0, end: 3, speaker: "You", isSelf: true, text: "we use Zorblat now"),
                      CaptionTurn(start: 0, end: 3, speaker: "Alice", text: "we use Zorblin now")]
        let heard = words([(" we", 1), (" use", 1), (" zorblet", 0.3), (" now", 1)])
        #expect(CaptionSpelling.fix(heard, context: c, mic: true).map(\.text)[2] == " Zorblat")
        #expect(CaptionSpelling.fix(heard, context: c, mic: false).map(\.text)[2] == " Zorblin")
        // No word of the side's captions was heard: that side isn't used, and the other one isn't either.
        c.captions[0].text = "something else entirely"
        #expect(CaptionSpelling.fix(heard, context: c, mic: true).map(\.text) == heard.map(\.text))
        #expect(CaptionSpelling.fix(heard, context: c, mic: false).map(\.text)[2] == " Zorblin")
    }

    @Test func uncertain() {
        #expect(CaptionSpelling.uncertain(LiveWord(text: " the", start: 0, end: 1, confidence: 0.2)))
        #expect(!CaptionSpelling.uncertain(LiveWord(text: " the", start: 0, end: 1)))
        #expect(CaptionSpelling.uncertain(LiveWord(text: " Zorblat", start: 0, end: 1)))
        #expect(!CaptionSpelling.uncertain(LiveWord(text: " 42", start: 0, end: 1, confidence: 0.1)))
    }
}
