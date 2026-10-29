import CryptoKit
import Foundation

/// Pushes selected events to the URLs in Settings.webhooks, so other apps don't have
/// to poll or hold an SSE connection. `meeting.finalized` and `job.done` carry the whole transcript.
///
/// Each POST has `X-Earshot-Event` and `X-Earshot-Signature: sha256=<HMAC of the body, keyed with
/// `Webhooks.secret`>`. The body always carries `event` and `ts`, so a captured delivery can't be replayed as new.
/// `webhook_events` entries are prefixes, like the SSE filter: "meeting." matches every meeting event.
enum Webhooks {
    private static let secretKey = "webhookSecret"
    private static let lock = NSLock()

    /// Signing secret, separate from the API token; created on first use.
    static var secret: String {
        lock.withLock {
            if let s = UserDefaults.standard.string(forKey: secretKey), s.count >= 64 { return s }
            let s = API.randomHex(32)
            UserDefaults.standard.set(s, forKey: secretKey)
            return s
        }
    }

    static func rotateSecret() {
        lock.withLock { UserDefaults.standard.set(API.randomHex(32), forKey: secretKey) }
    }

    static func matches(_ event: String, _ patterns: [String]) -> Bool {
        patterns.contains { !$0.isEmpty && ($0 == "*" || event.hasPrefix($0)) }
    }

    static func deliver(_ event: String, _ body: [String: Any]) {
        let urls = Settings.webhooks.compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard !urls.isEmpty, matches(event, Settings.webhookEvents) else { return }
        var body = body
        body["event"] = event
        if body["ts"] == nil { body["ts"] = Formats.iso(Date()) }
        if let id = body["transcript_id"] as? String, let t = Store.shared.get(id) { body["transcript"] = Formats.verbose(t) }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return }
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        for url in urls {
            Task.detached { await post(data, to: url, event: event, signature: signature) }
        }
    }

    /// Three tries: now, after 2 s, after 10 s.
    private static func post(_ data: Data, to url: URL, event: String, signature: String) async {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(event, forHTTPHeaderField: "X-Earshot-Event")
        req.setValue("sha256=" + signature, forHTTPHeaderField: "X-Earshot-Signature")
        req.setValue("Earshot/\(appVersion)", forHTTPHeaderField: "User-Agent")
        for delay in [0, 2, 10] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let code = (response as? HTTPURLResponse)?.statusCode, code < 500 { return }
        }
    }
}
