import SwiftUI
import FlockCore

/// The management screen reached after signing in.
///
/// It shows real state where real state exists -- the local queue is live, read
/// straight from the SQLite store -- and says plainly what is not built yet
/// rather than faking it. Session control arrives with the BLE and location
/// work in Tasks 13-15.
struct DashboardView: View {
    var onSignedOut: () -> Void

    @StateObject private var location = LocationProvider()
    @StateObject private var peripheral = PeripheralClient()

    @State private var pending = 0
    @State private var camerasTotal = 0
    @State private var camerasSession: Int?      // nil until a session has run
    @State private var labelled = 0
    @State private var storeError: String?

    // Received this launch, in memory only. Not the queue's counts -- those
    // come from SightingStore once Task 15 wires storage -- just proof the
    // radio is live.
    @State private var sightingsSeen = 0
    @State private var labelsSeen = 0

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
            peripheral.onSighting = { _ in sightingsSeen += 1 }
            peripheral.onDeviceLabel = { _ in labelsSeen += 1 }
            peripheral.start()
            await location.requestAuthorization()
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Theme.accent)
            Text("Squawker").displayFont(19, weight: .semibold)
                .foregroundStyle(Theme.ink)
            Spacer()
            Circle().fill(Theme.faint).frame(width: 7, height: 7)
            Text("idle").font(.caption).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassPanel(radius: 999)
        .padding(.horizontal, 18).padding(.top, 6)
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
                    stat("\(sightingsSeen)", "sightings")
                    divider
                    stat("\(labelsSeen)", "device labels")
                }
                Text("Session control arrives with Task 15. This is the live "
                     + "Bluetooth link on its own: a subscribed link with zero "
                     + "counts above means paired-but-idle, not broken -- give it "
                     + "a moment for the first notification.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Button {
                } label: {
                    Text("Start session").fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                }
                .background(Theme.bg3, in: .rect(cornerRadius: Theme.R.md, style: .continuous))
                .foregroundStyle(Theme.faint)
                .disabled(true)
            }
        }
    }

    private var detectorStatusText: String {
        switch peripheral.state {
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
        switch peripheral.state {
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
    /// BLE pairing and session start arrive with Tasks 14-15; this card only
    /// surfaces the permission state they will depend on.
    private var locationCard: some View {
        card(title: "Location", systemImage: "location.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text(locationStatusText)
                    .displayFont(20)
                    .foregroundStyle(locationStatusColor)
                switch location.readiness {
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
                    Button("Allow always") { location.requestAlwaysUpgrade() }
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
        switch location.readiness {
        case .notDetermined:   "Waiting for permission"
        case .denied:          "Location access denied"
        case .reducedAccuracy: "Precise Location required"
        case .foregroundOnly:  "Foreground only"
        case .ready:           "Ready"
        }
    }

    private var locationStatusColor: Color {
        switch location.readiness {
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
                stat("\(pending)", "waiting to upload")
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

    /// Reads the same SQLite store the uploader will use, so these counts are
    /// the real thing rather than a mock -- and they persist across launches.
    private func refresh() {
        do {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = try SightingStore(path: dir.appendingPathComponent("sightings.sqlite").path)
            pending = try store.pendingCount()
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
