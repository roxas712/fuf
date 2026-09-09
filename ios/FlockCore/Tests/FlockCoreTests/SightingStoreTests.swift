import Foundation
import Testing
@testable import FlockCore

@Suite("SightingStore")
struct SightingStoreTests {

    private func makeStore() throws -> SightingStore {
        // A file, not :memory: -- the point of this store is surviving process
        // death, and an in-memory database cannot exercise reopening.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite")
        return try SightingStore(path: url.path)
    }

    private func sighting(seq: Int, session: String = "s1",
                          mac: String = "aa:bb:cc:dd:ee:ff",
                          fix: LocationFix? = nil) -> Sighting {
        Sighting(sessionID: session, seq: seq, observedAt: 1_757_000_000.5,
                 msSinceBoot: 1_000, bootEpoch: 0, mac: mac, rssi: -73,
                 channel: 6, radio: 0, matchFlags: 0, certainty: 100,
                 alertLevel: 3, lat: fix?.lat, lon: fix?.lon,
                 horizAcc: fix?.horizontalAccuracy, speed: fix?.speed,
                 uploadedAt: nil)
    }

    @Test("a fresh database has no pending records")
    func emptyStore() throws {
        let s = try makeStore()
        #expect(try s.pending(limit: 10).isEmpty)
        #expect(try s.pendingCount() == 0)
    }

    @Test("an inserted sighting comes back as pending")
    func insertThenPending() throws {
        let s = try makeStore()
        try s.insert(sighting(seq: 1))
        let pending = try s.pending(limit: 10)
        #expect(pending.count == 1)
        #expect(pending[0].seq == 1)
        #expect(pending[0].rssi == -73)
        #expect(pending[0].uploadedAt == nil)
    }

    @Test("a location fix round-trips, and its absence stays null")
    func locationRoundTrip() throws {
        let s = try makeStore()
        try s.insert(sighting(seq: 1, fix: LocationFix(
            lat: 35.0456, lon: -85.3097, horizontalAccuracy: 5.0, speed: 13.4)))
        try s.insert(sighting(seq: 2, fix: nil))
        let p = try s.pending(limit: 10).sorted { $0.seq < $1.seq }
        #expect(p[0].lat == 35.0456)
        #expect(p[0].horizAcc == 5.0)
        #expect(p[0].speed == 13.4)
        #expect(p[1].lat == nil)
        #expect(p[1].lon == nil)
        #expect(p[1].speed == nil)
    }

    @Test("pending returns oldest first")
    func oldestFirst() throws {
        let s = try makeStore()
        for seq in [3, 1, 2] { try s.insert(sighting(seq: seq)) }
        #expect(try s.pending(limit: 10).map(\.seq) == [3, 1, 2])
    }

    @Test("pending honours its limit")
    func limit() throws {
        let s = try makeStore()
        for seq in 1...10 { try s.insert(sighting(seq: seq)) }
        #expect(try s.pending(limit: 4).count == 4)
    }

    @Test("records survive closing and reopening the database")
    func survivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite")
        do {
            let s = try SightingStore(path: url.path)
            try s.insert(sighting(seq: 1))
        }
        let reopened = try SightingStore(path: url.path)
        #expect(try reopened.pendingCount() == 1)
    }

    @Test("opening an existing database twice does not duplicate the schema")
    func migrationIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flock-\(UUID().uuidString).sqlite")
        _ = try SightingStore(path: url.path)
        _ = try SightingStore(path: url.path)
        let s = try SightingStore(path: url.path)
        #expect(try s.pendingCount() == 0)
    }

    @Test("re-inserting the same (session, seq) is refused, not duplicated")
    func duplicateSeqRefused() throws {
        // Mirrors the server's UNIQUE (session_id, seq). Catching it locally
        // means a retry after a crash mid-insert cannot create a second row
        // that would upload as a distinct sighting.
        let s = try makeStore()
        try s.insert(sighting(seq: 1))
        #expect(throws: StoreError.self) { try s.insert(sighting(seq: 1)) }
        #expect(try s.pendingCount() == 1)
    }

    @Test("marking uploaded removes records from pending")
    func markUploaded() throws {
        let s = try makeStore()
        for seq in 1...3 { try s.insert(sighting(seq: seq)) }
        try s.markUploaded(sessionID: "s1", seqs: [1, 2], at: 1_757_000_100)
        #expect(try s.pending(limit: 10).map(\.seq) == [3])
        #expect(try s.pendingCount() == 1)
    }

    @Test("marking uploaded is scoped to its session")
    func markUploadedIsScoped() throws {
        let s = try makeStore()
        try s.insert(sighting(seq: 1, session: "s1"))
        try s.insert(sighting(seq: 1, session: "s2"))
        try s.markUploaded(sessionID: "s1", seqs: [1], at: 1_757_000_100)
        #expect(try s.pendingCount() == 1)
    }

    @Test("pruning removes uploaded records older than the window")
    func pruneOld() throws {
        let s = try makeStore()
        for seq in 1...3 { try s.insert(sighting(seq: seq)) }
        let now = 1_757_000_000.0
        let thirtyOneDaysAgo = now - 31 * 86_400
        try s.markUploaded(sessionID: "s1", seqs: [1, 2], at: thirtyOneDaysAgo)
        try s.markUploaded(sessionID: "s1", seqs: [3], at: now)
        #expect(try s.prune(uploadedBefore: now - 30 * 86_400) == 2)
        #expect(try s.totalCount() == 1)
    }

    @Test("pruning never touches records that have not uploaded")
    func pruneSparesPending() throws {
        // Losing un-uploaded detections to a retention sweep would defeat the
        // entire local-first design, so this is asserted rather than assumed.
        let s = try makeStore()
        for seq in 1...5 { try s.insert(sighting(seq: seq)) }
        #expect(try s.prune(uploadedBefore: 9_999_999_999) == 0)
        #expect(try s.pendingCount() == 5)
    }

    @Test("a large backlog is reported rather than discarded")
    func backlogIsReported() throws {
        let s = try makeStore()
        for seq in 1...5 { try s.insert(sighting(seq: seq)) }
        #expect(s.backlogIsAlarming(threshold: 3, count: try s.pendingCount()))
        #expect(s.backlogIsAlarming(threshold: 100, count: try s.pendingCount()) == false)
    }
}

// Camera counts come from the sightings themselves, not the devices table.
//
// `devices` is only written when a DeviceInfo notification arrives, and the
// firmware skips that entirely for an empty identifier -- so a hidden-SSID
// camera produces sightings and never appears there. Counting devices would
// undercount exactly the cameras most worth noticing.
extension SightingStoreTests {

    @Test("total cameras counts distinct MACs across every session")
    func totalCameras() throws {
        let s = try makeStore()
        try s.insert(sighting(seq: 1, session: "s1", mac: "aa:aa:aa:aa:aa:01"))
        try s.insert(sighting(seq: 2, session: "s1", mac: "aa:aa:aa:aa:aa:01"))
        try s.insert(sighting(seq: 3, session: "s1", mac: "aa:aa:aa:aa:aa:02"))
        try s.insert(sighting(seq: 1, session: "s2", mac: "aa:aa:aa:aa:aa:03"))
        #expect(try s.camerasSeen() == 3)
    }

    @Test("a camera seen in two sessions counts once in the total")
    func sameCameraTwoSessions() throws {
        let s = try makeStore()
        try s.insert(sighting(seq: 1, session: "s1", mac: "aa:aa:aa:aa:aa:01"))
        try s.insert(sighting(seq: 1, session: "s2", mac: "aa:aa:aa:aa:aa:01"))
        #expect(try s.camerasSeen() == 1)
    }

    @Test("session cameras counts only that session")
    func sessionCameras() throws {
        let s = try makeStore()
        try s.insert(sighting(seq: 1, session: "s1", mac: "aa:aa:aa:aa:aa:01"))
        try s.insert(sighting(seq: 2, session: "s1", mac: "aa:aa:aa:aa:aa:02"))
        try s.insert(sighting(seq: 1, session: "s2", mac: "aa:aa:aa:aa:aa:03"))
        #expect(try s.camerasSeen(inSession: "s1") == 2)
        #expect(try s.camerasSeen(inSession: "s2") == 1)
        #expect(try s.camerasSeen(inSession: "nope") == 0)
    }

    @Test("a camera with no label still counts")
    func unlabelledCameraCounts() throws {
        // The hidden-SSID case. It never reaches the devices table, so a count
        // taken from there would miss it entirely.
        let s = try makeStore()
        try s.insert(sighting(seq: 1, session: "s1", mac: "aa:aa:aa:aa:aa:09"))
        #expect(try s.camerasSeen() == 1)
        #expect(try s.deviceCount() == 0)      // no DeviceInfo ever arrived
    }
}
