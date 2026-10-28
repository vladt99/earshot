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

struct JobRequest: Sendable {
    var file: URL
    var title: String
    var origin: String
    var options: TranscribeOptions
    var save = true
    /// Delete `file` when done (uploads, temp exports).
    var deleteFileAfter = false
    /// Recorded in history as the source; nil for uploads.
    var sourcePath: String?
}

/// Serial transcription queue. Everything (API, UI, dictation) goes through here so the
/// speech models never run two transcriptions at once.
actor Jobs {
    static let shared = Jobs()

    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?

    func submit(_ req: JobRequest) -> Job {
        let job = Job(id: UUID().uuidString.lowercased(), status: "queued", title: req.title,
                      createdAt: Date(), saved: req.save)
        jobs[job.id] = job
        order.append(job.id)
        trim()
        let previous = tail
        let task = Task {
            await previous?.value
            await self.run(job.id, req)
        }
        tasks[job.id] = task
        tail = task
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

    private func run(_ id: String, _ req: JobRequest) async {
        jobs[id]?.status = "running"
        jobs[id]?.startedAt = Date()
        defer {
            if req.deleteFileAfter { try? FileManager.default.removeItem(at: req.file) }
            tasks[id] = nil
            Task { await self.publishCounts() }
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
                Store.shared.insert(transcript)
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
