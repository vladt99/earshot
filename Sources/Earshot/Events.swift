import Foundation

/// Fan-out of app events to Server-Sent-Events subscribers (`GET /v1/events`).
final class EventBus: @unchecked Sendable {
    static let shared = EventBus()

    private let lock = NSLock()
    private var subscribers: [UUID: (filter: Set<String>?, continuation: AsyncStream<Data>.Continuation)] = [:]

    /// `filter`: event-name prefixes to receive (e.g. ["meeting."], "*" = all); nil = everything. Same rule as webhooks.
    func subscribe(filter: Set<String>?) -> AsyncStream<Data> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.subscribers.removeValue(forKey: id) }
        }
        lock.withLock { subscribers[id] = (filter, continuation) }
        continuation.yield(Data(": connected\n\n".utf8))
        return stream
    }

    func publish(_ event: String, _ payload: [String: Any]) {
        var body = payload
        body["event"] = event
        body["ts"] = Formats.iso(Date())
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return }
        let frame = Data("event: \(event)\ndata: ".utf8) + json + Data("\n\n".utf8)
        let targets = lock.withLock { Array(subscribers.values) }
        for t in targets where t.filter.map({ Webhooks.matches(event, Array($0)) }) ?? true {
            t.continuation.yield(frame)
        }
        Webhooks.deliver(event, body)
    }

    var subscriberCount: Int { lock.withLock { subscribers.count } }
}
