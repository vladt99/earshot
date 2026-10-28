import AppKit
import AVFoundation

/// Push-to-talk style recording from the default microphone, then transcription through `Jobs`.
@MainActor
enum Dictation {
    private static var recorder: AVAudioRecorder?
    private static var file: URL?

    static var isRecording: Bool { recorder?.isRecording ?? false }

    static func start(kind: String = "dictation") async throws {
        guard !isRecording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw APIError(403, "Microphone access denied") }
        default:
            throw APIError(403, "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone.")
        }
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
        guard rec.record() else { throw APIError(500, "Could not start recording") }
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
        let job = await Jobs.shared.run(JobRequest(file: url, title: title, origin: origin, options: options,
                                                   save: save, deleteFileAfter: !save, sourcePath: save ? url.path : nil))
        if kind == "dictation", Settings.copyDictationToClipboard, let text = job.transcript?.text, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return job
    }

    static func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        file = nil
        AppState.shared.recordingStarted = nil
        AppState.shared.recordingKind = nil
    }
}
