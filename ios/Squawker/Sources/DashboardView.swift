import SwiftUI
import FlockCore

/// The management screen reached after signing in.
///
/// It shows real state where real state exists -- the local queue is live, read
/// straight from the SQLite store. Session control itself belongs to
/// `SessionController`: this view only observes it and drives it through
/// `start()`/`stop()`.
struct DashboardView: View {
    var onSignedOut: () -> Void

    // Owns BLE, location, the store, and the upload loop. The dashboard only
    // observes it and drives it through start()/stop() -- it makes no
    // CoreBluetooth or CoreLocation calls of its own.
    @StateObject private var session = SessionController()

    @State private var showingDeviceSettings = false

    @State private var camerasTotal = 0
    @State private var camerasSession: Int?      // nil until a session has run
    @State private var labelled = 0
    @State private var storeError: String?

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(spacing: 18) {
                    detectorCard
                    locationCard
                    camerasCard
                    queueCard
                    accountCard
                }
                .glassGroup()
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .top) { titleBar }
        }
        .preferredColorScheme(.dark)
        .task {
            refresh()
            await session.location.requestAuthorization()
        }
        .onChange(of: session.status) { _, newStatus in
            // Recount once a session stops, so "cameras this session" and
            // the all-time stats catch up with what it just recorded.
            if newStatus != .running { refresh() }
        }
        .sheet(isPresented: $showingDeviceSettings) {
            SettingsView(peripheral: session.peripheral)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Theme.accent)
            Text("Squawker").displayFont(19, weight: .semibold)
                .foregroundStyle(Theme.ink)
            Spacer()
            Circle().fill(titleBarDotColor).frame(width: 7, height: 7)
            Text(titleBarStatusText).font(.caption).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassPanel(radius: 999)
        .padding(.horizontal, 18).padding(.top, 6)
    }

    private var titleBarDotColor: Color {
        switch session.status {
        case .idle:    Theme.faint
        case .running: Theme.green
        case .blocked: Theme.heart
        }
    }

    private var titleBarStatusText: String {
        switch session.status {
        case .idle:    "idle"
        case .running: "recording"
        case .blocked: "blocked"
        }
    }

    private var detectorCard: some View {
        card(title: "Detector", systemImage: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(detectorStatusColor).frame(width: 8, height: 8)
                    Text(detectorStatusText)
                        .displayFont(22).foregroundStyle(Theme.ink)
                }
                HStack(spacing: 0) {
                    stat("\(session.sightingCount)", "sightings")
                    divider
                    stat("\(session.labelsSeen)", "device labels")
                }
                detectorFootnote
                Button {
                    Task {
                        if session.status == .running { session.stop() }
                        else { await session.start() }
                    }
                } label: {
                    Text(session.status == .running ? "Stop session" : "Start session")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .buttonStyle(PrimaryActionStyle(enabled: true))

                Button {
                    showingDeviceSettings = true
                } label: {
                    Text("Device settings")
                }
                .buttonStyle(PrimaryActionStyle(enabled: true))
            }
        }
    }

    /// Whatever is most relevant right now: a block reason outranks a
    /// transient error, which outranks the steady-state explanation of what
    /// zero counts above actually mean.
    @ViewBuilder
    private var detectorFootnote: some View {
        if case .blocked(let reason) = session.status {
            Text(reason).font(.footnote).foregroundStyle(Theme.heart)
        } else if let lastError = session.lastError {
            Text(lastError).font(.footnote).foregroundStyle(Theme.gold)
        } else {
            Text("A subscribed link with zero counts above means paired-but-idle, "
                 + "not broken -- give it a moment for the first notification.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private var detectorStatusText: String {
        switch session.peripheral.state {
        case .idle:          "Not connected"
        case .poweredOff:    "Bluetooth is off"
        case .unauthorized:  "Bluetooth access denied"
        case .scanning:      "Scanning\u{2026}"
        case .connecting:    "Connecting\u{2026}"
        case .connected:     "Connected, subscribing\u{2026}"
        case .subscribed:    "Subscribed"
        case .needsRepair:   "Needs re-pairing"
        }
    }

    private var detectorStatusColor: Color {
        switch session.peripheral.state {
        case .subscribed:                     Theme.green
        case .needsRepair, .unauthorized:     Theme.heart
        case .poweredOff:                     Theme.gold
        case .idle, .scanning, .connecting,
             .connected:                      Theme.faint
        }
    }

    /// Reflects `LocationProvider.readiness` and, when Precise Location is
    /// off, blocks rather than warns: a map built from reduced-accuracy fixes
    /// is confidently wrong, which is worse than the app refusing outright.
    private var locationCard: some View {
        card(title: "Location", systemImage: "location.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(locationStatusText)
                    .displayFont(20)
                    .foregroundStyle(locationStatusColor)
                switch session.location.readiness {
                case .reducedAccuracy:
                    Text("Precise Location is off, so camera positions can't be "
                         + "trusted. Turn it on in Settings \u{2192} Privacy & "
                         + "Security \u{2192} Location Services \u{2192} Squawker "
                         + "before starting a session.")
                        .font(.footnote).foregroundStyle(Theme.heart)

                case .foregroundOnly:
                    // Not blocking: this genuinely works with the screen on. But
                    // it stops recording the moment the phone locks, and that
                    // failure is silent, so it has to be visible here.
                    Text("Sightings will only be recorded while the app is open. "
                         + "iOS asks for background access after the app has used "
                         + "location for a while \u{2014} or you can grant it now.")
                        .font(.footnote).foregroundStyle(Theme.gold)
                    Button("Allow always") { session.location.requestAlwaysUpgrade() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)

                case .denied:
                    Text("Sightings cannot be placed on a map without location. "
                         + "Enable it in Settings \u{2192} Privacy & Security.")
                        .font(.footnote).foregroundStyle(Theme.heart)

                case .notDetermined, .ready:
                    EmptyView()
                }
            }
        }
    }

    private var locationStatusText: String {
        switch session.location.readiness {
        case .notDetermined:   "Waiting for permission"
        case .denied:          "Location access denied"
        case .reducedAccuracy: "Precise Location required"
        case .foregroundOnly:  "Foreground only"
        case .ready:           "Ready"
        }
    }

    private var locationStatusColor: Color {
        switch session.location.readiness {
        case .reducedAccuracy, .denied: Theme.heart
        case .foregroundOnly:           Theme.gold
        case .notDetermined:            Theme.muted
        case .ready:                    Theme.ink
        }
    }

    private var camerasCard: some View {
        card(title: "Cameras seen", systemImage: "video.badge.waveform") {
            HStack(spacing: 0) {
                stat(camerasSession.map(String.init) ?? "—", "this session")
                divider
                stat("\(camerasTotal)", "all time")
            }
            // Counted from distinct MACs in the sightings, not from the devices
            // table: the detector sends no DeviceInfo for a hidden SSID, so a
            // count of named devices would silently miss those cameras.
            if camerasTotal > labelled {
                Text("\(camerasTotal - labelled) with no broadcast name")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
            if camerasSession == nil {
                Text("No session has run yet.")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
        }
    }

    private var queueCard: some View {
        card(title: "Local queue", systemImage: "tray.full") {
            HStack(spacing: 0) {
                stat("\(session.pendingCount)", "waiting to upload")
                divider
                stat("\(labelled)", "named devices")
            }
            if let storeError {
                Text(storeError).font(.caption).foregroundStyle(Theme.heart)
            }
        }
    }

    private var accountCard: some View {
        card(title: "Account", systemImage: "person.crop.circle") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signed in").foregroundStyle(Theme.ink)
                    Text(LoginService.baseURL.host() ?? "")
                        .font(.caption).foregroundStyle(Theme.faint)
                }
                Spacer()
                Button("Sign out") {
                    TokenStore.clear()
                    onSignedOut()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.heart)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 34)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).displayFont(30, weight: .bold).foregroundStyle(Theme.accent)
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func card<C: View>(title: String, systemImage: String,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassPanel()
    }

    /// Reads a second, independent connection to the same SQLite file the
    /// session's own store uses -- safe under WAL, and simpler than reaching
    /// into `SessionController`'s private store just for these all-time,
    /// occasionally-refreshed counts. `session.pendingCount` is the live
    /// figure the queue card actually shows; this fills in what it does not
    /// track (all-time and per-session camera counts, named-device count).
    private func refresh() {
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = try SightingStore(path: dir.appendingPathComponent("sightings.sqlite").path)
            camerasTotal = try store.camerasSeen()
            labelled = try store.deviceCount()
            if let id = SessionMemory.currentSessionID {
                camerasSession = try store.camerasSeen(inSession: id)
            }
        } catch {
            storeError = "Local store unavailable: \(error)"
        }
    }
}
