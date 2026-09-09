import Foundation
import FlockCore

/// Owns the session and everything in it. The UI observes this and makes no
/// CoreBluetooth or CoreLocation calls of its own -- that boundary is what
/// keeps the lifecycle logic reviewable in one place.
///
/// `peripheral` and `location` are exposed, not hidden, so the dashboard can
/// show connection/permission state and reach the device-settings screen --
/// but every state *change* to either still only happens through
/// `start()`/`stop()` below.
@MainActor
final class SessionController: ObservableObject {
    enum Status: Equatable {
        case idle
        case blocked(String)
        case running
    }

    @Published private(set) var status: Status = .idle
    /// Since app launch, not just this session -- proof the radio and store
    /// are alive even across a stop/start within one run of the app.
    @Published private(set) var sightingCount = 0
    @Published private(set) var labelsSeen = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastError: String?

    let peripheral = PeripheralClient()
    let location = LocationProvider()

    /// `nil` only if the local store failed to open (disk full, an unusual
    /// sandbox state). `SightingStore.init` throws, but `@StateObject` has no
    /// throwing initializer for a SwiftUI view to call, so this class cannot
    /// declare `init() throws` itself without pushing that problem onto every
    /// call site. Failing open instead -- store `nil`, `status` pre-seeded
    /// `.blocked` -- keeps the rest of the dashboard (account, settings)
    /// usable and says exactly what is wrong, rather than the whole screen
    /// refusing to construct.
    private var store: SightingStore?
    private var uploader: Uploader?
    /// One-shot latch: see the comment on `refreshUploaderDeviceIDIfNeeded()`.
    private var uploaderDeviceIDKnown = false

    private var sessionID = ""
    private var seq = 0
    private var bootEpoch = BootEpoch()
    private var uploadTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try SightingStore(path: dir.appendingPathComponent("sightings.sqlite").path)
        } catch {
            store = nil
            status = .blocked("Local storage is unavailable: \(error)")
        }
        pendingCount = (try? store?.pendingCount()) ?? 0

        peripheral.onSighting    = { [weak self] in self?.handle($0) }
        peripheral.onDeviceLabel = { [weak self] in self?.handle($0) }

        closeOrphanedSessionIfAny()
    }

    /// Starting while a session runs is a no-op, not an error -- the UI just
    /// reflects the session already going.
    func start() async {
        guard status != .running else { return }
        guard let store else { return }   // reason already in `status`, from init

        await location.requestAuthorization()
        guard location.readiness.canStartSession else {
            status = .blocked(blockedReason(for: location.readiness))
            return
        }
        // `.foregroundOnly` falls through here too -- it is a real, working
        // state (see `LocationProvider.Readiness`), not a block. It works
        // with the screen on; the dashboard's location card is what surfaces
        // the "stops recording once the phone locks" caveat, as a warning
        // rather than a refusal.

        sessionID = UUID().uuidString
        try? store.openSession(id: sessionID, startedAt: Date().timeIntervalSince1970)
        seq = 0
        bootEpoch = BootEpoch()
        lastError = nil
        uploaderDeviceIDKnown = false

        let startedAt = Date().timeIntervalSince1970
        SessionMemory.currentSessionID = sessionID
        SessionMemory.currentSessionLastActivity = startedAt

        // `peripheral.deviceID` is still nil here: BLE has not connected yet
        // (it connects after `peripheral.start()`, below, and does so
        // asynchronously). `refreshUploaderDeviceIDIfNeeded()` corrects this
        // the moment it becomes known, instead of uploading the whole
        // session under a permanently blank device id.
        uploader = makeUploader(store: store, deviceID: peripheral.deviceID)

        // Location first, then BLE. The location background mode is what
        // keeps the app alive, which is what makes BLE delivery reliable
        // when the phone is locked.
        location.start()
        // peripheral.start() is NOT called here -- see connectDetector().
        status = .running
        startUploadLoop()
    }

    /// Connects to the detector, independent of any session.
    ///
    /// The link is not part of recording. Adjusting the device's volume or
    /// brightness from the phone -- the reason the settings characteristic
    /// exists -- should not require starting a session, because a session also
    /// turns on continuous GPS at roughly 10-15% battery per hour. Sightings
    /// that arrive while no session is running are counted for display and
    /// deliberately not stored: they have no session to belong to.
    func connectDetector() {
        peripheral.start()
    }

    func stop() {
        // Close the row before tearing down, so a clean stop is distinguishable
        // from a crash on next launch.
        if status == .running, let store {
            let endedAt = (try? store.lastObservedAt(inSession: sessionID))
                ?? Date().timeIntervalSince1970
            try? store.closeSession(id: sessionID, endedAt: endedAt)
        }
        // The detector link outlives the session, deliberately: settings are
        // adjustable without recording. See connectDetector().
        location.stop()
        uploadTask?.cancel()
        uploadTask = nil
        status = .idle
        // Marks the session closed cleanly -- see the comment on
        // `SessionMemory.currentSessionLastActivity`. `currentSessionID`
        // itself is left alone: it still correctly names the session that
        // just ended for anything (e.g. the dashboard's "cameras this
        // session" stat) that wants to describe it after the fact.
        SessionMemory.currentSessionLastActivity = nil
        Task { [weak self] in await self?.drain() }
    }

    private func blockedReason(for readiness: LocationProvider.Readiness) -> String {
        switch readiness {
        case .denied:
            return "Location access is required to place detections on a map."
        case .reducedAccuracy:
            // Blocking on purpose. With Precise Location off, fixes are
            // accurate to a kilometre or worse, and the app would keep
            // working, keep uploading, and produce a map that is
            // confidently wrong.
            return "Turn on Precise Location in Settings. Without it, camera "
                 + "positions would be wrong by up to a kilometre."
        case .notDetermined:
            return "Location permission was not granted."
        case .foregroundOnly, .ready:
            // Unreachable: both make `canStartSession` true, so `start()`
            // never calls this for them. Written out anyway, rather than
            // `default:`, so a future case added to `Readiness` fails to
            // compile here instead of silently returning a blank reason.
            return ""
        }
    }

    /// If the app was killed while a session was running, `SessionMemory`
    /// still names it: a clean `stop()` always clears
    /// `currentSessionLastActivity`, so finding it still set here means the
    /// app never reached that. That old session is closed now, using the
    /// last time it is known to have done anything -- never "now", which
    /// could be hours after an overnight interruption actually ended it.
    ///
    /// This does not touch a `sessions` row: `SightingStore` exposes no way
    /// to write `started_at`/`ended_at` for one, and FlockCore is not this
    /// task's to change. "Closing" here means: stop treating the id as an
    /// open session, and say so, rather than silently carrying it forward
    /// into whatever the user starts next.
    private func closeOrphanedSessionIfAny() {
        guard let store else { return }
        do {
            guard let orphan = try store.openSessionID() else { return }
            // ended_at from the last sighting it actually recorded, not from
            // now: a session interrupted overnight would otherwise appear to
            // have run for hours.
            let endedAt = try store.lastObservedAt(inSession: orphan)
                ?? Date().timeIntervalSince1970
            try store.closeSession(id: orphan, endedAt: endedAt)
            SessionMemory.currentSessionID = nil
            SessionMemory.currentSessionLastActivity = nil
            let when = DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: endedAt),
                dateStyle: .short, timeStyle: .short)
            lastError = "The previous session ended unexpectedly around \(when), when the "
                + "app stopped. Its sightings are still queued and will upload."
        } catch {
            lastError = "Could not close the previous session: \(error)"
        }
    }

    private func makeUploader(store: SightingStore, deviceID: String?) -> Uploader {
        Uploader(
            store: store,
            http: URLSessionHTTPClient(),
            endpoint: LoginService.baseURL.appendingPathComponent("api/flock/sightings"),
            token: { TokenStore.load() },
            deviceID: deviceID)
    }

    /// `Uploader.deviceID` is captured once, at construction, and there is no
    /// way to hand it a later value -- so building the uploader in `start()`,
    /// before BLE has connected, means it would otherwise upload this whole
    /// session under a permanently nil device id. Any notification proves
    /// the device is connected and identified (`PeripheralClient` sets
    /// `deviceID` in `didConnect`, strictly before discovery or a
    /// subscription that could ever deliver one), so this rebuilds the
    /// uploader -- same store, same endpoint, same token, fresh backoff --
    /// the first time that becomes true. A one-shot latch, not a check run
    /// every notification: once known, `peripheral.deviceID` does not change
    /// again for the life of one BLE connection.
    private func refreshUploaderDeviceIDIfNeeded() {
        guard !uploaderDeviceIDKnown, let store, let deviceID = peripheral.deviceID else { return }
        uploaderDeviceIDKnown = true
        uploader = makeUploader(store: store, deviceID: deviceID)
    }

    private func handle(_ record: SightingRecord) {
        // Counted whenever the detector is linked, so the dashboard shows the
        // radio working before a session starts.
        sightingCount += 1
        // Stored only while recording: a sighting outside a session has no
        // session_id, and the server's schema requires one.
        guard status == .running, let store else { return }
        refreshUploaderDeviceIDIfNeeded()
        seq += 1
        let observedAt = Date().timeIntervalSince1970
        let epoch = bootEpoch.observe(record, at: observedAt)
        let s = Sighting(record: record, sessionID: sessionID, seq: seq,
                         observedAt: observedAt,
                         bootEpoch: epoch, fix: location.latest)
        do {
            try store.insert(s)
            sightingCount += 1
            SessionMemory.currentSessionLastActivity = observedAt
            // Counted in memory, not re-queried. pendingCount() is
            // SELECT COUNT(*) over the pending index; at ~2 notifications
            // per second per camera, with several in range, running it per
            // notification scans the whole backlog ~20x/sec on the main
            // actor -- worst exactly when the backlog is large and the UI
            // is busy. The upload loop re-syncs it from SQL.
            pendingCount += 1
            if store.backlogIsAlarming(count: pendingCount) {
                lastError = "\(pendingCount) sightings are waiting to upload. "
                    + "Check your connection and login."
            }
        } catch StoreError.duplicate {
            // Only reachable if seq were reused within a session, which
            // cannot happen while seq is monotonic. Swallowed rather than
            // crashing a background callback.
        } catch {
            lastError = "Could not save a sighting: \(error)"
        }
    }

    private func handle(_ label: DeviceLabel) {
        guard let store else { return }
        refreshUploaderDeviceIDIfNeeded()
        try? store.recordLabel(mac: label.mac, label: label.label, radio: 0,
                               at: Date().timeIntervalSince1970)
        labelsSeen += 1
    }

    /// Uploads on a loop, respecting the backoff the uploader returns rather
    /// than a fixed interval. Every `UploadOutcome` case is handled by name,
    /// not a wildcard, so a case a future change adds to that enum fails to
    /// compile here instead of being silently swallowed by `default:`.
    private func startUploadLoop() {
        uploadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var wait: Double = 15
                do {
                    // Read fresh each time through `self.uploader`, rather
                    // than a captured local -- `refreshUploaderDeviceIDIfNeeded()`
                    // swaps that property out from under this loop, and the
                    // swap is meant to take effect on the very next tick.
                    switch try await self.uploader?.uploadOnce() {
                    case .uploaded:
                        wait = 1                       // drain fast while there is more
                    case .nothingToDo, .none:
                        wait = 15
                    case .authExpired:
                        self.lastError = "Your login expired. Sign in again to resume uploads."
                        wait = 60
                    case .quarantined(let seqs, let reason):
                        self.lastError = "\(seqs.count) sighting(s) were rejected: \(reason)"
                        wait = 1
                    case .retryLater(let after):
                        wait = after
                    }
                    self.pendingCount = (try? self.store?.pendingCount()) ?? self.pendingCount
                } catch {
                    wait = 30
                }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Flush on stop. Bounded so a long backlog cannot spin forever.
    private func drain() async {
        guard let uploader else { return }
        for _ in 0..<20 {
            guard let outcome = try? await uploader.uploadOnce() else { return }
            if outcome == .nothingToDo { break }
        }
        pendingCount = (try? store?.pendingCount()) ?? pendingCount
    }

    /// Uploaded records older than 30 days go; never-uploaded records never do.
    func pruneOldRecords() {
        guard let store else { return }
        let cutoff = Date().timeIntervalSince1970 - 30 * 86_400
        _ = try? store.prune(uploadedBefore: cutoff)
    }
}
