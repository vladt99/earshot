import AppKit
import Foundation

/// What to do when a call starts, chosen on Meet's pre-join screen.
struct PreJoinChoice: Codable, Hashable, Sendable {
    /// "auto" (follow Meet's captions) or an ISO 639-1 code.
    var language: String
    /// "record", "captions" or "none".
    var action: String
    var at = Date()

    static let actions = ["record", "captions", "none"]
}

/// Choices remembered per meeting code and per calendar series or title, so a weekly meeting held in Romanian
/// opens in Romanian. prejoin.json in Earshot's support folder.
struct PreJoinMemory: Codable, Sendable {
    var codes: [String: PreJoinChoice] = [:]
    var series: [String: PreJoinChoice] = [:]

    static let limit = 300

    /// A recurring calendar event keeps its identifier across occurrences; the title covers events not in the calendar.
    static func seriesKeys(eventID: String?, title: String?) -> [String] {
        var keys: [String] = []
        if let e = eventID, !e.isEmpty { keys.append("event:" + e) }
        if let t = title.map(normalized), t.count >= 3 { keys.append("title:" + t) }
        return keys
    }

    static func normalized(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func choice(code: String?, eventID: String?, title: String?) -> PreJoinChoice? {
        if let code = code?.lowercased(), let c = codes[code] { return c }
        return Self.seriesKeys(eventID: eventID, title: title).lazy.compactMap { series[$0] }.first
    }

    mutating func remember(_ c: PreJoinChoice, code: String?, eventID: String?, title: String?) {
        if let code = code?.lowercased(), !code.isEmpty { codes[code] = c }
        for k in Self.seriesKeys(eventID: eventID, title: title) { series[k] = c }
        for keyPath in [\PreJoinMemory.codes, \PreJoinMemory.series] where self[keyPath: keyPath].count > Self.limit {
            let keep = self[keyPath: keyPath].sorted { $0.value.at > $1.value.at }.prefix(Self.limit)
            self[keyPath: keyPath] = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

/// The pre-join state machine, pure: page reads in, what to do out.
/// nothing shown → preJoin/asking (show) → inCall (join) | ended (leave) | three reads that find nothing (lost)
struct PreJoinFlow: Equatable, Sendable {
    enum Event: Equatable, Sendable { case none, show, update, join, leave, lost }

    /// What the overlay shows; nil when it isn't shown.
    private(set) var phase: MeetPhase?
    private(set) var misses = 0
    static let maxMisses = 3

    /// One read of the Meet page: its phase, or nil when it couldn't be read (window gone, browser busy). `truncated`:
    /// the walk hit its limit, so a page without pre-join strings is a call whose tiles came in.
    mutating func read(_ p: MeetPhase?, truncated: Bool = false) -> Event {
        guard let shown = phase else {
            guard p == .preJoin || p == .asking else { return .none }
            phase = p
            misses = 0
            return .show
        }
        switch p {
        case .preJoin?, .asking?:
            misses = 0
            guard p != shown else { return .none }
            phase = p
            return .update
        case .inCall?:
            reset()
            return .join
        case .unknown? where truncated:
            reset()
            return .join
        case .ended?:
            reset()
            return .leave
        default:
            misses += 1
            guard misses >= Self.maxMisses else { return .none }
            reset()
            return .lost
        }
    }

    mutating func reset() {
        phase = nil
        misses = 0
    }
}

/// A Meet tab on its pre-join screen, shown in the panel as "Before you join".
struct PreJoinOffer: Equatable, Sendable {
    var bundleID: String
    var appName: String
    var windowTitle: String
    var code: String?
    var url: String?
    var title: String?
    var eventID: String?
    var attendees: Int?
    var phase: MeetPhase
    var language: String
    var action: String
    /// The choice came from an earlier meeting with this code, series or title.
    var remembered = false
    /// Hidden by the user: in "auto" the choice still applies on join, in "ask" the usual prompt comes instead.
    var dismissed = false

    /// Show "Turn on captions in Meet": only when Earshot doesn't turn them on itself.
    var captionsReminder: Bool { !Settings.autoEnableCaptions }

    /// The language the call will start in: the one picked, else Earshot's own.
    var startLanguage: String? { language == "auto" ? Settings.language : language }
}

/// Watches for Google Meet's pre-join screen so the language and what to record can be chosen before the call.
/// Cheap by design: every 2 s, and only while a supported browser is frontmost (or a pre-join screen is being
/// followed), it reads the browser's window titles. A Meet window it hasn't seen gets one bounded walk of its page;
/// only a page on its pre-join screen is walked again, every 2 s, until it joins, ends or closes.
///
/// unknown → preJoin/asking (overlay shown) → inCall (act on the choice, hand over to the session) | ended/closed (hide)
@MainActor
final class PreJoinWatcher {
    static let shared = PreJoinWatcher()

    private var loop: Task<Void, Never>?
    private var busy = false
    /// Meet window titles read once that showed no pre-join screen (a call, an end screen): not walked again while open.
    private var settled: [String: Set<String>] = [:]
    private var tries: [String: Int] = [:]
    private var flow = PreJoinFlow()
    /// Browsers whose page tree this watcher switched on (switched off again when it's done with them).
    private var webTree: Set<String> = []
    /// Calls the user chose not to record, by meeting code: their mic use isn't announced. For that call only: the
    /// entry lapses 10 minutes after the browser lets go of the mic (a quick rejoin is the same call), or after 12 h.
    private var declined: [String: Declined] = [:]
    private struct Declined { var bundle: String; var at = Date(); var released: Date? }
    /// When the shown Meet tab went behind another tab, where its page can't be read.
    private var backgroundSince: Date?
    private var tabCheck: (bundle: String, at: Date, open: Bool)?

    private var offer: PreJoinOffer? {
        get { AppState.shared.preJoin }
        set { AppState.shared.preJoin = newValue }
    }

    var enabled: Bool { Settings.preJoinOverlay && Settings.meetingMode != "off" }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.tick()
            }
        }
    }

    // MARK: Polling

    private func tick(force bundle: String? = nil) async {
        if bundle != nil { while busy { try? await Task.sleep(for: .milliseconds(100)) } }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard enabled, MeetObserver.trusted, MeetingController.shared.session == nil else {
            if offer != nil { offer = nil; flow.reset(); hidePanel() }
            for b in Array(webTree) { releaseWebTree(b) }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let target = offer?.bundleID ?? bundle ?? front.flatMap({ MeetingApp.browsers.contains($0) ? $0 : nil }),
              Settings.meetingApps.contains(target) else {
            for b in Array(webTree) { releaseWebTree(b) }
            return
        }
        guard let titles = await Task.detached(operation: { MeetObserver.windowTitles(bundleID: target) }).value else {
            if offer != nil { left() }
            return
        }
        let meet = titles.filter(MeetObserver.isMeetTitle)
        settled[target] = settled[target, default: []].intersection(meet)
        tries = tries.filter { k, _ in meet.contains { k == target + "|" + $0 } }

        if let o = offer { return await follow(o, meet: meet) }

        for title in meet where !settled[target, default: []].contains(title) {
            enableWebTree(target)
            guard let p = await Task.detached(operation: { MeetObserver.probe(bundleID: target, windowTitle: title) }).value else { continue }
            switch p.phase {
            case .preJoin, .asking:
                if isDeclined(p.code) { settle(target, title); continue }
                show(p, bundle: target)
                return
            case .unknown where p.truncated:
                settle(target, title)
            case .unknown:
                // The page tree may still be building: a few more looks, then leave it.
                let k = target + "|" + title
                tries[k, default: 0] += 1
                if tries[k]! >= 3 { settle(target, title) }
            case .inCall, .ended:
                settle(target, title)
            }
        }
        if !meet.contains(where: { !settled[target, default: []].contains($0) }) { releaseWebTree(target) }
    }

    /// The pre-join screen on show: did it join, end, close or move to another meeting? A read that finds nothing
    /// (the browser is busy right as it joins) only counts after three in a row.
    private func follow(_ shown: PreJoinOffer, meet: [String]) async {
        let bundle = shown.bundleID
        guard let title = meet.first(where: { $0 == shown.windowTitle })
                ?? meet.first(where: { shown.code != nil && MeetParse.code(inTitle: $0) == shown.code }) ?? (meet.count == 1 ? meet[0] : nil) else {
            // Another tab in front: keep the offer while the Meet tab is still open behind it.
            guard await tabOpen(bundle) else { backgroundSince = nil; return apply(flow.read(nil), title: nil) }
            guard offer?.bundleID == bundle else { return }
            let since = backgroundSince ?? Date()
            backgroundSince = since
            // Let in (or joined just before switching tabs) where the page can't be seen: once the browser has held the
            // mic for a while, it's the call.
            if micHeld(bundle), Date().timeIntervalSince(since) >= (shown.phase == .asking ? 5 : 15) { apply(.join, title: nil) }
            return
        }
        backgroundSince = nil
        enableWebTree(bundle)
        let p = await Task.detached(operation: { MeetObserver.probe(bundleID: bundle, windowTitle: title) }).value
        guard offer?.bundleID == bundle else { return }
        if let code = shown.code, let now = p?.code, now != code { return left() }
        apply(flow.read(p?.phase, truncated: p?.truncated ?? false), title: title, phase: p?.phase)
    }

    private func apply(_ e: PreJoinFlow.Event, title: String?, phase: MeetPhase? = nil) {
        guard let o = offer else { return }
        switch e {
        case .none, .show:
            break
        case .update:
            offer?.phase = phase ?? o.phase
            if let title { offer?.windowTitle = title }
        case .join:
            if let title { settle(o.bundleID, title) }
            joined(o)
        case .leave:
            if let title { settle(o.bundleID, title) }
            left()
        case .lost:
            left(fallback: true)
        }
    }

    private func settle(_ bundle: String, _ title: String) { settled[bundle, default: []].insert(title) }

    private func micHeld(_ bundle: String) -> Bool { MeetingDetector.shared.activeMeetings.contains { $0.appBundleID == bundle } }

    /// meetTabOpen walks the browser's tab strips: at most every 6 s, on a bounded budget.
    private func tabOpen(_ bundle: String) async -> Bool {
        if let c = tabCheck, c.bundle == bundle, Date().timeIntervalSince(c.at) < 6 { return c.open }
        let open = await Task.detached(operation: { MeetObserver.meetTabOpen(bundleID: bundle, limit: 800) }).value
        tabCheck = (bundle, Date(), open)
        return open
    }

    private func enableWebTree(_ bundle: String) {
        guard !webTree.contains(bundle), MeetObserver.enableWebTree(bundleID: bundle) else { return }
        webTree.insert(bundle)
    }

    private func releaseWebTree(_ bundle: String) {
        guard webTree.remove(bundle) != nil else { return }
        // A session reading this browser takes the tree over and switches it off when it stops.
        if MeetingController.shared.session?.adoptWebTree(bundle) == true { return }
        MeetObserver.disableWebTree(bundleID: bundle)
    }

    /// A starting session's observer takes the page tree this watcher switched on, so it isn't switched off and on
    /// again (Chrome would rebuild it, and the mic state would be unknown meanwhile).
    func takeWebTree(_ bundle: String) -> Bool { webTree.remove(bundle) != nil }

    // MARK: States

    private func show(_ p: MeetObserver.Probe, bundle: String) {
        let cal = MeetingDetector.calendarInfo(code: p.code, title: p.title, at: Date())
        let title = p.title ?? cal?.title
        let remembered = Self.memory.choice(code: p.code, eventID: cal?.eventID, title: title)
        let app = MeetingApp.find(bundle)?.name ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.localizedName ?? bundle
        flow.reset()
        _ = flow.read(p.phase)
        offer = PreJoinOffer(bundleID: bundle, appName: app, windowTitle: p.windowTitle, code: p.code, url: p.url, title: title,
                             eventID: cal?.eventID, attendees: cal.map { $0.attendees.count }.flatMap { $0 > 0 ? $0 : nil }, phase: p.phase,
                             language: remembered?.language ?? Self.defaultLanguage, action: remembered?.action ?? "record",
                             remembered: remembered != nil)
        LiveDebug.log("[prejoin] \(p.phase.rawValue) screen shown")
        prewarm()
        EventBus.shared.publish("meeting.prejoin", ["app": app, "app_bundle_id": bundle, "title": title ?? "", "meeting_code": p.code ?? ""])
        MeetingPanel.shared.show()
    }

    static var defaultLanguage: String { Settings.followMeetingLanguage ? "auto" : Settings.language ?? "auto" }

    /// Left the pre-join screen without joining (tab closed, back to Meet's home, end screen).
    private func left(fallback: Bool = false) {
        guard let o = offer else { return }
        LiveDebug.log("[prejoin] left\(fallback ? ", page lost" : "")")
        offer = nil
        flow.reset()
        backgroundSince = nil
        if let code = o.code { declined[code] = nil }
        // Lost track of the page while the browser holds the mic (its use held back for the overlay): the choice applies.
        if fallback, micHeld(o.bundleID) { return handOver(o) }
        releaseWebTree(o.bundleID)
        hidePanel()
    }

    private func hidePanel() {
        if AppState.shared.meeting == nil, AppState.shared.detectedMeeting == nil, !MeetingController.shared.isStopping { MeetingPanel.shared.hide() }
    }

    /// The call started: do what was chosen, instead of the usual "Meeting detected" prompt.
    private func joined(_ o: PreJoinOffer) {
        LiveDebug.log("[prejoin] joined: \(o.action), language \(o.language)")
        offer = nil
        flow.reset()
        backgroundSince = nil
        remember(o)
        handOver(o)
    }

    /// Does what was chosen instead of the usual "Meeting detected" prompt; hidden in "ask", the prompt comes (unless
    /// it was "Don't record"). The session's observer takes over the page tree.
    private func handOver(_ o: PreJoinOffer) {
        if o.dismissed, o.action != "none", Settings.meetingMode == "ask" {
            if let m = MeetingDetector.shared.activeMeetings.first(where: { $0.appBundleID == o.bundleID }) { MeetingDetector.shared.announce(m) }
            else { hidePanel() }
        } else {
            act(language: o.language, action: o.action, bundle: o.bundleID, appName: o.appName, title: o.title, code: o.code)
        }
        releaseWebTree(o.bundleID)
    }

    private func act(language: String, action: String, bundle: String, appName: String, title: String?, code: String?) {
        let lang = language == "auto" ? nil : language
        do {
            switch action {
            case "record":
                try MeetingController.shared.start(app: bundle, title: title, platform: "Google Meet", appName: appName, mic: true,
                                                   fromDetection: bundle, language: lang)
                Notifier.post("Transcribing \(title ?? "your Meet call")", body: lang.map { "In \(Self.languageName($0))." } ?? "Live transcript is running.")
            case "captions":
                try MeetingController.shared.start(app: bundle, title: "Live Captions", platform: "Live Captions", appName: appName, mic: true,
                                                   fromDetection: bundle, origin: "captions", save: false, language: lang)
            default:
                declined[code ?? "app:" + bundle] = Declined(bundle: bundle)
                hidePanel()
            }
        } catch {
            let reason = (error as? APIError)?.message ?? error.localizedDescription
            AppState.shared.lastError = "Couldn't record \(title ?? "the call"): \(reason)"
            Notifier.post("Couldn't transcribe \(title ?? "the call")", body: reason)
        }
    }

    static func languageName(_ code: String) -> String {
        LanguageMenu.languages.first { $0.0 == code }?.1 ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    // MARK: From the detector and the panel

    /// The browser took the microphone. Meet's preview does that on the pre-join screen, so a Meet page is read first:
    /// on the pre-join screen the overlay handles it, in a call the usual prompt follows. True: the watcher handles it.
    func intercept(_ m: DetectedMeeting) -> Bool {
        guard enabled, MeetObserver.trusted, MeetingController.shared.session == nil, MeetingApp.browsers.contains(m.appBundleID) else { return false }
        if let code = declinedCode(m) {
            declined[code]?.released = nil
            return true
        }
        if offer?.bundleID == m.appBundleID {
            Task { await tick(force: m.appBundleID) }
            return true
        }
        guard m.platform == "Google Meet" else { return false }
        Task { @MainActor in
            await tick(force: m.appBundleID)
            guard offer?.bundleID != m.appBundleID, MeetingController.shared.session == nil,
                  let still = MeetingDetector.shared.activeMeetings.first(where: { $0.key == m.key }) else { return }
            // In the call already. In "auto", a choice remembered for this meeting still applies.
            let cal = MeetingDetector.calendarInfo(code: still.meetingCode, title: still.title, at: Date())
            if Settings.meetingMode == "auto", let c = Self.memory.choice(code: still.meetingCode, eventID: cal?.eventID, title: still.title) {
                act(language: c.language, action: c.action, bundle: still.appBundleID, appName: still.appName,
                    title: still.title == "Google Meet meeting" ? nil : still.title, code: still.meetingCode)
            } else {
                MeetingDetector.shared.announce(still)
            }
        }
        return true
    }

    private func isDeclined(_ code: String?) -> Bool {
        guard let code, let d = declined[code] else { return false }
        let lapsed = Date().timeIntervalSince(d.at) > 12 * 3600 || d.released.map { Date().timeIntervalSince($0) > 600 } == true
        if lapsed { declined[code] = nil }
        return !lapsed
    }

    /// The declined call this mic use belongs to: by its code, or the browser's when the page wasn't read.
    private func declinedCode(_ m: DetectedMeeting) -> String? {
        if let code = m.meetingCode { return isDeclined(code) ? code : nil }
        return declined.first { $0.value.bundle == m.appBundleID && isDeclined($0.key) }?.key
    }

    /// The detector saw the browser let go of the mic: its declined call is over (or muted; see `declined`).
    func micReleased(_ bundle: String) {
        for (code, d) in declined where d.bundle == bundle { declined[code]?.released = Date() }
    }

    func setLanguage(_ language: String) {
        guard offer != nil else { return }
        offer?.language = language
        if Engine.usesWhisper(language: language == "auto" ? Settings.language : language) { AppState.shared.prepareWhisper() }
        if let o = offer { remember(o) }
        prewarm()
    }

    func setAction(_ action: String) {
        guard offer != nil, PreJoinChoice.actions.contains(action) else { return }
        offer?.action = action
        if let o = offer { remember(o) }
    }

    /// Loads the speech model the call will need while the user is still on the pre-join screen.
    private func prewarm() {
        guard let lang = offer.map(\.startLanguage) else { return }
        Task { await Engine.shared.prewarm(language: lang) }
    }

    func dismiss() {
        offer?.dismissed = true
        hidePanel()
    }

    // MARK: Memory

    static var memoryURL: URL { Paths.support.appendingPathComponent("prejoin.json") }

    static var memory: PreJoinMemory {
        (try? Data(contentsOf: memoryURL)).flatMap { try? JSONDecoder().decode(PreJoinMemory.self, from: $0) } ?? PreJoinMemory()
    }

    private func remember(_ o: PreJoinOffer) {
        var m = Self.memory
        m.remember(PreJoinChoice(language: o.language, action: o.action), code: o.code, eventID: o.eventID, title: o.title)
        try? JSONEncoder().encode(m).write(to: Self.memoryURL, options: .atomic)
    }
}
