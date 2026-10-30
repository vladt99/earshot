import AppKit
import ApplicationServices
import Foundation

// MARK: Meet UI strings

/// Google Meet's UI strings, grouped by what they tell us. English is checked against a real call; the other
/// languages (Romanian above all) are best guesses, so extend these tables when a call shows different wording.
enum MeetStrings {
    typealias Pattern = (prefix: String, suffix: String)

    static let titlePrefixes = ["Meet - ", "Meet – ", "Meet — "]
    /// aria-label of the captions region.
    static let captionRegions: Set<String> = ["captions", "subtitrări", "subtitrari", "untertitel", "sous-titres", "subtítulos",
                                              "sottotitoli", "legendas", "ondertiteling", "napisy"]
    /// How Meet names you in captions and lists.
    static let selfNames: Set<String> = ["you", "tu", "dvs.", "dumneavoastră", "dumneavoastra", "du", "sie", "vous", "tú", "usted", "você", "voi"]

    // Your microphone button names the action: "Turn off microphone" means it is on.
    static let micUnmuted = ["Turn off microphone", "Dezactivează microfonul", "Dezactivați microfonul", "Oprește microfonul"]
    static let micMuted = ["Turn on microphone", "Activează microfonul", "Activați microfonul", "Pornește microfonul"]
    static let micToastMuted = ["Your microphone is off", "Microfonul este dezactivat", "Microfonul tău este dezactivat", "Microfonul dvs. este dezactivat"]
    static let micToastUnmuted = ["Your microphone is on", "Microfonul este activat", "Microfonul tău este activat", "Microfonul dvs. este activat"]

    // End screen
    static let endTexts: Set<String> = ["You left the meeting", "The call has ended", "The meeting has ended", "You've been removed from the meeting",
                                        "You have been removed from the meeting", "Ați părăsit întâlnirea", "Ai părăsit întâlnirea",
                                        "Ați părăsit apelul", "Ai părăsit apelul", "Apelul s-a încheiat", "Întâlnirea s-a încheiat",
                                        "Ați fost eliminat din întâlnire", "Ai fost eliminat din întâlnire"]
    static let endButtons: [Set<String>] = [["Rejoin", "Return to home screen"], ["Reintrați", "Reveniți la ecranul de pornire"],
                                            ["Reintră", "Revino la ecranul de pornire"]]

    // Pre-join screen (the "green room"). English from Meet's UI; every Romanian string here is an unverified guess.
    static let preJoinTitles: Set<String> = ["Ready to join?", "Ask to join", "Sunteți gata să vă alăturați?", "Ești gata să te alături?",
                                             "Sunteți gata să participați?", "Ești gata să participi?"]
    static let joinButtons: Set<String> = ["Join now", "Ask to join", "Join here too", "Switch here", "Participați acum", "Participă acum",
                                           "Solicitați participarea", "Solicită participarea", "Alăturați-vă acum", "Alătură-te acum",
                                           "Participați și aici", "Comutați aici"]
    static let otherWaysToJoin: Set<String> = ["Other ways to join", "Alte modalități de participare", "Alte moduri de a participa",
                                               "Alte opțiuni de participare"]
    /// After "Ask to join": waiting for someone to let you in.
    static let asking: Set<String> = ["Asking to join…", "You'll join the call when someone lets you in", "Se solicită participarea…",
                                      "Solicitați participarea…", "Veți participa la apel când cineva vă permite accesul",
                                      "Vei participa la apel când cineva îți permite accesul"]
    /// Only the call itself has this button.
    static let leaveCall: Set<String> = ["Leave call", "Părăsiți apelul", "Părăsește apelul", "Ieșiți din apel", "Ieși din apel"]

    // Tiles (and the People panel's per-person controls)
    static let moreOptions: [Pattern] = [("More options for ", ""), ("More actions for ", ""), ("Mai multe opțiuni pentru ", ""),
                                         ("Alte opțiuni pentru ", ""), ("Mai multe acțiuni pentru ", "")]
    static let pin: [Pattern] = [("Pin ", " to your main screen"), ("Fixează ", " pe ecranul principal"), ("Fixați ", " pe ecranul principal")]
    /// The tile's mute control is offered, so that person is unmuted.
    static let unmutedOther: [Pattern] = [("Mute ", "'s microphone"), ("Dezactivează microfonul pentru ", ""),
                                          ("Dezactivați microfonul pentru ", ""), ("Dezactivați microfonul lui ", "")]
    /// Shown instead on a muted person's tile.
    static let mutedOther: Set<String> = ["You can't unmute someone else", "Nu poți activa microfonul altcuiva",
                                          "Nu puteți activa microfonul altcuiva", "Nu puteți activa microfonul altei persoane"]
    /// Controls only your own tile has.
    static let selfTile: Set<String> = ["Backgrounds and effects", "Reframe", "Apply visual effects", "Fundaluri și efecte",
                                        "Reîncadrează", "Reîncadrare", "Aplicați efecte vizuale"]
    static let presentationTile: [Pattern] = [("Unpin ", "'s presentation from your main screen"), ("Pin ", "'s presentation to your main screen"),
                                              ("", " (Presentation)"), ("", " (Prezentare)")]
    static let presenting: [Pattern] = [("", " is presenting"), ("", " (Presenting)"), ("", " (Presenting, annotating)"),
                                        ("", " prezintă"), ("", " (Prezintă)"), ("", " (Prezintă, adnotează)")]

    // Toasts and announcements (static text)
    static let joined: [Pattern] = [("", " has joined"), ("", " joined"), ("", " s-a alăturat apelului"), ("", " s-a alăturat"),
                                    ("", " a intrat în apel")]
    static let left: [Pattern] = [("", " has left the meeting"), ("", " left the meeting"), ("", " has left the call"), ("", " has left"),
                                  ("", " a părăsit întâlnirea"), ("", " a părăsit apelul"), ("", " a ieșit din apel")]
    static let startedPresenting: [Pattern] = [("", " started presenting"), ("The presentation by ", " was added to the main screen"),
                                               ("", " a început să prezinte"), ("", " a început prezentarea")]
    static let stoppedPresenting: [Pattern] = [("", " stopped presenting"), ("", " a oprit prezentarea"), ("", " nu mai prezintă")]
    static let chat = [" says in chat: ", " spune în chat: ", " a spus în chat: "]
    static let handRaised: [Pattern] = [("", " has raised a hand"), ("", " raised a hand"), ("", " has raised their hand"),
                                        ("", " raised their hand"), ("", " a ridicat mâna")]
    static let waiting = ["wants to join this call", "want to join this call", "guest waiting", "guests waiting",
                          "dorește să participe", "doresc să participe", "așteaptă să participe", "invitat așteaptă", "invitați așteaptă"]
    /// "Name (outside Org) joined"
    static let outside = ["outside ", "din afara "]
    static let and = [" and ", " și "]
    static let others = [" others", " more", " alții", " altele", " alte persoane"]
    static let notNames: Set<String> = ["external participants", "participanți externi", "someone", "cineva", "multiple people",
                                        "everyone", "toată lumea", "toți"]

    // Captions control. Like the mic, the button names the action ("Turn on captions": they are off); the call log
    // also showed a toggle, `AXCheckBox "Captions and translation"` (value 0/1), and "Turn off live captions".
    // Matched without a trailing shortcut ("Turn on captions (c)"). Romanian unverified.
    static let captionsTurnOn: Set<String> = ["Turn on captions", "Turn on live captions", "Activează subtitrările",
                                              "Activați subtitrările", "Activează subtitrările live", "Activați subtitrările live"]
    static let captionsTurnOff: Set<String> = ["Turn off captions", "Turn off live captions", "Dezactivează subtitrările",
                                               "Dezactivați subtitrările", "Dezactivează subtitrările live", "Dezactivați subtitrările live"]
    static let captionsToggle: Set<String> = ["Captions and translation", "Subtitrări și traducere", "Subtitrări și traduceri"]

    // Hands. Your own button names the action; a host sees "Lower X's hand" on raised hands. Romanian unverified.
    static let raiseHand: Set<String> = ["Raise hand", "Ridică mâna", "Ridicați mâna"]
    static let lowerHand: Set<String> = ["Lower hand", "Coboară mâna", "Coborâți mâna"]
    static let handUp: [Pattern] = [("Lower ", "'s hand"), ("Coboară mâna pentru ", ""), ("Coborâți mâna pentru ", ""),
                                    ("Coborâți mâna lui ", "")]
    static let handLowered: [Pattern] = [("", " lowered their hand"), ("", " has lowered their hand"), ("", " lowered a hand"),
                                         ("", " lowered hand"), ("", " a coborât mâna")]

    /// "X reacted with 👍" announcements. Reactions on tiles are bare emoji next to the tile's controls.
    static let reacted = [" reacted with ", " reacted ", " a reacționat cu ", " a reacționat "]

    // Screen sharing: Meet calls someone else's share "presenting" (see `presenting`); these are the "sharing" wordings
    // and your own share, which only your page shows. Romanian unverified.
    static let startedSharing: [Pattern] = [("", " started sharing their screen"), ("", " started sharing the screen"),
                                            ("", " is sharing their screen"), ("", " is sharing the screen"),
                                            ("", " a început să partajeze ecranul"), ("", " partajează ecranul")]
    static let stoppedSharing: [Pattern] = [("", " stopped sharing their screen"), ("", " stopped sharing the screen"),
                                            ("", " a oprit partajarea ecranului"), ("", " nu mai partajează ecranul")]
    static let selfSharingButtons: Set<String> = ["Stop presenting", "Stop sharing", "Stop sharing screen", "Oprește prezentarea",
                                                  "Opriți prezentarea", "Oprește partajarea", "Opriți partajarea"]
    static let selfSharingTexts: Set<String> = ["You are presenting to everyone", "You're presenting to everyone", "You are presenting",
                                                "You're presenting", "You are sharing your screen", "You're sharing your screen",
                                                "Prezentați tuturor", "Prezinți tuturor"]

    // The same account is in the call on another device (a phone): Meet offers to join here too or switch here.
    // Romanian unverified.
    static let elsewhereButtons: Set<String> = ["Join here too", "Switch here", "Participați și aici", "Participă și aici",
                                                "Comutați aici", "Comută aici"]
    static let elsewhereTexts: Set<String> = ["You're in this call on another device", "You are in this call on another device",
                                              "You're already in this call on another device", "You joined from another device",
                                              "You've joined from another device", "You switched to another device",
                                              "You've switched to another device", "This call is now on another device",
                                              "Participați la acest apel de pe alt dispozitiv", "Ești în acest apel pe alt dispozitiv",
                                              "V-ați alăturat de pe alt dispozitiv", "Te-ai alăturat de pe alt dispozitiv",
                                              "Ați comutat pe alt dispozitiv", "Ai comutat pe alt dispozitiv"]

    /// The captions language control ("Meeting language" combo box in the captions bar).
    static let languageControls: Set<String> = ["Meeting language", "Limba întâlnirii", "Limba ședinței", "Limba apelului",
                                                "Captions language", "Limba subtitrărilor"]
    /// Language names as Meet lists them, in English, the language itself and Romanian.
    static let languages: [String: String] = {
        let names: [String: [String]] = [
            "en": ["english", "engleză", "engleza", "englisch", "anglais", "inglés", "inglese", "inglês", "engels", "angielski", "англійська", "engelska"],
            "ro": ["romanian", "română", "romana", "rumänisch", "roumain", "rumano", "rumeno", "romeno", "roemeens", "rumuński", "румунська", "rumänska"],
            "de": ["german", "germană", "germana", "deutsch", "allemand", "alemán", "tedesco", "alemão", "duits", "niemiecki", "німецька", "tyska"],
            "fr": ["french", "franceză", "franceza", "französisch", "français", "francés", "francese", "francês", "frans", "francuski", "французька", "franska"],
            "es": ["spanish", "spaniolă", "spaniola", "spanisch", "espagnol", "español", "spagnolo", "espanhol", "spaans", "hiszpański", "іспанська", "spanska"],
            "it": ["italian", "italiană", "italiana", "italienisch", "italien", "italiano", "italiaans", "włoski", "італійська", "italienska"],
            "pt": ["portuguese", "portugheză", "portugheza", "portugiesisch", "portugais", "portugués", "portoghese", "português", "portugees", "portugalski", "португальська", "portugisiska"],
            "nl": ["dutch", "olandeză", "olandeza", "niederländisch", "néerlandais", "neerlandés", "olandese", "holandês", "nederlands", "niderlandzki", "нідерландська", "nederländska"],
            "pl": ["polish", "poloneză", "poloneza", "polnisch", "polonais", "polaco", "polacco", "polonês", "pools", "polski", "польська", "polska"],
            "uk": ["ukrainian", "ucraineană", "ucraineana", "ukrainisch", "ukrainien", "ucraniano", "ucraino", "oekraïens", "ukraiński", "українська", "ukrainska"],
            "sv": ["swedish", "suedeză", "suedeza", "schwedisch", "suédois", "sueco", "svedese", "zweeds", "szwedzki", "шведська", "svenska"],
        ]
        var out: [String: String] = [:]
        for (code, list) in names { for n in list { out[n] = code } }
        return out
    }()

    /// Notetaker bots that join as participants. Words that are also first names only count next to a bot word.
    static let bots = ["notetaker", "note taker", "fathom", "fireflies", "otter.ai", "read.ai", "tl;dv", "tldv", "avoma", "notta",
                       "supernormal", "tactiq", "meetgeek", "sembly"]
    static let ambiguousBots = ["otter", "fellow", "gong", "grain", "krisp", "jamie", "read"]
    static let botWords = ["bot", "ai", "notes", "assistant", "recorder", "meeting", "app"]
}

// MARK: Parsing (pure: shared by the live reader and the replay)

/// One accessibility node of the Meet page in document order; depth is relative to the web area.
struct MeetNode: Sendable, Hashable {
    var depth: Int
    var role: String
    var title: String? = nil
    var desc: String? = nil
    var value: String? = nil
    /// The element's identity (CFHash), 0 if unknown: tells a growing caption block from a new one.
    var key: Int = 0

    var label: String { MeetParse.clean(title.flatMap { $0.isEmpty ? nil : $0 } ?? desc ?? "") }
    var text: String { MeetParse.clean(value ?? "") }
}

struct MeetCaptionBlock: Sendable, Hashable {
    var key: Int
    var speaker: String
    var text: String
}

enum MeetToast: Sendable, Hashable {
    case joined(String, external: Bool), left(String), presenting(String), stoppedPresenting(String), chat(String, String),
         selfMic(muted: Bool), hand(String), waiting(String?, String),
         reaction(String, String), handLowered(String), sharing(String, started: Bool), elsewhere(String)
}

/// What one read of the Meet page shows.
struct MeetPage: Sendable {
    var selfMuted: Bool?
    var micIndex: Int?
    var captionIndex: Int?
    /// nil when the captions region isn't on the page.
    var captions: [MeetCaptionBlock]?
    var selfName: String?
    /// People with a tile (or a People-panel row), in page order; `muted` when their tile says.
    var people: [String] = []
    var muted: [String: Bool] = [:]
    var presentations: [String] = []
    var presenting: [String] = []
    var toasts: [MeetToast] = []
    var language: String?
    var ended = false
    var phase: MeetPhase = .unknown
    /// Captions on or off as Meet's own control (or, failing that, the captions region) says; nil when unknown.
    var captionsOn: Bool?
    /// The control that turns captions on, while they are off.
    var captionsControl: Int?
    /// Your raised hand, from your own button.
    var selfHand: Bool?
    /// People whose tiles offer "Lower X's hand".
    var hands: [String] = []
    /// Your own screen share is on.
    var selfSharing = false

    mutating func person(_ name: String, muted m: Bool? = nil) {
        guard MeetParse.plausibleName(name) else { return }
        if !people.contains(name) { people.append(name) }
        if let m { muted[name] = m }
    }
}

/// Which screen a Meet tab shows: the pre-join "green room", waiting to be let in, the call, or its end screen.
enum MeetPhase: String, Sendable, Hashable {
    case unknown, preJoin, asking, inCall, ended
}

enum MeetParse {
    /// Pre-join vs call vs end screen. The mic and camera buttons exist on both sides of Join, so only "Leave call"
    /// means the call; "Join now" / "Ask to join" / "Ready to join?" mean the green room.
    static func phase(_ nodes: [MeetNode]) -> MeetPhase {
        var join = false, asking = false, ended = false
        var buttons = Set<String>()
        for n in nodes {
            let label = dots(n.label), text = n.role == "AXStaticText" ? dots(n.text) : ""
            if n.role == "AXButton" {
                if MeetStrings.leaveCall.contains(label) { return .inCall }
                buttons.insert(label)
            }
            for s in [label, text] where !s.isEmpty {
                if MeetStrings.endTexts.contains(s) { ended = true }
                if MeetStrings.asking.contains(s) { asking = true }
                if MeetStrings.joinButtons.contains(s) || MeetStrings.preJoinTitles.contains(s) || MeetStrings.otherWaysToJoin.contains(s) { join = true }
            }
        }
        if ended || MeetStrings.endButtons.contains(where: { $0.isSubset(of: buttons) }) { return .ended }
        if asking { return .asking }
        return join ? .preJoin : .unknown
    }

    private static func dots(_ s: String) -> String { s.replacingOccurrences(of: "...", with: "…") }

    /// A control's label without its keyboard shortcut: "Turn on captions (c)" → "Turn on captions".
    static func bare(_ label: String) -> String {
        guard label.hasSuffix(")"), let r = label.range(of: " (", options: .backwards), label.distance(from: r.lowerBound, to: label.endIndex) <= 24 else { return label }
        return String(label[..<r.lowerBound])
    }

    /// A checkbox's AXValue: "1" checked, "0" not.
    static func checked(_ v: String?) -> Bool? { v == "1" ? true : v == "0" ? false : nil }

    /// Only emoji (a reaction): "👍", "❤️", "👏🏽".
    static func isEmoji(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 3 else { return false }
        return s.unicodeScalars.allSatisfy { u in
            u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x2100) || u.value == 0xFE0F || u.value == 0x200D
                || (0x1F3FB...0x1F3FF).contains(u.value)
        } && s.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x2100 }
    }

    /// Captions state from Meet's controls: a button naming the action wins over the toggle's value.
    static func captionsControl(_ n: MeetNode) -> (on: Bool, pressable: Bool)? {
        guard n.role == "AXButton" || n.role == "AXCheckBox" else { return nil }
        let b = bare(n.label)
        if MeetStrings.captionsTurnOn.contains(b) { return n.role == "AXCheckBox" && checked(n.value) == true ? (true, false) : (false, true) }
        if MeetStrings.captionsTurnOff.contains(b) { return (true, false) }
        if n.role == "AXCheckBox", MeetStrings.captionsToggle.contains(b), let c = checked(n.value) { return (c, !c) }
        return nil
    }

    /// "Meet - abc-defg-hij" → "abc-defg-hij".
    static func code(inTitle title: String) -> String? {
        guard let r = title.range(of: #"\b[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}\b"#, options: .regularExpression) else { return nil }
        return String(title[r])
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func name(_ s: String, _ patterns: [MeetStrings.Pattern]) -> String? {
        for p in patterns where s.count > p.prefix.count + p.suffix.count && s.hasPrefix(p.prefix) && s.hasSuffix(p.suffix) {
            let n = clean(String(s.dropFirst(p.prefix.count).dropLast(p.suffix.count)))
            if !n.isEmpty { return n }
        }
        return nil
    }

    static func plausibleName(_ n: String) -> Bool {
        !n.isEmpty && n.count <= 80 && n.split(separator: " ").count <= 8 && !MeetStrings.notNames.contains(n.lowercased())
    }

    static func isSelf(_ n: String) -> Bool { MeetStrings.selfNames.contains(n.lowercased()) }

    static func isBot(_ n: String) -> Bool {
        let l = n.lowercased()
        if MeetStrings.bots.contains(where: l.contains) { return true }
        let words = Set(l.split(whereSeparator: { !$0.isLetter && $0 != "." && $0 != ";" }).map(String.init))
        return MeetStrings.ambiguousBots.contains(where: words.contains) && MeetStrings.botWords.contains(where: words.contains)
    }

    /// "English", "Română", "English (United States)" → ISO 639-1.
    static func language(_ s: String) -> String? {
        let l = clean(s).lowercased()
        if let c = MeetStrings.languages[l] { return c }
        let base = l.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? l
        return MeetStrings.languages[base] ?? base.split(separator: " ").first.flatMap { MeetStrings.languages[String($0)] }
    }

    /// true = muted, from your microphone button's label. Exact match only: the tooltip text
    /// ("Turn on microphone (⌘ + d)") and other people's controls must not count as your button.
    static func micState(_ label: String) -> Bool? {
        if MeetStrings.micMuted.contains(label) { return true }
        if MeetStrings.micUnmuted.contains(label) { return false }
        return nil
    }

    /// "A joined", "A and B joined", "A (outside Org) joined" → names with their external flag.
    static func joinedNames(_ s: String) -> [(String, Bool)] {
        var parts = [s]
        for sep in MeetStrings.and { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.flatMap { $0.components(separatedBy: ", ") }
        if parts.count > 1, let last = parts.last, MeetStrings.others.contains(where: last.hasSuffix) { parts.removeLast() }
        return parts.compactMap { raw in
            var n = clean(raw), external = false
            if n.hasSuffix(")"), let open = n.range(of: " (", options: .backwards) {
                let inner = n[open.upperBound...].dropLast()
                if MeetStrings.outside.contains(where: inner.hasPrefix) { external = true; n = clean(String(n[..<open.lowerBound])) }
            }
            return plausibleName(n) ? (n, external) : nil
        }
    }

    static func toasts(_ raw: String) -> [MeetToast] {
        let s = clean(raw)
        guard !s.isEmpty, s.count <= 600 else { return [] }
        for sep in MeetStrings.chat {
            if let r = s.range(of: sep) {
                let who = clean(String(s[..<r.lowerBound]))
                return plausibleName(who) ? [.chat(who, String(s[r.upperBound...].prefix(500)))] : []
            }
        }
        let bare = s.hasSuffix(".") ? String(s.dropLast()) : s
        if MeetStrings.micToastMuted.contains(bare) { return [.selfMic(muted: true)] }
        if MeetStrings.micToastUnmuted.contains(bare) { return [.selfMic(muted: false)] }
        if let n = name(bare, MeetStrings.left), plausibleName(n) { return [.left(n)] }
        if let n = name(bare, MeetStrings.joined) { return joinedNames(n).map { .joined($0.0, external: $0.1) } }
        if let n = name(bare, MeetStrings.stoppedPresenting), plausibleName(n) { return [.stoppedPresenting(n)] }
        if let first = s.components(separatedBy: ". ").first, let n = name(first.hasSuffix(".") ? String(first.dropLast()) : first, MeetStrings.startedPresenting),
           plausibleName(n) { return [.presenting(n)] }
        if let n = name(bare, MeetStrings.handRaised), plausibleName(n) { return [.hand(n)] }
        if let n = name(bare, MeetStrings.handLowered), plausibleName(n) { return [.handLowered(n)] }
        if let n = name(bare, MeetStrings.startedSharing), plausibleName(n) { return [.sharing(n, started: true)] }
        if let n = name(bare, MeetStrings.stoppedSharing), plausibleName(n) { return [.sharing(n, started: false)] }
        if MeetStrings.elsewhereTexts.contains(bare) { return [.elsewhere(bare)] }
        for sep in MeetStrings.reacted {
            if let r = bare.range(of: sep) {
                let who = clean(String(bare[..<r.lowerBound])), what = clean(String(bare[r.upperBound...]))
                if plausibleName(who), !what.isEmpty, what.count <= 40 { return [.reaction(who, what)] }
            }
        }
        if MeetStrings.waiting.contains(where: { s.localizedCaseInsensitiveContains($0) }) { return [.waiting(nil, s)] }
        return []
    }

    /// One past the last node of the subtree at `i`.
    static func subtreeEnd(_ nodes: [MeetNode], _ i: Int) -> Int {
        var j = i + 1
        while j < nodes.count, nodes[j].depth > nodes[i].depth { j += 1 }
        return j
    }

    /// The caption blocks under the region at `region`: each block's first text is the speaker, the rest the caption.
    /// Single-child wrappers are skipped until the children are blocks (each holding a name and some text).
    static func captionBlocks(_ nodes: [MeetNode], region: Int) -> [MeetCaptionBlock] {
        func groups(_ d: Int, _ r: Range<Int>) -> [Range<Int>] {
            var out: [Range<Int>] = [], start: Int?
            for j in r {
                if nodes[j].depth == d { if let s = start { out.append(s..<j) }; start = j }
            }
            if let s = start { out.append(s..<r.upperBound) }
            return out
        }
        func texts(_ r: Range<Int>) -> [String] {
            r.compactMap { nodes[$0].role == "AXStaticText" ? nodes[$0].text : nil }.filter { !$0.isEmpty }
        }
        var range = (region + 1)..<subtreeEnd(nodes, region)
        var d = nodes[region].depth + 1
        while case let gs = groups(d, range), gs.count == 1 {
            let inner = groups(d + 1, (gs[0].lowerBound + 1)..<gs[0].upperBound)
            guard !inner.isEmpty, inner.allSatisfy({ texts($0).count >= 2 }) else { break }
            range = gs[0]
            d += 1
        }
        return groups(d, range).compactMap { g in
            let t = texts(g)
            guard t.count >= 2, t[0].count <= 80 else { return nil }
            return MeetCaptionBlock(key: nodes[g.lowerBound].key, speaker: t[0], text: t.dropFirst().joined(separator: " "))
        }
    }

    /// The named person a tile control at `i` belongs to: the tile's "More options for X" after it, else "Pin X" before it.
    static func tileOwner(_ nodes: [MeetNode], _ i: Int) -> String? {
        let floor = nodes[i].depth - 1
        var j = i + 1
        while j < min(nodes.count, i + 12), nodes[j].depth >= floor {
            if let n = name(nodes[j].label, MeetStrings.moreOptions) { return n }
            j += 1
        }
        j = i - 1
        while j >= max(0, i - 6), nodes[j].depth >= floor {
            if let n = name(nodes[j].label, MeetStrings.pin) ?? name(nodes[j].label, MeetStrings.moreOptions) { return n }
            j -= 1
        }
        return nil
    }

    static func page(_ nodes: [MeetNode]) -> MeetPage {
        var p = MeetPage()
        var endButtons = Set<String>()
        var control: Bool?
        var buttonEnd = 0
        var i = 0
        while i < nodes.count {
            let n = nodes[i], label = n.label
            if p.captions == nil, n.role == "AXGroup", MeetStrings.captionRegions.contains(label.lowercased()) {
                p.captionIndex = i
                p.captions = captionBlocks(nodes, region: i)
                i = subtreeEnd(nodes, i)
                continue
            }
            if control == nil, let c = captionsControl(n) {
                control = c.on
                if c.pressable { p.captionsControl = i }
            }
            if n.role == "AXButton" || n.role == "AXCheckBox", !label.isEmpty {
                let b = bare(label)
                if MeetStrings.raiseHand.contains(b) { p.selfHand = n.role == "AXCheckBox" ? checked(n.value) ?? false : false }
                else if MeetStrings.lowerHand.contains(b) { p.selfHand = true }
                else if MeetStrings.selfSharingButtons.contains(b) { p.selfSharing = true }
                else if MeetStrings.elsewhereButtons.contains(b), !p.toasts.contains(.elsewhere(b)) { p.toasts.append(.elsewhere(b)) }
                if let o = name(label, MeetStrings.handUp), plausibleName(o), !p.hands.contains(o) { p.hands.append(o) }
            }
            if n.role == "AXButton" { buttonEnd = max(buttonEnd, subtreeEnd(nodes, i)) }
            if n.role == "AXImage", i >= buttonEnd, isEmoji(label), let o = tileOwner(nodes, i) {
                let r = MeetToast.reaction(o, label)
                if !p.toasts.contains(r) { p.toasts.append(r) }
            }
            if !label.isEmpty {
                if n.role == "AXButton", p.selfMuted == nil, let m = micState(label) {
                    p.selfMuted = m
                    p.micIndex = i
                } else if MeetStrings.mutedOther.contains(label) {
                    if let o = tileOwner(nodes, i) { p.person(o, muted: true) }
                } else if let o = name(label, MeetStrings.presentationTile) {
                    if !p.presentations.contains(o) { p.presentations.append(o) }
                } else if let o = name(label, MeetStrings.unmutedOther) {
                    p.person(o, muted: false)
                } else if let o = name(label, MeetStrings.moreOptions) {
                    p.person(o)
                } else if let o = name(label, MeetStrings.pin) {
                    p.person(o)
                } else if MeetStrings.selfTile.contains(label) {
                    var j = i + 1
                    while j < min(nodes.count, i + 10), nodes[j].depth >= n.depth - 1 {
                        if let o = name(nodes[j].label, MeetStrings.moreOptions) { p.selfName = o; break }
                        j += 1
                    }
                } else if n.role != "AXStaticText", let o = name(label, MeetStrings.presenting) {
                    if !p.presenting.contains(o) { p.presenting.append(o) }
                } else if (n.role == "AXComboBox" || n.role == "AXPopUpButton"), MeetStrings.languageControls.contains(label),
                          let v = n.value, let code = language(v) {
                    p.language = code
                }
                if MeetStrings.endTexts.contains(label) { p.ended = true }
                if n.role == "AXButton" { endButtons.insert(label) }
                if n.role == "AXButton", let r = label.range(of: #"^\d+ with potential risks "#, options: .regularExpression),
                   case let who = String(label[r.upperBound...]), MeetParse.plausibleName(who) {
                    p.toasts.append(.waiting(who, label))
                }
                if n.role == "AXPopUpButton" || n.role == "AXButton", MeetStrings.waiting.contains(where: { label.localizedCaseInsensitiveContains($0) }),
                   label.first?.isNumber == true {
                    p.toasts.append(.waiting(nil, label))
                }
            }
            if n.role == "AXStaticText" {
                let t = n.text
                if MeetStrings.endTexts.contains(t) { p.ended = true }
                if MeetStrings.selfSharingTexts.contains(t) { p.selfSharing = true }
                if isEmoji(t) {
                    if i >= buttonEnd, let o = tileOwner(nodes, i), case let r = MeetToast.reaction(o, t), !p.toasts.contains(r) { p.toasts.append(r) }
                } else if let o = name(t, MeetStrings.presentationTile) {
                    if !p.presentations.contains(o) { p.presentations.append(o) }
                } else if let o = name(t, MeetStrings.presenting), !t.contains(". ") {
                    if !p.presenting.contains(o) { p.presenting.append(o) }
                } else {
                    for toast in toasts(t) where !p.toasts.contains(toast) { p.toasts.append(toast) }
                }
            }
            i += 1
        }
        if MeetStrings.endButtons.contains(where: { $0.isSubset(of: endButtons) }) { p.ended = true }
        p.captionsOn = control ?? (p.captionIndex != nil ? true : nil)
        if p.captionsOn != false { p.captionsControl = nil }
        p.phase = phase(nodes)
        return p
    }
}

// MARK: Tracking (pure: page reads over time → MeetingContext)

struct MeetTracker {
    private(set) var context = MeetingContext()
    /// When the first page read happened: tiles keep loading for a few seconds after that, and whoever shows up
    /// within `alreadyThere` seconds was in the call before we looked (no join event, joined at 0).
    private var firstPageAt: Double?
    private var selfName: String?
    private var muted: Bool?
    private var tileMuted: [String: Bool] = [:]
    private var toastSeen: [String: Double] = [:]
    private var presentingSeen: [String: Double] = [:]
    private var turnOf: [Int: Int] = [:]        // caption block → its current turn (-1: was there before we looked)
    private var blockText: [Int: String] = [:]
    private var segmentBase: [Int: String] = [:]
    private var closed: Set<Int> = []
    private var captionsSeen = false
    private var selfHand: Bool?
    private var handSeen: [String: Double] = [:]
    private var handUp: Set<String> = []
    private var sharingSeen: Double?

    /// Turn Meet's captions on once per call when they are off (set from Settings.autoEnableCaptions).
    var autoCaptions = false
    /// Captions on/off as last read; nil until a read shows it.
    private(set) var captionsOn: Bool?
    private var captionsWereOn = false
    private var captionsOffSince: Double?
    private var inCallSince: Double?
    private var inCall = false
    private var pressedAt: Double?
    private var pressDone = false
    private(set) var health = MeetHealth()
    private var status = Status()

    static let pause = 2.5
    static let alreadyThere = 10.0
    static let maxText = 500
    /// In the call this long before captions are turned on; the press must show within `pressTimeout`.
    static let settle = 2.0
    static let pressTimeout = 3.0
    /// Captions off this long before `captionsOff` is reported.
    static let offAfter = 5.0

    struct Changes {
        var selfMuted: Bool?
        var ended = false
        var speakers: [String] = []
        var changed = false
        /// Press Meet's "turn on captions" control now (the page's `captionsControl`).
        var pressCaptions = false
    }

    /// What the session shows about the page itself.
    struct Status: Equatable, Sendable {
        var captionsOff = false
        var health: String?
        var missing: [MeetHealth.Landmark] = []
    }

    func status(now: Double) -> Status {
        Status(captionsOff: captionsOff(now: now), health: health.hint, missing: health.missing)
    }

    /// Captions stay off: the auto-enable is off, failed, or the user turned them off.
    func captionsOff(now: Double) -> Bool {
        guard inCall, captionsOn == false, let since = captionsOffSince else { return false }
        if pressedAt != nil { return pressDone }
        return now - since >= Self.offAfter
    }

    /// Pressing the captions control failed: no retry.
    mutating func captionsPressFailed() { pressDone = true }

    /// A page read that found nothing (an empty or unreadable web area): only the health check learns from it.
    mutating func unreadable(at t: Double) -> Changes {
        health.read(mic: false, tiles: false, region: false, captionsOn: captionsOn, inCall: true, at: t)
        return Changes(changed: updateStatus(t))
    }

    private mutating func updateStatus(_ t: Double) -> Bool {
        let s = status(now: t)
        defer { status = s }
        return s != status
    }

    init(platform: String = "Google Meet") { context.platform = platform }

    mutating func meta(title: String?, url: String?, code: String?) -> Changes {
        let before = context
        if let title { context.title = title }
        if let url { context.url = url }
        if let code { context.meetingCode = code }
        return Changes(changed: before != context)
    }

    /// The context with the open mute interval running to `now`.
    func snapshot(now: Double) -> MeetingContext {
        var c = context
        if muted == true, let last = c.selfMuted.indices.last { c.selfMuted[last][1] = max(c.selfMuted[last][0], now) }
        c.selfMuted = c.selfMuted.filter { $0[1] > 0 || $0[0] > 0 }
        return c
    }

    // MARK: People

    private func find(_ name: String) -> Int? {
        let l = name.lowercased()
        return context.participants.firstIndex { $0.name.lowercased() == l }
    }

    private var selfIndex: Int? { context.participants.firstIndex { $0.isSelf } }

    /// Within the first `alreadyThere` seconds of reading (or before the first read).
    private func early(_ t: Double) -> Bool { firstPageAt.map { t - $0 < Self.alreadyThere } ?? true }

    private mutating func event(_ kind: MeetingEvent.Kind, _ t: Double, who: String? = nil, text: String? = nil) {
        context.events.append(MeetingEvent(t: t, kind: kind, who: who, text: text))
    }

    /// The participant for a name Meet shows; created (with a join event after the first read) when new.
    @discardableResult
    private mutating func person(_ raw: String, _ t: Double, joining: Bool = false) -> Int? {
        let name = MeetParse.clean(raw)
        guard MeetParse.plausibleName(name) else { return nil }
        if MeetParse.isSelf(name) || name == selfName {
            if let i = selfIndex { return i }
            context.participants.append(MeetingParticipant(name: selfName ?? "You", isSelf: true, joinedAt: early(t) ? 0 : max(0, t)))
            return context.participants.count - 1
        }
        if let i = find(name) {
            if joining, let left = context.participants[i].leftAt, t - left > 3 {
                context.participants[i].leftAt = nil
                event(context.participants[i].bot ? .notetakerJoined : .joined, t, who: name)
            }
            return i
        }
        let bot = MeetParse.isBot(name)
        context.participants.append(MeetingParticipant(name: name, bot: bot, joinedAt: early(t) && !joining ? 0 : max(0, t)))
        if !early(t) || joining { event(bot ? .notetakerJoined : .joined, t, who: name) }
        return context.participants.count - 1
    }

    private mutating func learnSelf(_ name: String) {
        guard name != selfName, !MeetParse.isSelf(name) else { return }
        selfName = name
        if let other = find(name), !context.participants[other].isSelf {
            if let s = selfIndex {
                context.participants[other].joinedAt = min(context.participants[other].joinedAt ?? 0, context.participants[s].joinedAt ?? 0)
                context.participants.remove(at: s)
            }
            if let o = find(name) { context.participants[o].isSelf = true; context.participants[o].bot = false }
        } else if let s = selfIndex {
            context.participants[s].name = name
        } else {
            context.participants.append(MeetingParticipant(name: name, isSelf: true, joinedAt: 0))
        }
        for i in context.captions.indices where context.captions[i].isSelf { context.captions[i].speaker = name }
    }

    private mutating func presentation(_ owner: String, _ t: Double) {
        guard let o = person(owner, t) else { return }
        let name = "\(context.participants[o].name) (Presentation)"
        guard find(name) == nil else { return }
        context.participants.append(MeetingParticipant(name: name, presentation: true, joinedAt: max(0, t)))
    }

    // MARK: Reads

    mutating func page(_ p: MeetPage, at t: Double) -> Changes {
        let before = context
        var ch = Changes()
        if let s = p.selfName { learnSelf(s) }
        for name in p.people {
            guard let i = person(name, t), !context.participants[i].isSelf, let m = p.muted[name] else { continue }
            let key = context.participants[i].name
            if let old = tileMuted[key], old != m { event(m ? .muted : .unmuted, t, who: key) }
            tileMuted[key] = m
        }
        for o in p.presentations { presentation(o, t) }
        var showing = Set<String>()
        for raw in p.presenting {
            guard let i = person(raw, t) else { continue }
            let name = context.participants[i].name
            showing.insert(name)
            if presentingSeen[name] == nil { event(.presentingStarted, t, who: name) }
            presentingSeen[name] = t
        }
        for toast in p.toasts {
            let key = "\(toast)"
            defer { toastSeen[key] = t }
            if let last = toastSeen[key], t - last < 10 { continue }
            switch toast {
            case let .joined(name, external):
                if let i = person(name, t, joining: true), external { context.participants[i].external = true }
            case let .left(name):
                if let i = person(name, t), !context.participants[i].isSelf {
                    context.participants[i].leftAt = max(0, t)
                    tileMuted[context.participants[i].name] = nil
                    event(.left, t, who: context.participants[i].name)
                }
            case let .presenting(raw):
                if let i = person(raw, t) {
                    let name = context.participants[i].name
                    if presentingSeen[name] == nil { event(.presentingStarted, t, who: name) }
                    presentingSeen[name] = t
                    showing.insert(name)
                }
            case let .stoppedPresenting(raw):
                if let i = person(raw, t), presentingSeen.removeValue(forKey: context.participants[i].name) != nil {
                    event(.presentingStopped, t, who: context.participants[i].name)
                }
            case let .chat(raw, text):
                let who = person(raw, t).map { context.participants[$0].name } ?? raw
                event(.chat, t, who: who, text: text)
            case let .selfMic(m):
                if p.selfMuted == nil, let c = setMuted(m, at: t) { ch.selfMuted = c }
            case let .hand(raw):
                let name = person(raw, t).map { context.participants[$0].name } ?? raw
                if handUp.insert(name).inserted || handSeen[name] == nil { event(.handRaised, t, who: name) }
            case let .handLowered(raw):
                let name = person(raw, t).map { context.participants[$0].name } ?? raw
                handUp.remove(name)
                handSeen[name] = nil
                event(.handRaised, t, who: name, text: "lowered")
            case let .waiting(who, text):
                event(.waiting, t, who: who, text: text)
            case let .reaction(raw, what):
                event(.reaction, t, who: person(raw, t).map { context.participants[$0].name } ?? raw, text: what)
            case let .sharing(raw, started):
                event(started ? .screenShareStarted : .screenShareStopped, t, who: person(raw, t).map { context.participants[$0].name } ?? raw)
            case let .elsewhere(text):
                event(.joinedElsewhere, t, who: selfName ?? "You", text: text)
            }
        }
        for (name, last) in presentingSeen where !showing.contains(name) && t - last > 8 {
            presentingSeen[name] = nil
            event(.presentingStopped, t, who: name)
        }
        inCall = ![.preJoin, .asking, .ended].contains(p.phase) && !p.ended
        hands(p, at: t)
        let me = selfName ?? "You"
        if p.selfSharing {
            if sharingSeen == nil { event(.screenShareStarted, t, who: me) }
            sharingSeen = t
        } else if let s = sharingSeen, t - s > 8 {
            sharingSeen = nil
            event(.screenShareStopped, t, who: me)
        }
        ch.pressCaptions = captions(p, at: t)
        health.read(mic: p.micIndex != nil, tiles: !p.people.isEmpty || p.selfName != nil || !p.presentations.isEmpty,
                    region: p.captionIndex != nil, captionsOn: captionsOn, inCall: inCall, at: t)
        if let m = p.selfMuted, let c = setMuted(m, at: t) { ch.selfMuted = c }
        if let lang = p.language { context.captionLanguage = lang }
        if firstPageAt == nil { firstPageAt = t }
        if let blocks = p.captions { ch.speakers = captions(blocks, at: t) }
        if p.ended { ch.ended = end(at: t) }
        ch.changed = updateStatus(t) || before != context || ch.selfMuted != nil
        return ch
    }

    /// Captions on/off events, and whether to turn them on: once per call, only if they were never on in this call
    /// (so a user who turned them off keeps them off), and never again after one press.
    private mutating func captions(_ p: MeetPage, at t: Double) -> Bool {
        if let on = p.captionsOn {
            if let old = captionsOn, old != on {
                event(on ? .captionsOn : .captionsOff, t, text: on && pressedAt != nil && !pressDone ? "Turned on by Earshot" : nil)
            }
            captionsOn = on
            if on { captionsWereOn = true; captionsOffSince = nil } else if captionsOffSince == nil { captionsOffSince = t }
        }
        guard inCall else { inCallSince = nil; return false }
        if inCallSince == nil { inCallSince = t }
        if let at = pressedAt {
            if !pressDone, captionsOn == true || t - at >= Self.pressTimeout { pressDone = true }
            return false
        }
        guard autoCaptions, !captionsWereOn, captionsOn == false, p.captionsControl != nil, let since = inCallSince,
              t - since >= Self.settle else { return false }
        pressedAt = t
        return true
    }

    private mutating func hands(_ p: MeetPage, at t: Double) {
        if let h = p.selfHand {
            if let old = selfHand, old != h { event(.handRaised, t, who: selfName ?? "You", text: h ? nil : "lowered") }
            selfHand = h
        }
        for raw in p.hands {
            guard let i = person(raw, t) else { continue }
            let name = context.participants[i].name
            if handUp.insert(name).inserted { event(.handRaised, t, who: name) }
            handSeen[name] = t
        }
        for (name, last) in handSeen where t - last > 8 {
            handSeen[name] = nil
            if handUp.remove(name) != nil { event(.handRaised, t, who: name, text: "lowered") }
        }
    }

    /// Caption blocks as shown now (oldest first). A block grows while its speaker talks; a pause of 2.5 s or 500
    /// characters starts a new turn, and a newer block closes the older ones. Returns who is talking now.
    mutating func captions(_ blocks: [MeetCaptionBlock], at t: Double) -> [String] {
        var talking: [String] = []
        let first = !captionsSeen
        captionsSeen = true
        for (pos, b) in blocks.enumerated() {
            let isSelf = MeetParse.isSelf(b.speaker) || b.speaker == selfName
            let speaker = isSelf ? (selfName ?? "You") : MeetParse.clean(b.speaker)
            guard MeetParse.plausibleName(speaker) else { continue }
            if let i = turnOf[b.key] {
                guard i >= 0, blockText[b.key] != b.text else { continue }
                let old = blockText[b.key] ?? ""
                blockText[b.key] = b.text
                let open = !closed.contains(b.key)
                let turn = context.captions[i]
                if open, t - turn.end > Self.pause || turn.text.count >= Self.maxText, let base = Self.commonPrefix(old, b.text),
                   base.count >= old.count / 2 {
                    segmentBase[b.key] = base
                    let rest = String(b.text.dropFirst(base.count)).trimmingCharacters(in: .whitespaces)
                    context.captions.append(CaptionTurn(start: t, end: t, speaker: speaker, isSelf: isSelf, text: String(rest.prefix(Self.maxText))))
                    turnOf[b.key] = context.captions.count - 1
                } else {
                    let base = segmentBase[b.key] ?? ""
                    let rest = b.text.hasPrefix(base) ? String(b.text.dropFirst(base.count)).trimmingCharacters(in: .whitespaces) : b.text
                    context.captions[i].text = String(rest.prefix(Self.maxText))
                    if open { context.captions[i].end = t }
                }
                if open && !isSelf { talking.append(speaker) }
            } else {
                blockText[b.key] = b.text
                // What was on screen before we started reading isn't timed: only the newest block counts.
                if first && pos < blocks.count - 1 { turnOf[b.key] = -1; closed.insert(b.key); continue }
                for k in turnOf.keys { closed.insert(k) }
                person(speaker, t)
                context.captions.append(CaptionTurn(start: t, end: t, speaker: speaker, isSelf: isSelf, text: String(b.text.prefix(Self.maxText))))
                turnOf[b.key] = context.captions.count - 1
                segmentBase[b.key] = ""
                if !isSelf { talking.append(speaker) }
            }
        }
        return talking
    }

    /// Common prefix cut back to a word boundary; nil if there is none.
    private static func commonPrefix(_ a: String, _ b: String) -> String? {
        var n = 0
        for (x, y) in zip(a, b) { if x != y { break }; n += 1 }
        guard n > 0 else { return nil }
        if n == a.count, n <= b.count { return a }
        let p = a.prefix(n)
        guard let space = p.lastIndex(of: " ") else { return nil }
        return String(p[..<space])
    }

    /// Your mute state; returns the new state when it changed.
    mutating func setMuted(_ m: Bool, at t: Double) -> Bool? {
        guard m != muted else { return nil }
        let was = muted
        muted = m
        if m {
            context.selfMuted.append([max(0, t), max(0, t)])
        } else if was == true, let last = context.selfMuted.indices.last {
            context.selfMuted[last][1] = max(context.selfMuted[last][0], t)
        }
        if was != nil { event(m ? .selfMuted : .selfUnmuted, t) }
        return m
    }

    /// The end screen appeared, or the Meet tab is gone. True the first time.
    mutating func end(at t: Double) -> Bool {
        guard !context.ended else { return false }
        context.ended = true
        if muted == true, let last = context.selfMuted.indices.last { context.selfMuted[last][1] = max(context.selfMuted[last][0], t) }
        muted = nil
        event(.ended, t)
        return true
    }
}

// MARK: Health (pure: can the page still be read?)

/// While in a call, the landmarks a readable Meet page always has: your mic button, the participant tiles, and the
/// captions region while captions are on. One missing for `grace` seconds of reading means Meet's page changed
/// (or can't be read), so names and mute detection are off. Time not spent reading (the tab in the background)
/// doesn't count. The captions region may go away while nobody talks, so once found it counts as there.
struct MeetHealth: Sendable, Hashable {
    enum Landmark: String, Sendable, Hashable { case mic, tiles, captions }
    static let grace = 20.0
    /// A pause between reads longer than this restarts the clock (the page was away).
    static let gap = 4.0

    private var lastRead: Double?
    private var seen: [Landmark: Double] = [:]
    private var regionFound = false
    private(set) var missing: [Landmark] = []

    var hint: String? {
        if missing.contains(.mic) || missing.contains(.tiles) { return "Earshot can't read this Meet page; speaker names and mute detection are off" }
        if missing.contains(.captions) { return "Earshot can't read Meet's captions; speaker names from captions are off" }
        return nil
    }

    mutating func read(mic: Bool, tiles: Bool, region: Bool, captionsOn: Bool?, inCall: Bool, at t: Double) {
        guard inCall else { lastRead = nil; seen = [:]; missing = []; regionFound = false; return }
        if lastRead.map({ t - $0 > Self.gap }) ?? true { seen = [.mic: t, .tiles: t, .captions: t] }
        lastRead = t
        if mic { seen[.mic] = t }
        if tiles { seen[.tiles] = t }
        if region { regionFound = true }
        if regionFound || captionsOn != true { seen[.captions] = t }
        missing = [Landmark.mic, .tiles, .captions].filter { t - (seen[$0] ?? t) >= Self.grace }
    }
}

// MARK: Live observer

/// Reads Google Meet's page in a Chromium browser or Safari through the Accessibility API and keeps a
/// `MeetingContext`: room, people, captions (who spoke when), your mute state and the end of the call.
/// Needs Earshot in System Settings → Privacy & Security → Accessibility. Read-only, with one exception: with
/// `autoEnableCaptions` it presses Meet's own "turn on captions" control, once per call. Callbacks run on the
/// observer's own threads.
final class MeetObserver: @unchecked Sendable {
    static var regionLabels: Set<String> { MeetStrings.captionRegions }
    static var selfLabels: Set<String> { MeetStrings.selfNames }
    static let captionTail = 4

    let bundleID: String
    private let app: AXUIElement
    private let clock: @Sendable () -> Double
    private let queue = DispatchQueue(label: "earshot.meet", qos: .utility)
    private let lock = NSLock()

    // Under the lock
    private var tracker = MeetTracker()
    private var reading = false
    private var handlers = Handlers()
    private var mic: AXUIElement?
    private var endedFired = false
    private var lastChange = Date.distantPast
    private var pendingChange = false
    private var logged = MeetTracker.Status()

    // On the queue
    private var timer: DispatchSourceTimer?
    private var web: AXUIElement?
    private var region: AXUIElement?
    private var tick = 0
    private var nextSearch = Date.distantPast
    private var lostAt: Date?
    private var wasActive = false
    private var setManual = false
    /// Full scans every 0.5 s until then: the captions press is being checked.
    private var boostUntil = Date.distantPast

    // On the AX thread
    private var axThread: AXThread?
    private var axObserver: AXObserver?
    private var observed: AXUIElement?

    private struct Handlers {
        var selfMute: (@Sendable (Bool) -> Void)?
        var ended: (@Sendable () -> Void)?
        var change: (@Sendable () -> Void)?
        var speaker: (@Sendable (String) -> Void)?
    }

    var context: MeetingContext {
        let now = clock()
        return lock.withLock { tracker.snapshot(now: now) }
    }

    /// The Meet page is found and being read.
    var active: Bool { lock.withLock { reading } }

    /// Turn Meet's captions on when a call starts with them off (one press per call, never retried).
    var autoEnableCaptions: Bool {
        get { lock.withLock { tracker.autoCaptions } }
        set { lock.withLock { tracker.autoCaptions = newValue } }
    }

    /// Captions left off, and whether the page can be read as expected.
    var status: MeetTracker.Status {
        let now = clock()
        return lock.withLock { tracker.status(now: now) }
    }

    var onSelfMute: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { handlers.selfMute } }
        set { lock.withLock { handlers.selfMute = newValue } }
    }
    var onEnded: (@Sendable () -> Void)? {
        get { lock.withLock { handlers.ended } }
        set { lock.withLock { handlers.ended = newValue } }
    }
    var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { handlers.change } }
        set { lock.withLock { handlers.change = newValue } }
    }
    var onCaptionSpeaker: (@Sendable (String) -> Void)? {
        get { lock.withLock { handlers.speaker } }
        set { lock.withLock { handlers.speaker = newValue } }
    }

    init?(bundleID: String, clock: @escaping @Sendable () -> Double) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        self.bundleID = bundleID
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        self.clock = clock
    }

    deinit { axThread?.stop() }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once per build; afterwards the user grants it in System Settings. Each ad-hoc
    /// signed build is a new identity the old grant doesn't cover, so a new build asks again (once).
    static func requestTrust() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        guard !trusted, UserDefaults.standard.string(forKey: "askedAccessibilityBuild") != build else { return }
        UserDefaults.standard.removeObject(forKey: "askedAccessibility")
        UserDefaults.standard.set(build, forKey: "askedAccessibilityBuild")
        ask()
    }

    /// Asking is what puts Earshot into System Settings → Privacy & Security → Accessibility (switched off);
    /// then open that pane so the user can switch it on.
    static func ask() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            // Chromium only builds the web accessibility tree for assistive apps that ask for it (costly, so stop() undoes it).
            if Self.attribute(app, "AXManualAccessibility") as? Bool != true {
                setManual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
            }
            let th = AXThread()
            th.every(0.25) { [weak self] in self?.readMic() }
            axThread = th
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    /// The pre-join watcher switched the page tree on and hands it over: this observer switches it off at stop().
    func adoptWebTree() { queue.async { [self] in setManual = true } }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let th = axThread {
                th.sync { [self] in
                    if let o = axObserver, let e = observed { Self.notifications.forEach { AXObserverRemoveNotification(o, e, $0 as CFString) } }
                    observed = nil
                    axObserver = nil
                }
                th.stop()
            }
            axThread = nil
            web = nil
            region = nil
            lock.withLock { reading = false; mic = nil }
            if setManual { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse) }
            setManual = false
        }
    }

    // MARK: Polling

    private func poll() {
        guard Self.trusted else { return }
        tick += 1
        let now = Date()
        if let w = web, Self.attribute(w, kAXRoleAttribute) == nil {
            web = nil
            region = nil
            lock.withLock { reading = false; mic = nil }
            LiveDebug.log("[meet] page lost")
        }
        guard web != nil else {
            if now >= nextSearch {
                nextSearch = now.addingTimeInterval(2)
                if let found = Self.findMeet(app) {
                    web = found.element
                    lostAt = nil
                    wasActive = true
                    lock.withLock { reading = true }
                    LiveDebug.log("[meet] reading the page")
                    fullScan()
                    return
                }
            }
            if wasActive {
                if lostAt == nil { lostAt = now }
                if let lostAt, now.timeIntervalSince(lostAt) > 4, tick % 8 == 0, !Self.meetTabExists(app) {
                    let t = clock()
                    deliver(lock.withLock { MeetTracker.Changes(ended: tracker.end(at: t), changed: true) })
                    wasActive = false
                }
            }
            flushChange()
            return
        }
        if tick % 6 == 0 || ((lock.withLock { mic == nil } || now < boostUntil) && tick % 2 == 0) {
            fullScan()
        } else if tick % 2 == 0, let region {
            let (nodes, _) = Self.captionNodes(region, depth: 0, header: true)
            if nodes.isEmpty {
                self.region = nil
            } else {
                let blocks = MeetParse.captionBlocks(nodes, region: 0)
                let t = clock()
                deliver(lock.withLock {
                    let before = tracker.context.captions
                    let speakers = tracker.captions(blocks, at: t)
                    return MeetTracker.Changes(speakers: speakers, changed: before != tracker.context.captions)
                })
            }
        }
        flushChange()
    }

    private func fullScan() {
        guard let web else { return }
        let (nodes, elements) = Self.walk(web)
        guard !nodes.isEmpty else {
            let t = clock()
            deliver(lock.withLock { tracker.unreadable(at: t) })
            logStatus(nodes: 0, phase: .unknown)
            return
        }
        let page = MeetParse.page(nodes)
        region = page.captionIndex.map { elements[$0] }
        let newMic = page.micIndex.map { elements[$0] }
        let url = (Self.attribute(web, "AXURL") as? URL)?.absoluteString
        let title = Self.pageTitle(Self.attribute(web, kAXTitleAttribute) as? String)
        let t = clock()
        let ch = lock.withLock {
            mic = newMic
            var c = tracker.meta(title: title, url: url.flatMap { Self.meetCode($0) != nil ? $0 : nil }, code: url.flatMap(Self.meetCode))
            let p = tracker.page(page, at: t)
            c.selfMuted = p.selfMuted
            c.ended = p.ended
            c.speakers = p.speakers
            c.changed = c.changed || p.changed
            return c
        }
        if let newMic { axThread?.async { [weak self] in self?.observe(newMic) } }
        if ch.pressCaptions, let i = page.captionsControl { pressCaptions(elements[i], nodes[i]) }
        logStatus(nodes: nodes.count, phase: page.phase)
        deliver(ch)
    }

    /// Presses Meet's captions control, after checking it is still that control. A failure isn't retried.
    private func pressCaptions(_ e: AXUIElement, _ n: MeetNode) {
        var ok = false
        if let r = Self.read(e), MeetParse.captionsControl(MeetNode(depth: 0, role: r.role, title: r.title, desc: r.desc, value: r.value))?.pressable == true {
            ok = AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        }
        LiveDebug.log("[meet] captions off: pressed \(n.role) \"\(n.label)\" \(ok ? "ok" : "failed")")
        if ok { boostUntil = Date().addingTimeInterval(MeetTracker.pressTimeout + 0.5) } else { lock.withLock { tracker.captionsPressFailed() } }
    }

    private func logStatus(nodes: Int, phase: MeetPhase) {
        let s = status
        let (old, captions) = lock.withLock { () -> (MeetTracker.Status, Bool?) in defer { logged = s }; return (logged, tracker.captionsOn) }
        guard s != old else { return }
        if s.captionsOff != old.captionsOff { LiveDebug.log("[meet] captions \(s.captionsOff ? "stay off" : "on or pending")") }
        if s.missing != old.missing {
            LiveDebug.log("[meet] health: \(s.missing.isEmpty ? "ok" : "missing " + s.missing.map(\.rawValue).joined(separator: ","))"
                          + " (\(nodes) nodes, phase \(phase.rawValue), captions \(captions.map { $0 ? "on" : "off" } ?? "?"))")
        }
    }

    private func deliver(_ ch: MeetTracker.Changes) {
        let h = lock.withLock { () -> Handlers in
            if ch.changed { pendingChange = true }
            return handlers
        }
        if let m = ch.selfMuted { h.selfMute?(m) }
        for s in NSOrderedSet(array: ch.speakers).array as? [String] ?? [] { h.speaker?(s) }
        if ch.ended {
            let first = lock.withLock { () -> Bool in defer { endedFired = true }; return !endedFired }
            if first { LiveDebug.log("[meet] meeting ended"); h.ended?() }
        }
    }

    /// onChange, at most twice a second.
    private func flushChange() {
        let fire = lock.withLock { () -> (@Sendable () -> Void)?? in
            guard pendingChange, Date().timeIntervalSince(lastChange) >= 0.5 else { return nil }
            pendingChange = false
            lastChange = Date()
            return .some(handlers.change)
        }
        if case let .some(f) = fire { f?() }
    }

    // MARK: Your microphone (AX thread: polled every 250 ms and observed for title changes)

    private static let notifications = [kAXTitleChangedNotification, kAXValueChangedNotification, kAXUIElementDestroyedNotification]

    private func readMic() {
        guard let mic = lock.withLock({ mic }) else { return }
        let label = MeetParse.clean((Self.attribute(mic, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.attribute(mic, kAXDescriptionAttribute) as? String ?? "")
        guard let m = MeetParse.micState(label) else {
            if Self.attribute(mic, kAXRoleAttribute) == nil { lock.withLock { if self.mic.map({ CFEqual($0, mic) }) == true { self.mic = nil } } }
            return
        }
        let t = clock()
        let changed = lock.withLock { tracker.setMuted(m, at: t) }
        if let changed { deliver(MeetTracker.Changes(selfMuted: changed, changed: true)) }
    }

    private func observe(_ e: AXUIElement) {
        if let o = observed, CFEqual(o, e) { return }
        if let ax = axObserver, let o = observed { Self.notifications.forEach { AXObserverRemoveNotification(ax, o, $0 as CFString) } }
        observed = nil
        if axObserver == nil {
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            var o: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                Unmanaged<MeetObserver>.fromOpaque(refcon).takeUnretainedValue().readMic()
            }
            guard AXObserverCreate(pid, callback, &o) == .success, let o else { return }
            axObserver = o
            axThread?.add(AXObserverGetRunLoopSource(o))
        }
        guard let ax = axObserver else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notifications { AXObserverAddNotification(ax, e, n as CFString, ref) }
        observed = e
    }

    // MARK: Accessibility tree

    private static let attributeNames = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray

    private static func read(_ e: AXUIElement) -> (role: String, title: String?, desc: String?, value: String?, kids: [AXUIElement])? {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let a = out as? [AnyObject], a.count == 5, let role = a[0] as? String else { return nil }
        func s(_ v: AnyObject) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        // A checkbox's value is a number: kept as "0" / "1" (the captions toggle).
        let value = s(a[3]) ?? (role == "AXCheckBox" ? (a[3] as? NSNumber)?.stringValue : nil)
        return (role, s(a[1]), s(a[2]), value, a[4] as? [AXUIElement] ?? [])
    }

    private static func node(_ r: (role: String, title: String?, desc: String?, value: String?, kids: [AXUIElement]), _ e: AXUIElement, _ depth: Int) -> MeetNode {
        MeetNode(depth: depth, role: r.role, title: r.title, desc: r.desc, value: r.value, key: Int(bitPattern: UInt(CFHash(e))))
    }

    /// The page in document order, bounded; of the captions only the newest blocks are read.
    static func walk(_ root: AXUIElement, limit: Int = 3000, maxDepth: Int = 60) -> ([MeetNode], [AXUIElement]) {
        var nodes: [MeetNode] = [], elements: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let item = stack.popLast(), nodes.count < limit {
            let (e, d) = item
            guard let r = read(e) else { continue }
            nodes.append(node(r, e, d))
            elements.append(e)
            if r.role == "AXGroup", MeetStrings.captionRegions.contains(MeetParse.clean(r.title ?? r.desc ?? "").lowercased()) {
                let (n, els) = captionNodes(e, depth: d, header: false, kids: r.kids)
                nodes += n
                elements += els
                continue
            }
            guard d < maxDepth else { continue }
            for k in r.kids.reversed() { stack.append((k, d + 1)) }
        }
        return (nodes, elements)
    }

    /// The captions region's subtree, single-child wrappers included, but only its newest blocks.
    static func captionNodes(_ region: AXUIElement, depth: Int, header: Bool, kids given: [AXUIElement]? = nil) -> ([MeetNode], [AXUIElement]) {
        var nodes: [MeetNode] = [], elements: [AXUIElement] = []
        var kids: [AXUIElement]
        if let given { kids = given } else {
            guard let r = read(region) else { return ([], []) }
            if header { nodes.append(node(r, region, depth)); elements.append(region) }
            kids = r.kids
        }
        var d = depth + 1
        while kids.count == 1, d < depth + 6, let r = read(kids[0]) {
            nodes.append(node(r, kids[0], d))
            elements.append(kids[0])
            kids = r.kids
            d += 1
        }
        for block in kids.suffix(captionTail) {
            var stack: [(AXUIElement, Int)] = [(block, d)]
            var budget = 200
            while let item = stack.popLast(), budget > 0 {
                let (e, nd) = item
                budget -= 1
                guard let r = read(e) else { continue }
                nodes.append(node(r, e, nd))
                elements.append(e)
                if nd < d + 8 { for k in r.kids.reversed() { stack.append((k, nd + 1)) } }
            }
        }
        return (nodes, elements)
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    // MARK: Finding the Meet page

    static func meetCode(_ url: String) -> String? {
        guard let u = URL(string: url), u.host?.lowercased() == "meet.google.com" else { return nil }
        return u.pathComponents.first { $0.range(of: #"^[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}$"#, options: .regularExpression) != nil }
    }

    /// "Meet - Weekly sync" → "Weekly sync"; nil for Meet's own titles and bare meeting codes.
    static func pageTitle(_ raw: String?) -> String? {
        guard var t = raw.map(MeetParse.clean),
              let r = MeetStrings.titlePrefixes.compactMap({ t.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        t = String(t[r.upperBound...])
        for suffix in [" - Google Chrome", " - Microsoft Edge", " - Brave", " - Vivaldi", " – Google Chrome"] {
            if let s = t.range(of: suffix) { t = String(t[..<s.lowerBound]) }
        }
        t = MeetParse.clean(t)
        guard !t.isEmpty, t.range(of: #"^[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}$"#, options: .regularExpression) == nil else { return nil }
        return t
    }

    private static func looksMeet(_ title: String) -> Bool {
        MeetStrings.titlePrefixes.contains { title.contains($0) } || title.localizedCaseInsensitiveContains("meet.google.com")
    }

    /// Breadth-first through one window for a web area showing a Meet call, without entering web content.
    private static func webArea(in window: AXUIElement, limit: Int = 400) -> (element: AXUIElement, url: String?, title: String?)? {
        var queue = [window], i = 0
        while i < queue.count, i < limit {
            let e = queue[i]
            i += 1
            guard let role = attribute(e, kAXRoleAttribute) as? String else { continue }
            if role == "AXWebArea" {
                let url = (attribute(e, "AXURL") as? URL)?.absoluteString
                let title = attribute(e, kAXTitleAttribute) as? String
                if url.flatMap(meetCode) != nil || (url == nil && title.map(looksMeet) == true) { return (e, url, title) }
                continue
            }
            queue += children(e)
        }
        return nil
    }

    private static func windows(_ app: AXUIElement) -> [(AXUIElement, String)] {
        (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, attribute($0, kAXTitleAttribute) as? String ?? "") }
    }

    static func findMeet(_ app: AXUIElement) -> (element: AXUIElement, url: String?, title: String?)? {
        let all = windows(app)
        for (w, _) in all.filter({ looksMeet($0.1) }) + all.filter({ !looksMeet($0.1) }) {
            if let r = webArea(in: w) { return r }
        }
        return nil
    }

    /// A Meet tab still exists (in the background): a tab or address bar outside web content names it. `limit`: elements
    /// read across all windows.
    static func meetTabExists(_ app: AXUIElement, limit: Int = 1500) -> Bool {
        let all = windows(app)
        if all.contains(where: { looksMeet($0.1) }) { return true }
        var budget = limit
        for (w, _) in all {
            var queue = [w], i = 0
            while i < queue.count, budget > 0 {
                let e = queue[i]
                i += 1
                budget -= 1
                guard let role = attribute(e, kAXRoleAttribute) as? String, role != "AXWebArea" else { continue }
                for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    if let s = attribute(e, key) as? String, looksMeet(s) { return true }
                }
                queue += children(e)
            }
        }
        return false
    }

    /// For the detector: is a Google Meet call open in this browser? Reads window titles first, then the web area's URL.
    static func meetPage(bundleID: String) -> (code: String?, title: String?, url: String?)? {
        guard trusted, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let meet = windows(app).filter { looksMeet($0.1) }
        guard !meet.isEmpty else { return nil }
        for (w, _) in meet {
            if let r = webArea(in: w), let url = r.url, let code = meetCode(url) { return (code, pageTitle(r.title), url) }
        }
        return (nil, pageTitle(meet[0].1), nil)
    }

    // MARK: Before the call (the pre-join watcher)

    struct Probe: Sendable {
        var windowTitle: String
        var code: String?
        var url: String?
        var title: String?
        var phase: MeetPhase
        /// The walk hit its node limit: a page that big with no pre-join strings read is a call.
        var truncated = false
    }

    private static func axApp(_ bundleID: String) -> AXUIElement? {
        guard trusted, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    /// A Meet tab's window title: "Meet - abc-defg-hij" or "Meet - Weekly sync".
    static func isMeetTitle(_ title: String) -> Bool { looksMeet(title) }

    /// The browser's window titles: the cheap first look, nothing inside the windows is read. nil if it isn't running.
    static func windowTitles(bundleID: String) -> [String]? {
        axApp(bundleID).map { windows($0).map { MeetParse.clean($0.1) } }
    }

    /// One Meet window in depth: its page's URL, and which screen it shows from one bounded walk of the page.
    static func probe(bundleID: String, windowTitle: String, limit: Int = 3000) -> Probe? {
        guard let app = axApp(bundleID), let w = windows(app).first(where: { MeetParse.clean($0.1) == windowTitle })?.0 else { return nil }
        var p = Probe(windowTitle: windowTitle, code: MeetParse.code(inTitle: windowTitle), title: pageTitle(windowTitle), phase: .unknown)
        guard let web = webArea(in: w) else { return p }
        if let url = web.url, let code = meetCode(url) { p.url = url; p.code = code }
        p.title = pageTitle(web.title) ?? p.title
        let (nodes, _) = walk(web.element, limit: limit)
        p.phase = MeetParse.phase(nodes)
        p.truncated = nodes.count >= limit
        return p
    }

    /// A Meet tab is open in this browser, maybe behind another tab of its window.
    static func meetTabOpen(bundleID: String, limit: Int = 1500) -> Bool { axApp(bundleID).map { meetTabExists($0, limit: limit) } ?? false }

    /// Chromium builds the page's accessibility tree only on request. Returns true when this call switched it on.
    static func enableWebTree(bundleID: String) -> Bool {
        guard let app = axApp(bundleID), attribute(app, "AXManualAccessibility") as? Bool != true else { return false }
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    static func disableWebTree(bundleID: String) {
        guard let app = axApp(bundleID) else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse)
    }
}

/// A thread with its own run loop for AX observer callbacks and the microphone poll, off the main thread.
private final class AXThread: @unchecked Sendable {
    private var loop: CFRunLoop?
    private var thread: Thread?

    init() {
        let ready = DispatchSemaphore(value: 0)
        let th = Thread { [weak self] in
            self?.loop = CFRunLoopGetCurrent()
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        th.name = "earshot.meet.ax"
        th.qualityOfService = .userInitiated
        th.start()
        ready.wait()
        thread = th
    }

    func every(_ seconds: Double, _ block: @escaping () -> Void) {
        guard let loop else { return }
        let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + seconds, seconds, 0, 0) { _ in block() }
        CFRunLoopAddTimer(loop, t, .defaultMode)
    }

    func add(_ source: CFRunLoopSource) {
        guard let loop else { return }
        CFRunLoopAddSource(loop, source, .defaultMode)
    }

    func async(_ block: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    func sync(_ block: @escaping () -> Void) {
        guard loop != nil else { return block() }
        let done = DispatchSemaphore(value: 0)
        async { block(); done.signal() }
        done.wait()
    }

    func stop() {
        guard let loop else { return }
        self.loop = nil
        CFRunLoopStop(loop)
    }
}

// MARK: Until Meeting.swift switches over

typealias MeetCaptionWatcher = MeetObserver

extension MeetObserver {
    /// The old caption watcher's call: `onHint` gets each caption speaker who is talking.
    convenience init?(bundleID: String, onHint: @escaping @Sendable (String) -> Void) {
        let t0 = Date()
        self.init(bundleID: bundleID, clock: { Date().timeIntervalSince(t0) })
        onCaptionSpeaker = onHint
    }
}
