/// The database shape, and the only place DDL lives.
///
/// `user_version` is SQLite's own integer, free to read and write, which is why
/// migration needs no bookkeeping table of its own.
enum Schema {
    static let currentVersion: Int32 = 1

    /// Applied once, in a transaction, when `user_version` is 0.
    static let v1 = """
    CREATE TABLE IF NOT EXISTS sightings (
      id            INTEGER PRIMARY KEY,
      session_id    TEXT    NOT NULL,
      seq           INTEGER NOT NULL,
      observed_at   REAL    NOT NULL,
      ms_since_boot INTEGER NOT NULL,
      boot_epoch    INTEGER NOT NULL,
      mac           TEXT    NOT NULL,
      rssi          INTEGER NOT NULL,
      channel       INTEGER,
      radio         INTEGER,
      match_flags   INTEGER,
      certainty     INTEGER,
      alert_level   INTEGER,
      lat           REAL,
      lon           REAL,
      horiz_acc     REAL,
      speed         REAL,
      uploaded_at   REAL,
      UNIQUE (session_id, seq)
    );

    -- Partial index: the pending query is the hot path and runs on every upload
    -- tick, while uploaded rows are dead weight to it.
    CREATE INDEX IF NOT EXISTS idx_pending
      ON sightings (id) WHERE uploaded_at IS NULL;

    -- Retention sweeps by upload time.
    CREATE INDEX IF NOT EXISTS idx_uploaded_at
      ON sightings (uploaded_at) WHERE uploaded_at IS NOT NULL;

    CREATE TABLE IF NOT EXISTS devices (
      mac        TEXT PRIMARY KEY,
      label      TEXT,
      radio      INTEGER,
      first_seen REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sessions (
      id         TEXT PRIMARY KEY,
      started_at REAL NOT NULL,
      ended_at   REAL
    );
    """
}
