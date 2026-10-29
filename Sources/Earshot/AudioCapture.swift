import AppKit
import AVFoundation
import Accelerate
import FluidAudio
import CoreAudio
import Darwin
import Foundation
import os

private let audioLog = Logger(subsystem: "com.earshot", category: "audio")

// MARK: - Core Audio helpers

enum CA {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var out = value
        let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? out : value
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr, let s = out?.takeRetainedValue() else { return nil }
        return s as String
    }

    /// Where call audio actually plays (not the alerts device).
    static var defaultOutputDevice: AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    /// Headphones, AirPods or a headset: nothing the mic can pick up as echo.
    static func outputIsHeadphones(_ device: AudioObjectID = defaultOutputDevice) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        let transport: UInt32 = value(device, kAudioDevicePropertyTransportType, default: 0)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        let source: UInt32 = value(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: 0)
        if source == 0x6864_706E { return true } // 'hdpn'
        // A USB device with its own microphone is a headset.
        return transport == kAudioDeviceTransportTypeUSB
            && !array(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self).isEmpty
    }

    static let standardRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    static func standardRate(near rate: Double) -> Double {
        standardRates.min { abs($0 - rate) < abs($1 - rate) } ?? rate
    }
}

/// mach_absolute_time arithmetic (the clock of AudioTimeStamp.mHostTime and AVAudioTime.hostTime; it stops during sleep).
enum HostTime {
    private static let secondsPerTick: Double = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return Double(t.numer) / Double(t.denom) / 1e9
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func seconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? Double(b - a) * secondsPerTick : -Double(a - b) * secondsPerTick
    }

    static func offset(_ t: UInt64, seconds s: Double) -> UInt64 {
        let ticks = s / secondsPerTick
        if ticks >= 0 { return t &+ UInt64(ticks) }
        let back = UInt64(-ticks)
        return back < t ? t - back : 0
    }
}

/// Frames a source delivers vs. host-clock time over 10 s windows. Off by more than 10% means the assumed
/// sample rate is wrong (AirPods switch to 16/24 kHz call mode while a format still says 48 kHz).
struct RateCheck {
    private var start: (host: UInt64, index: Int)?

    /// `index`: cumulative frames delivered before the frame stamped `host`. Returns the measured rate on a mismatch.
    mutating func measure(host: UInt64, index: Int, assumed: Double) -> Double? {
        guard host != 0 else { return nil }
        guard let s = start, host >= s.host, index >= s.index else { start = (host, index); return nil }
        guard host > s.host else { return nil }
        let elapsed = HostTime.seconds(from: s.host, to: host)
        guard elapsed >= 10 else { return nil }
        start = (host, index)
        let measured = Double(index - s.index) / elapsed
        return abs(measured - assumed) > assumed * 0.1 ? measured : nil
    }

    mutating func reset() { start = nil }
}

private extension DispatchQueue {
    /// sync, or inline when already on this queue (deinit can run there).
    func syncHere<T>(_ key: DispatchSpecificKey<Void>, _ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: key) != nil ? try body() : try sync(execute: body)
    }
}

/// A process that Core Audio knows about (macOS 14.4+ process objects).
struct AudioProcess: Hashable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    static func all() -> [AudioProcess] {
        CA.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self).map { obj in
            AudioProcess(
                object: obj,
                pid: CA.value(obj, kAudioProcessPropertyPID, default: pid_t(-1)),
                bundleID: CA.string(obj, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: CA.value(obj, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0,
                isRunningOutput: CA.value(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            )
        }
    }

    /// Chrome plays audio from helper processes (com.google.Chrome.helper…), so match by prefix.
    static func matching(prefix: String) -> [AudioProcess] {
        all().filter { $0.bundleID == prefix || $0.bundleID.hasPrefix(prefix + ".") }
    }
}

// MARK: - Sample sink

/// Thread-safe 16 kHz mono float buffer fed by a capture source and drained by the live transcriber.
/// Everything is also written to a WAV file (one file per stream).
final class SampleSink: @unchecked Sendable {
    static let rate: Double = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    /// Drift allowed before the timeline is corrected (100 ms).
    private static let tolerance = 1_600
    /// A longer computed gap is treated as a bogus timestamp and re-anchored instead of filled.
    private static let maxFill = Int(rate * 1_800)

    private let lock = NSLock()
    private var samples: [Float] = []
    /// Absolute sample index of samples[0].
    private var base = 0
    private var file: AVAudioFile?
    private let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)!
    let fileURL: URL

    private var _origin: UInt64?
    /// Wall-clock samples cut from the timeline (sleep).
    private var skew = 0
    private var resyncAt: UInt64?
    private var rateCheck = RateCheck()
    private var received = 0
    private var _onRateMismatch: (@Sendable () -> Void)?

    /// mach_absolute_time of the meeting start, the same on every track. When set, buffers that carry a host time land
    /// at their wall-clock position: leading silence before the first one, real capture gaps (restarts, device switches)
    /// filled with silence, and drift beyond 100 ms corrected by inserting silence or dropping samples.
    var origin: UInt64? {
        get { lock.withLock { _origin } }
        set { lock.withLock { _origin = newValue } }
    }

    /// Called when host-stamped input runs >10% off wall-clock for 10 s (the source's sample rate is wrong).
    var onRateMismatch: (@Sendable () -> Void)? {
        get { lock.withLock { _onRateMismatch } }
        set { lock.withLock { _onRateMismatch = newValue } }
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        file = try? AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// After system sleep: the next buffer fills only the time since this call, never the time asleep.
    func resync() { lock.withLock { resyncAt = HostTime.now } }

    /// `hostTime`: host time of the buffer's first sample (used only when `origin` is set).
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        append(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)), hostTime: hostTime)
    }

    func append(samples: [Float], hostTime: UInt64? = nil) {
        samples.withUnsafeBufferPointer { append($0, hostTime: hostTime) }
    }

    private func append(_ data: UnsafeBufferPointer<Float>, hostTime: UInt64?) {
        guard let p = data.baseAddress, data.count > 0 else { return }
        var peak: Float = 0
        vDSP_maxmgv(p, 1, &peak, vDSP_Length(data.count))
        let now = Date()
        lock.lock()
        var start = 0
        var mismatch: Double?
        if let hostTime {
            mismatch = rateCheck.measure(host: hostTime, index: received, assumed: Self.rate)
            if let origin = _origin {
                let wall = Int((HostTime.seconds(from: origin, to: hostTime) * Self.rate).rounded())
                let written = base + samples.count + pending.count
                var exact = written == 0
                if let wake = resyncAt {
                    resyncAt = nil
                    let awake = max(0, Int((HostTime.seconds(from: wake, to: hostTime) * Self.rate).rounded()))
                    skew = wall - written - min(awake, max(0, wall - skew - written))
                    exact = true
                }
                var diff = wall - skew - written
                if diff > Self.maxFill { skew += diff; diff = 0 }
                if diff > 0, exact || diff > Self.tolerance {
                    if diff > Int(Self.rate / 2) { rateCheck.reset() }
                    writeSilence(diff)
                } else if diff < 0, exact || -diff > Self.tolerance {
                    start = min(data.count, -diff)
                }
            }
        }
        received += data.count
        if start < data.count { write(p + start, count: data.count - start) }
        lastData = now
        if peak > soundThreshold { lastSound = now }
        let callback = mismatch != nil ? _onRateMismatch : nil
        lock.unlock()
        if let mismatch {
            audioLog.error("\(self.fileURL.lastPathComponent, privacy: .public): \(Int(mismatch)) samples/s arriving for a 16000 Hz track; re-reading the source format")
            callback?()
        }
    }

    /// Mic track of a meeting that reports mute: samples wait this long before reaching the buffer and the file,
    /// so muting also blanks the moment before the mute was noticed.
    private var holdback = 0
    private var pending: [Float] = []
    private var muted = false

    func hold(seconds: Double) { lock.withLock { holdback = Int(seconds * Self.rate) } }

    /// Muted: zeros instead of samples from now on, held-back samples included. The timeline keeps its length.
    func gate(muted: Bool) {
        lock.withLock {
            self.muted = muted
            if muted, !pending.isEmpty { vDSP_vclr(&pending, 1, vDSP_Length(pending.count)) }
        }
    }

    private func write(_ p: UnsafePointer<Float>, count: Int) {
        guard holdback > 0 || muted || !pending.isEmpty else { return commit(p, count: count) }
        if muted { pending.append(contentsOf: repeatElement(0, count: count)) }
        else { pending.append(contentsOf: UnsafeBufferPointer(start: p, count: count)) }
        release(keeping: holdback)
    }

    private func release(keeping n: Int) {
        let k = pending.count - n
        guard k > 0 else { return }
        pending.withUnsafeBufferPointer { commit($0.baseAddress!, count: k) }
        pending.removeFirst(k)
    }

    private func commit(_ p: UnsafePointer<Float>, count: Int) {
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
        guard let file, let dst = scratch.floatChannelData?[0] else { return }
        var done = 0
        while done < count {
            let n = min(count - done, Int(scratch.frameCapacity))
            dst.update(from: p + done, count: n)
            scratch.frameLength = AVAudioFrameCount(n)
            try? file.write(from: scratch)
            done += n
        }
    }

    private func writeSilence(_ count: Int) {
        guard holdback == 0, pending.isEmpty else {
            pending.append(contentsOf: repeatElement(0, count: count))
            return release(keeping: holdback)
        }
        samples.append(contentsOf: repeatElement(0, count: count))
        guard let file, let dst = scratch.floatChannelData?[0] else { return }
        dst.update(repeating: 0, count: Int(scratch.frameCapacity))
        var done = 0
        while done < count {
            let n = min(count - done, Int(scratch.frameCapacity))
            scratch.frameLength = AVAudioFrameCount(n)
            try? file.write(from: scratch)
            done += n
        }
    }

    /// Peak level that counts as "something audible" for the no-audio watchdog.
    var soundThreshold: Float = 0.003
    private var lastData = Date()
    private var lastSound = Date()

    /// Seconds since any buffer arrived (capture stalled) and since an audible one did.
    var secondsSinceData: Double { lock.withLock { Date().timeIntervalSince(lastData) } }
    var secondsSinceSound: Double { lock.withLock { Date().timeIntervalSince(lastSound) } }

    /// Frame-exact silence for a capture gap, so both tracks stay aligned in time.
    func appendSilence(frames: Int) {
        guard frames > 0 else { return }
        lock.withLock {
            if frames > Int(Self.rate / 2) { rateCheck.reset() }
            writeSilence(frames)
        }
    }

    /// Total samples received since start.
    var total: Int { lock.withLock { base + samples.count } }

    /// Samples from absolute index `from` to now.
    func read(from: Int) -> [Float] {
        lock.withLock {
            let start = max(0, from - base)
            return start < samples.count ? Array(samples[start...]) : []
        }
    }

    /// Forget samples before absolute index `index` (they're confirmed and on disk).
    func discard(before index: Int) {
        lock.withLock {
            let n = min(samples.count, max(0, index - base))
            samples.removeFirst(n)
            base += n
        }
    }

    func close() {
        lock.withLock {
            release(keeping: 0)
            file = nil
        }
    }
}

/// Any PCM buffer → 16 kHz mono. The converter is rebuilt with the *actual* input format whenever it changes.
/// Formats AVAudioConverter can't downmix (>2 channels without a usable layout) are averaged by hand first.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var manual = false
    private var monoConverter: AVAudioConverter?
    private var monoRate: Double = 0
    private var warned = false
    /// Buffers labelled `from` Hz really carry `to` Hz (a stale device format); relabel before converting.
    var rateOverride: (from: Double, to: Double)?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        var buffer = buffer
        if let o = rateOverride, o.from == buffer.format.sampleRate, let fixed = Self.relabel(buffer, rate: o.to) { buffer = fixed }
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: SampleSink.format)
            converter?.downmix = true
            manual = converter == nil
            if manual { audioLog.notice("No converter for \(buffer.format, privacy: .public); averaging \(buffer.format.channelCount) channels") }
        }
        if !manual, let converter {
            if let out = Self.run(converter, buffer) { return out }
            manual = true
            audioLog.error("Conversion failed for \(buffer.format, privacy: .public); averaging channels instead")
        }
        guard let mono = Self.downmix(buffer) else {
            if !warned { warned = true; audioLog.error("Unsupported capture format \(buffer.format, privacy: .public)") }
            return nil
        }
        if mono.format.sampleRate == SampleSink.rate { return mono }
        if monoRate != mono.format.sampleRate || monoConverter == nil {
            monoRate = mono.format.sampleRate
            monoConverter = AVAudioConverter(from: mono.format, to: SampleSink.format)
        }
        guard let monoConverter else { return nil }
        return Self.run(monoConverter, mono)
    }

    private static func run(_ converter: AVAudioConverter, _ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * SampleSink.rate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: SampleSink.format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return status != .error && error == nil ? out : nil
    }

    /// Average all channels into one float channel at the input rate.
    private static func downmix(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let fmt = buffer.format
        let n = Int(buffer.frameLength), channels = Int(fmt.channelCount)
        guard channels > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        let interleaved = fmt.isInterleaved, stride = buffer.stride, scale = 1 / Float(channels)
        func mix(_ sample: (Int, Int) -> Float) {
            for f in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += sample(c, f) }
                dst[f] = v * scale
            }
        }
        if let p = buffer.floatChannelData {
            mix { c, f in interleaved ? p[0][f * stride + c] : p[c][f] }
        } else if let p = buffer.int16ChannelData {
            mix { c, f in Float(interleaved ? p[0][f * stride + c] : p[c][f]) / 32_768 }
        } else if let p = buffer.int32ChannelData {
            mix { c, f in Float(interleaved ? p[0][f * stride + c] : p[c][f]) / 2_147_483_648 }
        } else {
            return nil
        }
        return out
    }

    private static func relabel(_ buffer: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer? {
        var asbd = buffer.format.streamDescription.pointee
        asbd.mSampleRate = rate
        guard let fmt = AVAudioFormat(streamDescription: &asbd, channelLayout: buffer.format.channelLayout),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            if let s = src[i].mData, let d = dst[i].mData { memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize))) }
        }
        return out
    }
}

/// Timeline keeper shared by both capture sources: fills gaps with exact-length silence based on the
/// hardware sample time, and *cuts* (does not fill) the time the Mac was asleep.
final class GapFiller: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedNext: Double?
    private var resetPending = false

    /// Returns the number of missing frames (at the source rate) before a buffer starting at `sampleTime`.
    func gap(sampleTime: Double, frames: Int) -> Int {
        lock.withLock {
            defer { expectedNext = sampleTime + Double(frames) }
            if resetPending { resetPending = false; return 0 }
            guard let expected = expectedNext else { return 0 }
            let gap = (sampleTime - expected).rounded()
            return gap > 0 && gap < 48_000 * 3600 ? Int(gap) : 0
        }
    }

    /// After sleep: "the paused period is not part of the recording or transcript".
    func cut() { lock.withLock { resetPending = true } }
}

// MARK: - Which processes to tap

/// The processes to tap: the selected apps' PIDs, every audio process whose bundle id starts with "<app id>."
/// (Chrome/Teams/Dia helpers, case-insensitive), processes descended from the app or running from inside its bundle
/// (Chromium renderers and audio services), daemons Core Audio reports without a bundle id matched by executable
/// name (com.apple.avconferenced → /usr/libexec/avconferenced), and for Safari its WebKit GPU process.
struct TapProcessResolver: Sendable {
    let bundleIDs: [String]

    func resolveProcessObjectIDs() -> Set<AudioObjectID> {
        let apps = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        let pids = Set(apps.map(\.processIdentifier))
        let bundlePaths = apps.compactMap { $0.bundleURL?.standardizedFileURL.path }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let ids = bundleIDs.map { $0.lowercased() }
        let names = Set(ids.compactMap { $0.split(separator: ".").last.map(String.init) })
        let safari = ids.contains("com.apple.safari")
        var out = Set<AudioObjectID>()
        for p in AudioProcess.all() {
            let bid = p.bundleID.lowercased()
            let path = Self.path(of: p.pid)
            if pids.contains(p.pid)
                || ids.contains(where: { bid == $0 || bid.hasPrefix($0 + ".") })
                || (safari && bid == "com.apple.webkit.gpu")
                || Self.descends(p.pid, from: pids)
                || (path.map { path in bundlePaths.contains { path.hasPrefix($0) } } ?? false)
                || (bid.isEmpty && path.map { names.contains(($0 as NSString).lastPathComponent.lowercased()) } ?? false) {
                out.insert(p.object)
            }
        }
        return out
    }

    private static func descends(_ pid: pid_t, from ancestors: Set<pid_t>) -> Bool {
        guard !ancestors.isEmpty else { return false }
        var current = pid
        for _ in 0..<8 {
            guard let parent = parent(of: current), parent > 1 else { return false }
            if ancestors.contains(parent) { return true }
            current = parent
        }
        return false
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func path(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

// MARK: - App audio (Core Audio process tap)

/// What the real-time IO proc touches. Retained separately from the capture (released only after the IO proc is
/// destroyed), and immutable apart from the ring, so the HAL thread never sees a freed or half-updated object.
private final class TapIOContext: @unchecked Sendable {
    let ring: MonoRing
    let gapFiller: GapFiller?
    let expectedBuffers: Int
    let interleaved: Bool

    init(ring: MonoRing, gapFiller: GapFiller?, expectedBuffers: Int, interleaved: Bool) {
        self.ring = ring
        self.gapFiller = gapFiller
        self.expectedBuffers = expectedBuffers
        self.interleaved = interleaved
    }

    func noteTimestamp(_ time: UnsafePointer<AudioTimeStamp>, frames: Int) {
        guard let gapFiller, time.pointee.mFlags.contains(.sampleTimeValid) else { return }
        let gap = gapFiller.gap(sampleTime: time.pointee.mSampleTime, frames: frames)
        if gap > 0 { ring.addSilence(gap) }
    }
}

private final class StartWait: @unchecked Sendable {
    let lock = NSLock()
    var error: Error?
    var finished = false
    var abandoned = false
}

/// Captures what an app plays (the other participants):
/// CATapDescription(stereoMixdownOfProcesses:) – unmuted, private – on a private aggregate device whose main
/// sub-device is the default output device, tap "drift" on, "tapautostart" off; a C IO proc writes into a ring buffer
/// that a separate queue drains; the process list is re-targeted in place on every
/// kAudioHardwarePropertyProcessObjectList change (100 ms debounce). With no matching process yet,
/// the tap starts empty and records silence until the app makes sound. If the app's tap stays digitally silent
/// while the app is in a call, it falls back to all system audio.
final class ProcessTapCapture: @unchecked Sendable {
    enum Mode: Sendable { case apps([String]), allSystemAudio, monoAllSystemAudio }

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    let mode: Mode
    private let onAudio: (AVAudioPCMBuffer, UInt64?) -> Void
    private let gapFiller: GapFiller?
    private let queue = DispatchQueue(label: "earshot.tap", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var context: Unmanaged<TapIOContext>?
    private var currentProcesses: Set<AudioObjectID> = []
    private var pendingUpdate: DispatchWorkItem?
    private var pendingRebuild: DispatchWorkItem?
    private var consecutiveFailures = 0
    private var listeners: [Listener] = []
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var drainTimer: DispatchSourceTimer?
    private let ring = MonoRing(capacity: 48_000 * 10)
    private var channels = 2
    private var interleaved = true
    private var sampleRate: Double = 48_000
    /// Rate measured from the IO timestamps after the reported format proved wrong; wins over reported formats.
    private var measuredRate: Double?
    private var rateCheck = RateCheck()
    private let resampler = Resampler()
    private var fellBack = false
    private var heardSound = false
    private var zeroSeconds = 0.0
    private var silenceSink: SampleSink?

    init(mode: Mode, gapFiller: GapFiller? = nil, onAudio: @escaping (AVAudioPCMBuffer, UInt64?) -> Void) {
        self.mode = mode
        self.gapFiller = gapFiller
        self.onAudio = onAudio
        queue.setSpecific(key: queueKey, value: ())
    }

    convenience init(mode: Mode, sink: SampleSink, gapFiller: GapFiller? = nil) {
        self.init(mode: mode, gapFiller: gapFiller) { sink.append($0, hostTime: $1) }
        self.silenceSink = sink
        sink.onRateMismatch = { [weak self] in self?.recheckFormat() }
    }

    deinit { stop() }

    /// Waits at most 3 s: if the system audio permission prompt is still up, returns and the tap starts once it's answered.
    func start() throws {
        let wait = StartWait()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            var failure: Error?
            do { try build() } catch { failure = error }
            let abandoned = wait.lock.withLock { () -> Bool in
                wait.finished = true
                wait.error = failure
                return wait.abandoned
            }
            // A late start keeps following the device, so the watchdog's restart() can still recover it.
            if failure == nil || abandoned { watchOutputDevice() }
            if let failure, abandoned { audioLog.error("Audio tap failed to start: \(failure.localizedDescription, privacy: .public)") }
            done.signal()
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            let pending = wait.lock.withLock { () -> Bool in
                if !wait.finished { wait.abandoned = true }
                return !wait.finished
            }
            if pending {
                audioLog.notice("Audio tap still starting (permission prompt?); continuing in the background")
                return
            }
        }
        if let error = wait.lock.withLock({ wait.error }) { throw error }
    }

    /// Idempotent; safe from any thread, including the tap's own queue.
    func stop() {
        queue.syncHere(queueKey) {
            unwatchOutputDevice()
            pendingRebuild?.cancel()
            pendingRebuild = nil
            teardown()
        }
    }

    /// Tear the tap down and build it again (watchdog: no buffers are arriving any more).
    func restart() {
        queue.async { [weak self] in self?.rebuild() }
    }

    /// Re-read the stream format (a sink saw the wrong number of samples per second).
    func recheckFormat() {
        queue.async { [weak self] in self?.refreshFormat() }
    }

    /// The aggregate device is clocked by the default output device. When that changes (AirPods connect,
    /// a display with speakers is plugged in) the old aggregate goes quiet, so rebuild it on the new device.
    private func watchOutputDevice() {
        guard outputListener == nil else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr else { return }
        outputListener = block
    }

    private func unwatchOutputDevice() {
        guard let block = outputListener else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        outputListener = nil
    }

    private func scheduleRebuild() {
        guard outputListener != nil else { return }
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = item
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    /// Runs on `queue`. The new device's sample clock starts over, so the gap filler must not bridge to it
    /// (with a sink origin set, the sink fills the real gap from host times).
    private func rebuild(attempt: Int = 0) {
        guard outputListener != nil else { return }
        teardown()
        gapFiller?.cut()
        do {
            try build()
        } catch where attempt < 5 {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rebuild(attempt: attempt + 1) }
        } catch {
            audioLog.error("Audio tap rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func build() throws {
        let global = fellBack
        let d: CATapDescription
        switch global ? Mode.allSystemAudio : mode {
        case .apps(let ids):
            currentProcesses = TapProcessResolver(bundleIDs: ids).resolveProcessObjectIDs()
            d = CATapDescription(stereoMixdownOfProcesses: Array(currentProcesses))
        case .allSystemAudio:
            d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .monoAllSystemAudio:
            d = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        d.muteBehavior = .unmuted
        d.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(d, &tap)
        guard status == noErr else {
            throw APIError(403, "System audio recording is off (\(status)) — System Settings → Privacy & Security → Screen & System Audio Recording → allow Earshot.")
        }
        tapID = tap

        let output = CA.defaultOutputDevice
        guard output != kAudioObjectUnknown, let outputUID = CA.string(output, kAudioDevicePropertyDeviceUID) else {
            teardown()
            throw APIError(500, "No audio output device")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Earshot-Tap-" + UUID().uuidString.prefix(8),
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: d.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else { teardown(); throw APIError(500, "Could not create aggregate device (\(status))") }
        aggregateID = agg

        let format = readFormat()
        sampleRate = format.rate
        channels = format.channels
        interleaved = format.interleaved
        measuredRate = nil
        rateCheck.reset()

        let ctx = Unmanaged.passRetained(TapIOContext(ring: ring, gapFiller: gapFiller,
                                                      expectedBuffers: interleaved ? 1 : channels, interleaved: interleaved))
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregateID, tapIOProc, ctx.toOpaque(), &proc)
        guard status == noErr, let proc else {
            ctx.release()
            teardown()
            throw APIError(500, "Could not create IO proc (\(status))")
        }
        procID = proc
        context = ctx

        // AirPods switch between 48 kHz (A2DP) and 16/24 kHz (call mode) under a running aggregate: follow the rate.
        let wildcard = kAudioObjectPropertyScopeWildcard
        listen(aggregateID, kAudioDevicePropertyNominalSampleRate) { $0.refreshFormat() }
        listen(aggregateID, kAudioDevicePropertyStreamConfiguration, scope: wildcard) { $0.refreshFormat() }
        if let stream = format.stream { listen(stream, kAudioStreamPropertyVirtualFormat) { $0.refreshFormat() } }
        listen(output, kAudioDevicePropertyNominalSampleRate) { $0.refreshFormat() }
        listen(tapID, kAudioTapPropertyFormat) { $0.refreshFormat() }
        if case .apps = mode, !global {
            listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) { $0.scheduleRetarget() }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            teardown()
            throw APIError(status == 0x10004003 ? 403 : 500,
                           status == 0x10004003 ? "Timed out starting capture; the system audio permission dialog was not answered."
                                                : "Could not start capture (\(status))")
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ handler: @escaping (ProcessTapCapture) -> Void) {
        guard object != kAudioObjectUnknown else { return }
        var addr = CA.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in if let self { handler(self) } }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr else { return }
        listeners.append(Listener(object: object, address: addr, block: block))
    }

    /// The IO proc receives the aggregate's input stream format, which follows the clock device's nominal rate.
    /// The tap's own format (kAudioTapPropertyFormat) can still say 48 kHz while AirPods run at 24 kHz.
    private func readFormat() -> (rate: Double, channels: Int, interleaved: Bool, stream: AudioObjectID?) {
        let tapFormat = CA.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let streams = CA.array(aggregateID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self)
        let stream = streams.last
        let streamFormat = stream.map { CA.value($0, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription()) }
        let nominal: Float64 = CA.value(aggregateID, kAudioDevicePropertyNominalSampleRate, default: 0)
        let asbd = (streamFormat?.mSampleRate ?? 0) > 0 ? streamFormat! : tapFormat
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : nominal > 0 ? nominal : 48_000
        return (rate, max(1, Int(asbd.mChannelsPerFrame)), asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0, stream)
    }

    private func refreshFormat() {
        guard aggregateID != kAudioObjectUnknown else { return }
        let f = readFormat()
        if f.channels != channels || f.interleaved != interleaved {
            audioLog.notice("Tap stream layout changed (\(f.channels) ch); rebuilding")
            return outputListener != nil ? scheduleRebuild() : ()
        }
        if let measured = measuredRate, abs(f.rate - measured) > measured * 0.1 { return }
        guard f.rate != sampleRate else { return }
        audioLog.notice("Tap sample rate \(Int(self.sampleRate)) → \(Int(f.rate)) Hz")
        drain()
        sampleRate = f.rate
        rateCheck.reset()
    }

    /// The last word on the rate: frames per host-clock second, measured from the IO timestamps.
    private func checkRate(_ stamp: (host: UInt64, index: Int)) {
        guard let measured = rateCheck.measure(host: stamp.host, index: stamp.index, assumed: sampleRate) else { return }
        let reported = readFormat().rate
        let fixed = abs(reported - measured) <= measured * 0.1 ? reported : CA.standardRate(near: measured)
        audioLog.error("Tap delivers \(Int(measured)) frames/s but \(Int(self.sampleRate)) Hz was assumed; using \(Int(fixed)) Hz")
        sampleRate = fixed
        measuredRate = fixed
    }

    /// LiveTapUpdater.scheduleUpdate: cancel the pending update and run it 100 ms after the last change.
    private func scheduleRetarget() {
        pendingUpdate?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.retarget() }
        pendingUpdate = item
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }

    /// LiveTapUpdater.performUpdate: same set → nothing; otherwise rewrite the tap's process list in place.
    private func retarget() {
        guard case .apps(let ids) = mode, !fellBack, tapID != kAudioObjectUnknown else { return }
        let resolved = TapProcessResolver(bundleIDs: ids).resolveProcessObjectIDs()
        guard resolved != currentProcesses else { return }
        var addr = CA.address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
        var current: Unmanaged<CATapDescription>?
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &current) == noErr,
              let d = current?.takeRetainedValue() else { return retryAfterFailure() }
        d.processes = Array(resolved)
        var ref = Unmanaged.passUnretained(d)
        let status = AudioObjectSetPropertyData(tapID, &addr, 0, nil, size, &ref)
        if status == noErr {
            currentProcesses = resolved
            consecutiveFailures = 0
        } else {
            retryAfterFailure()
        }
    }

    private func retryAfterFailure() {
        consecutiveFailures += 1
        if consecutiveFailures < 3 { scheduleRetarget() }
    }

    /// Ring buffer → resample to 16 kHz mono → consumer. Gaps reported by the IO proc become silence.
    private func drain() {
        let chunk = ring.take(rate: sampleRate)
        if chunk.silence > 0 {
            rateCheck.reset()
            if let sink = silenceSink { sink.appendSilence(frames: Int(Double(chunk.silence) * SampleSink.rate / sampleRate)) }
        }
        if let stamp = chunk.stamp { checkRate(stamp) }
        guard !chunk.frames.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk.frames.count)) else { return }
        buf.frameLength = AVAudioFrameCount(chunk.frames.count)
        chunk.frames.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.frames.count) }
        watchForSilence(chunk.frames)
        if let out = resampler.convert(buf) { onAudio(out, chunk.host) }
    }

    /// A tap that has only ever delivered exact zeros for 5 s while the app plays or holds the mic is tapping the wrong
    /// processes (a browser helper we can't see): record all system audio instead.
    private func watchForSilence(_ frames: [Float]) {
        guard case .apps(let ids) = mode, !fellBack, !heardSound else { return }
        var peak: Float = 0
        vDSP_maxmgv(frames, 1, &peak, vDSP_Length(frames.count))
        guard peak == 0 else { heardSound = true; return }
        zeroSeconds += Double(frames.count) / sampleRate
        guard zeroSeconds >= 5 else { return }
        zeroSeconds = 0
        let mine = TapProcessResolver(bundleIDs: ids).resolveProcessObjectIDs()
        guard AudioProcess.all().contains(where: { mine.contains($0.object) && ($0.isRunningOutput || $0.isRunningInput) }) else { return }
        fellBack = true
        let app = ids.joined(separator: ",")
        audioLog.error("Tap for \(app, privacy: .public) delivered only digital silence while the app is in a call; recording all system audio instead")
        EventBus.shared.publish("audio.tap_fallback", ["app": app, "reason": "app tap silent", "mode": "system"])
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            self.gapFiller?.cut()
            do { try self.build() } catch {
                audioLog.error("System-wide fallback tap failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleRebuild()
            }
        }
    }

    private func teardown() {
        drainTimer?.cancel()
        drainTimer = nil
        pendingUpdate?.cancel()
        pendingUpdate = nil
        for var l in listeners { AudioObjectRemovePropertyListenerBlock(l.object, &l.address, queue, l.block) }
        listeners = []
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        // The IO proc is gone; only now may its context go.
        context?.release()
        context = nil
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        drain()
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        currentProcesses = []
    }
}

/// Real-time IO proc (a C function): mixes the tap's channels to mono and pushes them into the ring buffer;
/// no allocation, no Swift closures.
private func tapIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                       _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                       _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                       _ client: UnsafeMutableRawPointer?) -> OSStatus {
    guard let client else { return noErr }
    let ctx = Unmanaged<TapIOContext>.fromOpaque(client).takeUnretainedValue()
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    // correctionForBufferLayout: when the output device also exposes input streams the aggregate hands us
    // extra leading buffers; keep only the trailing ones that belong to the tap.
    let first = max(0, list.count - ctx.expectedBuffers)
    guard first < list.count, let data = list[first].mData else { return noErr }
    let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : 0
    if ctx.interleaved {
        let ch = max(1, Int(list[first].mNumberChannels))
        let frames = Int(list[first].mDataByteSize) / (MemoryLayout<Float>.size * ch)
        ctx.noteTimestamp(inputTime, frames: frames)
        ctx.ring.writeMixed(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch, host: host)
    } else {
        let frames = Int(list[first].mDataByteSize) / MemoryLayout<Float>.size
        ctx.noteTimestamp(inputTime, frames: frames)
        ctx.ring.writePlanar(list, from: first, frames: frames, host: host)
    }
    return noErr
}

/// Single-producer/single-consumer mono float ring guarded by an unfair lock (held for a copy only).
/// Remembers the host time of the latest IO buffer so drained frames can be placed on the wall clock.
final class MonoRing: @unchecked Sendable {
    struct Chunk {
        var frames: [Float]
        /// Source frames of silence that precede `frames`.
        var silence: Int
        /// Host time of frames[0].
        var host: UInt64?
        /// Latest IO buffer's host time and the cumulative frame index it starts at (for rate checks).
        var stamp: (host: UInt64, index: Int)?
    }

    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var head = 0, count = 0, pendingSilence = 0
    private var written = 0
    private var stampHost: UInt64 = 0, stampIndex = 0
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    func writeMixed(_ p: UnsafePointer<Float>, frames: Int, channels: Int, host: UInt64) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        stamp(host)
        let scale = 1 / Float(channels)
        for f in 0..<frames {
            var v: Float = 0
            for c in 0..<channels { v += p[f * channels + c] }
            push(v * scale)
        }
    }

    /// Averages buffers `from..<list.count` (one channel each).
    func writePlanar(_ list: UnsafeMutableAudioBufferListPointer, from first: Int, frames: Int, host: UInt64) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var valid = 0, n = frames
        for c in first..<list.count where list[c].mData != nil {
            valid += 1
            n = min(n, Int(list[c].mDataByteSize) / MemoryLayout<Float>.size)
        }
        guard valid > 0 else { return }
        stamp(host)
        let scale = 1 / Float(valid)
        for f in 0..<n {
            var v: Float = 0
            for c in first..<list.count {
                if let d = list[c].mData { v += d.assumingMemoryBound(to: Float.self)[f] }
            }
            push(v * scale)
        }
    }

    func addSilence(_ frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        // Flush order: silence belongs before the frames that follow; the consumer handles it first.
        pendingSilence += frames
    }

    private func stamp(_ host: UInt64) {
        guard host != 0 else { return }
        stampHost = host
        stampIndex = written
    }

    private func push(_ v: Float) {
        storage[(head + count) % capacity] = v
        if count < capacity { count += 1 } else { head = (head + 1) % capacity }
        written += 1
    }

    /// Buffered frames, the silence that precedes them, and where they sit in host time (`rate`: source rate).
    func take(rate: Double) -> Chunk {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let firstIndex = written - count
        let host: UInt64? = stampHost != 0 && rate > 0 ? HostTime.offset(stampHost, seconds: Double(firstIndex - stampIndex) / rate) : nil
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = storage[(head + i) % capacity] }
        head = 0
        count = 0
        let s = pendingSilence
        pendingSilence = 0
        return Chunk(frames: out, silence: s, host: host, stamp: stampHost != 0 ? (stampHost, stampIndex) : nil)
    }
}

// MARK: - Microphone

/// Microphone capture. With echo cancellation on, the mic goes through FluidAudio's LocalVQE with a mono tap of
/// everything the Mac plays as the far-end reference, so the other side of the call doesn't leak into your track.
final class MicCapture: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private let sink: SampleSink
    private let resampler = Resampler()
    private let gapFiller = GapFiller()
    private var canceller: EchoCanceller?
    private let queue = DispatchQueue(label: "earshot.mic")
    private let queueKey = DispatchSpecificKey<Void>()
    private var configObserver: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var running = false
    let echoCancellation: Bool

    static let deniedMessage = "Microphone access is off — System Settings → Privacy & Security → Microphone"

    init(sink: SampleSink, echoCancellation: Bool) {
        self.sink = sink
        self.echoCancellation = echoCancellation
        queue.setSpecific(key: queueKey, value: ())
        sink.onRateMismatch = { [weak self] in self?.restart() }
    }

    deinit { stop() }

    func start() throws {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        guard permission != .denied, permission != .restricted else { throw APIError(403, Self.deniedMessage) }
        if echoCancellation {
            let c = EchoCanceller(output: sink)
            c.start()
            canceller = c
        }
        do {
            if permission == .notDetermined {
                // Don't hold the main thread across the permission prompt: start once it's answered.
                queue.sync { running = true }
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard let self else { return }
                    self.queue.async {
                        guard self.running else { return }
                        guard granted else { return audioLog.error("\(Self.deniedMessage, privacy: .public)") }
                        self.restartOnQueue()
                    }
                }
            } else {
                try queue.sync {
                    try startEngine()
                    running = true
                }
            }
        } catch {
            canceller?.stop()
            canceller = nil
            throw error
        }
        // A headset plugged in mid-call, or a new default input picked in System Settings: follow it.
        var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restartOnQueue() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            inputListener = block
        }
    }

    /// A fresh engine on the current default input; the old one may still point at a device that is gone.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restartOnQueue() }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(500, "No microphone available") }
        stats.withLock { rateCheck.reset() }
        canceller?.micRestarted()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.process(buffer, time: time)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            throw error
        }
    }

    // Watchdog: raw microphone input, before echo cancellation (which legitimately outputs near-silence).
    private let stats = NSLock()
    private var lastBuffer = Date()
    private var lastInput = Date()
    private var rateCheck = RateCheck()
    private var micFrames = 0
    private var rateMismatches = 0

    /// Runs on the engine's tap thread.
    private func process(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let peak = noteInput(buffer)
        let n = Int(buffer.frameLength)
        let rate = resampler.rateOverride.flatMap { $0.from == buffer.format.sampleRate ? $0.to : nil } ?? buffer.format.sampleRate
        var host: UInt64? = time.isHostTimeValid ? time.hostTime : nil
        var samples: [Float] = []
        var gapped = false
        if time.isSampleTimeValid {
            let gap = gapFiller.gap(sampleTime: Double(time.sampleTime), frames: n)
            if gap > 0 {
                gapped = true
                samples = [Float](repeating: 0, count: Int(Double(gap) * SampleSink.rate / rate))
                host = host.map { HostTime.offset($0, seconds: -Double(gap) / rate) }
            }
        }
        if time.isHostTimeValid { checkRate(host: time.hostTime, frames: n, rate: rate, buffer: buffer, gapped: gapped) }
        if let converted = resampler.convert(buffer), let ch = converted.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(converted.frameLength)))
        }
        guard !samples.isEmpty else { return }
        if let canceller { canceller.push(mic: samples, host: host, rawPeak: peak) } else { sink.append(samples: samples, hostTime: host) }
    }

    /// AirPods' call-mode mic runs at 16/24 kHz; if buffers labelled otherwise arrive, restart, then relabel.
    private func checkRate(host: UInt64, frames: Int, rate: Double, buffer: AVAudioPCMBuffer, gapped: Bool) {
        let result: (measured: Double, count: Int)? = stats.withLock {
            if gapped { rateCheck.reset() }
            defer { micFrames += frames }
            guard let m = rateCheck.measure(host: host, index: micFrames, assumed: rate) else { return nil }
            rateMismatches += 1
            return (m, rateMismatches)
        }
        guard let result else { return }
        if result.count == 1 {
            audioLog.error("Mic delivers \(Int(result.measured)) frames/s labelled \(Int(rate)) Hz; restarting the engine to re-read the format")
            restart()
        } else {
            let actual = CA.standardRate(near: result.measured)
            audioLog.error("Mic still delivers \(Int(result.measured)) frames/s labelled \(Int(rate)) Hz; treating it as \(Int(actual)) Hz")
            resampler.rateOverride = (buffer.format.sampleRate, actual)
        }
    }

    /// Peak over every channel; returns it.
    private func noteInput(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var peak: Float = 0
        if let ch = buffer.floatChannelData {
            let interleaved = buffer.format.isInterleaved
            let planes = interleaved ? 1 : Int(buffer.format.channelCount)
            let length = interleaved ? n * Int(buffer.format.channelCount) : n
            for c in 0..<planes {
                var p: Float = 0
                vDSP_maxmgv(ch[c], 1, &p, vDSP_Length(length))
                peak = max(peak, p)
            }
        } else {
            peak = 1
        }
        let now = Date()
        stats.withLock {
            lastBuffer = now
            // Any working microphone has a noise floor above this; a muted or dead one sends exact zeros.
            if peak > 0.0002 { lastInput = now }
        }
        return peak
    }

    var secondsSinceBuffer: Double { stats.withLock { Date().timeIntervalSince(lastBuffer) } }
    var secondsSinceInput: Double { stats.withLock { Date().timeIntervalSince(lastInput) } }

    private func stopEngine() {
        guard let engine else { return }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine.stop()
    }

    /// Watchdog: no samples are arriving any more.
    func restart() { queue.async { [weak self] in self?.restartOnQueue() } }

    private func restartOnQueue(attempt: Int = 0) {
        guard running else { return }
        stopEngine()
        gapFiller.cut()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            try startEngine()
        } catch where attempt < 5 {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restartOnQueue(attempt: attempt + 1) }
        } catch {
            audioLog.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mac woke from sleep: don't silence-fill the time it was asleep.
    func cutTimeline() { gapFiller.cut() }

    /// Synchronous; returns once the echo canceller has written everything it had (or after a few seconds).
    func stop() {
        if let block = inputListener {
            var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            inputListener = nil
        }
        queue.syncHere(queueKey) {
            running = false
            if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
            configObserver = nil
            stopEngine()
        }
        canceller?.stop()
    }
}

/// 16 kHz far-end reference stamped with host time, so it is paired with the mic by time rather than by sample count.
final class ReferenceRing: @unchecked Sendable {
    /// How far the reference may run ahead of the mic chunk it's paired with (echo arrives after the sound is played).
    static let targetLead = 0.02, maxLead = 0.15
    private static let rate = SampleSink.rate

    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var head = 0, count = 0
    /// Host time of storage[head].
    private var headHost: UInt64?
    private var lastWrite: UInt64 = 0
    private var lock = os_unfair_lock()

    init(seconds: Double) {
        capacity = Int(seconds * Self.rate)
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    func write(_ p: UnsafePointer<Float>, count n: Int, host: UInt64?) {
        guard n > 0 else { return }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        lastWrite = HostTime.now
        if let host { headHost = HostTime.offset(host, seconds: -Double(count) / Self.rate) }
        for i in 0..<n {
            let v = p[i]
            storage[(head + count + i) % capacity] = v.isFinite ? v : 0
        }
        let total = count + n
        if total > capacity {
            let drop = total - capacity
            head = (head + drop) % capacity
            count = capacity
            headHost = headHost.map { HostTime.offset($0, seconds: Double(drop) / Self.rate) }
        } else {
            count = total
        }
    }

    func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0
        count = 0
        headHost = nil
    }

    /// Written to within the last half second.
    var isLive: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return lastWrite != 0 && HostTime.seconds(from: lastWrite, to: HostTime.now) < 0.5
    }

    /// Holds reference audio up to host time `t`.
    func covers(_ t: UInt64) -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard let headHost else { return false }
        return HostTime.offset(headHost, seconds: Double(count) / Self.rate) >= t
    }

    /// `n` reference samples for a mic chunk starting at `micHost`: stale reference is dropped and a reference that
    /// runs too far ahead is delayed with zeros, so the lead stays within 0–150 ms.
    func read(count n: Int, at micHost: UInt64?) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else { return out }
        var pad = 0
        if let micHost, let h = headHost {
            let lead = HostTime.seconds(from: micHost, to: h)
            if lead < 0 || lead > Self.maxLead {
                let shift = Int(((Self.targetLead - lead) * Self.rate).rounded())
                if shift > 0 {
                    let d = min(shift, count)
                    head = (head + d) % capacity
                    count -= d
                    headHost = HostTime.offset(h, seconds: Double(d) / Self.rate)
                } else {
                    pad = min(n, -shift)
                }
            }
        }
        let k = min(n - pad, count)
        for i in 0..<k { out[pad + i] = storage[(head + i) % capacity] }
        head = (head + k) % capacity
        count -= k
        headHost = headHost.map { HostTime.offset($0, seconds: Double(k) / Self.rate) }
        return out
    }
}

/// LocalVQE (16 ms realtime chunks): mic = near end, system output = far-end reference, lined up by host time.
/// The mic passes through unchanged while the model loads, if it fails, when output goes to headphones (no echo),
/// and if the model stops producing sound while the mic clearly has some.
final class EchoCanceller: @unchecked Sendable {
    private struct Chunk: Sendable {
        var mic: [Float]
        var host: UInt64?
        var rawPeak: Float
        var reset = false
    }

    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var vqe: LocalVqeStream?
        var passThrough = true
        var bypassed = false
    }

    /// Audio fed to the model but not yet returned, kept raw so nothing is lost if the model fails.
    private final class Clip {
        let output: SampleSink
        var vqe: LocalVqeStream?
        var raw: [Float] = []
        var host: UInt64?

        init(output: SampleSink) { self.output = output }

        func feed(_ mic: [Float], host chunkHost: UInt64?) {
            if raw.isEmpty { host = chunkHost }
            raw.append(contentsOf: mic)
        }

        func emit(_ clean: [Float]) {
            guard !clean.isEmpty else { return }
            output.append(samples: clean, hostTime: host)
            let m = min(clean.count, raw.count)
            raw.removeFirst(m)
            host = host.map { HostTime.offset($0, seconds: Double(m) / SampleSink.rate) }
        }

        func passRaw() {
            if !raw.isEmpty { output.append(samples: raw, hostTime: host) }
            raw = []
            host = nil
        }

        /// Drain the model's delay line into the sink.
        func flush() async {
            guard let vqe, !raw.isEmpty else { return }
            if let tail = try? await vqe.flush(), tail.allSatisfy(\.isFinite) {
                emit(tail)
            } else {
                try? await vqe.reset()
            }
            passRaw()
        }
    }

    private let output: SampleSink
    private let reference = ReferenceRing(seconds: 4)
    private let queue = DispatchQueue(label: "earshot.echo")
    private let queueKey = DispatchSpecificKey<Void>()
    private var tap: ProcessTapCapture?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .unbounded)
    private var worker: Task<Void, Never>?
    private let shared = Shared()
    private var stopped = false

    init(output: SampleSink) {
        self.output = output
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    static func config() -> LocalVqeConfig {
        var c = LocalVqeConfig.default
        c.chunk = .realtime16ms
        return c
    }

    /// Downloads the model on first launch (20 MB).
    static func prepareModel() async {
        _ = try? await LocalVqeManager(config: config(), progressHandler: Engine.progress(ModelCatalog.echo.id))
        await Engine.finishDownload(ModelCatalog.echo.id)
    }

    /// Never fails: anything that goes wrong leaves the raw microphone recording.
    func start() {
        Task.detached { [shared] in
            do {
                let vqe = try await LocalVqeManager(config: Self.config()).makeStream()
                shared.lock.withLock { shared.vqe = vqe }
            } catch {
                audioLog.error("Echo cancellation model unavailable; recording the raw microphone: \(error.localizedDescription, privacy: .public)")
            }
        }
        queue.sync {
            followOutput()
            var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.followOutput() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
                outputListener = block
            }
        }
        worker = Task.detached { [output, stream, reference, shared] in
            await Self.run(stream: stream, output: output, reference: reference, shared: shared)
        }
    }

    /// Runs on `queue`. Headphones need no echo cancellation; speakers need a reference tap on the output device.
    private func followOutput() {
        guard !stopped else { return }
        let headphones = CA.outputIsHeadphones()
        if headphones {
            tap?.stop()
            tap = nil
            reference.clear()
        } else if tap == nil {
            let ref = reference
            let t = ProcessTapCapture(mode: .monoAllSystemAudio) { buffer, host in
                guard let ch = buffer.floatChannelData?[0] else { return }
                ref.write(ch, count: Int(buffer.frameLength), host: host)
            }
            do {
                try t.start()
                tap = t
            } catch {
                audioLog.error("Echo reference tap failed; recording the raw microphone: \(error.localizedDescription, privacy: .public)")
            }
        }
        let passThrough = headphones || tap == nil
        shared.lock.withLock { shared.passThrough = passThrough }
    }

    func push(mic: [Float], host: UInt64?, rawPeak: Float) { continuation.yield(Chunk(mic: mic, host: host, rawPeak: rawPeak)) }

    /// The mic engine was (re)started: end the model's clip and drop the reference collected for the old one.
    func micRestarted() { continuation.yield(Chunk(mic: [], host: nil, rawPeak: 0, reset: true)) }

    private static func run(stream: AsyncStream<Chunk>, output: SampleSink, reference: ReferenceRing, shared: Shared) async {
        let clip = Clip(output: output)
        var silentWhileLoud = 0.0
        var failures = 0
        for await chunk in stream {
            if chunk.reset {
                await clip.flush()
                reference.clear()
                continue
            }
            let (vqe, skip) = shared.lock.withLock { (shared.vqe, shared.passThrough || shared.bypassed) }
            guard let vqe, !skip else {
                await clip.flush()
                output.append(samples: chunk.mic, hostTime: chunk.host)
                continue
            }
            clip.vqe = vqe
            let n = chunk.mic.count
            // The reference tap drains every 20 ms: give it a moment to catch up with this chunk.
            if let host = chunk.host {
                let end = HostTime.offset(host, seconds: Double(n) / SampleSink.rate + ReferenceRing.targetLead)
                var tries = 0
                while tries < 20, !reference.covers(end), reference.isLive {
                    try? await Task.sleep(for: .milliseconds(10))
                    tries += 1
                }
            }
            let far = reference.read(count: n, at: chunk.host)
            let mic = chunk.mic.map { $0.isFinite ? $0 : 0 }
            clip.feed(mic, host: chunk.host)
            do {
                let clean = try await vqe.enhance(mic: mic, reference: far)
                guard clean.allSatisfy(\.isFinite) else { throw LocalVqeError.modelProcessingFailed("non-finite output") }
                clip.emit(clean)
                failures = 0
                // Exact (sub -120 dB) silence out while the mic has sound in: the canceller is broken here.
                if chunk.rawPeak > 0.0002, !clean.isEmpty {
                    var peak: Float = 0
                    vDSP_maxmgv(clean, 1, &peak, vDSP_Length(clean.count))
                    silentWhileLoud = peak < 1e-6 ? silentWhileLoud + Double(n) / SampleSink.rate : 0
                    if silentWhileLoud >= 3 {
                        shared.lock.withLock { shared.bypassed = true }
                        audioLog.error("Echo cancellation produced only silence for 3 s of live mic input; recording the raw microphone")
                        EventBus.shared.publish("audio.echo_cancellation_bypassed", ["reason": "silent output"])
                        await clip.flush()
                    }
                }
            } catch {
                try? await vqe.reset()
                clip.passRaw()
                failures += 1
                if failures == 1 { audioLog.error("Echo cancellation failed, passing the mic through: \(error.localizedDescription, privacy: .public)") }
                if failures >= 20 { shared.lock.withLock { shared.bypassed = true } }
            }
        }
        await clip.flush()
    }

    /// Synchronous: stops the reference tap, then waits (up to 4 s) for queued mic audio and the model's tail to reach the sink.
    func stop() {
        let alreadyStopped = queue.syncHere(queueKey) { () -> Bool in
            let was = stopped
            stopped = true
            if let block = outputListener {
                var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
                outputListener = nil
            }
            tap?.stop()
            tap = nil
            return was
        }
        continuation.finish()
        guard !alreadyStopped, let worker else { return }
        self.worker = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await worker.value
            done.signal()
        }
        if done.wait(timeout: .now() + 4) == .timedOut {
            audioLog.error("Echo canceller did not drain within 4 s; the end of me.wav may be short")
        }
    }
}
