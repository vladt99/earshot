import AppKit
import EventKit
import Foundation

struct MeetingApp: Sendable {
    let bundleID: String
    let name: String
    let isBrowser: Bool

    /// Apps whose microphone use can mean a call.
    static let known: [MeetingApp] = [
        .init(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false),
        .init(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isBrowser: false),
        .init(bundleID: "Cisco-Systems.Spark", name: "Webex", isBrowser: false),
        .init(bundleID: "com.hnc.Discord", name: "Discord", isBrowser: false),
        .init(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", isBrowser: false),
        .init(bundleID: "com.apple.FaceTime", name: "FaceTime", isBrowser: false),
        .init(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", isBrowser: false),
        .init(bundleID: "ru.keepcoder.Telegram", name: "Telegram", isBrowser: false),
        .init(bundleID: "com.amazon.Amazon-Chime", name: "Amazon Chime", isBrowser: false),
        .init(bundleID: "com.tencent.meeting", name: "Tencent Meeting", isBrowser: false),
        .init(bundleID: "com.tencent.tencentmeeting", name: "Tencent Meeting (CN)", isBrowser: false),
        .init(bundleID: "ru.yandex.desktop.telemost", name: "Telemost", isBrowser: false),
        .init(bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true),
        .init(bundleID: "com.apple.Safari", name: "Safari", isBrowser: true),
        .init(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isBrowser: true),
        .init(bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true),
        .init(bundleID: "com.brave.Browser", name: "Brave", isBrowser: true),
        .init(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", isBrowser: true),
        .init(bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true),
        .init(bundleID: "company.thebrowser.dia", name: "Dia", isBrowser: true),
        .init(bundleID: "app.zen-browser.zen", name: "Zen", isBrowser: true),
        .init(bundleID: "ai.perplexity.comet", name: "Comet", isBrowser: true),
        .init(bundleID: "com.openai.atlas", name: "ChatGPT Atlas", isBrowser: true),
        .init(bundleID: "com.kagi.kagimacOS", name: "Orion", isBrowser: true),
    ]

    static func find(_ bundleID: String) -> MeetingApp? { known.first { $0.bundleID == bundleID } }

    static let browsers = Set(known.filter(\.isBrowser).map(\.bundleID))

    /// Chrome web apps (com.google.Chrome.app.<id>) record through their host browser.
    static func host(of bundleID: String) -> String {
        bundleID.hasPrefix("com.google.Chrome.app.") ? "com.google.Chrome" : bundleID
    }

    /// Processes that carry an app's call audio: FaceTime's calls run in the avconferenced daemon.
    static func audioProcesses(of bundleID: String) -> [String] {
        bundleID == "com.apple.FaceTime" ? [bundleID, "com.apple.avconferenced"] : [bundleID]
    }
}

struct DetectedMeeting: Equatable, Sendable {
    var appBundleID: String
    var appName: String
    var platform: String
    var title: String
    var url: String?

    var key: String { appBundleID }
}

/// Detects calls without polling or URL checks: it tails ControlCenter's
/// privacy-indicator attributions (`log stream --style ndjson`) and treats an observed app that holds the
/// microphone as "in a meeting". A release only counts after 4 s; the stream respawns if it dies.
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()

    static let predicate = #"process == "ControlCenter" AND (eventMessage CONTAINS "Active activity attributions changed to " OR eventMessage CONTAINS "data changed for media domain: <STMediaStatusDomainData")"#

    private var process: Process?
    private var buffer = Data()
    private var respawnDelay: Double = 1
    private var startedAt = Date()
    /// Bundle ids currently holding the mic, per ControlCenter.
    private var micHolders: Set<String> = []
    private var pendingRelease: [String: Task<Void, Never>] = [:]
    private(set) var appsInMeeting: [String] = []
    private var ignored: Set<String> = []
    private var everStarted = false
    private var lastEvent = Date.distantPast
    private var resyncTask: Task<Void, Never>?

    var current: DetectedMeeting? { appsInMeeting.first.map(Self.meeting(for:)) }

    /// Calls in progress that the user hasn't chosen to ignore.
    var activeMeetings: [DetectedMeeting] { appsInMeeting.filter { !ignored.contains($0) }.map(Self.meeting(for:)) }

    func start() {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // Main queue, not a Task per chunk: chunks must be ingested in order.
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return } // EOF
            DispatchQueue.main.async { MainActor.assumeIsolated { MeetingDetector.shared.ingest(data) } }
        }
        p.terminationHandler = { proc in
            reader.readabilityHandler = nil
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { MeetingDetector.shared.streamEnded(status: status) } }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
            if everStarted { resync() }
            everStarted = true
        } catch {
            AppState.shared.lastError = "Meeting detection could not start: \(error.localizedDescription)"
        }
    }

    /// The stream was down: a hang-up in that window was never logged (ControlCenter only logs changes), so ask
    /// Core Audio which of the apps still record. Two checks a few seconds apart, and only if no attribution
    /// arrived meanwhile, so a device switch isn't taken for hanging up.
    private func resync() {
        resyncTask?.cancel()
        let since = Date()
        resyncTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let first = Self.recording(self.micHolders.union(self.appsInMeeting))
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self.lastEvent < since else { return }
            let known = self.micHolders.union(self.appsInMeeting)
            let gone = known.subtracting(first).subtracting(Self.recording(known))
            guard !gone.isEmpty else { return }
            self.update(self.micHolders.subtracting(gone))
            for id in self.appsInMeeting where gone.contains(id) && self.pendingRelease[id] == nil { self.released(id) }
        }
    }

    /// Which of these apps (or their helper processes) currently take audio input.
    static func recording(_ ids: Set<String>) -> Set<String> {
        let inputs = AudioProcess.all().filter(\.isRunningInput)
        return ids.filter { app in
            MeetingApp.audioProcesses(of: app).contains { id in
                let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier))
                return inputs.contains { pids.contains($0.pid) || $0.bundleID == id || $0.bundleID.hasPrefix(id + ".") }
            }
        }
    }

    private func streamEnded(status: Int32) {
        process = nil
        buffer = Data()
        // "Media-attribution log stream ended unexpectedly; respawning in Ns"
        if Date().timeIntervalSince(startedAt) > 60 { respawnDelay = 1 } else { respawnDelay = min(respawnDelay * 2, 30) }
        let delay = respawnDelay
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            MeetingDetector.shared.start()
        }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = obj["eventMessage"] as? String else { continue }
            if let holders = Self.micHolders(in: message) {
                lastEvent = Date()
                update(holders)
            }
        }
    }

    /// `Active activity attributions changed to ["mic:com.google.Chrome","cam:com.google.Chrome"]`
    /// or a STMediaStatusDomainData dump with microphoneBundleIdentifier = …
    static func micHolders(in message: String) -> Set<String>? {
        if let r = message.range(of: "Active activity attributions changed to ") {
            let list = message[r.upperBound...]
            var out = Set<String>()
            let re = try! NSRegularExpression(pattern: #"mic:([A-Za-z0-9._\-]+)"#)
            let s = String(list)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let rr = Range(m.range(at: 1), in: s) { out.insert(String(s[rr])) }
            }
            return out
        }
        if message.contains("STMediaStatusDomainData") {
            let re = try! NSRegularExpression(pattern: #"microphoneBundleIdentifier[^A-Za-z0-9]+([A-Za-z0-9._\-]+)"#)
            var out = Set<String>()
            for m in re.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
                if let rr = Range(m.range(at: 1), in: message), message[rr] != "nil" { out.insert(String(message[rr])) }
            }
            return out
        }
        return nil
    }

    private func update(_ holders: Set<String>) {
        let me = Bundle.main.bundleIdentifier ?? "io.github.vladt99.Earshot"
        let observed = Set(Settings.meetingApps)
        let now = Set(holders.map(MeetingApp.host(of:)).filter { $0 != me && observed.contains($0) })
        for id in now where !micHolders.contains(id) {
            if let t = pendingRelease.removeValue(forKey: id) {
                t.cancel() // came back within 4 s: same meeting (mute toggle, device switch)
            } else if !appsInMeeting.contains(id) {
                appsInMeeting.append(id)
                didDetect(Self.meeting(for: id))
            }
        }
        for id in micHolders where !now.contains(id) {
            pendingRelease[id] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                MeetingDetector.shared.released(id)
            }
        }
        micHolders = now
    }

    private func released(_ id: String) {
        pendingRelease[id] = nil
        appsInMeeting.removeAll { $0 == id }
        ignored.remove(id)
        let m = Self.meeting(for: id)
        if AppState.shared.detectedMeeting?.key == id {
            // A detected call that was never answered ended: take its prompt down.
            AppState.shared.detectedMeeting = nil
            if MeetingController.shared.session == nil, !MeetingController.shared.isStopping { MeetingPanel.shared.hide() }
        }
        EventBus.shared.publish("meeting.ended_detected", ["app": m.appName, "app_bundle_id": id])
        MeetingController.shared.detectedMeetingEnded(m)
    }

    private func didDetect(_ m: DetectedMeeting) {
        EventBus.shared.publish("meeting.detected", ["app": m.appName, "app_bundle_id": m.appBundleID, "title": m.title])
        guard !ignored.contains(m.key) else { return }
        AppState.shared.detectedMeeting = m
        MeetingController.shared.meetingDetected(m)
    }

    func ignore(_ m: DetectedMeeting) { ignored.insert(m.key) }

    static func meeting(for bundleID: String) -> DetectedMeeting {
        let app = MeetingApp.find(bundleID)
        let name = app?.name ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        return DetectedMeeting(appBundleID: bundleID, appName: name, platform: name,
                               title: CalendarLookup.currentEventTitle() ?? "\(name) meeting", url: nil)
    }

    func detect() -> DetectedMeeting? { current }
}

/// Smart meeting titles: the calendar event happening now.
enum CalendarLookup {
    private static let store = EKEventStore()
    private static var requested = false

    static func requestAccess() {
        guard !requested, Settings.useCalendarTitles, EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        requested = true
        store.requestFullAccessToEvents { _, _ in }
    }

    static func currentEventTitle() -> String? {
        guard Settings.useCalendarTitles, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(15 * 60), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate <= now.addingTimeInterval(15 * 60) && $0.endDate >= now.addingTimeInterval(-5 * 60) }
        return events.min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }?.title
    }
}
