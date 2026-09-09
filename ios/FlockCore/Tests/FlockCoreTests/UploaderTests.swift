import Foundation
import Testing
@testable import FlockCore

/// Records what was sent and replays canned responses, so batching, retry and
/// the response taxonomy are all testable with no network and no server.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var responses: [Result<HTTPReply, Error>] = []
    private(set) var sentBodies: [Data] = []
    private(set) var sentTokens: [String?] = []

    func post(url: URL, body: Data, bearer: String?) async throws -> HTTPReply {
        sentBodies.append(body)
        sentTokens.append(bearer)
        guard !responses.isEmpty else { return HTTPReply(status: 200, body: Data()) }
        return try responses.removeFirst().get()
    }

    func decodedBody(_ i: Int) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: sentBodies[i]) as! [String: Any]
    }
}

@Suite("Uploader")
struct UploaderTests {

    private func makeStore() throws -> SightingStore {
        try SightingStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite").path)
    }

    private func sighting(seq: Int, session: String = "sess-1") -> Sighting {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[9] = 1; raw[10] = 0xB7
        return Sighting(record: SightingRecord(raw)!, sessionID: session, seq: seq,
                        observedAt: 1_757_000_000, bootEpoch: 0, fix: nil)
    }

    private func ok(accepted: Int, duplicates: Int = 0) -> HTTPReply {
        HTTPReply(status: 200,
                  body: #"{"accepted":\#(accepted),"duplicates":\#(duplicates)}"#
                    .data(using: .utf8)!)
    }

    @Test("an empty queue sends nothing")
    func emptyQueue() async throws {
        let http = FakeHTTP()
        let up = Uploader(store: try makeStore(), http: http,
                          endpoint: URL(string: "https://example.com/api/flock/sightings")!,
                          token: { "tok" })
        let outcome = try await up.uploadOnce()
        #expect(outcome == .nothingToDo)
        #expect(http.sentBodies.isEmpty)
    }

    @Test("a successful upload marks the batch and clears pending")
    func successMarks() async throws {
        let store = try makeStore()
        for seq in 1...3 { try store.insert(sighting(seq: seq)) }
        let http = FakeHTTP()
        http.responses = [.success(ok(accepted: 3))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "tok" })

        #expect(try await up.uploadOnce() == .uploaded(3))
        #expect(try store.pendingCount() == 0)
    }

    @Test("the bearer token is sent")
    func sendsToken() async throws {
        let store = try makeStore()
        try store.insert(sighting(seq: 1))
        let http = FakeHTTP()
        http.responses = [.success(ok(accepted: 1))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "secret-token" })
        _ = try await up.uploadOnce()
        #expect(http.sentTokens.first == "secret-token")
    }

    @Test("a batch never exceeds the preferred size")
    func batchSize() async throws {
        let store = try makeStore()
        for seq in 1...250 { try store.insert(sighting(seq: seq)) }
        let http = FakeHTTP()
        http.responses = [.success(ok(accepted: 200))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })
        _ = try await up.uploadOnce()
        let sent = http.decodedBody(0)["sightings"] as! [[String: Any]]
        #expect(sent.count == UploadPayload.preferredBatch)
        #expect(try store.pendingCount() == 50)
    }

    @Test("duplicates reported by the server still clear locally")
    func duplicatesClear() async throws {
        // The server's UNIQUE (session_id, seq) makes a resend a no-op. If a
        // response was lost after the server committed, the retry comes back
        // all-duplicates -- which means those records ARE stored, so leaving
        // them pending would retry them forever.
        let store = try makeStore()
        for seq in 1...2 { try store.insert(sighting(seq: seq)) }
        let http = FakeHTTP()
        http.responses = [.success(ok(accepted: 0, duplicates: 2))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })
        #expect(try await up.uploadOnce() == .uploaded(0))
        #expect(try store.pendingCount() == 0)
    }

    @Test("one batch per session, even when several are queued")
    func oneSessionPerBatch() async throws {
        // session_id is a top-level field, so a batch cannot span sessions.
        let store = try makeStore()
        try store.insert(sighting(seq: 1, session: "sess-A"))
        try store.insert(sighting(seq: 2, session: "sess-A"))
        try store.insert(sighting(seq: 1, session: "sess-B"))
        let http = FakeHTTP()
        http.responses = [.success(ok(accepted: 2)), .success(ok(accepted: 1))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        _ = try await up.uploadOnce()
        #expect(http.decodedBody(0)["session_id"] as? String == "sess-A")
        #expect((http.decodedBody(0)["sightings"] as! [[String: Any]]).count == 2)
        _ = try await up.uploadOnce()
        #expect(http.decodedBody(1)["session_id"] as? String == "sess-B")
    }

    @Test("a 401 preserves the queue and asks for a re-login")
    func authExpired() async throws {
        let store = try makeStore()
        for seq in 1...3 { try store.insert(sighting(seq: seq)) }
        let http = FakeHTTP()
        http.responses = [.success(HTTPReply(status: 401, body: Data()))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "stale" })

        #expect(try await up.uploadOnce() == .authExpired)
        // Nothing lost: the same batch goes out after re-login.
        #expect(try store.pendingCount() == 3)
    }

    @Test("a 5xx backs off and keeps the queue")
    func serverErrorBacksOff() async throws {
        let store = try makeStore()
        try store.insert(sighting(seq: 1))
        let http = FakeHTTP()
        http.responses = [.success(HTTPReply(status: 503, body: Data()))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        guard case .retryLater(let delay, _) = try await up.uploadOnce() else {
            Issue.record("expected retryLater"); return
        }
        #expect(delay > 0)
        #expect(try store.pendingCount() == 1)
    }

    @Test("the failing status reaches the caller, not just a delay")
    func serverErrorReportsStatus() async throws {
        // A 500 on every batch is permanent from the phone's point of view, but
        // it arrives through the same path as a transient 503. Only the status
        // tells them apart, so the UI can say "the server is rejecting these"
        // instead of leaving a pending count to climb in silence.
        let store = try makeStore()
        try store.insert(sighting(seq: 1))
        let http = FakeHTTP()
        http.responses = [.success(HTTPReply(status: 500, body: Data()))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        guard case .retryLater(_, let status) = try await up.uploadOnce() else {
            Issue.record("expected retryLater"); return
        }
        #expect(status == 500)
    }

    @Test("backoff grows and is capped at five minutes")
    func backoffIsCapped() async throws {
        let store = try makeStore()
        try store.insert(sighting(seq: 1))
        let http = FakeHTTP()
        http.responses = Array(repeating: .success(HTTPReply(status: 500, body: Data())),
                               count: 15)
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        var last: Double = 0
        for _ in 1...15 {
            guard case .retryLater(let d, _) = try await up.uploadOnce() else {
                Issue.record("expected retryLater"); return
            }
            #expect(d >= last)
            last = d
        }
        #expect(last == 300)
    }

    @Test("a 4xx quarantines the batch instead of retrying it forever")
    func malformedIsQuarantined() async throws {
        let store = try makeStore()
        for seq in 1...2 { try store.insert(sighting(seq: seq)) }
        let http = FakeHTTP()
        http.responses = [.success(HTTPReply(
            status: 400,
            body: #"{"error":"out of range","index":0,"field":"rssi"}"#.data(using: .utf8)!))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        guard case .quarantined(let seqs, let reason) = try await up.uploadOnce() else {
            Issue.record("expected quarantined"); return
        }
        #expect(seqs == [1, 2])
        #expect(reason.contains("rssi"))
        // Cleared from pending so the queue behind it can drain.
        #expect(try store.pendingCount() == 0)
    }

    @Test("a locally invalid record is quarantined before it can block a batch")
    func locallyInvalidIsQuarantinedAlone() async throws {
        // Only the offender is removed. The server never sees it, so the 199
        // good sightings that would have travelled with it are unaffected.
        let store = try makeStore()
        var bad = sighting(seq: 1)
        bad.rssi = 5
        try store.insert(bad)
        try store.insert(sighting(seq: 2))
        let http = FakeHTTP()
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        guard case .quarantined(let seqs, _) = try await up.uploadOnce() else {
            Issue.record("expected quarantined"); return
        }
        #expect(seqs == [1])
        #expect(http.sentBodies.isEmpty)          // never sent
        #expect(try store.pendingCount() == 1)    // seq 2 still queued
    }

    @Test("a successful upload resets the backoff")
    func successResetsBackoff() async throws {
        let store = try makeStore()
        for seq in 1...2 { try store.insert(sighting(seq: seq)) }
        let http = FakeHTTP()
        http.responses = [.success(HTTPReply(status: 500, body: Data())),
                          .success(ok(accepted: 2)),
                          .success(HTTPReply(status: 500, body: Data()))]
        let up = Uploader(store: store, http: http,
                          endpoint: URL(string: "https://x/y")!, token: { "t" })

        _ = try await up.uploadOnce()                    // fail, backoff grows
        _ = try await up.uploadOnce()                    // succeed, reset
        try store.insert(sighting(seq: 3))
        guard case .retryLater(let d, _) = try await up.uploadOnce() else {
            Issue.record("expected retryLater"); return
        }
        #expect(d == 2)                                  // back to the first step
    }
}
