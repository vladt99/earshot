import Foundation

/// A name the user gave a live speaker: the times that speaker talked, so the polish (which clusters from scratch)
/// can give the same name to the cluster that covers them.
struct SpeakerPick: Codable, Hashable, Sendable {
    var name: String
    /// [start, end] pairs on the meeting-audio clock.
    var spans: [[Double]]
}

/// "Who is this?": voices that no caption named ("Speaker 2") and the people on the meeting's roster who could be them.
/// Pure: the transcript view and the live panel use the same rules.
enum SpeakerPicker {
    struct Prompt: Hashable, Sendable {
        var label: String
        /// Seconds this voice talked.
        var talk: Double
        /// A representative 3–5 s to play: the longest stretch nobody else talks over.
        var clip: Clip?
        /// The text of that stretch, to recognise the voice without playing it.
        var sample: String
        /// Unassigned people from the roster, most likely first.
        var candidates: [String]
    }

    struct Clip: Hashable, Sendable {
        var start: Double
        var end: Double
    }

    static let liveMinTalk = 20.0

    static func isUnnamed(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    static func key(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// People who can be heard (not you, bots or presentation tiles) and who no speaker label names yet, in roster order.
    static func unassigned(segments: [Segment], context: MeetingContext?) -> [String] {
        guard let context else { return [] }
        let used = Set(segments.compactMap(\.speaker).map(key))
        var seen = Set<String>(), out: [String] = []
        for p in context.speakingParticipants where !MeetParse.isBot(p.name) {
            let k = key(p.name)
            guard !k.isEmpty, !used.contains(k), seen.insert(k).inserted else { continue }
            out.append(p.name)
        }
        return out
    }

    /// Unassigned people ordered by how likely they are `label`: present (joinedAt…leftAt) while it talked, then their
    /// captions overlapping its lines, then anyone who spoke in the captions at all.
    static func candidates(for label: String, segments: [Segment], context: MeetingContext?) -> [String] {
        guard let context else { return [] }
        let pool = unassigned(segments: segments, context: context)
        let mine = segments.filter { $0.speaker == label }.map { ($0.start, $0.end) }
        let talk = mine.reduce(0) { $0 + max(0, $1.1 - $1.0) }
        let widened = mine.map { ($0.0 - 1, $0.1 + 3) }
        var captions: [String: [(Double, Double)]] = [:]
        for c in context.captions where !c.isSelf { captions[key(c.speaker), default: []].append((c.start, max(c.start, c.end))) }
        let scored = pool.enumerated().map { i, name -> (name: String, presence: Int, captioned: Double, spoke: Bool, order: Int) in
            let p = context.participants.first { key($0.name) == key(name) }
            let present = overlap(mine, [(p?.joinedAt ?? 0, p?.leftAt ?? .infinity)])
            let share = talk > 0 ? present / talk : 1
            let theirs = captions[key(name)] ?? []
            return (name, Int((share * 20).rounded()), overlap(widened, theirs), !theirs.isEmpty, i)
        }
        return scored.sorted { a, b in
            if a.presence != b.presence { return a.presence > b.presence }
            if a.captioned != b.captioned { return a.captioned > b.captioned }
            if a.spoke != b.spoke { return a.spoke }
            return a.order < b.order
        }.map(\.name)
    }

    /// The longest line of `label` that no other line overlaps (else its longest line), as a 3–5 s clip.
    static func clip(for label: String, segments: [Segment]) -> (clip: Clip, text: String)? {
        let mine = segments.filter { $0.speaker == label && $0.end > $0.start }
        let others = segments.filter { $0.speaker != label }
        func clean(_ s: Segment) -> Bool { !others.contains { $0.start < s.end + 0.3 && $0.end > s.start - 0.3 } }
        let longest: (Segment, Segment) -> Bool = { ($0.end - $0.start) < ($1.end - $1.start) }
        guard let best = mine.filter(clean).max(by: longest) ?? mine.max(by: longest) else { return nil }
        let length = min(5, max(3, best.end - best.start))
        return (Clip(start: best.start, end: best.start + length), best.text.trimmingCharacters(in: .whitespaces))
    }

    /// One prompt per unnamed voice (most talk first), when the roster still has someone unassigned.
    static func prompts(segments: [Segment], context: MeetingContext?, skipped: Set<String> = []) -> [Prompt] {
        guard context != nil, !unassigned(segments: segments, context: context).isEmpty else { return [] }
        var talk: [String: Double] = [:]
        for s in segments where isUnnamed(s.speaker) && !skipped.contains(s.speaker!) { talk[s.speaker!, default: 0] += max(0, s.end - s.start) }
        return talk.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { label, seconds in
            let c = clip(for: label, segments: segments)
            return Prompt(label: label, talk: seconds, clip: c?.clip, sample: Self.sample(c?.text ?? ""),
                          candidates: candidates(for: label, segments: segments, context: context))
        }
    }

    /// The live panel asks about one voice at a time, once it has talked for `liveMinTalk` seconds.
    static func livePrompt(lines: [Segment], context: MeetingContext?, skipped: Set<String>) -> Prompt? {
        prompts(segments: lines, context: context, skipped: skipped).first { $0.talk >= liveMinTalk && !$0.candidates.isEmpty }
    }

    private static func sample(_ text: String) -> String {
        text.count <= 140 ? text : String(text.prefix(137)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: At polish

    /// Clusters → picked names: a cluster takes the name whose spans cover most of it (≥ 2 s and ≥ 50 % of its talk),
    /// and every picked name gets at least the cluster it overlaps most. One name may cover two clusters (one person
    /// split in two).
    static func fromPicks(turns: [(start: Double, end: Double, speaker: String)], picks: [SpeakerPick]) -> [String: String] {
        var spans: [String: [(Double, Double)]] = [:]
        for p in picks { spans[p.name, default: []] += p.spans.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil } }
        var clusters: [String: [(Double, Double)]] = [:]
        for t in turns { clusters[t.speaker, default: []].append((t.start, t.end)) }
        var out: [String: String] = [:]
        for (cluster, cs) in clusters {
            let talk = cs.reduce(0) { $0 + max(0, $1.1 - $1.0) }
            guard talk > 0, let best = spans.map({ (name: $0.key, o: overlap(cs, $0.value)) }).max(by: { $0.o < $1.o }),
                  best.o >= 2, best.o / talk >= 0.5 else { continue }
            out[cluster] = best.name
        }
        for (name, s) in spans.sorted(by: { $0.key < $1.key }) where !out.values.contains(name) {
            if let best = clusters.filter({ out[$0.key] == nil }).map({ (cluster: $0.key, o: overlap($0.value, s)) }).max(by: { $0.o < $1.o }),
               best.o >= 2 { out[best.cluster] = name }
        }
        return out
    }

    static func overlap(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var total = 0.0
        for x in a { for y in b { total += max(0, min(x.1, y.1) - max(x.0, y.0)) } }
        return total
    }
}
