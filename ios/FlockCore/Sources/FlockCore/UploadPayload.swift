import Foundation

/// The request body for `POST /api/flock/sightings`, shaped to the contract in
/// `backend/routes/flock.py`.
///
/// Encoded with explicit CodingKeys rather than a key-encoding strategy so the
/// wire names are visible here and cannot drift with a global setting.
public struct UploadPayload: Encodable {
    /// The server refuses a larger batch outright rather than truncating it.
    public static let maxBatch = 500
    /// What the client actually sends. Well under the cap, so a retry that
    /// merges two batches can never breach it.
    public static let preferredBatch = 200
    /// The server rejects the whole batch if any record is this far ahead.
    static let maxFutureSeconds: Double = 24 * 60 * 60

    public let sessionID: String
    public let deviceID: String?
    public let startedAt: Double?
    public let endedAt: Double?
    public let sightings: [Item]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case deviceID  = "device_id"
        case startedAt = "started_at"
        case endedAt   = "ended_at"
        case sightings
    }

    public init(sessionID: String, deviceID: String?, startedAt: Double?,
                endedAt: Double?, sightings: [Sighting]) {
        self.sessionID = sessionID
        self.deviceID  = deviceID
        self.startedAt = startedAt
        self.endedAt   = endedAt
        self.sightings = sightings.map(Item.init)
    }

    public struct Item: Encodable {
        let seq: Int
        let observedAt: Double
        let mac: String
        let rssi: Int
        let channel: Int
        let radio: Int
        let matchFlags: Int
        let certainty: Int
        let alertLevel: Int
        let lat: Double?
        let lon: Double?
        let horizAcc: Double?
        let speed: Double?

        enum CodingKeys: String, CodingKey {
            case seq
            case observedAt = "observed_at"
            case mac, rssi, channel, radio
            case matchFlags = "match_flags"
            case certainty
            case alertLevel = "alert_level"
            case lat, lon
            case horizAcc = "horiz_acc"
            case speed
        }

        init(_ s: Sighting) {
            seq = s.seq; observedAt = s.observedAt; mac = s.mac; rssi = s.rssi
            channel = s.channel; radio = s.radio; matchFlags = s.matchFlags
            certainty = s.certainty; alertLevel = s.alertLevel
            lat = s.lat; lon = s.lon; horizAcc = s.horizAcc; speed = s.speed
        }
    }

    /// Mirrors the server's `RANGES` and future-clock check.
    ///
    /// Duplicated deliberately. Validation there is all-or-nothing: the first
    /// bad record returns 400 and nothing in the batch is stored, so a single
    /// out-of-range value would block 199 good sightings indefinitely, and the
    /// uploader would retry it forever. Returns a human-readable reason so a
    /// quarantined record can say why.
    public static func invalidReason(for s: Sighting, now: Double = Date().timeIntervalSince1970) -> String? {
        if s.observedAt > now + maxFutureSeconds { return "observed_at is too far in the future" }
        if !(-128...0).contains(s.rssi)          { return "rssi out of range" }
        if !(0...14).contains(s.channel)         { return "channel out of range" }
        if !(0...1).contains(s.radio)            { return "radio out of range" }
        if !(0...100).contains(s.certainty)      { return "certainty out of range" }
        if !(0...3).contains(s.alertLevel)       { return "alert_level out of range" }
        if let lat = s.lat, !(-90.0...90.0).contains(lat)    { return "lat out of range" }
        if let lon = s.lon, !(-180.0...180.0).contains(lon)  { return "lon out of range" }
        return nil
    }
}
