import Foundation
import Testing
@testable import Earshot

struct SeriesLookupTests {
    private func meeting(_ id: String, _ title: String, day: Double, series: String? = nil, calendarTitle: String? = nil) -> Transcript {
        var t = Transcript(id: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + day * 86400), title: title, sourcePath: nil,
                           origin: "meeting", model: "", language: nil, duration: nil, processingSeconds: 0, text: "", segments: [])
        if series != nil || calendarTitle != nil {
            var c = MeetingContext()
            c.calendar = CalendarInfo(title: calendarTitle, seriesID: series)
            t.context = c
        }
        return t
    }

    @Test func titleFindsCalendarSeries() {
        let index = Series.build([
            meeting("a", "Zorblin sync", day: 1, series: "uid-1", calendarTitle: "Zorblin sync"),
            meeting("b", "Zorblin sync", day: 8, series: "uid-1", calendarTitle: "Zorblin sync"),
            meeting("c", "Zorblin Sync 12.03", day: 15),
        ])
        #expect(index.groups["uid-1"] == ["c", "b", "a"])
        #expect(Series.find("Zorblin sync", in: index) == ["c", "b", "a"])
        #expect(Series.find("title:zorblin sync", in: index) == ["c", "b", "a"])
        #expect(Series.find("uid-1", in: index) == ["c", "b", "a"])
        #expect(Series.find("Other meeting", in: index) == nil)
        #expect(index.byMeeting["c"] == "uid-1")
    }

    @Test func defaultTitlesAreNoSeries() {
        let generic = ["Zoom meeting", "Google Meet meeting", "Meeting Oct 29, 2026 at 10:00 AM", "Meeting Nov 2, 2026 at 3:30 PM",
                       "Dia meeting", "System audio", "Live Captions", "Google Chrome meeting"]
        let meetings = generic.enumerated().flatMap { i, title in
            [meeting("\(i)a", title, day: Double(i)), meeting("\(i)b", title, day: Double(i) + 0.5)]
        }
        #expect(Series.groups(meetings).isEmpty)
        for title in generic { #expect(Series.isGeneric(title)) }
        #expect(!Series.isGeneric("Team meeting"))
        #expect(Series.groups([meeting("x", "Team meeting", day: 1), meeting("y", "Team meeting", day: 8)]) == ["title:team meeting": ["y", "x"]])
    }
}

struct DailyNoteTests {
    @Test func relativeFolderIsUnderHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(PostProcess.dailyNoteFolder("Notes/Daily", home: home).path == "/Users/example/Notes/Daily")
        #expect(PostProcess.dailyNoteFolder("/Volumes/Vault/Daily", home: home).path == "/Volumes/Vault/Daily")
        #expect(PostProcess.dailyNoteFolder("~/Vault", home: home).path.hasSuffix("/Vault"))
        #expect(!PostProcess.dailyNoteFolder("~/Vault", home: home).path.hasPrefix("~"))
    }

    @Test func lineEndings() {
        let entry = "- [[Zorblin sync]] 10:00 Zorblin sync"
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: nil) == entry + "\n")
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("# Today\n".utf8)) == entry + "\n")
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("# Today\r\n".utf8)) == entry + "\r\n")
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("# Today\r\nmore".utf8)) == "\r\n" + entry + "\r\n")
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("# Today".utf8)) == "\n" + entry + "\n")
    }

    @Test func duplicatesAreExact() {
        let entry = "- [[Zorblin sync]] 10:00 Zorblin sync"
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("- [[Zorblin sync]] 09:00\n".utf8)) == nil)
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("- [[Zorblin sync abcdef]] 09:00\n".utf8)) == nil)
        #expect(PostProcess.dailyNoteLine(entry, link: "Zorblin sync", id: "abcdef12", existing: Data("- [[Zorblin sync 2]] 09:00\n".utf8)) != nil)
    }
}
