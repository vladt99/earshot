import AppKit
import Carbon.HIToolbox
import Foundation

/// "This person was speaking at `time`" (seconds on the meeting-audio clock), read from Meet's captions.
struct SpeakerHint: Codable, Sendable {
    var time: Double
    var name: String
}

/// meeting.json in every meeting folder, written while recording. If Earshot quits mid-meeting, the next
/// launch finds `saved == false` and transcribes what was recorded.
struct MeetingManifest: Codable {
    var id: String
    var title: String
    var appName: String
    var appBundle: String?
    var platform: String
    var origin: String
    var startedAt: Date
    var captureMic: Bool
    var language: String?
    var notes: [Note] = []
    var speakerHints: [SpeakerHint] = []
    /// A session that is never saved (Live Captions): recovery deletes its folder.
    var discard: Bool? = nil
    var saved = false

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("meeting.json") }

    func write(to folder: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Self.url(folder), options: .atomic)
    }

    static func read(_ folder: URL) -> MeetingManifest? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(folder))).flatMap { try? d.decode(MeetingManifest.self, from: $0) }
    }

    static func markSaved(_ folder: URL) {
        guard var m = read(folder) else { return }
        m.saved = true
        m.write(to: folder)
    }
}

/// speakers.json: speaker label → voice embedding for one meeting, so naming a speaker later teaches Earshot
/// that person's voice.
enum MeetingVoices {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("speakers.json") }

    static func read(_ folder: URL) -> [String: [Float]] {
        (try? Data(contentsOf: url(folder))).flatMap { try? JSONDecoder().decode([String: [Float]].self, from: $0) } ?? [:]
    }

    static func write(_ voices: [String: [Float]], to folder: URL) {
        try? JSONEncoder().encode(voices).write(to: url(folder), options: .atomic)
    }

    /// A speaker was renamed in the editor: remember the voice under the new name.
    static func renamed(in folder: URL, from old: String, to new: String) {
        var voices = read(folder)
        guard let voice = voices.removeValue(forKey: old) else { return }
        voices[new] = voice
        write(voices, to: folder)
        if Settings.rememberVoices { Store.shared.learnVoice(new, voice) }
    }
}

/// context.json in a meeting folder: what the meeting app showed about the room, its people, captions and events.
enum MeetingContextFile {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("context.json") }

    static func read(_ folder: URL) -> MeetingContext? {
        (try? Data(contentsOf: url(folder))).flatMap { try? decoder.decode(MeetingContext.self, from: $0) }
    }

    static func write(_ context: MeetingContext, to folder: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(context).write(to: url(folder), options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Turns speaker clusters ("Speaker 1") into names.
enum SpeakerNaming {
    /// Meet captions name whoever is talking; a caption appears ~0.3–3 s after the words. Each hint votes for the
    /// speaker whose turns overlap that window; a speaker gets a name with ≥ 2 s of votes and ≥ 60 % of its votes.
    static func fromHints(turns: [(start: Double, end: Double, speaker: String)], hints: [SpeakerHint]) -> [String: String] {
        var votes: [String: [String: Double]] = [:]
        for h in hints {
            let a = h.time - 3.0, b = h.time - 0.2
            for t in turns {
                let o = min(t.end, b) - max(t.start, a)
                if o > 0 { votes[t.speaker, default: [:]][h.name, default: 0] += o }
            }
        }
        let candidates = votes.flatMap { speaker, byName -> [(String, String, Double)] in
            let total = byName.values.reduce(0, +)
            return byName.filter { $0.value >= 2 && $0.value / total >= 0.6 }.map { (speaker, $0.key, $0.value) }
        }
        return assignUnique(candidates)
    }

    /// Saved voices: cosine similarity ≥ 0.7 and clearly better (by 0.08) than the next person.
    static func fromVoices(_ voices: [String: [Float]], known: [String: [Float]], taken: Set<String>) -> [String: String] {
        var candidates: [(String, String, Double)] = []
        for (speaker, v) in voices {
            let scored = known.filter { !taken.contains($0.key) }.map { ($0.key, cosine(v, $0.value)) }.sorted { $0.1 > $1.1 }
            guard let best = scored.first, best.1 >= 0.7, best.1 - (scored.dropFirst().first?.1 ?? 0) >= 0.08 else { continue }
            candidates.append((speaker, best.0, best.1))
        }
        return assignUnique(candidates)
    }

    /// Strongest pairs first; each speaker and each name used once.
    static func assignUnique(_ candidates: [(speaker: String, name: String, score: Double)]) -> [String: String] {
        var out: [String: String] = [:]
        var used = Set<String>()
        for c in candidates.sorted(by: { $0.score > $1.score }) where out[c.speaker] == nil && !used.contains(c.name) {
            out[c.speaker] = c.name
            used.insert(c.name)
        }
        return out
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }
}

typealias SpeakerTurn = (start: Double, end: Double, speaker: String)

/// From diarizer clusters to speaker turns without flicker, sentences with one speaker each, and names from the
/// meeting's captions. Pure: the same code runs live, in the polish and on files.
enum SpeakerPipeline {
    /// Voices this close (cosine of the cluster centroids) are one person split in two. Different people measure
    /// 0.1–0.35, one person split by pyannote 0.64–0.96. Bounded by a roster, only near-identical voices merge.
    static let sameVoice = 0.6, sameVoiceBounded = 0.9
    /// A cluster with less talk than this (seconds, or share of all talk) is folded into its nearest voice.
    static let tinyTalk = 8.0, tinyShare = 0.03
    /// A run of another speaker shorter than this between two runs of the same speaker is that speaker.
    static let flicker = 1.5

    // MARK: How many speakers

    /// Bounds for the diarizer: at most everyone who can be heard and was in the call while it recorded (plus caption
    /// speakers missing from the roster), at least everyone else who spoke in the captions. nil without a roster.
    static func range(_ c: MeetingContext?, duration: Double) -> (min: Int, max: Int)? {
        guard let c else { return nil }
        let quiet = Set(c.participants.filter { $0.isSelf || $0.bot }.map { key($0.name) })
        let present = c.speakingParticipants.filter { ($0.joinedAt ?? 0) < max(duration, 1) && ($0.leftAt ?? .infinity) > 0 }
        var turns: [String: Int] = [:]
        for t in c.captions where !t.isSelf { turns[key(t.speaker), default: 0] += 1 }
        let captioned = Set(turns.keys).subtracting(quiet).subtracting([""])
        let most = Set(present.map { key($0.name) }).union(captioned).count
        guard most > 0 else { return nil }
        // Someone with a single caption said a word or two: not enough to make the diarizer find them.
        let least = captioned.filter { turns[$0, default: 0] >= 2 }.count
        return (min(max(1, least), most), most)
    }

    static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Cleaner clusters

    static func talk(_ turns: [SpeakerTurn]) -> [String: Double] {
        turns.reduce(into: [:]) { $0[$1.speaker, default: 0] += max(0, $1.end - $1.start) }
    }

    /// Clusters with near-identical voices become one. Without a roster to bound the count (`absorb`), clusters
    /// with hardly any talk are also folded into the neighbouring voice they sound most like.
    static func tidy(_ turns: [SpeakerTurn], embeddings: [String: [Float]], same: Double = sameVoice,
                     absorb: Bool = true) -> ([SpeakerTurn], [String: [Float]]) {
        var turns = turns.sorted { $0.start < $1.start }, voices = embeddings
        var seconds = talk(turns)
        while true {
            var best: (a: String, b: String, sim: Double)?
            let ids = seconds.keys.sorted()
            for (i, a) in ids.enumerated() {
                for b in ids[(i + 1)...] {
                    guard let va = voices[a], let vb = voices[b] else { continue }
                    let sim = SpeakerNaming.cosine(va, vb)
                    if sim >= same, sim > (best?.sim ?? 0) { best = (a, b, sim) }
                }
            }
            guard let best else { break }
            let (keep, gone) = seconds[best.a]! >= seconds[best.b]! ? (best.a, best.b) : (best.b, best.a)
            voices[keep] = mean(voices[keep]!, seconds[keep]!, voices[gone]!, seconds[gone]!)
            voices[gone] = nil
            for i in turns.indices where turns[i].speaker == gone { turns[i].speaker = keep }
            seconds = talk(turns)
        }
        let total = seconds.values.reduce(0, +)
        let tiny = Set(seconds.filter { $0.value < tinyTalk || $0.value < tinyShare * total }.keys)
        let kept = seconds.keys.filter { !tiny.contains($0) }
        guard absorb, !tiny.isEmpty, !kept.isEmpty else { return (joined(turns), voices) }
        let original = turns
        for i in turns.indices where tiny.contains(turns[i].speaker) {
            let id = turns[i].speaker
            let before = original[..<i].last { !tiny.contains($0.speaker) && turns[i].start - $0.end < 3 }?.speaker
            let after = original[(i + 1)...].first { !tiny.contains($0.speaker) && $0.start - turns[i].end < 3 }?.speaker
            let near = [before, after].compactMap { $0 }
            let pool = near.isEmpty ? kept : near
            turns[i].speaker = pool.max { a, b in
                let sa = voices[id].flatMap { v in voices[a].map { SpeakerNaming.cosine(v, $0) } } ?? -1
                let sb = voices[id].flatMap { v in voices[b].map { SpeakerNaming.cosine(v, $0) } } ?? -1
                return sa != sb ? sa < sb : (seconds[a] ?? 0) < (seconds[b] ?? 0)
            }!
        }
        for id in tiny { voices[id] = nil }
        return (joined(turns), voices)
    }

    private static func mean(_ a: [Float], _ wa: Double, _ b: [Float], _ wb: Double) -> [Float] {
        guard a.count == b.count, wa + wb > 0 else { return a }
        return zip(a, b).map { Float((Double($0) * wa + Double($1) * wb) / (wa + wb)) }
    }

    /// Consecutive turns of one speaker less than `flicker` apart become one turn.
    static func joined(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var out: [SpeakerTurn] = []
        for t in turns.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.speaker == t.speaker, t.start - last.end < flicker {
                out[out.count - 1].end = max(last.end, t.end)
            } else {
                out.append(t)
            }
        }
        return out
    }

    /// A run shorter than `flicker` that sits (within a second either side) between two runs of the same speaker is
    /// that speaker: pyannote flips for a moment inside one person's sentence.
    static func smooth(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var t = joined(turns)
        var changed = true
        while changed, t.count > 2 {
            changed = false
            for i in 1..<(t.count - 1) where t[i - 1].speaker == t[i + 1].speaker && t[i].speaker != t[i - 1].speaker
                && t[i].end - t[i].start < flicker && t[i].start - t[i - 1].end < 1 && t[i + 1].start - t[i].end < 1 {
                t[i].speaker = t[i - 1].speaker
                changed = true
            }
            if changed { t = joined(t) }
        }
        return t
    }

    // MARK: Sentences

    /// Each word's speaker: the turn it overlaps most, else the nearest turn.
    static func label(_ words: [LiveWord], turns: [SpeakerTurn]) -> [String?] {
        let t = turns.sorted { $0.start < $1.start }
        var j = 0
        return words.map { w in
            while j < t.count, t[j].end < w.start - 1 { j += 1 }
            var best: String?, overlap = 0.0, nearest: (speaker: String, gap: Double)?
            for k in max(0, j - 1)..<t.count {
                if t[k].start > w.end + 1, nearest != nil { break }
                let o = min(t[k].end, w.end) - max(t[k].start, w.start)
                if o > overlap { overlap = o; best = t[k].speaker }
                let gap = max(0, t[k].start - w.end, w.start - t[k].end)
                if gap < (nearest?.gap ?? .infinity) { nearest = (t[k].speaker, gap) }
                if t[k].start > w.end + 1 { break }
            }
            return best ?? nearest?.speaker
        }
    }

    /// Words → segments with one speaker each (diarizer ids). Sentences end at punctuation or a pause over 1 s; a
    /// sentence goes to the speaker of most of its words, and only a stretch of another speaker that is long on its own
    /// (≥ `flicker` and ≥ 3 words) splits it. A short sentence between two of the same speaker is theirs.
    static func attribute(_ words: [LiveWord], turns: [SpeakerTurn]) -> [Segment] {
        let labels = label(words, turns: turns)
        var pieces: [(words: [LiveWord], speaker: String?)] = []
        var sentence: [(LiveWord, String?)] = []
        func flush() {
            pieces += split(sentence)
            sentence = []
        }
        for (w, l) in zip(words, labels) {
            if let last = sentence.last?.0, w.start - last.end > 1.0 { flush() }
            sentence.append((w, l))
            let t = w.text.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") { flush() }
        }
        flush()
        var segments = pieces.compactMap { p -> Segment? in
            guard let first = p.words.first, let last = p.words.last else { return nil }
            let text = p.words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !hallucinations.contains(text.lowercased()) else { return nil }
            return Segment(start: first.start, end: last.end, text: text, speaker: p.speaker)
        }
        if segments.count > 2 {
            for i in 1..<(segments.count - 1) {
                let a = segments[i - 1], b = segments[i], c = segments[i + 1]
                if a.speaker == c.speaker, b.speaker != a.speaker, b.end - b.start < flicker,
                   b.start - a.end < 1, c.start - b.end < 1 { segments[i].speaker = a.speaker }
            }
        }
        return segments
    }

    static let hallucinations: Set<String> = ["thank you.", "thanks for watching!", "you", "[music]", "[blank_audio]"]

    private static func split(_ sentence: [(LiveWord, String?)]) -> [(words: [LiveWord], speaker: String?)] {
        var runs: [(words: [LiveWord], speaker: String?)] = []
        for (w, l) in sentence {
            if let last = runs.last, last.speaker == l || l == nil { runs[runs.count - 1].words.append(w) }
            else if let last = runs.last, last.speaker == nil { runs[runs.count - 1] = (last.words + [w], l) }
            else { runs.append(([w], l)) }
        }
        func span(_ r: (words: [LiveWord], speaker: String?)) -> Double { (r.words.last?.end ?? 0) - (r.words.first?.start ?? 0) }
        func weak(_ r: (words: [LiveWord], speaker: String?)) -> Bool { span(r) < flicker || r.words.count < 3 }
        while runs.count > 1, let i = runs.indices.filter({ weak(runs[$0]) }).min(by: { span(runs[$0]) < span(runs[$1]) }) {
            let into: Int
            if i == 0 { into = 1 } else if i == runs.count - 1 { into = i - 1 }
            else { into = span(runs[i - 1]) + Double(runs[i - 1].words.count) * 0.01 >= span(runs[i + 1]) ? i - 1 : i + 1 }
            let words = into < i ? runs[into].words + runs[i].words : runs[i].words + runs[into].words
            runs[into].words = words
            runs.remove(at: i)
            var k = 1
            while k < runs.count {
                if runs[k].speaker == runs[k - 1].speaker { runs[k - 1].words += runs[k].words; runs.remove(at: k) } else { k += 1 }
            }
        }
        return runs
    }

    /// Consecutive segments of one speaker less than `gap` apart become one, up to `cap` seconds (subtitles stay usable).
    static func merge(_ segments: [Segment], gap: Double = flicker, cap: Double = 30) -> [Segment] {
        var out: [Segment] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.speaker != nil, last.speaker == s.speaker, s.start - last.end < gap,
               max(last.end, s.end) - last.start <= cap, last.favorite == nil, s.favorite == nil {
                out[out.count - 1].end = max(last.end, s.end)
                out[out.count - 1].text = last.text + " " + s.text
            } else {
                out.append(s)
            }
        }
        return out
    }

    // MARK: Names from captions

    /// Captions show words 0.5–2 s after they're spoken: the lag (0–3 s) that best lines the captions' words up with
    /// the words heard on the others track, 1 s when nothing matches.
    static func captionLag(_ captions: [CaptionTurn], words: [LiveWord]) -> Double {
        var heard: [String: [Double]] = [:]
        for w in words where w.key.count >= 3 { heard[w.key, default: []].append(w.start) }
        for k in heard.keys { heard[k]!.sort() }
        let lags = stride(from: 0.0, through: 3.0, by: 0.1).map { $0 }
        var score = [Double](repeating: 0, count: lags.count)
        for c in captions where !c.isSelf {
            let keys = c.text.split(separator: " ").map { LiveWord(text: String($0), start: 0, end: 0).key }
            guard !keys.isEmpty else { continue }
            let span = max(0, c.end - c.start)
            for (i, k) in keys.enumerated() where k.count >= 3 {
                guard let times = heard[k] else { continue }
                let shown = c.start + span * Double(i + 1) / Double(keys.count)
                for (n, lag) in lags.enumerated() where nearest(times, shown - lag) <= 1.0 { score[n] += 1 }
            }
        }
        guard let top = score.max(), top > 0 else { return 1 }
        // The middle of the best plateau.
        let best = score.indices.filter { score[$0] >= top * 0.98 }
        return lags[best[best.count / 2]]
    }

    private static func nearest(_ sorted: [Double], _ t: Double) -> Double {
        var lo = 0, hi = sorted.count
        while lo < hi { let m = (lo + hi) / 2; if sorted[m] < t { lo = m + 1 } else { hi = m } }
        var d = Double.infinity
        if lo < sorted.count { d = sorted[lo] - t }
        if lo > 0 { d = min(d, t - sorted[lo - 1]) }
        return d
    }

    /// When each person was muted in the meeting (events muted/unmuted).
    static func mutedIntervals(_ c: MeetingContext) -> [String: [(Double, Double)]] {
        var open: [String: Double] = [:], out: [String: [(Double, Double)]] = [:]
        for e in c.events.sorted(by: { $0.t < $1.t }) {
            guard let who = e.who.map(key) else { continue }
            if e.kind == .muted, open[who] == nil { open[who] = e.t }
            if e.kind == .unmuted, let s = open.removeValue(forKey: who) { out[who, default: []].append((s, e.t)) }
        }
        for (who, s) in open { out[who, default: []].append((s, .infinity)) }
        return out
    }

    static func overlap(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var total = 0.0
        for x in a { for y in b { total += max(0, min(x.1, y.1) - max(x.0, y.0)) } }
        return total
    }

    /// Clusters → caption speakers: after shifting captions back by their lag, each cluster takes the person whose
    /// captions it overlaps most, if that person covers ≥ 50 % of the cluster's captioned time and ≥ 2 s. Someone
    /// muted while the cluster talks can't be it. One name per cluster (a person split over two clusters names both);
    /// clusters without a match stay "Speaker N".
    static func fromCaptions(turns: [SpeakerTurn], context: MeetingContext, words: [LiveWord]) -> [String: String] {
        let captions = context.captions.filter { !$0.isSelf && !key($0.speaker).isEmpty }
        guard !captions.isEmpty, !turns.isEmpty else { return [:] }
        let lag = captionLag(captions, words: words)
        let bots = Set(context.participants.filter { $0.bot || $0.isSelf }.map { key($0.name) })
        var shown: [String: [(Double, Double)]] = [:], display: [String: String] = [:]
        for c in captions where !bots.contains(key(c.speaker)) {
            shown[key(c.speaker), default: []].append((c.start - lag, max(c.start, c.end) - lag))
            display[key(c.speaker)] = display[key(c.speaker)] ?? c.speaker
        }
        let muted = mutedIntervals(context)
        var byCluster: [String: [(Double, Double)]] = [:]
        for t in turns { byCluster[t.speaker, default: []].append((t.start, t.end)) }
        var candidates: [(speaker: String, name: String, score: Double)] = [], loose: [(speaker: String, name: String, share: Double)] = []
        for (cluster, spans) in byCluster {
            let talk = spans.reduce(0) { $0 + $1.1 - $1.0 }
            let scores = shown.mapValues { overlap(spans, $0) }
            let captioned = scores.values.reduce(0, +)
            guard captioned > 0 else { continue }
            for (name, o) in scores where o >= 2 && o / captioned >= 0.5 {
                let mutedTalk = overlap(spans, muted[name] ?? [])
                guard mutedTalk <= max(3, 0.2 * talk) else { continue }
                candidates.append((cluster, display[name]!, o - 2 * mutedTalk))
                if o >= 4, o / captioned >= 0.75 { loose.append((cluster, display[name]!, o / captioned)) }
            }
        }
        var names = SpeakerNaming.assignUnique(candidates)
        for l in loose.sorted(by: { $0.share > $1.share }) where names[l.speaker] == nil { names[l.speaker] = l.name }
        return names
    }
}

/// Meetings whose recording never reached the library (Earshot quit, crashed or lost power mid-call).
enum MeetingRecovery {
    @MainActor
    static func run() async {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let m = MeetingManifest.read(folder), !m.saved, !MeetingController.shared.owns(folder) else { continue }
            if m.discard == true {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            guard Store.shared.get(m.id) == nil else { continue }
            let tracks = ["others.wav", "me.wav"].map { folder.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            tracks.forEach(WAVRepair.fix)
            let seconds = tracks.compactMap(WAVReader.duration).max() ?? 0
            guard seconds >= 1 else { continue }
            let t = Transcript(id: m.id, createdAt: m.startedAt, title: m.title, sourcePath: folder.path, origin: m.origin,
                               model: Engine.modelID(for: m.language), language: m.language, duration: seconds, processingSeconds: 0,
                               text: "", segments: [], notes: m.notes.isEmpty ? nil : m.notes, context: MeetingContextFile.read(folder))
            guard Store.shared.insert(t) else {
                AppState.shared.lastError = "Couldn't recover \(m.title) into the library. Earshot will try again at the next launch."
                continue
            }
            AppState.shared.didSave(t)
            MeetingManifest.markSaved(folder)
            Notifier.post("Recovering \(m.title)", body: "Earshot stopped during this meeting. Transcribing what was recorded…")
            EventBus.shared.publish("meeting.recovered", ["meeting_id": m.id, "title": m.title, "duration": Formats.num(seconds)])
            if let final = try? await MeetingController.shared.retranscribe(m.id) { MeetingController.shared.finalize(final) }
        }
    }
}

/// A WAV whose writer never closed has zero/stale sizes in its header; patch them to the real file length.
enum WAVRepair {
    static func fix(_ url: URL) {
        guard let h = try? FileHandle(forUpdating: url), let data = try? h.read(upToCount: 4096), data.count > 12 else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var i = 12
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let chunk = data[i + 4..<i + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if id == "data" {
                let dataSize = UInt32(clamping: Int(size) - i - 8)
                guard chunk != Int(dataSize) else { return }
                write(h, at: 4, UInt32(clamping: Int(size) - 8))
                write(h, at: UInt64(i + 4), dataSize)
                return
            }
            i += 8 + chunk + (chunk & 1)
        }
    }

    private static func write(_ h: FileHandle, at offset: UInt64, _ value: UInt32) {
        var le = value.littleEndian
        try? h.seek(toOffset: offset)
        h.write(Data(bytes: &le, count: 4))
    }
}

/// ⌃⌘B from any app: bookmark the running meeting. Registered only while a meeting records, so the shortcut
/// belongs to other apps the rest of the time.
@MainActor
final class BookmarkHotkey {
    static let shared = BookmarkHotkey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func update() {
        Settings.bookmarkHotkey && MeetingController.shared.session != nil ? install() : uninstall()
    }

    private func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in MeetingController.shared.addNote(nil, kind: "bookmark") }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5357_4842), id: 1) // 'SWHB'
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func uninstall() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
