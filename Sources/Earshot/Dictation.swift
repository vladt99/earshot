import AppKit
import AVFoundation

/// Push-to-talk style recording from the default microphone, then transcription through `Jobs`.
@MainActor
enum Dictation {
    private static var recorder: AVAudioRecorder?
    private static var file: URL?
    /// Set before the first await, so a second toggle while the permission prompt is up can't start another recorder.
    private static var starting = false
    /// Bumped by cancel(); a start still waiting on the prompt sees it and gives up.
    private static var generation = 0

    static var isRecording: Bool { recorder?.isRecording ?? false }

    static func start(kind: String = "dictation") async throws {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        let gen = generation
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw APIError(403, "Microphone access is off — System Settings → Privacy & Security → Microphone")
            }
        default:
            throw APIError(403, "Microphone access is off — System Settings → Privacy & Security → Microphone")
        }
        guard gen == generation, recorder == nil else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Paths.media.appendingPathComponent("dictation_\(f.string(from: Date())).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        guard rec.record() else {
            rec.deleteRecording()
            throw APIError(500, "Could not start recording")
        }
        recorder = rec
        file = url
        AppState.shared.recordingStarted = Date()
        AppState.shared.recordingKind = kind
    }

    /// Stops recording and transcribes. Returns the finished job (transcript inside when done).
    static func stop(options: TranscribeOptions, save: Bool = true, origin: String) async throws -> Job {
        guard let rec = recorder, let url = file else { throw APIError(409, "Not recording") }
        rec.stop()
        recorder = nil
        file = nil
        let kind = AppState.shared.recordingKind ?? "dictation"
        AppState.shared.recordingStarted = nil
        AppState.shared.recordingKind = nil
        // API callers pass origin "api"; the library groups by what was recorded.
        let origin = kind

        let title = "\(kind == "voicememo" ? "Voice Memo" : "Dictation") \(Date().formatted(date: .abbreviated, time: .shortened))"
        var req = JobRequest(file: url, title: title, origin: origin, options: options,
                             save: save, deleteFileAfter: !save, sourcePath: save ? url.path : nil)
        req.urgent = true
        let job = await Jobs.shared.run(req)
        if kind == "dictation", Settings.copyDictationToClipboard, let text = job.transcript?.text, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return job
    }

    static func cancel() {
        generation += 1
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        file = nil
        AppState.shared.recordingStarted = nil
        AppState.shared.recordingKind = nil
    }
}
