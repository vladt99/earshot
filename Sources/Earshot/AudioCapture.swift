import AppKit
import AVFoundation
import Accelerate
import FluidAudio
import CoreAudio
import Foundation
import os

// MARK: - Core Audio helpers

enum CA {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var out = value
        let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? out : value
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of _: T.Type) -> [T] {
        var addr = address(selector)
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

    static var defaultOutputDevice: AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
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

    private let lock = NSLock()
    private var samples: [Float] = []
    /// Absolute sample index of samples[0].
    private var origin = 0
    private var file: AVAudioFile?
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        file = try? AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var peak: Float = 0
        vDSP_maxmgv(ch, 1, &peak, vDSP_Length(buffer.frameLength))
        let now = Date()
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        try? file?.write(from: buffer)
        lastData = now
        if peak > soundThreshold { lastSound = now }
        lock.unlock()
    }

    /// Peak level that counts as "something audible" for the no-audio watchdog.
    var soundThreshold: Float = 0.003
    private var lastData = Date()
    private var lastSound = Date()

    /// Seconds since any buffer arrived (capture stalled) and since an audible one did.
    var secondsSinceData: Double { lock.withLock { Date().timeIntervalSince(lastData) } }
    var secondsSinceSound: Double { lock.withLock { Date().timeIntervalSince(lastSound) } }

    func append(samples: [Float]) {
        guard !samples.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        append(buf)
    }

    /// Frame-exact silence for a capture gap, so both tracks stay aligned in time.
    func appendSilence(frames: Int) {
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        silence.frameLength = AVAudioFrameCount(frames)
        silence.floatChannelData?[0].update(repeating: 0, count: frames)
        append(silence)
    }

    /// Total samples received since start.
    var total: Int { lock.withLock { origin + samples.count } }

    /// Samples from absolute index `from` to now.
    func read(from: Int) -> [Float] {
        lock.withLock {
            let start = max(0, from - origin)
            return start < samples.count ? Array(samples[start...]) : []
        }
    }

    /// Forget samples before absolute index `index` (they're confirmed and on disk).
    func discard(before index: Int) {
        lock.withLock {
            let n = min(samples.count, max(0, index - origin))
            samples.removeFirst(n)
            origin += n
        }
    }

    func close() {
        lock.withLock { file = nil }
    }
}

/// Mono float at an arbitrary rate → 16 kHz mono. The converter is rebuilt with the *actual* input rate
/// whenever the device's nominal rate changes.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: SampleSink.format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * SampleSink.rate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: SampleSink.format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
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

/// The processes to tap: the selected apps' PIDs, every audio process
/// whose bundle id starts with "<app id>." (Chrome/Teams helpers), and for Safari its WebKit GPU process.
struct TapProcessResolver: Sendable {
    let bundleIDs: [String]

    func resolveProcessObjectIDs() -> Set<AudioObjectID> {
        let pids = Set(bundleIDs.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)
        })
        var ids = Set<AudioObjectID>()
        for p in AudioProcess.all() {
            if pids.contains(p.pid) || bundleIDs.contains(p.bundleID)
                || bundleIDs.contains(where: { p.bundleID.hasPrefix($0 + ".") })
                || (bundleIDs.contains("com.apple.Safari") && p.bundleID == "com.apple.WebKit.GPU") {
                ids.insert(p.object)
            }
        }
        return ids
    }
}

// MARK: - App audio (Core Audio process tap)

/// Captures what an app plays (the other participants):
/// CATapDescription(stereoMixdownOfProcesses:) – unmuted, private – on a private aggregate device whose main
/// sub-device is the system output, tap "drift" on, "tapautostart" off; a C IO proc writes into a ring buffer
/// that a separate queue drains; the process list is re-targeted in place on every
/// kAudioHardwarePropertyProcessObjectList change (100 ms debounce). With no matching process yet,
/// the tap starts empty and records silence until the app makes sound.
final class ProcessTapCapture: @unchecked Sendable {
    enum Mode: Sendable { case apps([String]), allSystemAudio, monoAllSystemAudio }

    let mode: Mode
    private let onAudio: (AVAudioPCMBuffer) -> Void
    private let gapFiller: GapFiller?
    private let queue = DispatchQueue(label: "earshot.tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var currentProcesses: Set<AudioObjectID> = []
    private var pendingUpdate: DispatchWorkItem?
    private var consecutiveFailures = 0
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var drainTimer: DispatchSourceTimer?
    fileprivate let ring = MonoRing(capacity: 48_000 * 10)
    fileprivate var expectedBuffers = 1
    fileprivate var channels = 2
    fileprivate var interleaved = true
    private var sampleRate: Double = 48_000
    private let resampler = Resampler()

    init(mode: Mode, gapFiller: GapFiller? = nil, onAudio: @escaping (AVAudioPCMBuffer) -> Void) {
        self.mode = mode
        self.gapFiller = gapFiller
        self.onAudio = onAudio
    }

    convenience init(mode: Mode, sink: SampleSink, gapFiller: GapFiller? = nil) {
        self.init(mode: mode, gapFiller: gapFiller) { sink.append($0) }
        self.silenceSink = sink
    }

    private var silenceSink: SampleSink?

    func start() throws {
        try queue.sync {
            try build()
            watchOutputDevice()
        }
    }

    func stop() {
        queue.sync {
            unwatchOutputDevice()
            teardown()
        }
    }

    /// Tear the tap down and build it again (watchdog: no buffers are arriving any more).
    func restart() {
        queue.async { [weak self] in self?.rebuild() }
    }

    private var outputListener: AudioObjectPropertyListenerBlock?

    /// The aggregate device is clocked by the default output device. When that changes (AirPods connect,
    /// a display with speakers is plugged in) the old aggregate goes quiet, so rebuild it on the new device.
    private func watchOutputDevice() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.outputListener != nil else { return }
            self.rebuild()
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        outputListener = block
    }

    private func unwatchOutputDevice() {
        guard let block = outputListener else { return }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        outputListener = nil
    }

    /// Runs on `queue`. The new device's sample clock starts over, so the gap filler must not bridge to it.
    private func rebuild(attempt: Int = 0) {
        guard outputListener != nil else { return }
        teardown()
        gapFiller?.cut()
        do {
            try build()
        } catch where attempt < 5 {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rebuild(attempt: attempt + 1) }
        } catch {}
    }

    private func build() throws {
        let d: CATapDescription
        switch mode {
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
        description = d

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(d, &tap)
        guard status == noErr else {
            throw APIError(403, "Could not create audio tap (\(status)). Allow Earshot under System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        tapID = tap

        var asbd = CA.value(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        channels = max(1, Int(asbd.mChannelsPerFrame))
        interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        expectedBuffers = interleaved ? 1 : channels
        _ = AVAudioFormat(streamDescription: &asbd)

        let outputUID = CA.string(CA.defaultOutputDevice, kAudioDevicePropertyDeviceUID) ?? ""
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

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcID(aggregateID, tapIOProc, Unmanaged.passUnretained(self).toOpaque(), &proc)
        guard status == noErr, let proc else { teardown(); throw APIError(500, "Could not create IO proc (\(status))") }
        procID = proc

        // Nominal sample-rate changes are absorbed by rebuilding the resampler with the actual rate.
        var rateAddr = CA.address(kAudioDevicePropertyNominalSampleRate)
        let rateBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let rate: Float64 = CA.value(self.aggregateID, kAudioDevicePropertyNominalSampleRate, default: 0)
            if rate > 0 { self.sampleRate = rate }
        }
        AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddr, queue, rateBlock)
        rateListener = rateBlock

        if case .apps = mode {
            var listAddr = CA.address(kAudioHardwarePropertyProcessObjectList)
            let listBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRetarget() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, queue, listBlock)
            processListListener = listBlock
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

    /// LiveTapUpdater.scheduleUpdate: cancel the pending update and run it 100 ms after the last change.
    private func scheduleRetarget() {
        pendingUpdate?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.retarget() }
        pendingUpdate = item
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: item)
    }

    /// LiveTapUpdater.performUpdate: same set → nothing; otherwise rewrite the tap's process list in place.
    private func retarget() {
        guard case .apps(let ids) = mode, tapID != kAudioObjectUnknown else { return }
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
        let (frames, silence) = ring.take()
        if silence > 0 {
            let missing = Int(Double(silence) * SampleSink.rate / sampleRate)
            if let sink = silenceSink { sink.appendSilence(frames: missing) }
        }
        guard !frames.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames.count)) else { return }
        buf.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: frames.count) }
        if let out = resampler.convert(buf) { onAudio(out) }
    }

    fileprivate func noteTimestamp(_ time: UnsafePointer<AudioTimeStamp>, frames: Int) {
        guard let gapFiller, time.pointee.mFlags.contains(.sampleTimeValid) else { return }
        let gap = gapFiller.gap(sampleTime: time.pointee.mSampleTime, frames: frames)
        if gap > 0 { ring.addSilence(gap) }
    }

    private func teardown() {
        drainTimer?.cancel()
        drainTimer = nil
        pendingUpdate?.cancel()
        if let block = processListListener {
            var addr = CA.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            processListListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            if let block = rateListener {
                var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, queue, block)
                rateListener = nil
            }
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        drain()
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        currentProcesses = []
    }
}

/// Real-time IO proc (a C function): mixes the tap's channels to mono
/// and pushes them into the ring buffer; no allocation, no Swift closures.
private func tapIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                       _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                       _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                       _ client: UnsafeMutableRawPointer?) -> OSStatus {
    guard let client else { return noErr }
    let tap = Unmanaged<ProcessTapCapture>.fromOpaque(client).takeUnretainedValue()
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    // correctionForBufferLayout: when the output device also exposes input streams the aggregate hands us
    // extra leading buffers; keep only the trailing ones that belong to the tap.
    let drop = max(0, list.count - tap.expectedBuffers)
    let buffers = Array(list.dropFirst(drop))
    guard let first = buffers.first, let data = first.mData else { return noErr }
    if tap.interleaved {
        let ch = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
        tap.noteTimestamp(inputTime, frames: frames)
        tap.ring.writeMixed(data.assumingMemoryBound(to: Float.self), frames: frames, channels: ch, stride: ch)
    } else {
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        tap.noteTimestamp(inputTime, frames: frames)
        let ptrs = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
        tap.ring.writePlanar(ptrs, frames: frames)
    }
    return noErr
}

/// Single-producer/single-consumer mono float ring guarded by an unfair lock (held for a memcpy only).
final class MonoRing: @unchecked Sendable {
    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var head = 0, count = 0, pendingSilence = 0
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    func writeMixed(_ p: UnsafePointer<Float>, frames: Int, channels: Int, stride: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let scale = 1 / Float(channels)
        for f in 0..<frames {
            var v: Float = 0
            for c in 0..<channels { v += p[f * stride + c] }
            push(v * scale)
        }
    }

    func writePlanar(_ ptrs: [UnsafeMutablePointer<Float>], frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let scale = 1 / Float(max(1, ptrs.count))
        for f in 0..<frames {
            var v: Float = 0
            for p in ptrs { v += p[f] }
            push(v * scale)
        }
    }

    func addSilence(_ frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        // Flush order: silence belongs before the frames that follow; the consumer handles it first.
        pendingSilence += frames
    }

    private func push(_ v: Float) {
        storage[(head + count) % capacity] = v
        if count < capacity { count += 1 } else { head = (head + 1) % capacity }
    }

    /// Up to `max` of the oldest frames (used for the echo-cancellation reference).
    func take(max n: Int) -> ([Float], Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let k = min(n, count)
        var out = [Float](repeating: 0, count: k)
        for i in 0..<k { out[i] = storage[(head + i) % capacity] }
        head = (head + k) % capacity
        count -= k
        return (out, 0)
    }

    /// Returns buffered frames and the silence (in source frames) that precedes them.
    func take() -> ([Float], Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = storage[(head + i) % capacity] }
        head = 0
        count = 0
        let s = pendingSilence
        pendingSilence = 0
        return (out, s)
    }
}

// MARK: - Microphone

/// Microphone capture. With echo cancellation on, the mic goes through FluidAudio's LocalVQE with a mono tap of
/// everything the Mac plays as the far-end reference, so the other side of the call doesn't leak into your track.
final class MicCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let sink: SampleSink
    private let resampler = Resampler()
    private let gapFiller = GapFiller()
    private var canceller: EchoCanceller?
    private let queue = DispatchQueue(label: "earshot.mic")
    private var configObserver: NSObjectProtocol?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var running = false
    let echoCancellation: Bool

    init(sink: SampleSink, echoCancellation: Bool) {
        self.sink = sink
        self.echoCancellation = echoCancellation
    }

    func start() throws {
        if echoCancellation {
            let c = EchoCanceller(output: sink)
            try c.start()
            canceller = c
        }
        try queue.sync {
            try startEngine()
            running = true
        }
        // A headset plugged in mid-call, or a new default input picked in System Settings: follow it.
        var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restartOnQueue() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        inputListener = block
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
        guard format.sampleRate > 0 else { throw APIError(500, "No microphone available") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.noteInput(buffer)
            if time.isSampleTimeValid {
                let gap = self.gapFiller.gap(sampleTime: Double(time.sampleTime), frames: Int(buffer.frameLength))
                if gap > 0 { self.deliver([Float](repeating: 0, count: Int(Double(gap) * SampleSink.rate / format.sampleRate))) }
            }
            guard let converted = self.resampler.convert(buffer), let ch = converted.floatChannelData?[0] else { return }
            self.deliver(Array(UnsafeBufferPointer(start: ch, count: Int(converted.frameLength))))
        }
        engine.prepare()
        try engine.start()
    }

    // Watchdog: raw microphone input, before echo cancellation (which legitimately outputs near-silence).
    private let stats = NSLock()
    private var lastBuffer = Date()
    private var lastInput = Date()

    private func noteInput(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var peak: Float = 0
        vDSP_maxmgv(ch, 1, &peak, vDSP_Length(buffer.frameLength))
        let now = Date()
        stats.withLock {
            lastBuffer = now
            // Any working microphone has a noise floor above this; a muted or dead one sends exact zeros.
            if peak > 0.0002 { lastInput = now }
        }
    }

    var secondsSinceBuffer: Double { stats.withLock { Date().timeIntervalSince(lastBuffer) } }
    var secondsSinceInput: Double { stats.withLock { Date().timeIntervalSince(lastInput) } }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Watchdog: no samples are arriving any more.
    func restart() { queue.async { [weak self] in self?.restartOnQueue() } }

    private func restartOnQueue(attempt: Int = 0) {
        guard running else { return }
        stopEngine()
        gapFiller.cut()
        do {
            try startEngine()
        } catch where attempt < 5 {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restartOnQueue(attempt: attempt + 1) }
        } catch {}
    }

    private func deliver(_ samples: [Float]) {
        if let canceller { canceller.push(mic: samples) } else { sink.append(samples: samples) }
    }

    /// Mac woke from sleep: don't silence-fill the time it was asleep.
    func cutTimeline() { gapFiller.cut() }

    func stop() {
        if let block = inputListener {
            var addr = CA.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            inputListener = nil
        }
        queue.sync {
            running = false
            if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
            configObserver = nil
            stopEngine()
        }
        canceller?.stop()
        canceller = nil
    }
}

/// LocalVQE (16 ms realtime chunks): mic = near end, system output = far-end reference.
/// If the model can't load, the microphone passes through unchanged.
final class EchoCanceller: @unchecked Sendable {
    private let output: SampleSink
    private let reference = MonoRing(capacity: 16_000 * 10)
    private var tap: ProcessTapCapture?
    private let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    private var worker: Task<Void, Never>?

    init(output: SampleSink) { self.output = output }

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

    func start() throws {
        let ref = reference
        let t = ProcessTapCapture(mode: .monoAllSystemAudio) { buffer in
            guard let ch = buffer.floatChannelData?[0] else { return }
            ref.writePlanar([ch], frames: Int(buffer.frameLength))
        }
        try t.start()
        tap = t
        worker = Task.detached { [output, stream, ref] in
            var vqe: LocalVqeStream?
            do { vqe = try await LocalVqeManager(config: Self.config()).makeStream() } catch { vqe = nil }
            for await mic in stream {
                let (far, _) = ref.take(max: mic.count)
                let reference = far.count < mic.count ? far + [Float](repeating: 0, count: mic.count - far.count) : far
                if let vqe, let clean = try? await vqe.enhance(mic: mic, reference: reference) {
                    output.append(samples: clean)
                } else {
                    output.append(samples: mic)
                }
            }
        }
    }

    func push(mic: [Float]) { continuation.yield(mic) }

    func stop() {
        tap?.stop()
        tap = nil
        continuation.finish()
    }
}
