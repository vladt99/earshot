import Testing
@testable import Earshot

struct MeetParseTests {
    static let pages: [String: [MeetNode]] = [
        "green room": Pages.greenRoom, "guest green room": Pages.greenRoomGuest, "Romanian green room": Pages.greenRoomRo,
        "asking": Pages.asking, "call": Pages.inCall, "call with a Join button": Pages.inCallWithJoin, "Romanian call": Pages.inCallRo,
        "end screen": Pages.ended, "end screen, buttons only": Pages.endedButtonsOnly, "loading": Pages.loading, "Meet home": Pages.home,
        "busy call": Pages.busyCall,
    ]

    @Test(arguments: [
        ("green room", MeetPhase.preJoin), ("guest green room", .preJoin), ("Romanian green room", .preJoin),
        ("asking", .asking), ("call", .inCall), ("call with a Join button", .inCall), ("Romanian call", .inCall),
        ("end screen", .ended), ("end screen, buttons only", .ended), ("loading", .unknown), ("Meet home", .unknown),
        ("busy call", .inCall),
    ])
    func phase(_ page: String, _ expected: MeetPhase) throws {
        #expect(MeetParse.phase(try #require(Self.pages[page])) == expected)
    }

    @Test func greenRoomMicIsReadButNotEnded() {
        let p = MeetParse.page(Pages.greenRoom)
        #expect(p.selfMuted == false)
        #expect(!p.ended)
    }

    @Test func endScreen() {
        #expect(MeetParse.page(Pages.ended).ended)
        #expect(MeetParse.page(Pages.endedButtonsOnly).ended)
        #expect(!MeetParse.page(Pages.inCall).ended)
    }

    @Test func meetingCodeAndTitles() {
        #expect(MeetParse.code(inTitle: "Meet - abc-defg-hij") == "abc-defg-hij")
        #expect(MeetParse.code(inTitle: "Meet - Weekly sync") == nil)
        #expect(MeetObserver.isMeetTitle("Meet - abc-defg-hij"))
        #expect(MeetObserver.isMeetTitle("Meet – Weekly sync"))
        #expect(!MeetObserver.isMeetTitle("Google Meet"))
        #expect(!MeetObserver.isMeetTitle("Inbox - Mail"))
    }

    @Test func busyCallPage() {
        let p = MeetParse.page(Pages.busyCall)
        #expect(p.selfMuted == true)
        #expect(p.selfName == "Sam")
        #expect(p.people.contains("Alice") && p.people.contains("Bob"))
        #expect(p.muted["Alice"] == false)
        #expect(p.muted["Bob"] == true)
        #expect(p.presentations == ["Carol"])
        #expect(p.language == "en")
        #expect(p.captions == [MeetCaptionBlock(key: 11, speaker: "Alice", text: "so the plan for this week"),
                               MeetCaptionBlock(key: 12, speaker: "Bob", text: "sounds good")])
        #expect(!p.ended)
    }

    @Test func captionsBehindSingleChildWrappers() {
        let nodes = [
            node(0, "AXGroup", desc: "Captions"),
            node(1, "AXGroup"),
            node(2, "AXGroup"),
            node(3, "AXGroup", key: 1), node(4, "AXStaticText", value: "Alice"), node(4, "AXStaticText", value: "first"),
            node(4, "AXStaticText", value: "line"),
            node(3, "AXGroup", key: 2), node(4, "AXStaticText", value: "You"), node(4, "AXStaticText", value: "reply"),
        ]
        #expect(MeetParse.captionBlocks(nodes, region: 0) == [MeetCaptionBlock(key: 1, speaker: "Alice", text: "first line"),
                                                              MeetCaptionBlock(key: 2, speaker: "You", text: "reply")])
    }

    @Test func emptyCaptionsRegion() {
        #expect(MeetParse.page(Pages.inCall).captions == [])
        #expect(MeetParse.page(Pages.greenRoom).captions == nil)
    }

    @Test func micState() {
        #expect(MeetParse.micState("Turn on microphone") == true)
        #expect(MeetParse.micState("Turn off microphone") == false)
        #expect(MeetParse.micState("Activează microfonul") == true)
        #expect(MeetParse.micState("Turn on microphone (⌘ + d)") == nil)
        #expect(MeetParse.micState("Mute Alice's microphone") == nil)
    }

    @Test func toasts() {
        #expect(MeetParse.toasts("Alice has joined") == [.joined("Alice", external: false)])
        #expect(MeetParse.toasts("Alice and Bob joined") == [.joined("Alice", external: false), .joined("Bob", external: false)])
        #expect(MeetParse.toasts("Carol (outside Acme) joined") == [.joined("Carol", external: true)])
        #expect(MeetParse.toasts("Alice, Bob and 3 others joined") == [.joined("Alice", external: false), .joined("Bob", external: false)])
        #expect(MeetParse.toasts("Dave has left the meeting") == [.left("Dave")])
        #expect(MeetParse.toasts("Erin says in chat: see the doc") == [.chat("Erin", "see the doc")])
        #expect(MeetParse.toasts("Your microphone is off.") == [.selfMic(muted: true)])
        #expect(MeetParse.toasts("Your microphone is on") == [.selfMic(muted: false)])
        #expect(MeetParse.toasts("Frank has raised a hand") == [.hand("Frank")])
        #expect(MeetParse.toasts("Grace started presenting") == [.presenting("Grace")])
        #expect(MeetParse.toasts("Grace stopped presenting") == [.stoppedPresenting("Grace")])
        #expect(MeetParse.toasts("2 guests waiting") == [.waiting(nil, "2 guests waiting")])
        #expect(MeetParse.toasts("Someone has joined") == [])
        #expect(MeetParse.toasts("Hello everyone") == [])
        #expect(MeetParse.toasts("") == [])
    }

    @Test func clean() {
        #expect(MeetParse.clean("  Alice’s\u{a0}tile \n") == "Alice's tile")
    }

    @Test func bots() {
        #expect(MeetParse.isBot("Alice's Fathom Notetaker"))
        #expect(MeetParse.isBot("Fireflies.ai Notetaker"))
        #expect(MeetParse.isBot("Jamie AI"))
        #expect(!MeetParse.isBot("Jamie"))
        #expect(!MeetParse.isBot("Otter"))
        #expect(!MeetParse.isBot("Alice"))
    }

    @Test func plausibleNames() {
        #expect(MeetParse.plausibleName("Alice Example"))
        #expect(!MeetParse.plausibleName(""))
        #expect(!MeetParse.plausibleName("Everyone"))
        #expect(!MeetParse.plausibleName(String(repeating: "a", count: 81)))
        #expect(!MeetParse.plausibleName("one two three four five six seven eight nine"))
    }

    @Test func isSelf() {
        #expect(MeetParse.isSelf("You"))
        #expect(MeetParse.isSelf("Tu"))
        #expect(!MeetParse.isSelf("Alice"))
    }

    @Test func language() {
        #expect(MeetParse.language("English") == "en")
        #expect(MeetParse.language("English (United States)") == "en")
        #expect(MeetParse.language("Română") == "ro")
        #expect(MeetParse.language("Deutsch") == "de")
        #expect(MeetParse.language("Klingon") == nil)
    }
}
