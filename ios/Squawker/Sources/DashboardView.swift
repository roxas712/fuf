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

    @State private var pending = 0
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
        .task { refresh() }
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
                Text("Not connected")
                    .displayFont(24).foregroundStyle(Theme.ink)
                Text("Bluetooth pairing, location and session control arrive with "
                     + "the next tasks. The screen is here so the shape of the app "
                     + "is real before the radios are.")
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
