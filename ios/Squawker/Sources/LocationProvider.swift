import CoreLocation
import FlockCore

/// Owns CoreLocation and hands out plain `LocationFix` values, so nothing
/// downstream needs to import CoreLocation or run on a device to be tested.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    enum Readiness: Equatable {
        case notDetermined
        case denied
        /// Authorized, but Precise Location is off. Blocking, deliberately.
        case reducedAccuracy
        /// When-In-Use only. Usable with the screen on, but nothing is recorded
        /// once the phone locks -- so it is surfaced rather than treated as
        /// ready. Silently recording nothing is the same kind of failure as
        /// silently recording the wrong place.
        case foregroundOnly
        case ready

        /// Whether a session may start at all.
        var canStartSession: Bool {
            self == .ready || self == .foregroundOnly
        }
    }

    @Published private(set) var readiness: Readiness = .notDetermined
    @Published private(set) var latest: LocationFix?

    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // ~10m of travel between fixes. Distance-based rather than time-based
        // so a parked phone stops waking the GPS.
        manager.distanceFilter = 10
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// iOS asks in two steps: When In Use first, then Always. Requesting Always
    /// directly from `.notDetermined` shows only the first prompt.
    ///
    /// **The Always prompt usually does not appear here, and that is normal.**
    /// Since iOS 13 the upgrade is deferred: the system grants it provisionally
    /// and asks the user to confirm later, after the app has actually used
    /// location in the background. So finishing this call in `.foregroundOnly`
    /// is an expected outcome, not a failure -- which is exactly why that state
    /// exists rather than being folded into `.ready`.
    func requestAuthorization() async {
        guard manager.authorizationStatus == .notDetermined else {
            evaluate(); return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            authContinuation = c
            manager.requestWhenInUseAuthorization()
        }
        manager.requestAlwaysAuthorization()
        evaluate()
    }

    /// Must be called before BLE. The location background mode is what keeps
    /// the app alive; relying on BLE-only wakeups, which iOS throttles hard,
    /// makes notification delivery to a pocketed phone unreliable.
    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    /// Re-asks for the Always upgrade. iOS shows this at most once per install;
    /// after that the only route is Settings, which is what the UI says.
    func requestAlwaysUpgrade() {
        manager.requestAlwaysAuthorization()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func evaluate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            readiness = .notDetermined
        case .denied, .restricted:
            readiness = .denied
        case .authorizedWhenInUse:
            // Precise is checked first: a reduced-accuracy fix is wrong data,
            // which is worse than no data, so it outranks the background gap.
            readiness = manager.accuracyAuthorization == .reducedAccuracy
                ? .reducedAccuracy : .foregroundOnly
        case .authorizedAlways:
            readiness = manager.accuracyAuthorization == .reducedAccuracy
                ? .reducedAccuracy : .ready
        @unknown default:
            readiness = .denied
        }
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in
            authContinuation?.resume()
            authContinuation = nil
            evaluate()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            // The sentinel filtering lives in FlockCore. Nothing can deliver a
            // delegate callback from a test, and both of CoreLocation's
            // "unavailable" markers -- a -1 speed and a negative
            // horizontalAccuracy -- are real uploaded values if they are missed.
            //
            // Assigned unconditionally, so an invalid fix clears `latest`
            // rather than leaving the last good one standing. `LocationFix`
            // carries no timestamp, so a retained fix is indistinguishable from
            // a current one to everything downstream: `SessionController`
            // stamps whatever is here onto the next sighting, which would put a
            // detection at a place the phone has since driven away from. Losing
            // the position is recoverable -- the sighting is still stored, and
            // the server interpolates it from the surrounding track -- and a
            // confidently wrong coordinate is not.
            latest = LocationFix.fromCoreLocation(
                lat: l.coordinate.latitude,
                lon: l.coordinate.longitude,
                horizontalAccuracy: l.horizontalAccuracy,
                speed: l.speed)
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // A transient failure is normal in a tunnel. The session continues and
        // sightings are stored with a null fix rather than dropped.
    }
}
