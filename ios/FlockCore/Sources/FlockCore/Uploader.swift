import Foundation

public enum UploadOutcome: Equatable, Sendable {
    case nothingToDo
    /// Server-accepted count. Duplicates are cleared locally but not counted.
    case uploaded(Int)
    case authExpired
    case quarantined(seqs: [Int], reason: String)
    case retryLater(afterSeconds: Double)
}

/// Batches pending sightings and posts them.
///
/// Local-first: nothing here decides what to keep. The store is the queue, and
/// a record leaves it only when the server has confirmed it -- including as a
/// duplicate, which means the server already has it.
public actor Uploader {
    private let store: SightingStore
    private let http: HTTPClient
    private let endpoint: URL
    private let token: @Sendable () -> String?
    private let deviceID: String?

    /// Backoff state, capped at five minutes.
    private var consecutiveFailures = 0
    static let maxBackoff: Double = 300

    public init(store: SightingStore, http: HTTPClient, endpoint: URL,
                token: @escaping @Sendable () -> String?, deviceID: String? = nil) {
        self.store = store
        self.http = http
        self.endpoint = endpoint
        self.token = token
        self.deviceID = deviceID
    }

    /// Uploads at most one batch. Returns what happened so the caller can
    /// decide whether to loop, wait, or surface something to the user.
    @discardableResult
    public func uploadOnce() async throws -> UploadOutcome {
        let queued = try store.pending(limit: UploadPayload.preferredBatch)
        guard let first = queued.first else { return .nothingToDo }

        // session_id is a top-level field, so one batch is one session.
        let batch = queued.prefix { $0.sessionID == first.sessionID }

        if let bad = batch.first(where: { UploadPayload.invalidReason(for: $0) != nil }) {
            let reason = UploadPayload.invalidReason(for: bad) ?? "invalid"
            try store.markUploaded(sessionID: bad.sessionID, seqs: [bad.seq],
                                   at: Date().timeIntervalSince1970)
            return .quarantined(seqs: [bad.seq], reason: reason)
        }

        let payload = UploadPayload(sessionID: first.sessionID, deviceID: deviceID,
                                    startedAt: nil, endedAt: nil,
                                    sightings: Array(batch))
        let body = try JSONEncoder().encode(payload)
        let reply = try await http.post(url: endpoint, body: body, bearer: token())

        switch reply.status {
        case 200:
            consecutiveFailures = 0
            let accepted = (try? JSONSerialization.jsonObject(with: reply.body)
                as? [String: Any])??["accepted"] as? Int ?? 0
            try store.markUploaded(sessionID: first.sessionID,
                                   seqs: batch.map(\.seq),
                                   at: Date().timeIntervalSince1970)
            return .uploaded(accepted)

        case 401:
            // The token expired or was revoked. The queue is untouched; the UI
            // prompts for a re-login and the same batch goes out afterwards.
            return .authExpired

        case 400..<500:
            // A payload the server will never accept. Retrying forever would
            // wedge the queue behind it, so it is quarantined and surfaced.
            let reason = String(data: reply.body, encoding: .utf8) ?? "rejected"
            try store.markUploaded(sessionID: first.sessionID,
                                   seqs: batch.map(\.seq),
                                   at: Date().timeIntervalSince1970)
            return .quarantined(seqs: batch.map(\.seq), reason: reason)

        default:
            consecutiveFailures += 1
            return .retryLater(afterSeconds: backoffDelay())
        }
    }

    /// Exponential, capped. A phone in a dead zone should not spin the radio.
    func backoffDelay() -> Double {
        min(Self.maxBackoff, pow(2.0, Double(min(consecutiveFailures, 10))))
    }
}
