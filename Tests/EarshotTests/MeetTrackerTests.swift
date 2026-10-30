import Testing
@testable import Earshot

struct MeetTrackerTests {
    private func page(people: [String] = [], muted: [String: Bool] = [:], selfMuted: Bool? = nil, toasts: [MeetToast] = [],
                      captions: [MeetCaptionBlock]? = nil, selfName: String? = nil, ended: Bool = false) -> MeetPage {
        var p = MeetPage()
        for name in people { p.person(name, muted: muted[name]) }
        p.selfMuted = selfMuted
        p.toasts = toasts
        p.captions = captions
        p.selfName = selfName
        p.ended = ended
        return p
    }

    @Test func peopleAlreadyThereHaveNoJoinEvent() {
        var t = MeetTracker()
        _ = t.page(page(people: ["Alice", "Bob"]), at: 0)
        _ = t.page(page(people: ["Alice", "Bob", "Carol"]), at: 30)
        let c = t.context
        #expect(c.platform == "Google Meet")
        #expect(c.participants.map(\.name) == ["Alice", "Bob", "Carol"])
        #expect(c.participants.map(\.joinedAt) == [0, 0, 30])
        #expect(c.events.map(\.kind) == [.joined])
        #expect(c.events.first?.who == "Carol")
    }

    @Test func joinAndLeaveToasts() {
        var t = MeetTracker()
        _ = t.page(page(people: ["Alice"]), at: 0)
        _ = t.page(page(toasts: [.joined("Dave", external: true)]), at: 20)
        _ = t.page(page(toasts: [.left("Dave")]), at: 50)
        let dave = t.context.participants.first { $0.name == "Dave" }
        #expect(dave?.external == true)
        #expect(dave?.joinedAt == 20)
        #expect(dave?.leftAt == 50)
        #expect(t.context.events.map(\.kind) == [.joined, .left])
    }

    @Test func repeatedToastCountsOnce() {
        var t = MeetTracker()
        _ = t.page(page(), at: 0)
        _ = t.page(page(toasts: [.chat("Erin", "hi")]), at: 15)
        _ = t.page(page(toasts: [.chat("Erin", "hi")]), at: 17)
        #expect(t.context.events.filter { $0.kind == .chat }.count == 1)
    }

    @Test func botsAreMarked() {
        var t = MeetTracker()
        _ = t.page(page(people: ["Alice", "Alice's Fathom Notetaker"]), at: 0)
        #expect(t.context.participants.map(\.bot) == [false, true])
        #expect(t.context.speakingParticipants.map(\.name) == ["Alice"])
    }

    @Test func tileMuteChanges() {
        var t = MeetTracker()
        _ = t.page(page(people: ["Alice"], muted: ["Alice": false]), at: 0)
        _ = t.page(page(people: ["Alice"], muted: ["Alice": true]), at: 12)
        _ = t.page(page(people: ["Alice"], muted: ["Alice": false]), at: 40)
        #expect(t.context.events.map(\.kind) == [.muted, .unmuted])
        #expect(SpeakerPipeline.mutedIntervals(t.context)["alice"]?.map { [$0.0, $0.1] } == [[12, 40]])
    }

    @Test func selfMuteIntervals() {
        var t = MeetTracker()
        #expect(t.page(page(selfMuted: false), at: 0).selfMuted == false)
        #expect(t.page(page(selfMuted: true), at: 5).selfMuted == true)
        #expect(t.page(page(selfMuted: true), at: 8).selfMuted == nil)
        #expect(t.snapshot(now: 9).selfMuted == [[5, 9]])
        _ = t.page(page(selfMuted: false), at: 12)
        #expect(t.context.selfMuted == [[5, 12]])
        #expect(t.context.events.map(\.kind) == [.selfMuted, .selfUnmuted])
    }

    @Test func micToastOnlyWithoutButton() {
        var t = MeetTracker()
        _ = t.page(page(selfMuted: false), at: 0)
        #expect(t.page(page(toasts: [.selfMic(muted: true)]), at: 3).selfMuted == true)
        #expect(t.context.selfMuted == [[3, 3]])
    }

    @Test func endOnce() {
        var t = MeetTracker()
        _ = t.page(page(selfMuted: true), at: 0)
        #expect(t.page(page(ended: true), at: 60).ended)
        #expect(!t.page(page(ended: true), at: 61).ended)
        #expect(t.context.ended)
        #expect(t.context.selfMuted == [[0, 60]])
        #expect(t.context.events.last?.kind == .ended)
    }

    @Test func learnsOwnName() {
        var t = MeetTracker()
        _ = t.page(page(captions: [MeetCaptionBlock(key: 1, speaker: "You", text: "hello")]), at: 0)
        _ = t.page(page(people: ["Alice", "Sam"], selfName: "Sam"), at: 2)
        let me = t.context.participants.filter(\.isSelf)
        #expect(me.map(\.name) == ["Sam"])
        #expect(t.context.participants.count == 2)
        #expect(t.context.captions.first?.speaker == "Sam")
        #expect(t.context.captions.first?.isSelf == true)
    }

    @Test func captionTurns() {
        var t = MeetTracker()
        let a = { (text: String) in MeetCaptionBlock(key: 7, speaker: "Alice", text: text) }
        #expect(t.captions([a("hello there")], at: 0) == ["Alice"])
        _ = t.captions([a("hello there how are you")], at: 1)
        #expect(t.context.captions.count == 1)
        #expect(t.context.captions[0].end == 1)
        #expect(t.context.captions[0].text == "hello there how are you")
        // A pause over 2.5 s in the same block starts a new turn with only the new words.
        _ = t.captions([a("hello there how are you so the plan")], at: 5)
        #expect(t.context.captions.count == 2)
        #expect(t.context.captions[1].start == 5)
        #expect(t.context.captions[1].text == "so the plan")
        // A newer block closes the older one.
        let b = MeetCaptionBlock(key: 8, speaker: "Bob", text: "sounds good")
        #expect(t.captions([a("hello there how are you so the plan"), b], at: 6) == ["Bob"])
        _ = t.captions([a("hello there how are you so the plan changed"), b], at: 7)
        #expect(t.context.captions[1].end == 5)
        #expect(t.context.participants.map(\.name).contains("Bob"))
    }

    @Test func captionsOnScreenBeforeReadingAreNotTimed() {
        var t = MeetTracker()
        let old = MeetCaptionBlock(key: 1, speaker: "Alice", text: "earlier words")
        let new = MeetCaptionBlock(key: 2, speaker: "Bob", text: "latest")
        #expect(t.captions([old, new], at: 0) == ["Bob"])
        #expect(t.context.captions.map(\.speaker) == ["Bob"])
    }

    @Test func ownCaptionsAreNotTalkers() {
        var t = MeetTracker()
        #expect(t.captions([MeetCaptionBlock(key: 1, speaker: "You", text: "my words")], at: 0) == [])
        #expect(t.context.captions.first?.isSelf == true)
    }

    @Test func presentation() {
        var t = MeetTracker()
        var p = page(people: ["Carol"])
        p.presentations = ["Carol"]
        p.presenting = ["Carol"]
        _ = t.page(p, at: 0)
        #expect(t.context.participants.contains { $0.name == "Carol (Presentation)" && $0.presentation })
        #expect(t.context.events.map(\.kind) == [.presentingStarted])
        _ = t.page(page(people: ["Carol"]), at: 20)
        #expect(t.context.events.map(\.kind) == [.presentingStarted, .presentingStopped])
    }

    @Test func meta() {
        var t = MeetTracker()
        #expect(t.meta(title: "Meet - abc-defg-hij", url: "https://meet.google.com/abc-defg-hij", code: "abc-defg-hij").changed)
        #expect(!t.meta(title: "Meet - abc-defg-hij", url: nil, code: nil).changed)
        #expect(t.context.meetingCode == "abc-defg-hij")
    }

    @Test func parsedPageIntoTracker() {
        var t = MeetTracker()
        let ch = t.page(MeetParse.page(Pages.busyCall), at: 0)
        #expect(ch.selfMuted == true)
        #expect(ch.speakers == ["Bob"])
        let c = t.context
        #expect(c.captionLanguage == "en")
        #expect(c.participants.first { $0.isSelf }?.name == "Sam")
        #expect(Set(c.speakingParticipants.map(\.name)) == ["Alice", "Bob", "Carol"])
    }
}
