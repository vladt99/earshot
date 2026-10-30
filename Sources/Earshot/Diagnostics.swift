import AVFoundation
import ApplicationServices
import CoreAudio
import CoreGraphics
import EventKit
import Foundation

/// Plain-text report for bug reports (Settings → About → Copy Diagnostics, GET /v1/diagnostics).
/// Meant to be pasted into public issues: never contains the API token, names, meeting titles or codes, transcript,
/// caption or chat text, or vocabulary. Devices are reported by kind, and the debug log keeps only technical words.
enum Diagnostics {
    static func report() async -> String {
        let warnings = UserDefaults.standard.stringArray(forKey: AppState.warningsKey) ?? []
        var out: [String] = ["Earshot diagnostics · \(Formats.iso(Date()))", ""]

        out.append("## This Mac")
        let info = ProcessInfo.processInfo
        out.append("Earshot \(Settings.appVersion) (build \(Settings.appBuild))")
        out.append("macOS \(info.operatingSystemVersionString)")
        out.append("Model: \(sysctl("hw.model") ?? "unknown") · Chip: \(sysctl("machdep.cpu.brand_string") ?? "unknown")")
        out.append("Memory: \(bytes(Int64(info.physicalMemory))) · Free disk: \(freeDisk().map(bytes) ?? "unknown")")
        out.append("Recordings on disk: \(bytes(AudioRetention.diskUse()))")
        out.append("")

        out.append("## Models")
        for m in ModelCatalog.all {
            let installed = ModelCatalog.isInstalled(m)
            out.append("\(m.name): \(installed ? "installed, \(bytes(ModelCatalog.installedBytes(m)))" : "not installed") (\(m.sizeText) download)")
        }
        out.append("")

        out.append("## Audio devices")
        out.append("Input: " + device(kAudioHardwarePropertyDefaultInputDevice))
        out.append("Output: " + device(kAudioHardwarePropertyDefaultOutputDevice))
        out.append("")

        out.append("## Permissions")
        out.append("Microphone: \(micStatus())")
        out.append("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
        out.append("Calendar: \(calendarStatus())")
        out.append("Screen recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")")
        out.append("System audio: not detectable (macOS asks when recording starts)")
        out.append("")

        out.append("## Settings")
        out.append("Language: \(Settings.language ?? "auto") · speech model \(Engine.modelID(for: Settings.language))")
        out.append("Meeting mode: \(Settings.meetingMode)")
        out.append("Echo cancellation: \(Settings.echoCancellation) · Respect mute: \(Settings.respectMute) · Follow meeting language: \(Settings.followMeetingLanguage)")
        out.append("Speaker detection: \(Settings.diarizeMeetings) · Name from captions: \(Settings.autoNameSpeakers) · Auto captions: \(Settings.autoEnableCaptions)")
        out.append("Room vocabulary: \(Settings.roomVocabulary) · Caption spelling: \(Settings.captionSpelling) · Polish after meeting: \(Settings.polishAfterMeeting)")
        out.append("Compress recordings: \(Settings.compressRecordings) · Keep recordings: \(AudioRetention.label(Settings.keepAudioDays))")
        out.append("Custom vocabulary: \(Settings.vocabulary.count) words · Debug log: \(LiveDebug.enabled ? "on" : "off")")
        out.append("")

        out.append("## Last meeting's warnings")
        out.append(contentsOf: warnings.isEmpty ? ["None"] : warnings.map { "- " + $0 })
        out.append("")

        let log = debugLog()
        out.append("## live-debug.log (\(log.isEmpty ? "not found" : "last \(log.count) lines, only technical words kept"))")
        out.append(contentsOf: log)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Mac

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func freeDisk() -> Int64? {
        let v = try? Paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    // MARK: Core Audio

    /// "Bluetooth headphones · 48000 Hz · Bluetooth". Not the device's name: it often carries its owner's ("Ana's AirPods").
    private static func device(_ selector: AudioObjectPropertySelector) -> String {
        var id = AudioDeviceID(0)
        guard get(AudioObjectID(kAudioObjectSystemObject), selector, &id), id != kAudioObjectUnknown else { return "none" }
        var rate = Float64(0)
        var transport = UInt32(0)
        let known = get(id, kAudioDevicePropertyTransportType, &transport)
        let parts = [known ? kind(transport, input: selector == kAudioHardwarePropertyDefaultInputDevice) : "unknown kind",
                     get(id, kAudioDevicePropertyNominalSampleRate, &rate) ? "\(Int(rate)) Hz" : nil,
                     known ? transportName(transport) : nil]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func kind(_ t: UInt32, input: Bool) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: input ? "built-in microphone" : "built-in speakers"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: input ? "Bluetooth headset" : "Bluetooth headphones"
        case kAudioDeviceTransportTypeUSB: "USB device"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay device"
        case kAudioDeviceTransportTypeAggregate: "aggregate device"
        case kAudioDeviceTransportTypeVirtual: "virtual device"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "iPhone (Continuity)"
        default: "other device"
        }
    }

    private static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func transportName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypePCI: "PCI"
        case kAudioDeviceTransportTypeFireWire: "FireWire"
        case kAudioDeviceTransportTypeContinuityCaptureWired: "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: "Continuity (wireless)"
        default: "other"
        }
    }

    // MARK: Permissions

    private static func micStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    private static func calendarStatus() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "full access"
        case .writeOnly: "write only"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }

    // MARK: Debug log

    /// Tags whose lines are kept (tag and message only), plus error lines of other tags.
    static let keptTags: Set<String> = ["tap", "audio", "captions", "prejoin", "speakers", "diarize", "vocab", "meet", "engine"]
    /// Tags whose lines are made of transcript words: never kept, not even as errors.
    static let textTags: Set<String> = ["app", "mic", "echo", "whisper"]

    /// The only words a kept line keeps, from Earshot's own log messages; every other word becomes "…".
    static let vocabulary: Set<String> = Set(("""
        a after again an and app asking at audio auto axbutton axcheckbox axmenuitem axswitch axtogglebutton bypassed call
        caption captions channel channels cluster clusters compress compressed confirm decoded device diarize diarized
        dropped en end ended rescored replacement replacements respelled endpoint energy engine error errors es failed fallback false final format frames from
        has health hz in incall input join joined kb khz language left live load loaded lost m mb me meet meeting mic
        missing model ms muted named nil no nodes none not of off ok on or others output page parakeet passes pending
        phase prejoin prev pressed prewarm reading reason record restart restarted room s samples screen self shown
        skipped speaker speakers start started stay stopped stopping stretch switch tap terms text tiles timeout to
        track true unexpected unknown unloaded unmuted unused vocab voice voices wav whisper win words
        nscocoaerrordomain nsosstatuserrordomain com apple coreaudio avfaudio
        """.split(whereSeparator: \.isWhitespace).map(String.init)) + LanguageMenu.languages.map(\.0))

    /// The last 200 kept lines of live-debug.log.
    static func debugLog(limit: Int = 200) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: LiveDebug.url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { filter(String($0)) }
        return Array(kept.suffix(limit))
    }

    /// "[tag] message" with the message sanitized; nil for lines that aren't kept.
    static func filter(_ line: String) -> String? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let tag = String(line[line.index(after: line.startIndex)..<close]).lowercased()
        let message = String(line[line.index(after: close)...])
        if textTags.contains(tag) || (!keptTags.contains(tag) && message.contains("words=")) { return nil }
        let isError = message.range(of: #"error|fail"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard keptTags.contains(tag) || isError else { return nil }
        let clean = sanitize(message.replacingOccurrences(of: #"text=.*$"#, with: "text=…", options: .regularExpression))
        let out = "[\(keptTags.contains(tag) ? tag : sanitize(tag))]" + clean
        return out.count > 200 ? String(out.prefix(200)) + "…" : out
    }

    /// Every run of letters not in `vocabulary` becomes "…" (runs next to each other, one "…"); numbers, units and
    /// punctuation stay. Doesn't rely on quotes: "O'Brien" or a caption without them is removed all the same.
    static func sanitize(_ s: String) -> String {
        var out = "", run = ""
        func flush() {
            guard !run.isEmpty else { return }
            out += vocabulary.contains(run.lowercased()) ? run : "…"
            run = ""
        }
        // Anything outside ASCII but the log's own arrows and dots counts as a letter (emoji in a name, ’), and so does
        // an apostrophe inside a word ("Pat's").
        func wordy(_ c: Character) -> Bool { c.isLetter || (!c.isASCII && !"→…·–—".contains(c)) }
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if wordy(ch) || (ch == "'" && !run.isEmpty && i + 1 < chars.count && wordy(chars[i + 1])) { run.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out.replacingOccurrences(of: #"…(?:[ '.\-]*…)+"#, with: "…", options: .regularExpression)
    }
}
