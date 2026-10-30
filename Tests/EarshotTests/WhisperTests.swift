import Foundation
import Testing
@testable import Earshot

struct RetimingTests {
    @Test func longestChainTakesTheNearestReference() {
        // Word 0 ("da") matches references 0 and 1 equally well; reference 1 is where it was said.
        let words = [word(" da", 5.0, 5.2), word(" bine", 6.0, 6.3)]
        let reference = [word(" da", 1.0, 1.2), word(" da", 5.1, 5.3), word(" bine", 6.1, 6.4)]
        let chain = Retiming.longestChain([(0, 0), (0, 1), (1, 2)]) { abs(words[$0].start - reference[$1].start) }
        #expect(chain.map(\.j) == [1, 2])
        #expect(Retiming.longestChain([(0, 0), (0, 1), (1, 2)]).map(\.j) == [0, 2])
        #expect(Retiming.retime(words, to: reference).map(\.start) == [5.1, 6.1])
    }

    @Test func gapWordsUseOnlyTheGapsReference() {
        // A stretch at 10–14 s decoded again; the same words were also said at 3 s, outside it.
        let gap: WhisperSupport.Gap = (Int(10 * SampleSink.rate)..<Int(14 * SampleSink.rate), 10.2...13.8)
        let found = [word(" alfa", 10.6, 10.9), word(" beta", 11.1, 11.4), word(" gama", 11.6, 11.9)]
        let far = [word(" alfa", 3.0, 3.3), word(" beta", 3.5, 3.8), word(" gama", 4.0, 4.3)]
        #expect(Retiming.gaps(found, in: [gap], reference: far).map(\.start) == found.map(\.start))
        #expect(Retiming.retime(found, to: far).map(\.start) == [3.0, 3.5, 4.0])   // what a meeting-wide retime did
        let inside = far + [word(" alfa", 10.8, 11.0), word(" beta", 11.3, 11.6)]
        #expect(Retiming.gaps(found, in: [gap], reference: inside).map(\.start).prefix(2) == [10.8, 11.3])
    }

    @Test func againKeepsWordsCentredInTheGapAndDropsRepeats() {
        let words = [word(" proiect", 9.5, 10.2), word(" gata", 13.8, 14.1)]
        let gap: WhisperSupport.Gap = (Int(10 * SampleSink.rate)..<Int(14.3 * SampleSink.rate), 10.2...13.8)
        let found = [word(" proiect", 10.0, 10.3),                  // the edge word decoded again from the padding
                     word(" nou", 10.4, 10.7), word(" azi", 13.5, 14.0),
                     word(" gata", 13.9, 14.2)]                     // centred past the gap
        #expect(WhisperSupport.again(words, gaps: [gap], found: found).map(\.text) == [" proiect", " nou", " azi", " gata"])
    }
}

struct WhisperChunkTests {
    /// 30 s of a quiet room with a 200 Hz voice from 5 to 9 s and from 20 to 23 s, at `level` peak.
    private func track(_ level: Float) -> [Float] {
        let rate = SampleSink.rate
        var noise = SystemRandomNumberGenerator()
        return (0..<Int(30 * rate)).map { i in
            let t = Double(i) / rate
            let voice: Float = (5..<9).contains(t) || (20..<23).contains(t) ? level * Float(sin(2 * .pi * 200 * t)) : 0
            return voice + Float.random(in: -0.0004...0.0004, using: &noise)
        }
    }

    @Test func quietTrackStillHasSpeech() {
        let loud = WhisperSupport.speechChunks(track(0.1)), quiet = WhisperSupport.speechChunks(track(0.006))
        #expect(!loud.isEmpty)
        #expect(quiet.count == loud.count)
        let seconds = quiet.reduce(0) { $0 + $1.count } / Int(SampleSink.rate)
        #expect(seconds >= 7)
    }

    @Test func isolatedBlipsAreDropped() {
        var samples = track(0.1)
        for i in Int(27 * SampleSink.rate)..<Int(27.1 * SampleSink.rate) { samples[i] = 0.2 }   // a click, alone
        let chunks = WhisperSupport.speechChunks(samples)
        #expect(!chunks.contains { $0.contains(Int(27.05 * SampleSink.rate)) })
        for i in Int(9.5 * SampleSink.rate)..<Int(9.6 * SampleSink.rate) { samples[i] = 0.2 }   // next to speech
        #expect(WhisperSupport.speechChunks(samples).contains { $0.contains(Int(9.55 * SampleSink.rate)) })
    }

    @Test func batchByMemory() {
        #expect(WhisperSupport.batchSize(memory: 8 << 30) == 4)
        #expect(WhisperSupport.batchSize(memory: 16 << 30) == 8)
        #expect(WhisperSupport.batchSize(memory: 24 << 30) == 8)
        #expect(WhisperSupport.batchSize(memory: 32 << 30) == 16)
        #expect(WhisperSupport.batchSize(memory: 64 << 30) == 16)
    }

    @Test func parakeetLanguages() {
        #expect(Engine.parakeetKnows("ro"))
        #expect(Engine.parakeetKnows("pt-BR"))
        #expect(Engine.parakeetKnows(nil))
        #expect(!Engine.parakeetKnows("ja"))
        #expect(!Engine.parakeetKnows("sr"))
    }
}
