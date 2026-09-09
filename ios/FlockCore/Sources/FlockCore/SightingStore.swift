import Foundation
import SQLite3

public enum StoreError: Error, Equatable {
    case open(String)
    case sql(String)
    case duplicate
}

/// SQLite is transactional and survives termination, which a JSON file would
/// not: a batch of sightings written during a crash must either all land or
/// none, and the queue has to be intact on relaunch.
///
/// Safe to use from more than one isolation domain, because the connection is
/// opened with SQLITE_OPEN_FULLMUTEX. That matters: the Uploader is an actor
/// and SessionController is @MainActor, and both touch this same instance.
///
/// `@unchecked Sendable` documents that contract rather than papering over it:
/// this type is not automatically thread-safe, but callers that serialise
/// their own access to it -- as `Uploader`, an actor, does -- may hold and
/// share an instance across isolation domains.
public final class SightingStore: @unchecked Sendable {
    private var db: OpaquePointer?

    public init(path: String) throws {
        // `db != nil` rather than `let db`: the unwrapped value is never used
        // (call sites read self.db), and binding it produced an unused-value
        // warning. One accepted warning is how the next real one gets ignored.
        // SQLITE_OPEN_FULLMUTEX, not plain sqlite3_open, and it is load-bearing.
        //
        // Apple ships SQLite in multi-thread mode (`sqlite3_threadsafe()` == 2),
        // whose rule is: safe across threads PROVIDED no single connection is
        // used simultaneously by two of them. This connection is -- the Uploader
        // actor reads and marks batches while SessionController inserts on the
        // main actor. FULLMUTEX forces serialized mode for this connection
        // regardless of the library default, which is what makes the
        // `@unchecked Sendable` above an honest claim rather than a wish.
        // Without it the failure is rare, unreproducible corruption.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, db != nil else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        // WAL survives a crash mid-write and lets a read run during one.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
        }
        sqlite3_finalize(stmt)
        guard version < Schema.currentVersion else { return }
        try exec("BEGIN;")
        do {
            try exec(Schema.v1)
            try exec("PRAGMA user_version=\(Schema.currentVersion);")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }

    /// SQLite keeps a pointer to bound text until the statement is stepped, so
    /// a Swift String's transient buffer must be copied. SQLITE_TRANSIENT is
    /// not exposed to Swift; this is the documented cast for it.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    public func insert(_ s: Sighting) throws {
        let sql = """
        INSERT INTO sightings
          (session_id, seq, observed_at, ms_since_boot, boot_epoch, mac, rssi,
           channel, radio, match_flags, certainty, alert_level,
           lat, lon, horiz_acc, speed, uploaded_at)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,NULL);
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }

        sqlite3_bind_text(st, 1, s.sessionID, -1, Self.transient)
        sqlite3_bind_int64(st, 2, Int64(s.seq))
        sqlite3_bind_double(st, 3, s.observedAt)
        sqlite3_bind_int64(st, 4, Int64(s.msSinceBoot))
        sqlite3_bind_int64(st, 5, Int64(s.bootEpoch))
        sqlite3_bind_text(st, 6, s.mac, -1, Self.transient)
        sqlite3_bind_int64(st, 7, Int64(s.rssi))
        sqlite3_bind_int64(st, 8, Int64(s.channel))
        sqlite3_bind_int64(st, 9, Int64(s.radio))
        sqlite3_bind_int64(st, 10, Int64(s.matchFlags))
        sqlite3_bind_int64(st, 11, Int64(s.certainty))
        sqlite3_bind_int64(st, 12, Int64(s.alertLevel))
        bindOptionalDouble(st, 13, s.lat)
        bindOptionalDouble(st, 14, s.lon)
        bindOptionalDouble(st, 15, s.horizAcc)
        bindOptionalDouble(st, 16, s.speed)

        let rc = sqlite3_step(st)
        if rc == SQLITE_CONSTRAINT { throw StoreError.duplicate }
        guard rc == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindOptionalDouble(_ st: OpaquePointer?, _ idx: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(st, idx, v) } else { sqlite3_bind_null(st, idx) }
    }

    /// Oldest first, by insertion order. `id` rather than `observed_at`: two
    /// sightings can share a millisecond, and upload order must be total.
    public func pending(limit: Int) throws -> [Sighting] {
        let sql = """
        SELECT session_id, seq, observed_at, ms_since_boot, boot_epoch, mac, rssi,
               channel, radio, match_flags, certainty, alert_level,
               lat, lon, horiz_acc, speed
        FROM sightings WHERE uploaded_at IS NULL ORDER BY id LIMIT ?1;
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(limit))

        var out: [Sighting] = []
        while sqlite3_step(st) == SQLITE_ROW {
            // Every field named explicitly. Building this by stamping a
            // synthetic SightingRecord and overwriting twelve fields would
            // compile just as well and lose a column silently the day one is
            // added and an assignment is forgotten.
            out.append(Sighting(
                sessionID:   String(cString: sqlite3_column_text(st, 0)),
                seq:         Int(sqlite3_column_int64(st, 1)),
                observedAt:  sqlite3_column_double(st, 2),
                msSinceBoot: UInt32(sqlite3_column_int64(st, 3)),
                bootEpoch:   Int(sqlite3_column_int64(st, 4)),
                mac:         String(cString: sqlite3_column_text(st, 5)),
                rssi:        Int(sqlite3_column_int64(st, 6)),
                channel:     Int(sqlite3_column_int64(st, 7)),
                radio:       Int(sqlite3_column_int64(st, 8)),
                matchFlags:  Int(sqlite3_column_int64(st, 9)),
                certainty:   Int(sqlite3_column_int64(st, 10)),
                alertLevel:  Int(sqlite3_column_int64(st, 11)),
                lat:         optionalDouble(st, 12),
                lon:         optionalDouble(st, 13),
                horizAcc:    optionalDouble(st, 14),
                speed:       optionalDouble(st, 15),
                uploadedAt:  nil))
        }
        return out
    }

    private func optionalDouble(_ st: OpaquePointer?, _ idx: Int32) -> Double? {
        sqlite3_column_type(st, idx) == SQLITE_NULL ? nil : sqlite3_column_double(st, idx)
    }

    public func pendingCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM sightings WHERE uploaded_at IS NULL;")
    }

    func scalar(_ sql: String) throws -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    /// Marks a batch uploaded in one transaction. All or nothing: a partial
    /// mark after a successful POST would re-upload records the server already
    /// accepted, which its (session_id, seq) constraint would reject as
    /// duplicates -- harmless, but it would hide a real bug behind a benign
    /// count.
    public func markUploaded(sessionID: String, seqs: [Int], at: Double) throws {
        guard !seqs.isEmpty else { return }
        try exec("BEGIN;")
        do {
            let sql = """
            UPDATE sightings SET uploaded_at = ?1
            WHERE session_id = ?2 AND seq = ?3 AND uploaded_at IS NULL;
            """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(st) }
            for seq in seqs {
                sqlite3_reset(st)
                sqlite3_bind_double(st, 1, at)
                sqlite3_bind_text(st, 2, sessionID, -1, Self.transient)
                sqlite3_bind_int64(st, 3, Int64(seq))
                guard sqlite3_step(st) == SQLITE_DONE else {
                    throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Deletes uploaded records older than the cutoff. Returns how many went.
    ///
    /// The `uploaded_at IS NOT NULL` clause is the important half: a record
    /// that never uploaded is never pruned, however old it is.
    @discardableResult
    public func prune(uploadedBefore cutoff: Double) throws -> Int {
        let sql = "DELETE FROM sightings WHERE uploaded_at IS NOT NULL AND uploaded_at < ?1;"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, cutoff)
        guard sqlite3_step(st) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    public func totalCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM sightings;")
    }

    /// How many distinct cameras have ever been labelled. Exposed as a method
    /// rather than letting callers run their own SQL: `scalar` stays internal
    /// so the app target cannot reach past this API into the schema.
    public func deviceCount() throws -> Int {
        try scalar("SELECT COUNT(*) FROM devices;")
    }

    /// A backlog this large means uploading has been broken for a long time.
    /// That is a state to surface, not to garbage-collect: silently discarding
    /// the evidence would turn a visible fault into an invisible data loss.
    public func backlogIsAlarming(threshold: Int = 100_000, count: Int) -> Bool {
        count > threshold
    }

    /// Upserts a label. `first_seen` is written only on insert -- re-seeing a
    /// camera must not reset when it was first encountered, which is the field
    /// the map uses to order an encounter history.
    public func recordLabel(mac: String, label: String?, radio: Int, at: Double) throws {
        let sql = """
        INSERT INTO devices (mac, label, radio, first_seen) VALUES (?1, ?2, ?3, ?4)
        ON CONFLICT(mac) DO UPDATE SET
          label = COALESCE(excluded.label, devices.label),
          radio = excluded.radio;
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, mac, -1, Self.transient)
        if let label { sqlite3_bind_text(st, 2, label, -1, Self.transient) }
        else { sqlite3_bind_null(st, 2) }
        sqlite3_bind_int64(st, 3, Int64(radio))
        sqlite3_bind_double(st, 4, at)
        guard sqlite3_step(st) == SQLITE_DONE else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func label(for mac: String) throws -> String? {
        try textColumn("SELECT label FROM devices WHERE mac = ?1;", mac)
    }

    public func firstSeen(for mac: String) throws -> Double? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT first_seen FROM devices WHERE mac = ?1;",
                                 -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, mac, -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(st, 0)
    }

    private func textColumn(_ sql: String, _ arg: String) throws -> String? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, arg, -1, Self.transient)
        guard sqlite3_step(st) == SQLITE_ROW,
              sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(st, 0))
    }
}
