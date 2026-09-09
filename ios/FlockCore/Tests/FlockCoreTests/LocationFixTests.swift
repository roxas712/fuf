import Foundation
import Testing
@testable import FlockCore

/// CoreLocation signals "I do not have this" with an in-band negative number
/// rather than an absent value, for both speed and horizontal accuracy -- but
/// the two mean different things. A -1 speed is a missing measurement about a
/// position that is still real. A negative horizontal accuracy is CoreLocation
/// saying the latitude and longitude themselves are invalid, so there is no
/// position at all: keeping the coordinates and clearing only the accuracy
/// records a place the phone was never at, and weighting a fabricated
/// coordinate lower is not the same as not having one.
@Suite("Location fix")
struct LocationFixTests {

    @Test("a real accuracy is kept")
    func keepsValidAccuracy() throws {
        let fix = try #require(
            LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                         horizontalAccuracy: 8.0, speed: 13.4))
        #expect(fix.horizontalAccuracy == 8.0)
        #expect(fix.speed == 13.4)
        #expect(fix.lat == 35.0456)
        #expect(fix.lon == -85.3097)
    }

    @Test("an invalid accuracy discards the whole fix, coordinates included")
    func negativeAccuracyYieldsNoFix() {
        // Not "the accuracy is unknown, the position stands". The position is
        // the thing CoreLocation is disowning.
        #expect(LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                             horizontalAccuracy: -1, speed: 13.4) == nil)
    }

    @Test("a perfect zero accuracy is a measurement, not a sentinel")
    func zeroAccuracyIsKept() {
        // Only a negative value is the marker. Guarding on `> 0` would throw
        // away every fix that came back rounded to nothing.
        let fix = LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                               horizontalAccuracy: 0, speed: 13.4)
        #expect(fix?.horizontalAccuracy == 0)
    }

    @Test("an unavailable speed becomes unknown, and takes nothing else with it")
    func dropsNegativeSpeed() throws {
        let fix = try #require(
            LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                         horizontalAccuracy: 8.0, speed: -1))
        #expect(fix.speed == nil)
        // An unknown speed says nothing about where the phone is, so the
        // position survives it -- the one asymmetry with the accuracy sentinel.
        #expect(fix.horizontalAccuracy == 8.0)
        #expect(fix.lat == 35.0456)
        #expect(fix.lon == -85.3097)
    }

    @Test("a stationary phone still reports a real zero speed")
    func zeroSpeedIsKept() {
        // 0 is a measurement -- the phone is parked -- and only a negative
        // value is the sentinel. Filtering on `> 0` would throw away every
        // reading taken at a stop light.
        let fix = LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                               horizontalAccuracy: 8.0, speed: 0)
        #expect(fix?.speed == 0)
    }

    @Test("a sighting built from an invalid fix keeps the detection and drops the place")
    func sightingFromInvalidFixHasNoPosition() throws {
        let fix = LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                               horizontalAccuracy: -1, speed: 13.4)
        let sighting = Sighting(record: try Self.record(), sessionID: "sess-1", seq: 1,
                                observedAt: 1_757_000_000, bootEpoch: 0, fix: fix)
        // The sighting itself is not lost -- a detection with no position is
        // still a detection, and the server interpolates from the track.
        #expect(sighting.rssi == -73)
        #expect(sighting.lat == nil)
        #expect(sighting.lon == nil)
        #expect(sighting.horizAcc == nil)
        #expect(sighting.speed == nil)
    }

    @Test("a sighting with no position is omitted from the wire, not zeroed")
    func invalidFixNeverReachesTheWire() throws {
        // The end of the path this guards: what the server is actually told.
        // A lat of 0 would be a real place off the coast of Africa.
        let fix = LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                               horizontalAccuracy: -1, speed: -1)
        let sighting = Sighting(record: try Self.record(), sessionID: "sess-1", seq: 1,
                                observedAt: 1_757_000_000, bootEpoch: 0, fix: fix)
        let payload = UploadPayload(sessionID: "sess-1", deviceID: nil,
                                    startedAt: nil, endedAt: nil,
                                    sightings: [sighting])
        let body = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)) as! [String: Any]
        let s = (body["sightings"] as! [[String: Any]])[0]
        #expect(s["lat"] == nil)
        #expect(s["lon"] == nil)
        #expect(s["horiz_acc"] == nil)
        #expect(s["speed"] == nil)
        // Everything the detector supplied still travels.
        #expect(s["rssi"] as? Int == -73)
    }

    @Test("a positionless sighting still uploads rather than being quarantined")
    func positionlessSightingUploads() async throws {
        let fix = LocationFix.fromCoreLocation(lat: 35.0456, lon: -85.3097,
                                               horizontalAccuracy: -1, speed: -1)
        let sighting = Sighting(record: try Self.record(), sessionID: "sess-1", seq: 1,
                                observedAt: 1_757_000_000, bootEpoch: 0, fix: fix)
        // Null coordinates must pass the locally mirrored server validation --
        // if they did not, discarding an invalid fix would silently trade a
        // fabricated position for a lost sighting.
        #expect(UploadPayload.invalidReason(for: sighting) == nil)

        let store = try SightingStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite").path)
        try store.insert(sighting)
        // Survives the round trip through SQLite as NULL, not as 0.
        let readBack = try #require(try store.pending(limit: 10).first)
        #expect(readBack.lat == nil)
        #expect(readBack.lon == nil)

        let http = FakeHTTP()
        http.responses = [.success(HTTPReply(
            status: 200, body: #"{"accepted":1,"duplicates":0}"#.data(using: .utf8)!))]
        let uploader = Uploader(store: store, http: http,
                                endpoint: URL(string: "https://x/y")!, token: { "tok" })
        #expect(try await uploader.uploadOnce() == .uploaded(1))
        #expect(try store.pendingCount() == 0)
        let sent = (http.decodedBody(0)["sightings"] as! [[String: Any]])[0]
        #expect(sent["lat"] == nil)
    }

    /// A minimally valid wire record: rssi -73, so nothing but the location is
    /// under test.
    private static func record() throws -> SightingRecord {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[10] = 0xB7
        return try #require(SightingRecord(raw))
    }
}
