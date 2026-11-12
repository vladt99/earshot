import Foundation
import Testing
@testable import Earshot

@Suite(.serialized)
struct APIAdmitTests {
    private func req(_ method: String, _ path: String, _ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: ["host": "127.0.0.1:7788"].merging(headers) { $1 }, body: Data())
    }

    private func accepted(_ r: HTTPRequest) -> Bool {
        if case .accept = API.admit(r) { return true }
        return false
    }

    init() {
        API.token = String(repeating: "a", count: 64)
        API.browserToken = String(repeating: "b", count: 64)
    }

    @Test func extensionPostsCaptionsWithItsToken() {
        let ext = ["origin": "chrome-extension://abcdefghijklmnop", "sec-fetch-site": "cross-site"]
        #expect(accepted(req("POST", "/v1/meet/captions", ext.merging(["authorization": "Bearer " + API.browserToken]) { $1 })))
        // Not with the main token, not without one, not from a web page, and nowhere else.
        #expect(!accepted(req("POST", "/v1/meet/captions", ext.merging(["authorization": "Bearer " + API.token]) { $1 })))
        #expect(!accepted(req("POST", "/v1/meet/captions", ext)))
        #expect(!accepted(req("POST", "/v1/meet/captions", ["origin": "https://evil.example", "authorization": "Bearer " + API.browserToken])))
        #expect(!accepted(req("GET", "/v1/transcripts", ext.merging(["authorization": "Bearer " + API.browserToken]) { $1 })))
        #expect(!accepted(req("GET", "/v1/meet/captions", ext.merging(["authorization": "Bearer " + API.browserToken]) { $1 })))
    }

    @Test func browserTokenOpensNothingElse() {
        #expect(!accepted(req("GET", "/v1/transcripts", ["authorization": "Bearer " + API.browserToken])))
        #expect(accepted(req("GET", "/v1/transcripts", ["authorization": "Bearer " + API.token])))
    }
}
