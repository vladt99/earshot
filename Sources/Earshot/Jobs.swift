import Foundation

struct Job: Codable, Sendable {
    var id: String
    /// queued, running, done, failed
    var status: String
    var title: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var saved: Bool
    var error: String?
    var transcript: Transcript?
}

struct JobRequest: Codable, Sendable {
    var file: URL
    var title: String
    var origin: String
    var options: TranscribeOptions
    var save = true
    /// Delete `file` when done (uploads, temp exports).
    var deleteFileAfter = false
    /// Recorded in history as the source; nil for uploads.
    var sourcePath: String?
    /// Runs before other queued jobs (dictation); never preempts the running one.
    var urgent = false
}

/// Serial transcription queue. Everything (API, UI, dictation) goes through here so the
/// speech models never run two transcriptions at once. Pending jobs survive a quit (jobs.json).
actor Jobs {
    static let shared = Jobs()

    private struct Pending: Codable {
        var id: String
        var createdAt: Date
        var request: JobRequest
    }

    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Queued or running requests, persisted until they finish.
    private var requests: [String: JobRequest] = [:]
    /// Queued ids in run order (urgent first).
    private var queue: [String] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var busy = false

    private static var file: URL { Paths.support.appendingPathComponent("jobs.json") }

    func submit(_ req: JobRequest) -> Job {
        enqueue(req, id: UUID().uuidString.lowercased(), createdAt: Date())
    }

    private func enqueue(_ req: JobRequest, id: String, createdAt: Date) -> Job {
        let job = Job(id: id, status: "queued", title: req.title, createdAt: createdAt, saved: req.save)
        jobs[id] = job
        order.append(id)
        requests[id] = req
        if req.urgent, let i = queue.firstIndex(where: { requests[$0]?.urgent != true }) { queue.insert(id, at: i) } else { queue.append(id) }
        trim()
        tasks[id] = Task {
            await self.turn(id)
            await self.run(id, req)
            self.finished(id)
        }
        persist()
        Task { await self.publishCounts() }
        return job
    }

    /// Submit and wait for the result.
    func run(_ req: JobRequest) async -> Job {
        let job = submit(req)
        return await wait(job.id) ?? job
    }

    func wait(_ id: String) async -> Job? {
        await tasks[id]?.value
        return jobs[id]
    }

    func get(_ id: String) -> Job? { jobs[id] }

    func all() -> [Job] { order.reversed().compactMap { jobs[$0] } }

    var activeCount: Int { jobs.values.filter { $0.status == "queued" || $0.status == "running" }.count }

    // MARK: Scheduling

    private func turn(_ id: String) async {
        await withCheckedContinuation { gates[id] = $0; dispatch() }
    }

    /// Starts the head of the queue once its task is waiting and nothing else runs.
    private func dispatch() {
        guard !busy, let next = queue.first, let gate = gates.removeValue(forKey: next) else { return }
        busy = true
        queue.removeFirst()
        gate.resume()
    }

    private func finished(_ id: String) {
        busy = false
        requests[id] = nil
        tasks[id] = nil
        persist()
        dispatch()
    }

    private func run(_ id: String, _ req: JobRequest) async {
        jobs[id]?.status = "running"
        jobs[id]?.startedAt = Date()
        await publishCounts()
        defer {
            if req.deleteFileAfter { try? FileManager.default.removeItem(at: req.file) }
        }
        let started = Date()
        do {
            let out = try await Engine.shared.transcribe(file: req.file, options: req.options)
            let raw = Transcript(
                id: id,
                createdAt: Date(),
                title: req.title,
                sourcePath: req.sourcePath,
                origin: req.origin,
                model: out.model,
                language: out.language,
                duration: out.duration,
                processingSeconds: Date().timeIntervalSince(started),
                text: out.text,
                segments: out.segments
            )
            let transcript = PostProcess.apply(raw)
            if req.save {
                guard Store.shared.insert(transcript) else { throw APIError(500, "Could not save “\(req.title)” to the library") }
                PostProcess.finished(transcript)
                await MainActor.run { AppState.shared.didSave(transcript) }
            }
            jobs[id]?.transcript = transcript
            jobs[id]?.status = "done"
            EventBus.shared.publish("job.done", ["job_id": id, "transcript_id": transcript.id, "title": transcript.title,
                                                 "origin": transcript.origin, "saved": req.save])
        } catch let e as APIError {
            jobs[id]?.status = "failed"
            jobs[id]?.error = e.message
        } catch {
            jobs[id]?.status = "failed"
            jobs[id]?.error = error.localizedDescription
        }
        jobs[id]?.finishedAt = Date()
        Task { await self.publishCounts() }
        if let err = jobs[id]?.error {
            EventBus.shared.publish("job.failed", ["job_id": id, "title": req.title, "error": err])
            await MainActor.run { AppState.shared.lastError = err }
        }
    }

    // MARK: Persistence

    private func persist() {
        let pending = order.compactMap { id in requests[id].map { Pending(id: id, createdAt: jobs[id]?.createdAt ?? Date(), request: $0) } }
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: Self.file)
        } else if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: Self.file, options: .atomic)
        }
    }

    /// At launch: re-queue jobs that were pending at quit (same ids), fail the ones that can't resume, and remove
    /// leftover uploads.
    func restore() {
        let fm = FileManager.default
        let pending = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? []
        var keep: Set<String> = []
        for p in pending where jobs[p.id] == nil {
            let exists = fm.fileExists(atPath: p.request.file.path)
            if let saved = Store.shared.get(p.id) {
                if p.request.deleteFileAfter { try? fm.removeItem(at: p.request.file) }
                record(p, status: "done", transcript: saved)
            } else if p.request.save, exists {
                keep.insert(p.request.file.standardizedFileURL.path)
                _ = enqueue(p.request, id: p.id, createdAt: p.createdAt)
            } else {
                if p.request.deleteFileAfter, exists { try? fm.removeItem(at: p.request.file) }
                record(p, status: "failed", error: exists ? "Earshot quit before this job finished" : "The file is no longer available")
            }
        }
        persist()
        let stale = Date().addingTimeInterval(-3600)
        for u in (try? fm.contentsOfDirectory(at: Paths.uploads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where !keep.contains(u.standardizedFileURL.path) && ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < stale {
            try? fm.removeItem(at: u)
        }
        Task { await self.publishCounts() }
    }

    private func record(_ p: Pending, status: String, error: String? = nil, transcript: Transcript? = nil) {
        jobs[p.id] = Job(id: p.id, status: status, title: p.request.title, createdAt: p.createdAt, finishedAt: Date(),
                         saved: p.request.save, error: error, transcript: transcript)
        order.append(p.id)
    }

    /// Keep the in-memory job list bounded; finished transcripts live on in the Store.
    private func trim() {
        while order.count > 200, let first = order.first, tasks[first] == nil {
            order.removeFirst()
            jobs[first] = nil
        }
    }

    private func publishCounts() async {
        let n = activeCount
        let list = Array(all().prefix(100))
        await MainActor.run {
            AppState.shared.activeJobs = n
            AppState.shared.jobs = list
        }
    }
}
