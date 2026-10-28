import CryptoKit
import Foundation

/// Pushes selected events to the URLs in Settings.webhooks, so other apps don't have
/// to poll or hold an SSE connection. `meeting.finalized` and `job.done` carry the whole transcript.
///
/// Each POST has `X-Earshot-Event` and `X-Earshot-Signature: sha256=<HMAC of the body, keyed with the API
/// token>`; the token itself is never sent.
enum Webhooks {
    static func deliver(_ event: String, _ body: [String: Any]) {
        let urls = Settings.webhooks.compactMap(URL.init(string:)).filter { ["http", "https"].contains($0.scheme ?? "") }
        guard !urls.isEmpty, Settings.webhookEvents.contains(event) else { return }
        var body = body
        if let id = body["transcript_id"] as? String, let t = Store.shared.get(id) { body["transcript"] = Formats.verbose(t) }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return }
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: Data(API.token.utf8)))
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
