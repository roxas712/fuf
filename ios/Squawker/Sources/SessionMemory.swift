import Foundation

/// Where the current session's id lives between launches.
///
/// A session outlives the app: it can be killed mid-drive and relaunched, and
/// the sightings already queued still belong to the session that was running.
/// UserDefaults rather than the Keychain because a session id is not a
/// credential -- it is an identifier the server already sees on every upload.
enum SessionMemory {
    private static let key = "current-session-id"

    static var currentSessionID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
