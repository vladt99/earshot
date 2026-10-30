import Foundation
import Testing
@testable import Earshot

struct PreJoinFlowTests {
    private func run(_ reads: [(MeetPhase?, Bool)]) -> [PreJoinFlow.Event] {
        var f = PreJoinFlow()
        return reads.map { f.read($0.0, truncated: $0.1) }
    }

    private func pages(_ list: [[MeetNode]?]) -> [(MeetPhase?, Bool)] { list.map { ($0.map(MeetParse.phase), false) } }

    @Test func openGreenRoomThenJoin() {
        #expect(run(pages([Pages.loading, Pages.greenRoom, Pages.greenRoom, Pages.inCall])) == [.none, .show, .none, .join])
    }

    @Test func askToJoinThenAdmitted() {
        #expect(run(pages([Pages.greenRoomGuest, Pages.asking, Pages.asking, Pages.inCall])) == [.show, .update, .none, .join])
    }

    @Test func greenRoomThenEndScreen() {
        #expect(run(pages([Pages.greenRoom, Pages.ended])) == [.show, .leave])
    }

    @Test func tabClosed() {
        #expect(run(pages([Pages.greenRoom, nil, nil, nil])) == [.show, .none, .none, .lost])
    }

    @Test func oneBusyReadDoesNotLoseIt() {
        #expect(run(pages([Pages.greenRoom, nil, Pages.greenRoom, nil, nil, Pages.inCall])) == [.show, .none, .none, .none, .none, .join])
    }

    @Test func pageWentBlank() {
        #expect(run(pages([Pages.greenRoom, Pages.loading, Pages.loading, Pages.loading])) == [.show, .none, .none, .lost])
    }

    @Test func truncatedWalkMeansTheCall() {
        #expect(run([(.preJoin, false), (.unknown, true)]) == [.show, .join])
    }

    @Test func callWithoutGreenRoomShowsNothing() {
        #expect(run(pages([Pages.inCall, Pages.ended, Pages.greenRoom])) == [.none, .none, .show])
    }

    @Test func joinsOnce() {
        #expect(run(pages([Pages.greenRoom, Pages.inCall, Pages.inCall])) == [.show, .join, .none])
    }

    @Test func resetClearsState() {
        var f = PreJoinFlow()
        _ = f.read(.preJoin)
        _ = f.read(nil)
        f.reset()
        #expect(f.phase == nil && f.misses == 0)
    }
}

struct PreJoinMemoryTests {
    @Test func lookups() {
        var mem = PreJoinMemory()
        mem.remember(PreJoinChoice(language: "ro", action: "record"), code: "abc-defg-hij", eventID: "EVT-1", title: "Weekly Sync")
        #expect(mem.choice(code: "abc-defg-hij", eventID: nil, title: nil)?.language == "ro")
        #expect(mem.choice(code: "ABC-DEFG-HIJ", eventID: nil, title: nil)?.language == "ro")
        #expect(mem.choice(code: "xyz-wxyz-xyz", eventID: "EVT-1", title: nil)?.language == "ro")
        #expect(mem.choice(code: nil, eventID: nil, title: "  weekly   sync ")?.language == "ro")
        #expect(mem.choice(code: "nop-qrst-uvw", eventID: "EVT-2", title: "Acme kickoff") == nil)
    }

    @Test func codeWinsOverSeries() {
        var mem = PreJoinMemory()
        mem.remember(PreJoinChoice(language: "ro", action: "record"), code: "abc-defg-hij", eventID: "EVT-1", title: nil)
        mem.remember(PreJoinChoice(language: "en", action: "captions"), code: "abc-defg-hij", eventID: nil, title: nil)
        #expect(mem.choice(code: "abc-defg-hij", eventID: "EVT-1", title: nil)?.action == "captions")
        #expect(mem.choice(code: nil, eventID: "EVT-1", title: nil)?.action == "record")
    }

    @Test func seriesKeys() {
        #expect(PreJoinMemory.seriesKeys(eventID: "E", title: "Équipe  Daily") == ["event:E", "title:equipe daily"])
        #expect(PreJoinMemory.seriesKeys(eventID: "", title: "ab") == [])
    }

    @Test func roundTrip() throws {
        var mem = PreJoinMemory()
        mem.remember(PreJoinChoice(language: "en", action: "none"), code: "abc-defg-hij", eventID: nil, title: "Planning")
        let back = try JSONDecoder().decode(PreJoinMemory.self, from: JSONEncoder().encode(mem))
        #expect(back.codes.count == 1)
        #expect(back.series["title:planning"]?.action == "none")
    }

    @Test func cappedOldestDropped() {
        var big = PreJoinMemory()
        for i in 0..<(PreJoinMemory.limit + 20) {
            big.remember(PreJoinChoice(language: "en", action: "record", at: Date(timeIntervalSince1970: Double(i))), code: "c\(i)", eventID: nil, title: nil)
        }
        #expect(big.codes.count == PreJoinMemory.limit)
        #expect(big.codes["c\(PreJoinMemory.limit + 19)"] != nil)
        #expect(big.codes["c0"] == nil)
    }
}
