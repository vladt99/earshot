import CoreML
import Foundation
import NaturalLanguage
import WhisperKit

/// Only Engine holds it, and Engine serialises inference.
extension WhisperKit: @retroactive @unchecked Sendable {}

/// Whisper large-v3-turbo (WhisperKit, Core ML) for every language except English: decoding options, the cut of
/// long audio into speech chunks, and the guard against Whisper's silence hallucinations.
enum WhisperSupport {
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
            // Over noise every fallback re-decodes the whole window; two keep the gain on hard speech.
            o.temperatureFallbackCount = 2
        }
        return o
    }

    /// Prompt tokens are decoded one by one in every window, and a long prompt makes Whisper drop words: on a Romanian
    /// call, 50 tokens cost +70 % time at unchanged quality, 141 tokens +145 % and 12 % of the words.
    static let promptBudget = 48

    /// Custom and room vocabulary as Whisper's initial prompt (names and terms it should spell this way). Terms that
    /// don't fit the budget are dropped from the end (WhisperKit would cut the front), but never the first `keep` (the
    /// custom vocabulary): those go in even over the budget, up to what WhisperKit keeps of a prompt.
    static func prompt(_ terms: [String], keep: Int = 0, tokenizer: (any WhisperTokenizer)?, budget: Int = promptBudget) -> [Int]? {
        guard !terms.isEmpty, let tokenizer else { return nil }
        for n in stride(from: terms.count, to: 0, by: -1) {
            let tokens = tokenizer.encode(text: " " + terms.prefix(n).joined(separator: ", ")).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if tokens.count <= budget || n <= keep { return tokens.isEmpty ? nil : Array(tokens.prefix(Constants.maxTokenContext / 2 - 1)) }
        }
        return nil
    }

    /// The first decode after a load pays for Core ML's first run; spend it on a second of near-silence.
    static func warmUp(_ kit: WhisperKit) async {
        var o = options(language: "en", translate: false, live: true, prompt: nil)
        o.sampleLength = 8
        var noise = SystemRandomNumberGenerator()
        let quiet = (0..<Int(SampleSink.rate)).map { _ in Float.random(in: -0.001...0.001, using: &noise) }
        _ = try? await kit.transcribe(audioArray: quiet, decodeOptions: o)
    }

    // MARK: Final pass

    /// The final pass decodes speech only: runs of voice (padded by `pad`) joined across pauses shorter than `bridge`,
    /// split at their longest pause when longer than `chunkSeconds`, then packed into chunks of at most `chunkSeconds`
    /// across silences up to `pack`. Longer silences are never decoded (nor hallucinated over).
    static let chunkSeconds = 29.0, bridge = 2.0, pad = 0.5, pack = 5.0
    /// Chunks decoded concurrently per turn of the engine lock (each decode holds its own buffers): by memory, and
    /// fewer while a meeting is live, so its passes get in.
    static let batch = batchSize(memory: ProcessInfo.processInfo.physicalMemory), liveBatch = 3

    static func batchSize(memory: UInt64) -> Int { memory >= 31 << 30 ? 16 : memory >= 15 << 30 ? 8 : 4 }

    /// Speech in the final pass: RMS over 0.003 and 3 × the track's noise floor (its 10th-percentile frame, digital
    /// silence aside), lower than the live streams' 0.02 so a quiet voice or a quiet mic is still decoded.
    static func speechThreshold(_ samples: [Float]) -> Float {
        let n = Int(0.1 * SampleSink.rate)
        let levels = stride(from: 0, to: samples.count, by: n).map { a -> Float in
            let b = min(a + n, samples.count)
            var sum: Float = 0
            for i in a..<b { sum += samples[i] * samples[i] }
            return (sum / Float(max(1, b - a))).squareRoot()
        }.filter { $0 > 0.0001 }.sorted()
        return max(0.003, 3 * (levels.isEmpty ? 0 : levels[levels.count / 10]))
    }

    static func speechChunks(_ samples: [Float]) -> [Range<Int>] {
        let rate = SampleSink.rate, frame = Int(0.1 * rate)
        let voiced = EnergyVAD(frameLength: 0.1, threshold: speechThreshold(samples)).voiceActivity(in: samples)
        var found: [Range<Int>] = [], open: Int?
        for (i, v) in voiced.enumerated() {
            if v, open == nil { open = i }
            if !v, let a = open { found.append(a..<i); open = nil }
        }
        if let a = open { found.append(a..<voiced.count) }
        // A blip under 0.3 s with no other voice within `bridge` (a click, a cough) is dropped; next to speech it stays.
        let near = Int(bridge * 10)
        let runs = found.indices.filter { k in
            found[k].count >= 3 || (k > 0 && found[k].lowerBound - found[k - 1].upperBound <= near)
                || (k + 1 < found.count && found[k + 1].lowerBound - found[k].upperBound <= near)
        }.map { found[$0] }
        let size = Int(chunkSeconds * rate), padding = Int(pad * rate), gap = Int(bridge * rate), packed = Int(pack * rate)
        var spans: [Range<Int>] = []
        for r in runs {
            let a = max(spans.last?.upperBound ?? 0, r.lowerBound * frame - padding), b = min(samples.count, r.upperBound * frame + padding)
            guard b > a else { continue }
            if let last = spans.last, a - last.upperBound <= gap { spans[spans.count - 1] = last.lowerBound..<b } else { spans.append(a..<b) }
        }
        var pieces: [Range<Int>] = []
        for var s in spans {
            while s.count > size {
                let at = cut(samples, from: s.lowerBound, limit: size)
                pieces.append(s.lowerBound..<at)
                s = at..<s.upperBound
            }
            pieces.append(s)
        }
        var out: [Range<Int>] = []
        for p in pieces where p.count >= Int(0.3 * rate) {
            if let last = out.last, p.lowerBound - last.upperBound <= packed, p.upperBound - last.lowerBound <= size {
                out[out.count - 1] = last.lowerBound..<p.upperBound
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// Where a voice going on for longer than a chunk is cut: the middle of its longest pause in the second half of the
    /// chunk (a window starting mid-sentence loses that sentence), else its quietest half second near the limit.
    static func cut(_ samples: [Float], from start: Int, limit: Int) -> Int {
        let frame = Int(0.1 * SampleSink.rate), lo = start + limit / 2, hi = start + limit
        let voiced = EnergyVAD(frameLength: 0.1, threshold: 0.02).voiceActivity(in: Array(samples[lo..<hi])) + [true]
        var best = 0..<0, open: Int?
        for (i, v) in voiced.enumerated() {
            if !v, open == nil { open = i }
            if v, let a = open { if i - a > best.count { best = a..<i }; open = nil }
        }
        if best.count >= 2 { return lo + (best.lowerBound + best.upperBound) / 2 * frame }
        return quietest(samples, in: (hi - Int(8 * SampleSink.rate))..<hi)
    }

    /// A stretch without words: `audio` to decode (padded 0.2 s into the words around it), `gap` between those words (s).
    typealias Gap = (audio: Range<Int>, gap: ClosedRange<Double>)

    /// Whisper sometimes ends a window early and skips the rest of it: the voiced stretches of `chunks` left without
    /// words, to decode once more (`again`).
    static func skipped(_ samples: [Float], chunks: [Range<Int>], words: [LiveWord]) -> [Gap] {
        chunks.flatMap { missed(samples, in: $0, words: words) }
    }

    /// Words decoded from `gaps` whose middle lies between the words around the gap, merged into `words`; a word
    /// repeating the one next to it at an overlapping time (decoded again from the padding) is dropped.
    static func again(_ words: [LiveWord], gaps: [Gap], found: [LiveWord]) -> [LiveWord] {
        let inside = found.filter { w in
            gaps.contains { $0.gap.contains((w.start + w.end) / 2) }
                && !words.contains { $0.key == w.key && $0.start < w.end && w.start < $0.end }
        }
        LiveDebug.log("[whisper] \(gaps.count) skipped stretch(es) decoded again: \(inside.count) words")
        return (words + inside).sorted { $0.start < $1.start }
    }

    /// Decodes `chunks` of `samples` concurrently: their words on the samples' clock, and the language heard first.
    static func decode(_ samples: [Float], chunks: [Range<Int>], kit: WhisperKit, options: DecodingOptions) async throws -> (words: [LiveWord], language: String?) {
        let pieces = chunks.map { Array(samples[$0]) }
        let results = await kit.transcribeWithResults(audioArrays: pieces, decodeOptions: options)
        var words: [LiveWord] = [], language: String?
        for (i, result) in results.enumerated() {
            let r = try result.get()
            language = language ?? r.first?.language
            let offset = Double(chunks[i].lowerBound) / SampleSink.rate
            words += Self.words(r.flatMap(\.segments), samples: pieces[i]).map {
                LiveWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence)
            }
        }
        return (words, language)
    }

    /// Stretches of `chunk` of at least 3 s without a word that hold 1.5 s of voice (the live streams' threshold).
    static func missed(_ samples: [Float], in chunk: Range<Int>, words: [LiveWord]) -> [Gap] {
        let rate = SampleSink.rate
        let a = Double(chunk.lowerBound) / rate, b = Double(chunk.upperBound) / rate
        let inside = words.filter { $0.end > a && $0.start < b }.sorted { $0.start < $1.start }
        var edges = [a]
        for w in inside { edges += [w.start, w.end] }
        edges.append(b)
        var out: [Gap] = []
        for i in stride(from: 0, to: edges.count - 1, by: 2) where edges[i + 1] - edges[i] >= 3 {
            let range = Int(max(a, edges[i] - 0.2) * rate)..<Int(min(b, edges[i + 1] + 0.2) * rate)
            if speechSeconds(Array(samples[range])) >= 1.5 { out.append((range, edges[i]...edges[i + 1])) }
        }
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

    /// Anything above digital silence (and as quiet as the final pass's speech may be).
    static func hasSound(_ samples: [Float]) -> Bool {
        EnergyVAD(frameLength: 0.1, threshold: 0.003).voiceActivity(in: samples).contains(true)
    }

    /// Seconds of voice (EnergyVAD, the live streams' threshold).
    static func speechSeconds(_ samples: [Float]) -> Double {
        Double(EnergyVAD(frameLength: 0.1, threshold: 0.02).voiceActivity(in: samples).filter { $0 }.count) * 0.1
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
                LiveDebug.log("[whisper] dropped (\(reason)): \(s.text.split(separator: " ").count) words")
                continue
            }
            // Whisper's words carry their own leading space; pieces like "-ul" in "Build-ul" don't.
            for (i, w) in (s.words ?? []).enumerated() {
                let text = w.word.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("<|") else { continue }
                let joined = i > 0 && !w.word.hasPrefix(" ") && !out.isEmpty
                let start = min(Double(w.start), duration)
                out.append(LiveWord(text: (joined ? "" : " ") + text, start: start, end: min(max(Double(w.end), start), duration),
                                    confidence: w.probability))
            }
        }
        return out
    }
}

/// With a prompt, Whisper's alignment heads drift: words land later the longer the prompt (≈ 0.06 s per prompt token,
/// 2 s with 33 tokens), and with long prompts a window comes out as one segment. Parakeet's timings of the same audio
/// are exact, so Whisper's words are moved onto them. Pure.
enum Retiming {
    /// Whisper words may be this far (s) from the Parakeet word they are.
    static let band = 12.0

    /// Words spelled alike (VocabularyGuard letters, similarity ≥ 0.75) within `band`, chained in order (longest
    /// increasing run) as anchors: an anchor takes Parakeet's timing, the words between anchors shift by the offset of
    /// the anchors around them. Returned unchanged when under a third of the words can be anchored.
    static func retime(_ words: [LiveWord], to reference: [LiveWord]) -> [LiveWord] { anchored(words, to: reference) ?? words }

    /// How far (s) past a skipped stretch its reference words are looked for.
    static let margin = 0.5

    /// Words decoded again from skipped stretches (`WhisperSupport.again`), each stretch's against the reference
    /// words inside it alone: one far away would pull them out of it. Unanchored, they keep Whisper's timings, which
    /// are already on the stretch.
    static func gaps(_ found: [LiveWord], in gaps: [WhisperSupport.Gap], reference: [LiveWord]) -> [LiveWord] {
        let rate = SampleSink.rate
        return gaps.flatMap { g -> [LiveWord] in
            let a = Double(g.audio.lowerBound) / rate, b = Double(g.audio.upperBound) / rate
            let words = found.filter { $0.start >= a && $0.start <= b }
            let near = reference.filter { $0.end >= a - margin && $0.start <= b + margin }
            return anchored(words, to: near) ?? words
        }
    }

    /// nil when under two words, or a third of them, can be anchored.
    static func anchored(_ words: [LiveWord], to reference: [LiveWord]) -> [LiveWord]? {
        guard words.count >= 2, !reference.isEmpty else { return nil }
        let a = words.map { VocabularyGuard.letters($0.text) }, b = reference.map { VocabularyGuard.letters($0.text) }
        var pairs: [(i: Int, j: Int)] = [], lo = 0
        for i in words.indices where !a[i].isEmpty {
            while lo < reference.count, reference[lo].start < words[i].start - band { lo += 1 }
            var j = lo
            while j < reference.count, reference[j].start <= words[i].start + band {
                if a[i] == b[j] || (min(a[i].count, b[j].count) >= 3 && VocabularyGuard.similarity(a[i], b[j]) >= 0.75) { pairs.append((i, j)) }
                j += 1
            }
        }
        let chain = longestChain(pairs) { abs(words[$0].start - reference[$1].start) }
        guard chain.count >= max(2, words.count / 3) else { return nil }
        var out = words
        for (i, j) in chain {
            out[i].start = reference[j].start
            out[i].end = reference[j].end
        }
        // Between anchors: each word keeps its own spacing, shifted by the anchors' offsets (interpolated in time).
        let anchored = Set(chain.map(\.i))
        var k = 0
        for i in words.indices where !anchored.contains(i) {
            while k < chain.count, chain[k].i < i { k += 1 }
            let before = k > 0 ? chain[k - 1] : nil, after = k < chain.count ? chain[k] : nil
            func delta(_ p: (i: Int, j: Int)) -> Double { reference[p.j].start - words[p.i].start }
            let shift: Double
            switch (before, after) {
            case let (b?, f?):
                let span = words[f.i].start - words[b.i].start
                let f0 = span > 0 ? (words[i].start - words[b.i].start) / span : 0.5
                shift = delta(b) + (delta(f) - delta(b)) * min(1, max(0, f0))
            case let (b?, nil): shift = delta(b)
            case let (nil, f?): shift = delta(f)
            default: shift = 0
            }
            let floor = before.map { reference[$0.j].end } ?? 0, ceiling = after.map { reference[$0.j].start } ?? .infinity
            let start = min(max(words[i].start + shift, floor), ceiling)
            out[i].start = start
            out[i].end = min(max(words[i].end + shift, start), max(start, ceiling))
        }
        return out
    }

    /// Longest run of pairs increasing in both indices (patience sorting); where a word can take several references
    /// without shortening the run, the nearest by `distance` (not the earliest).
    static func longestChain(_ pairs: [(i: Int, j: Int)], distance: (Int, Int) -> Double = { _, _ in 0 }) -> [(i: Int, j: Int)] {
        let sorted = pairs.sorted { $0.i != $1.i ? $0.i < $1.i : $0.j > $1.j }
        var tails: [Int] = [], back = [Int](repeating: -1, count: sorted.count)
        for (n, p) in sorted.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi { let m = (lo + hi) / 2; if sorted[tails[m]].j < p.j { lo = m + 1 } else { hi = m } }
            if lo > 0 { back[n] = tails[lo - 1] }
            if lo == tails.count { tails.append(n) } else { tails[lo] = n }
        }
        var out: [(i: Int, j: Int)] = [], n = tails.last ?? -1
        while n >= 0 { out.append(sorted[n]); n = back[n] }
        out.reverse()
        let options = Dictionary(grouping: pairs, by: \.i)
        for k in out.indices {
            let lo = k > 0 ? out[k - 1].j : -1, hi = k + 1 < out.count ? out[k + 1].j : Int.max
            if let p = options[out[k].i]?.filter({ $0.j > lo && $0.j < hi }).min(by: { distance($0.i, $0.j) < distance($1.i, $1.j) }) { out[k] = p }
        }
        return out
    }
}

/// WhisperKit times words from the decoder's attention rows counted from the transcript's first token, but with a
/// prompt (custom vocabulary) those rows begin with the prompt: each word got the timing of the token a prompt's
/// length before it (≈ 1.9 s early), and the first words of every window all landed at 0.00. The rows are shifted
/// past the prompt before WhisperKit aligns them.
final class PromptAlignedSeeker: SegmentSeeking {
    private let inner = SegmentSeeker()

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int, currentSeek seek: Int,
                                  segmentSize: Int, sampleRate: Int, timeToken: Int, specialToken: Int,
                                  tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        inner.findSeekPointAndSegments(decodingResult: decodingResult, options: options, allSegmentsCount: allSegmentsCount, currentSeek: seek,
                                       segmentSize: segmentSize, sampleRate: sampleRate, timeToken: timeToken, specialToken: specialToken,
                                       tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray, tokenizer: WhisperTokenizer, seek: Int,
                           segmentSize: Int, prependPunctuations: String, appendPunctuations: String, lastSpeechTimestamp: Float,
                           options: DecodingOptions, timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        let rows = Self.promptRows(options, tokenizer: tokenizer)
        return try inner.addWordTimestamps(segments: segments, alignmentWeights: rows > 0 ? try Self.drop(rows, of: alignmentWeights) : alignmentWeights,
                                           tokenizer: tokenizer, seek: seek, segmentSize: segmentSize, prependPunctuations: prependPunctuations,
                                           appendPunctuations: appendPunctuations, lastSpeechTimestamp: lastSpeechTimestamp,
                                           options: options, timings: timings)
    }

    /// Rows the prompt adds ahead of the transcript, as WhisperKit trims it. Measured against Parakeet's timings
    /// (four 25 s clips): shifting by the prompt's length leaves words 0.1–0.2 s late on average; one row more, 0.4–0.5 s.
    static func promptRows(_ options: DecodingOptions, tokenizer: WhisperTokenizer) -> Int {
        guard options.usePrefillPrompt, let prompt = options.promptTokens else { return 0 }
        return prompt.suffix(Constants.maxTokenContext / 2 - 1).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count
    }

    static func drop(_ rows: Int, of weights: MLMultiArray) throws -> MLMultiArray {
        let shape = weights.shape.map(\.intValue)
        guard shape.count >= 2, let columns = shape.last, rows < shape[shape.count - 2] else { return weights }
        let out = try MLMultiArray(shape: weights.shape, dataType: weights.dataType)
        let total = shape.reduce(1, *)
        weights.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst, _ in
                let size = src.count / total, skip = rows * columns * size
                memset(dst.baseAddress!, 0, dst.count)
                memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: skip), src.count - skip)
            }
        }
        return out
    }
}
