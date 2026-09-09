/// Tracks device restarts within a session.
///
/// The device has no real-time clock; it stamps `msSinceBoot` and that counter
/// resets to zero when it restarts. Every sighting is therefore ambiguous on
/// its own, and only the sequence tells you a reboot happened: the counter went
/// backwards. Each restart opens a new epoch, so `(boot_epoch, ms_since_boot)`
/// orders correctly across one.
///
/// Not a reboot: an equal timestamp. At ~2 notifications/sec per camera, with
/// several cameras in range, two sightings inside one millisecond are ordinary.
/// A value type: a copy counts independently of the original. Do not stash one
/// in a closure expecting it to track the session's.
public struct BootEpoch: Sendable {
    public private(set) var current: Int = 0
    private var last: (ms: UInt32, at: Double)?

    /// Absorbs notification latency and phone-clock jitter. Only a restart
    /// makes the device's clock lose whole seconds against the phone's.
    static let toleranceMs: Double = 5_000

    public init() {}

    /// Returns the epoch this record belongs to, incrementing first if the
    /// device restarted.
    ///
    /// Two independent signals, either one sufficient:
    ///
    /// 1. The device's counter went backwards at all. Notifications arrive
    ///    over an ordered GATT connection, so there is no reordering to
    ///    absorb -- any decrease, however small, is a genuine restart. This
    ///    also catches the `millis()` wrap at ~49.7 days: the device did not
    ///    restart, but its counter did, and only advancing the epoch keeps
    ///    (epoch, ms) ordered.
    /// 2. How far the *device's* clock advanced falls short of how far the
    ///    *phone's* did, by more than jitter/latency can explain. A bare
    ///    regression check misses this: if the device rebooted after 20s of
    ///    uptime and reconnecting took 40s, the first record back reads
    ///    higher than the last one before the reboot, so signal 1 alone sees
    ///    nothing wrong. That is the brownout case on a battery-powered
    ///    device -- the likeliest field reboot, and the one where epoch
    ///    separation matters most.
    @discardableResult
    public mutating func observe(_ record: SightingRecord, at observedAt: Double) -> Int {
        defer { last = (record.msSinceBoot, observedAt) }
        guard let last else { return current }
        let deviceDelta = Double(record.msSinceBoot) - Double(last.ms)
        let wallDelta   = (observedAt - last.at) * 1000
        if deviceDelta < 0 || deviceDelta < wallDelta - Self.toleranceMs { current += 1 }
        return current
    }
}
