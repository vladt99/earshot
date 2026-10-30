import AVFoundation
import Foundation

/// A meeting folder's recordings: others.wav / me.wav while recording, others.m4a / me.m4a once compressed.
enum MeetingAudio {
    static let tracks = ["others", "me"]
    static let bitRate = 32_000
    private static let chunk: AVAudioFrameCount = 65_536

    /// The meeting's track ("others" or "me"): .wav while recording, .m4a once compressed. nil if deleted.
    static func track(_ folder: URL, _ name: String) -> URL? {
        let fm = FileManager.default
        for ext in ["wav", "m4a"] {
            let u = folder.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func hasAudio(_ folder: URL) -> Bool { tracks.contains { track(folder, $0) != nil } }

    /// 16 kHz mono floats from either format.
    static func readMono16k(_ url: URL) -> [Float]? {
        if url.pathExtension.lowercased() == "wav", let s = WAVReader.readMonoPCM16(url) { return s }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let input = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else { return nil }
        let direct = input.sampleRate == SampleSink.rate && input.channelCount == 1 && input.commonFormat == .pcmFormatFloat32
        let converter = direct ? nil : AVAudioConverter(from: input, to: SampleSink.format)
        if !direct, converter == nil { return nil }
        converter?.downmix = true
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * SampleSink.rate / input.sampleRate) + 1024)
        if let converter {
            let cap = AVAudioFrameCount(Double(chunk) * SampleSink.rate / input.sampleRate) + 1024
            guard let dst = AVAudioPCMBuffer(pcmFormat: SampleSink.format, frameCapacity: cap) else { return nil }
            var done = false
            while true {
                var error: NSError?
                let status = converter.convert(to: dst, error: &error) { _, st in
                    if done { st.pointee = .endOfStream; return nil }
                    do { try file.read(into: buf, frameCount: chunk) } catch { done = true; st.pointee = .endOfStream; return nil }
                    if buf.frameLength == 0 { done = true; st.pointee = .endOfStream; return nil }
                    st.pointee = .haveData
                    return buf
                }
                if let ch = dst.floatChannelData?[0], dst.frameLength > 0 { out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(dst.frameLength))) }
                if status == .error || error != nil { return out.isEmpty ? nil : out }
                if status == .endOfStream || (done && dst.frameLength == 0) { break }
            }
        } else {
            while file.framePosition < file.length {
                guard (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData?[0] else { break }
                out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
            }
        }
        return out
    }

    /// Resolves and reads a track; retried once, since compression may swap the WAV for the m4a meanwhile.
    static func load(_ folder: URL, _ name: String) -> [Float]? {
        for _ in 0..<2 {
            guard let url = track(folder, name) else { return nil }
            if let s = readMono16k(url) { return s }
        }
        return nil
    }

    // MARK: Compression

    private static let busy = Busy()

    private final class Busy: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: Set<String> = []
        func claim(_ f: URL) -> Bool { lock.withLock { folders.insert(f.standardizedFileURL.path).inserted } }
        func release(_ f: URL) { _ = lock.withLock { folders.remove(f.standardizedFileURL.path) } }
    }

    struct CompressError: LocalizedError {
        var errorDescription: String?
    }

    /// WAV → AAC .m4a (mono 16 kHz, ~32 kbps), verified, then the WAV is removed. Idempotent.
    static func compress(folder: URL) async throws {
        guard busy.claim(folder) else { return }
        defer { busy.release(folder) }
        // Recording, saving or being polished: the folder's audio is in use (the final transcript compresses it).
        let id = MeetingManifest.read(folder)?.id
        if await MainActor.run(body: { MeetingController.shared.owns(folder) || id.map(AppState.shared.polishing.contains) == true }) { return }
        try await Task.detached(priority: .background) {
            for name in tracks { try compressTrack(folder, name) }
        }.value
    }

    /// After the final transcript: compress in the background when the setting is on.
    static func compressLater(_ folder: URL) {
        guard Settings.compressRecordings, folder.standardizedFileURL.path.hasPrefix(Paths.meetings.standardizedFileURL.path) else { return }
        Task.detached(priority: .background) {
            // The folder is named after the meeting: only its date goes in the log, and errors by code (they name paths).
            let when = String(folder.lastPathComponent.prefix(19))
            do {
                let before = size(folder)
                try await compress(folder: folder)
                LiveDebug.log("[audio] compressed \(when): \(before / 1024) KB → \(size(folder) / 1024) KB")
            } catch {
                let reason = (error as? CompressError)?.errorDescription ?? "\((error as NSError).domain) \((error as NSError).code)"
                LiveDebug.log("[audio] compress \(when) failed: \(reason)")
            }
        }
    }

    static func size(_ folder: URL) -> Int {
        tracks.compactMap { track(folder, $0) }.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private static func compressTrack(_ folder: URL, _ name: String) throws {
        let fm = FileManager.default
        let wav = folder.appendingPathComponent("\(name).wav"), m4a = folder.appendingPathComponent("\(name).m4a")
        let part = folder.appendingPathComponent("\(name).part.m4a")
        guard fm.fileExists(atPath: wav.path) else { return }
        try? fm.removeItem(at: part)
        defer { try? fm.removeItem(at: part) }
        let source = try AVAudioFile(forReading: wav)
        guard source.length > 0 else {
            // Nothing recorded on this track: no m4a to make.
            try fm.removeItem(at: wav)
            return
        }
        let (frames, energy) = try encode(source, to: part)
        let (outFrames, outEnergy) = try measure(part)
        let rate = source.processingFormat.sampleRate
        guard abs(Double(outFrames) * rate / SampleSink.rate - Double(frames)) <= 0.05 * rate else {
            throw CompressError(errorDescription: "\(name).m4a has \(outFrames) frames for \(frames)")
        }
        // AAC keeps the loudness: a silent or garbled encode differs by far more than this.
        guard energy < 1e-7 || (outEnergy / energy > 0.5 && outEnergy / energy < 2) else {
            throw CompressError(errorDescription: "\(name).m4a energy \(outEnergy) for \(energy)")
        }
        if fm.fileExists(atPath: m4a.path) { _ = try fm.replaceItemAt(m4a, withItemAt: part) } else { try fm.moveItem(at: part, to: m4a) }
        try fm.removeItem(at: wav)
    }

    /// Mean square of the source, and its frame count.
    private static func encode(_ source: AVAudioFile, to url: URL) throws -> (Int64, Double) {
        let format = source.processingFormat
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: SampleSink.rate, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: bitRate, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard format.channelCount == 1, format.sampleRate == SampleSink.rate,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CompressError(errorDescription: "Unexpected track format \(format)")
        }
        var out: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: false)
        var frames: Int64 = 0, sum = 0.0
        while source.framePosition < source.length {
            try source.read(into: buf, frameCount: chunk)
            guard buf.frameLength > 0 else { break }
            sum += meanSquare(buf) * Double(buf.frameLength)
            frames += Int64(buf.frameLength)
            try out?.write(from: buf)
        }
        out = nil
        return (frames, frames > 0 ? sum / Double(frames) : 0)
    }

    private static func measure(_ url: URL) throws -> (Int64, Double) {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return (0, 0) }
        var frames: Int64 = 0, sum = 0.0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            guard buf.frameLength > 0 else { break }
            sum += meanSquare(buf) * Double(buf.frameLength)
            frames += Int64(buf.frameLength)
        }
        return (frames, frames > 0 ? sum / Double(frames) : 0)
    }

    private static func meanSquare(_ b: AVAudioPCMBuffer) -> Double {
        let n = Int(b.frameLength)
        guard n > 0 else { return 0 }
        if let f = b.floatChannelData?[0] {
            var s = 0.0
            for i in 0..<n { s += Double(f[i] * f[i]) }
            return s / Double(n)
        }
        if let p = b.int16ChannelData?[0] {
            var s = 0.0
            for i in 0..<n { let v = Double(p[i]) / 32768; s += v * v }
            return s / Double(n)
        }
        return 0
    }

    /// Removes the audio files and keeps meeting.json, context.json and the transcript.
    static func deleteAudio(folder: URL) throws {
        let fm = FileManager.default
        for name in tracks {
            for ext in ["wav", "m4a", "part.m4a"] {
                let u = folder.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
            }
        }
    }
}
