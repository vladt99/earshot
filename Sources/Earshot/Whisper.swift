import Foundation
import NaturalLanguage
import WhisperKit

/// Only Engine holds it, and Engine serialises inference.
extension WhisperKit: @retroactive @unchecked Sendable {}

/// Whisper large-v3-turbo (WhisperKit, Core ML) for every language except English: decoding options, the cut of
/// long audio into blocks, and the guard against Whisper's silence hallucinations.
enum WhisperSupport {
    /// Long audio goes through in blocks of about this length, so a waiting live pass gets the engine in between.
    static let blockSeconds = 120.0

    /// The encoder runs ≈ 3.5× faster on the GPU than on the Neural Engine (M2 Max: 0.33 s vs 1.2 s per window).
    static let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)

    static func options(language: String?, translate: Bool, live: Bool, prompt: [Int]?) -> DecodingOptions {
        var o = DecodingOptions()
        o.task = translate ? .translate : .transcribe
        o.language = language
        o.detectLanguage = language == nil
        o.usePrefillPrompt = true
        o.skipSpecialTokens = true
        o.wordTimestamps = true
        o.promptTokens = prompt
        // An unlikely first token (a window starting mid-sentence) would otherwise end the window empty at every temperature.
        o.firstTokenLogProbThreshold = nil
        if live {
            // One window (≤ 25 s): no sampling fallback (passes must agree, the guard drops loops); the tail is decoded too.
            o.temperatureFallbackCount = 0
            o.windowClipTime = 0.2
        } else {
            o.chunkingStrategy = .vad
        }
        return o
    }

    /// Custom vocabulary as Whisper's initial prompt (names and terms it should spell this way).
    static func prompt(_ terms: [String], tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        guard !terms.isEmpty, let tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + terms.joined(separator: ", ")).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    /// Sample ranges of about `blockSeconds`, each cut in the quietest half second of its last 10 s.
    static func blocks(_ samples: [Float], seconds: Double = blockSeconds) -> [Range<Int>] {
        let rate = SampleSink.rate, size = Int(seconds * rate)
        var out: [Range<Int>] = [], start = 0
        while samples.count - start > size + size / 4 {
            let cut = quietest(samples, in: (start + size - Int(10 * rate))..<(start + size))
            out.append(start..<cut)
            start = cut
        }
        out.append(start..<samples.count)
        return out
    }

    /// Middle of the lowest-energy 0.5 s span in `range` (0.1 s steps).
    static func quietest(_ samples: [Float], in range: Range<Int>) -> Int {
        let rate = SampleSink.rate, span = Int(0.5 * rate), hop = Int(0.1 * rate)
        var best = range.upperBound, bestEnergy = Float.greatestFiniteMagnitude
        var i = range.lowerBound
        while i + span <= range.upperBound {
            var e: Float = 0
            for k in i..<(i + span) { e += samples[k] * samples[k] }
            if e < bestEnergy { bestEnergy = e; best = i + span / 2 }
            i += hop
        }
        return best
    }

    /// large-v3-turbo was not trained to translate and often answers in the spoken language.
    static func isEnglish(_ words: [LiveWord]) -> Bool {
        let r = NLLanguageRecognizer()
        r.processString(words.map(\.text).joined())
        return r.dominantLanguage == .english
    }

    /// Anything above digital silence.
    static func hasSound(_ samples: [Float]) -> Bool {
        EnergyVAD(frameLength: 0.1, threshold: 0.005).voiceActivity(in: samples).contains(true)
    }

    /// Share of 0.1 s frames with voice (EnergyVAD, the live streams' threshold) in [start, end] s, padded 0.5 s.
    static func voiced(_ samples: [Float], start: Double, end: Double) -> Double {
        let rate = SampleSink.rate
        let a = max(0, min(samples.count, Int((start - 0.5) * rate))), b = max(a, min(samples.count, Int((end + 0.5) * rate)))
        let frames = EnergyVAD(frameLength: 0.1, threshold: 0.02).voiceActivity(in: Array(samples[a..<b]))
        return frames.isEmpty ? 0 : Double(frames.filter { $0 }.count) / Double(frames.count)
    }

    // MARK: Hallucination guard

    /// What Whisper writes over silence, learned from subtitled video: normalized (lowercase, no diacritics or
    /// punctuation). A segment counts when it contains one and adds at most a few words ("Să vă mulțumesc
    /// pentru vizionare!", "Subtitrare realizată de …").
    static let stock = [
        "pentru vizionare", "subtitrare", "subtitrarea", "subtitrari", "abonati va", "abonativa", "va abonati",
        "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe", "subscribe to my channel",
        "untertitel", "untertitelung", "sous titres", "sous titrage", "amara org", "napisy", "sottotitoli", "ondertiteling",
    ].map { $0.split(separator: " ").map(String.init) }

    static func normalized(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func isStock(_ words: [String]) -> Bool {
        stock.contains { phrase in
            words.count >= phrase.count && words.count <= phrase.count + 4
                && (0...(words.count - phrase.count)).contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
        }
    }

    /// Segments → timed words, minus what Whisper made up: loops (compression ratio), unsure text over silence,
    /// stock subtitle/outro lines over quiet audio, and the same line repeated.
    static func words(_ segments: [TranscriptionSegment], samples: [Float]) -> [LiveWord] {
        let duration = Double(samples.count) / SampleSink.rate
        var out: [LiveWord] = []
        var last: [String] = [], repeats = 0
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let key = normalized(s.text)
            // Timestamps past the audio are decoded from the padding of the last 30 s window.
            guard !key.isEmpty, Double(s.start) < duration - 0.1 else { continue }
            let voice = voiced(samples, start: Double(s.start), end: Double(s.end))
            var reason: String?
            if s.compressionRatio > 2.4 { reason = "repetitive" }
            else if s.noSpeechProb > 0.6, s.avgLogprob < -1 { reason = "no speech" }
            else if s.avgLogprob < -1, voice < 0.1 { reason = "unsure over silence" }
            else if isStock(key), voice < 0.3 { reason = "stock phrase over quiet audio" }
            else if key == last, key.count >= 3 || repeats > 0 { reason = "repeated" }
            if key == last { repeats += 1 } else { repeats = 0 }
            last = key
            if let reason {
                LiveDebug.log("[whisper] dropped (\(reason)): \(s.text)")
                continue
            }
            // Whisper's words carry their own leading space; pieces like "-ul" in "Build-ul" don't.
            for (i, w) in (s.words ?? []).enumerated() {
                let text = w.word.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("<|") else { continue }
                let joined = i > 0 && !w.word.hasPrefix(" ") && !out.isEmpty
                let start = min(Double(w.start), duration)
                out.append(LiveWord(text: (joined ? "" : " ") + text, start: start, end: min(max(Double(w.end), start), duration)))
            }
        }
        return out
    }
}
