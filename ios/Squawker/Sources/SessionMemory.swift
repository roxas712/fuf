import Foundation

/// Where the current session's id lives between launches.
///
/// A session outlives the app: it can be killed mid-drive and relaunched, and
/// the sightings already queued still belong to the session that was running.
/// UserDefaults rather than the Keychain because a session id is not a
/// credential -- it is an identifier the server already sees on every upload.
enum SessionMemory {
    private static let idKey = "current-session-id"
    private static let lastActivityKey = "current-session-last-activity"

    /// The most recently started session's id.
    ///
    /// Deliberately NOT cleared by a clean `stop()` -- the dashboard's
    /// "cameras this session" stat reads this to describe the last session
    /// that ran, not only one still running, so it has to survive well past
    /// the session's end. It is only ever replaced, by the next `start()`.
    static var currentSessionID: String? {
        get { UserDefaults.standard.string(forKey: idKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: idKey) }
            else { UserDefaults.standard.removeObject(forKey: idKey) }
        }
    }

    /// Wall-clock time of the last known activity in `currentSessionID`'s
    /// session: set when that session starts, refreshed as it records each
    /// sighting, and cleared the moment `stop()` finishes cleanly.
    ///
    /// That last part is what makes this the session's open/closed marker,
    /// separate from `currentSessionID` (which never clears on its own): a
    /// clean stop always nils this out, so finding it still set on the next
    /// launch means the app never got there -- it was killed mid-session.
    /// Closing that orphaned session then uses this value, the last moment
    /// it is actually known to have done something, rather than the moment
    /// of relaunch -- otherwise an overnight interruption looks like a
    /// session that ran for hours.
    static var currentSessionLastActivity: Double? {
        get {
            let v = UserDefaults.standard.double(forKey: lastActivityKey)
            // UserDefaults.double(forKey:) returns 0 for a missing key, and
            // 0 is not a real timestamp any session will ever have (that's
            // the 1970 epoch) -- so it doubles safely as "unset".
            return v == 0 ? nil : v
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: lastActivityKey) }
            else { UserDefaults.standard.removeObject(forKey: lastActivityKey) }
        }
    }
}
