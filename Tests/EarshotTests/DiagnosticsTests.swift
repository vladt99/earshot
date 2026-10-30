import Foundation
import Testing
@testable import Earshot

struct DiagnosticsTests {
    /// None of the letters of `secret`'s words survive in `out`.
    private func hides(_ out: String?, _ secrets: [String]) -> Bool {
        guard let out else { return true }
        let lower = out.lowercased()
        return secrets.allSatisfy { s in
            s.lowercased().split { !$0.isLetter }.allSatisfy { !lower.contains($0) }
        }
    }

    @Test func roomVocabulary() {
        let out = Diagnostics.filter("[vocab] room: Ana Pop, Acme")
        #expect(out == "[vocab] room: …, …")
    }

    @Test func names() {
        let out = Diagnostics.filter("[speakers] Speaker 2 named Zorblina O'Brien")
        #expect(out == "[speakers] Speaker 2 named …")
        #expect(hides(Diagnostics.filter("[meet] call ended: stopping Quarterly Zorblin review"), ["Quarterly Zorblin review"]))
    }

    @Test func titlesWithApostrophes() {
        let line = "[audio] compressed 2026-10-29_10-00-00 Pat's Zorblin sync: 512 KB → 128 KB"
        let out = Diagnostics.filter(line)
        #expect(out == "[audio] compressed 2026-10-29_10-00-00 …: 512 KB → 128 KB")
        #expect(hides(Diagnostics.filter("[prejoin] left Pat’s ‘weekly’ Zorblin"), ["Pat’s weekly Zorblin"]))
    }

    @Test func captionText() {
        let out = Diagnostics.filter("[captions] 'sore blin budget' → 'Zorblin budget'")
        #expect(out == "[captions] '…' → '…'")
        #expect(hides(Diagnostics.filter("[captions] sore blin budget → Zorblin budget"), ["sore blin budget", "Zorblin"]))
        #expect(Diagnostics.filter("[vocab] text=we ship Zorblin 42 tomorrow") == "[vocab] text=…")
    }

    @Test func meetingCodes() {
        #expect(Diagnostics.filter("[prejoin] preJoin abc-defg-hij in Google Chrome") == "[prejoin] preJoin … in …")
    }

    @Test func technicalWordsStay() {
        #expect(Diagnostics.filter("[meet] health: missing captions,mic (412 nodes, phase inCall, captions off)")
                == "[meet] health: missing captions,mic (412 nodes, phase inCall, captions off)")
        #expect(Diagnostics.filter("[tap] restarted: 48000 Hz format fallback") == "[tap] restarted: 48000 Hz format fallback")
    }

    @Test func textTagsAndOthers() {
        #expect(Diagnostics.filter("[mic] t=1.00 words=hello@0.1 there@0.4") == nil)
        #expect(Diagnostics.filter("[app] t=1.00 win=2.00 words=hello@0.1 there@0.4 confirm=2") == nil)
        #expect(Diagnostics.filter("[APP] decode failed: hello there") == nil)
        #expect(Diagnostics.filter("[mic] error: hello there") == nil)
        #expect(Diagnostics.filter("[echo] dropped mic line: hello failed") == nil)
        #expect(Diagnostics.filter("[ui] something happened") == nil)
        #expect(Diagnostics.filter("[ui] export failed for Zorblin notes") == "[…] … failed …")
        #expect(Diagnostics.filter("no tag at all") == nil)
    }
}
