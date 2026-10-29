import Foundation

enum Paths {
    static let fm = FileManager.default

    static let support: URL = dir(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Earshot", isDirectory: true))


    static var meetings: URL { dir(support.appendingPathComponent("meetings", isDirectory: true)) }

    static var database: URL { support.appendingPathComponent("history.sqlite") }
    static var media: URL { dir(support.appendingPathComponent("media", isDirectory: true)) }
    static var uploads: URL { dir(fm.temporaryDirectory.appendingPathComponent("Earshot-uploads", isDirectory: true)) }
    /// Discovery file for other local apps: base URL, port and bearer token.
    static var apiInfo: URL { support.appendingPathComponent("api.json") }

    @discardableResult
    static func dir(_ url: URL) -> URL {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    static var port: UInt16 {
        let p = d.integer(forKey: "port")
        return p > 0 && p < 65536 ? UInt16(p) : 7788
    }

    /// ISO 639-1 code, or nil for auto-detect.
    static var language: String? {
        get { d.string(forKey: "language") }
        set { d.set(newValue, forKey: "language") }
    }

    // MARK: Meetings

    /// What to do when a call is detected: "ask", "auto", "off".
    static var meetingMode: String {
        get { d.string(forKey: "meetingMode") ?? "ask" }
        set { d.set(newValue, forKey: "meetingMode") }
    }

    /// Apps whose microphone use counts as a meeting.
    static var meetingApps: [String] {
        get { d.stringArray(forKey: "meetingApps") ?? MeetingApp.known.map(\.bundleID) }
        set { d.set(newValue, forKey: "meetingApps") }
    }

    /// "Stop recording 10 seconds after a meeting ends. Dismiss the alert to keep recording."
    static var autoStopAfterMeeting: Bool {
        get { d.object(forKey: "autoStopAfterMeeting") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoStopAfterMeeting") }
    }

    /// "Automatically dismiss detected meeting alerts after 10 seconds"
    static var autoDismissMeetingAlerts: Bool {
        get { d.object(forKey: "autoDismissMeetingAlerts") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoDismissMeetingAlerts") }
    }

    /// Label for the app stream when speakers aren't separated.
    static var participantsName: String {
        get { d.string(forKey: "participantsName") ?? "Meeting Participants" }
        set { d.set(newValue, forKey: "participantsName") }
    }

    static var useCalendarTitles: Bool {
        get { d.object(forKey: "useCalendarTitles") as? Bool ?? true }
        set { d.set(newValue, forKey: "useCalendarTitles") }
    }

    /// Split the other participants into Speaker 1, 2, … live (FluidAudio diarizer).
    static var diarizeMeetings: Bool {
        get { d.object(forKey: "diarizeMeetings") as? Bool ?? true }
        set { d.set(newValue, forKey: "diarizeMeetings") }
    }

    /// Diarize regular file transcriptions by default.
    static var diarizeFiles: Bool {
        get { d.object(forKey: "diarizeFiles") as? Bool ?? false }
        set { d.set(newValue, forKey: "diarizeFiles") }
    }

    static var echoCancellation: Bool {
        get { d.object(forKey: "echoCancellation") as? Bool ?? true }
        set { d.set(newValue, forKey: "echoCancellation") }
    }

    /// Speaker label for the microphone channel.
    static var myName: String {
        get { d.string(forKey: "myName") ?? "Me" }
        set { d.set(newValue, forKey: "myName") }
    }

    // MARK: Note taker

    /// After Stop, re-transcribe both recordings in one clean pass (better text and speakers than the live
    /// version).
    static var polishAfterMeeting: Bool {
        get { d.object(forKey: "polishAfterMeeting") as? Bool ?? true }
        set { d.set(newValue, forKey: "polishAfterMeeting") }
    }

    /// Name speakers from Google Meet's captions (read through Accessibility) and from saved voices.
    static var autoNameSpeakers: Bool {
        get { d.object(forKey: "autoNameSpeakers") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoNameSpeakers") }
    }

    /// Remember the voices of named people and recognise them in later meetings.
    static var rememberVoices: Bool {
        get { d.object(forKey: "rememberVoices") as? Bool ?? true }
        set { d.set(newValue, forKey: "rememberVoices") }
    }

    /// Words the speech model gets wrong: names, products, project terms. Needs Parakeet CTC 110M (≈ 100 MB).
    static var vocabulary: [String] {
        get { d.stringArray(forKey: "vocabulary") ?? [] }
        set { d.set(newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: "vocabulary") }
    }

    /// ⌃⌘B adds a bookmark to the running meeting from any app.
    static var bookmarkHotkey: Bool {
        get { d.object(forKey: "bookmarkHotkey") as? Bool ?? true }
        set { d.set(newValue, forKey: "bookmarkHotkey") }
    }

    /// Warn when the meeting app or the microphone has been silent for too long.
    static var audioWarnings: Bool {
        get { d.object(forKey: "audioWarnings") as? Bool ?? true }
        set { d.set(newValue, forKey: "audioWarnings") }
    }

    /// URLs that receive a POST for the events in `webhookEvents`.
    static var webhooks: [String] {
        get { d.stringArray(forKey: "webhooks") ?? [] }
        set { d.set(newValue.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: "webhooks") }
    }

    static var webhookEvents: [String] {
        get { d.stringArray(forKey: "webhookEvents") ?? ["meeting.finalized", "job.done"] }
        set { d.set(newValue, forKey: "webhookEvents") }
    }

    // MARK: Library & export

    static var watchedFolders: [String] {
        get { d.stringArray(forKey: "watchedFolders") ?? [] }
        set { d.set(newValue, forKey: "watchedFolders") }
    }

    static var playSoundWhenFinished: Bool {
        get { d.object(forKey: "playSoundWhenFinished") as? Bool ?? true }
        set { d.set(newValue, forKey: "playSoundWhenFinished") }
    }

    /// Exact segment texts to drop.
    static var ignoredSegments: [String] {
        get { d.stringArray(forKey: "ignoredSegments") ?? [] }
        set { d.set(newValue, forKey: "ignoredSegments") }
    }

    /// Applied to every new transcript. Each entry is [find, replace].
    static var findReplace: [[String]] {
        get { d.array(forKey: "findReplace") as? [[String]] ?? [] }
        set { d.set(newValue, forKey: "findReplace") }
    }

    /// Write every finished transcript here as well.
    static var autoExportFolder: String? {
        get { d.string(forKey: "autoExportFolder") }
        set { d.set(newValue, forKey: "autoExportFolder") }
    }

    static var autoExportFormats: [String] {
        get { d.stringArray(forKey: "autoExportFormats") ?? ["txt"] }
        set { d.set(newValue, forKey: "autoExportFormats") }
    }

    // MARK: Appearance

    /// "system", "light" or "dark".
    static var appearance: String {
        get { d.string(forKey: "appearance") ?? "system" }
        set { d.set(newValue, forKey: "appearance") }
    }

    /// Custom background image (copied into Application Support); nil = the desktop wallpaper.
    static var backgroundImage: String? {
        get { d.string(forKey: "backgroundImage") }
        set { d.set(newValue, forKey: "backgroundImage") }
    }

    static var backgroundDim: Double {
        get { d.object(forKey: "backgroundDim") as? Double ?? 0.15 }
        set { d.set(newValue, forKey: "backgroundDim") }
    }

    static var fontSize: Double {
        get { d.object(forKey: "fontSize") as? Double ?? 18 }
        set { d.set(newValue, forKey: "fontSize") }
    }

    /// Extra Home tiles added with "Add Shortcut": meeting-app bundle ids to record.
    static var homeShortcuts: [String] {
        get { d.stringArray(forKey: "homeShortcuts") ?? ["com.google.Chrome"] }
        set { d.set(newValue, forKey: "homeShortcuts") }
    }

    static var copyDictationToClipboard: Bool {
        get { d.object(forKey: "copyDictationToClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "copyDictationToClipboard") }
    }

    /// CFBundleShortVersionString; "dev" for a bare `swift run`.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

struct APIError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }
}

var appVersion: String { Settings.appVersion }
