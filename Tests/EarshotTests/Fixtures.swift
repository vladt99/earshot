@testable import Earshot

func node(_ depth: Int, _ role: String, title: String? = nil, desc: String? = nil, value: String? = nil, key: Int = 0) -> MeetNode {
    MeetNode(depth: depth, role: role, title: title, desc: desc, value: value, key: key)
}

func seg(_ start: Double, _ end: Double, _ speaker: String?, _ text: String = "words words") -> Segment {
    Segment(start: start, end: end, text: text, speaker: speaker)
}

func word(_ text: String, _ start: Double, _ end: Double) -> LiveWord { LiveWord(text: text, start: start, end: end) }

/// Synthetic Google Meet pages (accessibility nodes in document order).
enum Pages {
    static let greenRoom: [MeetNode] = [
        node(0, "AXWebArea", title: "Meet - abc-defg-hij"),
        node(1, "AXGroup"),
        node(2, "AXGroup", desc: "Video preview"),
        node(3, "AXButton", desc: "Turn off microphone"),
        node(3, "AXButton", desc: "Turn off camera"),
        node(3, "AXButton", desc: "Backgrounds and effects"),
        node(2, "AXHeading", title: "Ready to join?"),
        node(3, "AXStaticText", value: "Ready to join?"),
        node(2, "AXStaticText", value: "Alice is in this call"),
        node(2, "AXButton"),
        node(3, "AXStaticText", value: "Join now"),
        node(2, "AXButton", title: "Present"),
        node(2, "AXStaticText", value: "Other ways to join"),
    ]
    static let greenRoomGuest: [MeetNode] = [
        node(0, "AXWebArea"), node(1, "AXStaticText", value: "What's your name?"), node(1, "AXTextField", desc: "Your name"),
        node(1, "AXButton", title: "Ask to join"), node(1, "AXButton", desc: "Turn on microphone"),
    ]
    static let greenRoomRo: [MeetNode] = [
        node(0, "AXWebArea"), node(1, "AXStaticText", value: "Sunteți gata să vă alăturați?"),
        node(1, "AXButton", desc: "Dezactivează microfonul"), node(1, "AXButton", title: "Participați acum"),
    ]
    static let asking: [MeetNode] = [
        node(0, "AXWebArea"), node(1, "AXStaticText", value: "Asking to join..."),
        node(1, "AXStaticText", value: "You'll join the call when someone lets you in"), node(1, "AXButton", title: "Cancel"),
    ]
    static let inCall: [MeetNode] = [
        node(0, "AXWebArea", title: "Meet - abc-defg-hij"),
        node(1, "AXGroup"),
        node(2, "AXButton", desc: "Pin Alice to your main screen"),
        node(2, "AXButton", desc: "More options for Alice"),
        node(1, "AXGroup", desc: "Captions"),
        node(1, "AXToolbar"),
        node(2, "AXButton", desc: "Turn off microphone"),
        node(2, "AXButton", desc: "Turn on captions"),
        node(2, "AXButton", desc: "Leave call"),
    ]
    /// A breakout room's "Join now" inside a call still means the call.
    static let inCallWithJoin = inCall + [node(1, "AXButton", title: "Join now")]
    static let inCallRo: [MeetNode] = [node(0, "AXWebArea"), node(1, "AXButton", desc: "Dezactivează microfonul"), node(1, "AXButton", desc: "Părăsiți apelul")]
    static let ended: [MeetNode] = [
        node(0, "AXWebArea"), node(1, "AXStaticText", value: "You left the meeting"),
        node(1, "AXButton", title: "Rejoin"), node(1, "AXButton", title: "Return to home screen"),
    ]
    static let endedButtonsOnly: [MeetNode] = [node(0, "AXWebArea"), node(1, "AXButton", title: "Rejoin"), node(1, "AXButton", title: "Return to home screen")]
    static let loading: [MeetNode] = [node(0, "AXWebArea"), node(1, "AXGroup"), node(2, "AXGroup")]
    static let home: [MeetNode] = [node(0, "AXWebArea"), node(1, "AXButton", title: "New meeting"), node(1, "AXTextField", desc: "Enter a code or link"),
                                   node(1, "AXButton", title: "Join")]

    /// A call with tiles (one muted), your own tile, a presentation, the captions region and the language control.
    static let busyCall: [MeetNode] = [
        node(0, "AXWebArea", title: "Meet - abc-defg-hij"),
        node(1, "AXGroup"),
        node(2, "AXButton", desc: "Mute Alice's microphone"),
        node(2, "AXButton", desc: "More options for Alice"),
        node(1, "AXGroup"),
        node(2, "AXButton", desc: "You can't unmute someone else"),
        node(2, "AXButton", desc: "More options for Bob"),
        node(1, "AXGroup"),
        node(2, "AXButton", desc: "Backgrounds and effects"),
        node(2, "AXButton", desc: "More options for Sam"),
        node(1, "AXStaticText", value: "Carol (Presentation)"),
        node(1, "AXGroup", desc: "Captions"),
        node(2, "AXGroup", key: 11),
        node(3, "AXStaticText", value: "Alice"),
        node(3, "AXStaticText", value: "so the plan for this week"),
        node(2, "AXGroup", key: 12),
        node(3, "AXStaticText", value: "Bob"),
        node(3, "AXStaticText", value: "sounds good"),
        node(1, "AXComboBox", desc: "Meeting language", value: "English (United States)"),
        node(1, "AXToolbar"),
        node(2, "AXButton", desc: "Turn on microphone"),
        node(2, "AXButton", desc: "Leave call"),
    ]
}
