import Foundation
import Testing
@testable import Earshot

struct MeetEventsTests {
    @Test func newToasts() {
        #expect(MeetParse.toasts("Frank lowered their hand") == [.handLowered("Frank")])
        #expect(MeetParse.toasts("Grace started sharing their screen") == [.sharing("Grace", started: true)])
        #expect(MeetParse.toasts("Grace stopped sharing the screen.") == [.sharing("Grace", started: false)])
        #expect(MeetParse.toasts("Alice reacted with 👍") == [.reaction("Alice", "👍")])
        #expect(MeetParse.toasts("You're in this call on another device") == [.elsewhere("You're in this call on another device")])
    }

    @Test func emoji() {
        #expect(MeetParse.isEmoji("👍"))
        #expect(MeetParse.isEmoji("❤️"))
        #expect(MeetParse.isEmoji("👏🏽"))
        #expect(!MeetParse.isEmoji("ok"))
        #expect(!MeetParse.isEmoji("1"))
        #expect(!MeetParse.isEmoji(""))
    }

    @Test func captionsControl() {
        #expect(MeetParse.captionsControl(node(1, "AXButton", desc: "Turn on captions (c)"))! == (false, true))
        #expect(MeetParse.captionsControl(node(1, "AXButton", desc: "Turn off captions"))! == (true, false))
        #expect(MeetParse.captionsControl(node(1, "AXCheckBox", desc: "Captions and translation", value: "1"))! == (true, false))
        #expect(MeetParse.captionsControl(node(1, "AXCheckBox", desc: "Captions and translation", value: "0"))! == (false, true))
        #expect(MeetParse.captionsControl(node(1, "AXStaticText", value: "Turn on captions")) == nil)
        #expect(MeetParse.captionsControl(node(1, "AXButton", desc: "Leave call")) == nil)
    }

    @Test func bareLabel() {
        #expect(MeetParse.bare("Turn on captions (c)") == "Turn on captions")
        #expect(MeetParse.bare("Alice Example") == "Alice Example")
        #expect(MeetParse.checked("1") == true && MeetParse.checked("0") == false && MeetParse.checked(nil) == nil)
    }

    @Test func trackerRecordsNewEvents() {
        var t = MeetTracker()
        _ = t.page(MeetPage(), at: 0)
        var p = MeetPage()
        p.toasts = [.reaction("Alice", "👍"), .sharing("Grace", started: true), .elsewhere("You switched to another device")]
        _ = t.page(p, at: 20)
        let kinds = Set(t.context.events.map(\.kind))
        #expect(kinds.isSuperset(of: [.reaction, .screenShareStarted, .joinedElsewhere]))
    }
}

struct SeriesTests {
    private func meeting(_ id: String, _ title: String, series: String? = nil, day: Double) -> Transcript {
        var t = Transcript(id: id, createdAt: Date(timeIntervalSince1970: day * 86400), title: title, origin: "meeting", model: "m",
                           processingSeconds: 0, text: "", segments: [])
        if let series { var c = MeetingContext(); c.calendar = CalendarInfo(title: title, seriesID: series); t.context = c }
        return t
    }

    @Test func titleKey() {
        #expect(Series.titleKey("Weekly Sync 12.03") == "weekly sync")
        #expect(Series.titleKey("weekly sync") == "weekly sync")
        #expect(Series.titleKey("Planning – Monday 10am") == "planning")
        #expect(Series.titleKey("12.03") == nil)
    }

    @Test func groups() {
        let all = [meeting("a", "Weekly Sync 01.10", day: 1), meeting("b", "Weekly sync", day: 8), meeting("c", "One-off", day: 9),
                   meeting("d", "Design review", series: "S1", day: 2), meeting("e", "Design review", day: 3)]
        let g = Series.groups(all)
        #expect(g["title:weekly sync"] == ["b", "a"])
        #expect(g["S1"] == ["e", "d"])
        #expect(g.count == 2)
        #expect(Series.find("Weekly Sync", in: g) == ["b", "a"])
        #expect(Series.index(g)["d"] == "S1")
    }
}
