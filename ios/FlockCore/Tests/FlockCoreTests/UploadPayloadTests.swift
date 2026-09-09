import Foundation
import Testing
@testable import FlockCore

@Suite("Upload payload")
struct UploadPayloadTests {

    private func sighting(seq: Int, fix: LocationFix? = nil,
                          observedAt: Double = 1_757_000_000.5) -> Sighting {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[4] = 0xB6; raw[5] = 0x99; raw[6] = 0xF0
        raw[7] = 0x51; raw[8] = 0x45; raw[9] = 0xA4
        raw[10] = 0xB7          // -73
        raw[11] = 8             // channel
        raw[12] = 0             // wifi
        raw[13] = 0x41; raw[14] = 0x01   // matchFlags 321
        raw[15] = 100           // certainty
        raw[16] = 3             // alertLevel
        return Sighting(record: SightingRecord(raw)!, sessionID: "sess-1",
                        seq: seq, observedAt: observedAt, bootEpoch: 0, fix: fix)
    }

    private func json(_ p: UploadPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(p)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test("encodes the fields the server requires")
    func requiredFields() throws {
        let p = UploadPayload(sessionID: "sess-1", deviceID: "AA:BB:CC:DD:EE:FF",
                              startedAt: 1_757_000_000, endedAt: nil,
                              sightings: [sighting(seq: 1)])
        let o = try json(p)
        #expect(o["session_id"] as? String == "sess-1")
        #expect(o["device_id"] as? String == "AA:BB:CC:DD:EE:FF")
        let s = (o["sightings"] as! [[String: Any]])[0]
        #expect(s["seq"] as? Int == 1)
        #expect(s["observed_at"] as? Double == 1_757_000_000.5)
        #expect(s["mac"] as? String == "b6:99:f0:51:45:a4")
        #expect(s["rssi"] as? Int == -73)
    }

    @Test("radio is encoded as an integer, not a string")
    func radioIsAnInteger() throws {
        let o = try json(UploadPayload(sessionID: "s", deviceID: nil,
                                       startedAt: nil, endedAt: nil,
                                       sightings: [sighting(seq: 1)]))
        let s = (o["sightings"] as! [[String: Any]])[0]
        #expect(s["radio"] as? Int == 0)
        #expect(s["radio"] as? String == nil)
    }

    @Test("a missing fix omits the location keys rather than sending nulls")
    func omitsAbsentLocation() throws {
        let o = try json(UploadPayload(sessionID: "s", deviceID: nil,
                                       startedAt: nil, endedAt: nil,
                                       sightings: [sighting(seq: 1, fix: nil)]))
        let s = (o["sightings"] as! [[String: Any]])[0]
        #expect(s["lat"] == nil)
        #expect(s["lon"] == nil)
    }

    @Test("a present fix is encoded")
    func encodesLocation() throws {
        let fix = LocationFix(lat: 35.0456, lon: -85.3097,
                              horizontalAccuracy: 5.0, speed: 13.4)
        let o = try json(UploadPayload(sessionID: "s", deviceID: nil,
                                       startedAt: nil, endedAt: nil,
                                       sightings: [sighting(seq: 1, fix: fix)]))
        let s = (o["sightings"] as! [[String: Any]])[0]
        #expect(s["lat"] as? Double == 35.0456)
        #expect(s["horiz_acc"] as? Double == 5.0)
        #expect(s["speed"] as? Double == 13.4)
    }

    @Test("a sighting the server would reject is caught before it is sent")
    func validatesLocally() {
        // The server rejects the WHOLE batch on the first bad record, so one
        // out-of-range value would block every good sighting travelling with
        // it. Catching it here costs one comparison.
        var bad = sighting(seq: 1)
        bad.rssi = 5                         // server range is -128...0
        #expect(UploadPayload.invalidReason(for: bad) != nil)

        var future = sighting(seq: 2)
        future.observedAt = Date().timeIntervalSince1970 + 90_000  // >24h ahead
        #expect(UploadPayload.invalidReason(for: future) != nil)

        #expect(UploadPayload.invalidReason(for: sighting(seq: 3)) == nil)
    }

    @Test("every server range is enforced locally")
    func allRanges() {
        var s = sighting(seq: 1)
        s.channel = 15;     #expect(UploadPayload.invalidReason(for: s) != nil)
        s = sighting(seq: 1); s.certainty = 101
        #expect(UploadPayload.invalidReason(for: s) != nil)
        s = sighting(seq: 1); s.alertLevel = 4
        #expect(UploadPayload.invalidReason(for: s) != nil)
        s = sighting(seq: 1); s.radio = 2
        #expect(UploadPayload.invalidReason(for: s) != nil)
        s = sighting(seq: 1, fix: LocationFix(lat: 91, lon: 0,
                                              horizontalAccuracy: 1, speed: nil))
        #expect(UploadPayload.invalidReason(for: s) != nil)
    }

    @Test("the batch cap matches the server's")
    func batchCap() {
        #expect(UploadPayload.maxBatch == 500)
        #expect(UploadPayload.preferredBatch == 200)
        #expect(UploadPayload.preferredBatch <= UploadPayload.maxBatch)
    }
}
