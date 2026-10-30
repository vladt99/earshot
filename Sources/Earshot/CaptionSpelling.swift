import Foundation

/// Per-meeting hint terms: who is in the room, and the distinctive words of its calendar entry and chat. They become
/// Whisper's prompt and Parakeet's boosted vocabulary for that meeting. Pure.
enum RoomVocabulary {
    /// Whisper's prompt has a token budget; this many terms fit with room to spare.
    static let limit = 40
    /// Parakeet's boosting and caption spelling have no token budget.
    static let boostLimit = 150

    /// `custom` (Settings.vocabulary) first and always whole, then while under `limit`: names (participants, then
    /// calendar attendees), then capitalised names, acronyms and product or tech terms from the calendar title, agenda
    /// and chat, most frequent first.
    static func terms(_ context: MeetingContext?, custom: [String] = [], limit: Int = limit) -> [String] {
        var out: [String] = [], seen = Set<String>()
        func add(_ term: String, always: Bool) {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let k = VocabularyGuard.letters(t)
            guard always || out.count < limit, k.count >= 2, seen.insert(k).inserted else { return }
            out.append(t)
        }
        custom.forEach { add($0, always: true) }
        names(context).forEach { add($0, always: false) }
        // A first name or surname already in the list as part of a full name adds nothing.
        let parts = Set(out.flatMap { $0.split(separator: " ").map(VocabularyGuard.letters) })
        for w in words(context) where !parts.contains(VocabularyGuard.letters(w)) { add(w, always: false) }
        return out
    }

    /// Everyone who can be named: participants (not bots or presentation tiles) and attendees who didn't decline.
    static func names(_ c: MeetingContext?) -> [String] {
        guard let c else { return [] }
        var out = c.participants.filter { !$0.bot && !$0.presentation }.map(\.name)
        for a in c.calendar?.attendees ?? [] where a.status != "declined" {
            if let n = a.name, !n.trimmingCharacters(in: .whitespaces).isEmpty { out.append(n) }
            else if let n = a.email.flatMap(name(fromEmail:)) { out.append(n) }
        }
        return out.map(clean).filter { !$0.isEmpty && !$0.contains("@") && !MeetParse.isBot($0) && !MeetParse.isSelf($0) }
    }

    /// "Maya Ionescu (Presentation)", "Maya  (You)" → "Maya Ionescu", "Maya".
    static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "maya.ionescu@acme.com" → "Maya Ionescu"; nil for rooms, groups and one-word or numbered mailboxes.
    static func name(fromEmail email: String) -> String? {
        let parts = email.lowercased().split(separator: "@")
        guard parts.count == 2, !parts[1].contains("calendar.google"), !parts[1].contains("resource") else { return nil }
        let pieces = parts[0].split(whereSeparator: { $0 == "." || $0 == "_" })
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return pieces.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: Distinctive words

    /// Lines of invitation boilerplate (join links, dial-ins), never meeting content.
    static let boilerplate = ["meet.google", "google meet", "join by phone", "join with", "pin:", "zoom.us", "teams.microsoft",
                              "microsoft teams", "meeting id", "passcode", "dial-in", "dial in", "google calendar",
                              "learn more about", "invitation", "more phone numbers", "reply for", "this event"]

    /// Calendar title (title-like), agenda lines and chat messages → the distinctive words, best first.
    static func words(_ c: MeetingContext?) -> [String] {
        guard let c else { return [] }
        var texts: [(text: String, title: Bool)] = []
        for t in [c.calendar?.title, c.title].compactMap({ $0 }) where !texts.contains(where: { $0.text == t }) { texts.append((t, true)) }
        for line in plain(c.calendar?.notes ?? "").components(separatedBy: .newlines) {
            let l = line.lowercased()
            if !boilerplate.contains(where: l.contains) { texts.append((line, false)) }
        }
        for e in c.events where e.kind == .chat { if let t = e.text { texts.append((t, false)) } }
        return rank(texts)
    }

    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: #"<br\s*/?>|</p>|</li>|</div>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"&[a-z]+;|&#\d+;"#, with: " ", options: .regularExpression)
    }

    struct Stat { var text: String; var score = 0.0; var first: Int; var inside = false; var lower = false; var titled = false; var strong = false }

    static func rank(_ texts: [(text: String, title: Bool)]) -> [String] {
        var stats: [String: Stat] = [:], order = 0
        for (raw, title) in texts {
            let tokens = Self.tokens(raw)
            // A Title Case line (agenda heading) tells nothing by its capitals.
            let caps = tokens.filter { $0.text.first?.isUppercase == true }.count
            let titleLike = title || (tokens.count >= 3 && Double(caps) >= 0.6 * Double(tokens.count))
            for t in tokens {
                let k = VocabularyGuard.letters(t.text)
                guard k.count >= 2, !k.allSatisfy(\.isNumber), !Lexicon.stop.contains(k) else { continue }
                let kind = Lexicon.kind(t.text)
                order += 1
                var s = stats[k] ?? Stat(text: t.text, first: order)
                switch kind {
                case .lower: s.lower = true
                case .strong: s.strong = true; s.score += title ? 3 : 2
                case .capitalised:
                    if titleLike { s.titled = true; s.score += title ? 2 : 1 }
                    else if !t.initial { s.inside = true; s.score += 1; s.text = t.text }
                    else { s.score += 0.5 }
                }
                stats[k] = s
            }
        }
        let accepted = stats.filter { k, s in
            if s.strong { return true }
            guard k.count >= 3, !s.lower else { return false }
            if Lexicon.isCommon(k) { return s.inside && !s.titled }
            // A Romanian word starting a sentence or a title is still just a word; inside a sentence it's a name.
            return s.inside || !Lexicon.romanian(s.text)
        }
        return accepted.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.first < $1.first }.map(\.text)
    }

    /// Words with their inner punctuation ("Node.js", "GPT-4", "C++"), URLs, addresses and meeting codes removed;
    /// `initial`: first of its line or sentence.
    static func tokens(_ text: String) -> [(text: String, initial: Bool)] {
        let cleaned = text.replacingOccurrences(of: #"https?://\S+|\S+@\S+|\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b|\S+\.(com|ro|io|net|org)\S*"#,
                                                with: " . ", options: .regularExpression)
        var out: [(String, Bool)] = [], initial = true
        for piece in cleaned.split(whereSeparator: \.isWhitespace) {
            let core = piece.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#")).inverted)
            if core.contains(where: \.isLetter) { out.append((Lexicon.stem(String(core)), initial)) }
            if core.isEmpty { initial = initial || piece.contains { ".!?:;-•*–—|".contains($0) } }
            else { initial = piece.last.map { ".!?:;".contains($0) } ?? false }
        }
        return out
    }
}

/// Spelling of names and terms by the meeting's captions: where the ASR is unsure of a word (or it isn't a
/// dictionary word) and the caption shown for that moment has a name or term that is spelled and sounds like it,
/// the caption's spelling wins. Timing stays the ASR's. Pure.
enum CaptionSpelling {
    /// Below this word confidence (Whisper word probability, Parakeet token confidence) a word is unsure.
    static let unsure: Float = 0.6
    /// How far (s) an ASR word may be from where its caption places the name.
    static let reach = 2.5

    struct Candidate {
        var text: String
        var key: String
        var time: Double
        /// A room-vocabulary word (participant, attendee, agenda term).
        var term: Bool
    }

    /// `words` on a clock `offset` s after the captions' (the audio's). Uses the captions of one side, shifted back by
    /// their measured lag: yours for your mic (`mic` true), everyone else's for theirs (false), else whichever these
    /// words match; a side none of the words match is not used.
    static func fix(_ words: [LiveWord], context: MeetingContext, terms: [String] = [], offset: Double = 0, mic: Bool? = nil) -> [LiveWord] {
        guard !words.isEmpty, !context.captions.isEmpty else { return words }
        let from = (words.first?.start ?? 0) + offset - 10, to = (words.last?.end ?? 0) + offset + 10
        let near = context.captions.filter { $0.end >= from && $0.start <= to }
        let absolute = offset == 0 ? words : words.map { var w = $0; w.start += offset; w.end += offset; return w }
        let heard = Set(absolute.map { Lexicon.split($0.text).key })
        func matches(_ cs: [CaptionTurn]) -> Int {
            cs.reduce(0) { $0 + RoomVocabulary.tokens($1.text).filter { heard.contains(VocabularyGuard.letters($0.text)) }.count }
        }
        let mine = near.filter(\.isSelf), theirs = near.filter { !$0.isSelf }
        let own = mic ?? (matches(mine) > matches(theirs))
        guard matches(own ? mine : theirs) > 0 else { return words }
        let side = own ? mine.map { var c = $0; c.isSelf = false; return c } : theirs
        let lag = SpeakerPipeline.captionLag(side, words: absolute)
        return apply(words, captions: side, lag: lag + offset, terms: terms)
    }

    /// The captions' names and terms, each at the time (on the words' clock) its caption places it, and every caption
    /// word's key and time (a word the caption also shows is never changed). Both sorted by time.
    static func candidates(_ captions: [CaptionTurn], lag: Double, terms: [String]) -> (names: [Candidate], all: [Candidate]) {
        var spelled: [String: String] = [:]
        for t in terms { for w in t.split(separator: " ") { spelled[VocabularyGuard.letters(w)] = String(w) } }
        var names: [Candidate] = [], all: [Candidate] = []
        for c in captions {
            let tokens = RoomVocabulary.tokens(c.text)
            let span = max(0, c.end - c.start)
            for (i, t) in tokens.enumerated() {
                let k = VocabularyGuard.letters(t.text)
                let time = c.start + span * Double(i + 1) / Double(tokens.count) - lag
                all.append(Candidate(text: t.text, key: k, time: time, term: false))
                guard k.count >= 3, !Lexicon.stop.contains(k) else { continue }
                if let term = spelled[k] { names.append(Candidate(text: term, key: k, time: time, term: true)); continue }
                switch Lexicon.kind(t.text) {
                case .strong: names.append(Candidate(text: t.text, key: k, time: time, term: false))
                case .capitalised where !t.initial: names.append(Candidate(text: t.text, key: k, time: time, term: false))
                default: break
                }
            }
        }
        return (names.sorted { $0.time < $1.time }, all.sorted { $0.time < $1.time })
    }

    /// Replaces unsure ASR words (or spans of up to three) by a caption name or term within `reach` s of them that is
    /// spelled and sounds alike (VocabularyGuard). `lag`: how late captions show words, on the words' clock.
    static func apply(_ words: [LiveWord], captions: [CaptionTurn], lag: Double, terms: [String] = []) -> [LiveWord] {
        let (names, all) = candidates(captions, lag: lag, terms: terms)
        guard !names.isEmpty else { return words }
        var out: [LiveWord] = [], i = 0
        while i < words.count {
            if let (n, c) = best(words, at: i, names: names, all: all) {
                let span = words[i..<(i + n)]
                let lead = String(span.first!.text.prefix { $0.isWhitespace })
                let trailing = String(span.last!.text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                // A Romanian ending the ASR heard stays on the name ("Mayah-ul" → "Maya-ul").
                let ending = Lexicon.split(span.last!.text).ending
                LiveDebug.log("[captions] respelled \(n) words")
                out.append(LiveWord(text: lead + c.text + ending + trailing, start: span.first!.start, end: span.last!.end, confidence: 1))
                i += n
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    /// Unsure, or not a dictionary word.
    static func uncertain(_ w: LiveWord) -> Bool {
        let k = Lexicon.split(w.text).key
        guard !k.isEmpty, !k.allSatisfy(\.isNumber) else { return false }
        return w.confidence < unsure || !Lexicon.isCommon(k)
    }

    /// Candidates within `reach` s of `t` (sorted by time).
    static func around(_ sorted: [Candidate], _ t: Double) -> ArraySlice<Candidate> {
        var lo = 0, hi = sorted.count
        while lo < hi { let m = (lo + hi) / 2; if sorted[m].time < t - reach { lo = m + 1 } else { hi = m } }
        var end = lo
        while end < sorted.count, sorted[end].time <= t + reach { end += 1 }
        return sorted[lo..<end]
    }

    static func best(_ words: [LiveWord], at i: Int, names: [Candidate], all: [Candidate]) -> (Int, Candidate)? {
        var found: (n: Int, c: Candidate, score: Double)?
        for n in 1...3 where i + n <= words.count {
            let span = Array(words[i..<(i + n)])
            // Pieces Whisper joins without a space ("Build" + "-ul") belong to the word before them.
            if n > 1, !span[n - 1].text.hasPrefix(" ") || span[n - 2].text.last.map({ !$0.isLetter && !$0.isNumber }) == true { break }
            if i + n < words.count, !words[i + n].text.hasPrefix(" ") { continue }
            // Keyed as the captions' tokens are, without a Romanian ending: "Docker-ul" heard is the caption's "Docker".
            let keys = span.map { Lexicon.split($0.text).key }
            let heard = keys.joined()
            guard heard.count >= 3, span.contains(where: uncertain) else { continue }
            let mid = (span.first!.start + span.last!.end) / 2
            let pool = around(names, mid)
            guard !pool.isEmpty else { continue }
            // The caption shows one of these very words there: the ASR heard what the captions did.
            if around(all, mid).contains(where: { keys.contains($0.key) }) { continue }
            let text = keys.joined(separator: " ")
            for c in pool where n > 1 || c.key != heard {
                let spelled = VocabularyGuard.similarity(heard, c.key)
                guard spelled >= (c.term ? 0.5 : 0.6), VocabularyGuard.accepts(original: text, replacement: c.text) else { continue }
                // Merging several heard words into one name needs strong evidence.
                if n > 1, !c.term, spelled < 0.8 { continue }
                let score = spelled - 0.02 * Double(n - 1) - 0.01 * abs(c.time - mid)
                if score > (found?.score ?? 0) { found = (n, c, score) }
            }
        }
        return found.map { ($0.n, $0.c) }
    }
}

/// Custom vocabulary replacements are kept only when the heard words are spelled and sound like the term.
enum VocabularyGuard {
    static func accepts(original: String, replacement: String) -> Bool {
        let words = original.split(separator: " ").map(letters).filter { !$0.isEmpty }
        let heard = words.joined(), term = letters(replacement)
        guard !heard.isEmpty, !term.isEmpty else { return false }
        let spelled = similarity(heard, term)
        guard spelled >= 0.5, similarity(phonetic(heard), phonetic(term)) >= 0.75 else { return false }
        // An ordinary English word needs to be spelled closer still before it becomes a term.
        if words.count == 1, spelled < 0.6, common.contains(heard) { return false }
        return true
    }

    /// Lowercased letters and digits, diacritics and punctuation removed.
    static func letters<S: StringProtocol>(_ s: S) -> String {
        String(String.UnicodeScalarView(String(s).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Simplified Metaphone: vowels after the first letter dropped, similar consonants merged, repeats collapsed.
    static func phonetic(_ word: String) -> String {
        var out = ""
        for (i, c) in Array(word.replacingOccurrences(of: "ph", with: "f")).enumerated() {
            let key: String
            switch c {
            case "a", "e", "i", "o", "u", "y": key = i == 0 ? "A" : ""
            case "h", "w": key = i == 0 ? String(c).uppercased() : ""
            case "c", "k", "q", "g", "j": key = "K"
            case "s", "z": key = "S"
            case "d", "t": key = "T"
            case "b", "p": key = "P"
            case "f", "v": key = "F"
            case "x": key = "KS"
            default: key = String(c).uppercased()
            }
            for k in key where out.last != k { out.append(k) }
        }
        return out
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// Lowercase entries of the system word list (proper nouns excluded).
    static let common: Set<String> = {
        guard let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(list.split(separator: "\n").filter { $0.first?.isLowercase == true }.map { $0.lowercased() })
    }()
}

/// Word lists for telling names and terms from ordinary English and Romanian words (keys as VocabularyGuard.letters).
enum Lexicon {
    enum Kind { case lower, capitalised, strong }

    /// Acronyms ("API", "QA2"), inner capitals ("GitHub", "iOS") and letters with digits ("GPT4") are `strong`.
    static func kind(_ token: String) -> Kind {
        let letters = token.filter(\.isLetter)
        guard let first = letters.first else { return .lower }
        if letters.count >= 2, letters.allSatisfy(\.isUppercase), !stopAcronyms.contains(letters) { return .strong }
        if letters.dropFirst().contains(where: \.isUppercase), letters.contains(where: \.isLowercase) { return .strong }
        if letters.count >= 2, token.contains(where: \.isNumber), first.isUppercase { return .strong }
        return first.isUppercase ? .capitalised : .lower
    }

    /// Romanian article and case endings on a borrowed word: "PR-ul", "build-urile", "Jira-ului" → "PR", "build", "Jira".
    static func stem(_ token: String) -> String {
        guard let dash = token.lastIndex(of: "-"), dash > token.startIndex else { return token }
        let ending = token[token.index(after: dash)...]
        return endings.contains(String(ending)) ? String(token[..<dash]) : token
    }

    static let endings: Set<String> = ["ul", "ului", "uri", "urile", "urilor", "le", "lor", "a", "ii", "iul", "lui"]

    /// An ASR word's key as a caption token's (punctuation and Romanian ending off), and that ending: " Docker-ul," →
    /// ("docker", "-ul").
    static func split(_ word: String) -> (key: String, ending: String) {
        let core = word.trimmingCharacters(in: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#")).inverted)
        let base = stem(core)
        return (VocabularyGuard.letters(base), String(core.dropFirst(base.count)))
    }

    /// In the system word list (which has few inflections: "actions", "planned", "testing" count by their stem) or a stopword.
    static func isCommon(_ key: String) -> Bool {
        if stop.contains(key) || VocabularyGuard.common.contains(key) { return true }
        let d = VocabularyGuard.common
        for (suffix, stems) in [("ies", ["y"]), ("es", ["", "e"]), ("s", [""]), ("ed", ["", "e"]), ("ing", ["", "e"]), ("ly", [""])] where key.hasSuffix(suffix) {
            let base = String(key.dropLast(suffix.count))
            if base.count >= 3, stems.contains(where: { d.contains(base + $0) }) { return true }
        }
        return false
    }

    /// Spelled with Romanian letters: an ordinary Romanian word unless it shows up capitalised mid-sentence.
    static func romanian(_ s: String) -> Bool { s.contains { "ăâîșşțţĂÂÎȘŞȚŢ".contains($0) } }

    static let stopAcronyms: Set<String> = ["OK", "AM", "PM", "TBD", "FYI", "ASAP", "EOD", "ETA", "CET", "EET", "EEST", "UTC", "GMT",
                                            "PIN", "ID", "URL", "RSVP", "AKA", "TBC", "NB", "PS", "OOO", "WFH"]

    static let stop: Set<String> = Set((english + romanianWords + calendar).split(separator: " ").map(String.init))

    static let english = """
        the a an and or but if then so to of in on at by for with from about as into over under after before is are was were be \
        been being it its this that these those we you he she they i me my our ours your yours their his her them us will would \
        can could should may might must do does did done have has had not no yes yeah ok okay hi hello hey thanks thank please \
        all any some just also here there what when where who whom why how which today tomorrow yesterday now new next last \
        meeting meetings call sync weekly daily standup review sprint planning retro demo update updates status agenda notes \
        team project kickoff intro catch sure great good fine let lets one two three first second via per vs etc re fwd \
        everyone guys folks morning afternoon evening week month year
        """
    static let romanianWords = """
        si sau dar ca sa de la in pe cu din pentru prin spre despre este e sunt era erau fi fost am ai are avem aveti au eu tu el \
        ea noi voi ei ele mi ti ne va le lui al ale a o un una unui unei niste acest aceasta acesta aceste acestea acel acea \
        acela aceea care ce cine cum cand unde daca nu da mai foarte doar tot toti toate deja inca acum azi astazi maine ieri \
        bine multumesc mersi salut buna ziua seara dimineata sedinta intalnire saptamanala discutie discutii echipa proiect \
        deci apoi atunci fara sub peste intre dupa inainte asa aici acolo vreau vrem poate putem trebuie facem face fac zic \
        zice vad stiu cred bun mare mic nou noua prima primul doi trei patru cinci gata super perfect bine adica chiar cam \
        ceva cineva nimic nimeni fiecare orice totul altul alta alte altii lor lucru lucrul lucruri treaba partea parte \
        uite hai stai vezi zi zile ora ore minute timp azi saptamana luna anul problema probleme task taskuri
        """
    static let calendar = """
        monday tuesday wednesday thursday friday saturday sunday january february march april may june july august september \
        october november december luni marti miercuri joi vineri sambata duminica ianuarie februarie martie aprilie iunie \
        iulie septembrie octombrie noiembrie decembrie
        """
}
