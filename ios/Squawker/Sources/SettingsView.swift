import SwiftUI

/// The detector's on-device settings, reachable from `DashboardView` as a
/// sheet. Lets the user adjust volume, brightness, the heartbeat chime and
/// battery saver from the phone instead of the device's three physical
/// buttons.
///
/// Two things this view is careful about:
///
/// - **No write per slider tick.** A continuous drag would flood the BLE
///   link and hammer the device's flash, which persists on every accepted
///   write. Sliders only commit on `onEditingChanged` (the drag ending); a
///   toggle commits immediately because a single tap already is the
///   "finished" gesture.
/// - **No claimed success the app cannot verify.** `PeripheralClient.write`
///   reads the characteristic back and only returns once the republished
///   value matches what was sent -- see its doc comment for why an ATT-level
///   acknowledgement alone is not proof on this hardware. This view always
///   displays `peripheral.deviceSettings`, i.e. what the device actually
///   confirmed, not an unverified local guess.
struct SettingsView: View {
    @ObservedObject var peripheral: PeripheralClient
    @Environment(\.dismiss) private var dismiss

    /// The working copy the controls bind to. Seeded from
    /// `peripheral.deviceSettings` and re-synced whenever that changes --
    /// including the read-back a write triggers -- so an edit that failed to
    /// verify snaps back to what the device actually has.
    @State private var local: DeviceSettings?
    @State private var isCommitting = false
    @State private var queued: DeviceSettings?
    @State private var writeError: String?

    private var isEditable: Bool {
        peripheral.state == .subscribed && local != nil
    }

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(spacing: 18) {
                    if !isEditable {
                        notConnectedCard
                    }
                    volumeCard
                    brightnessCard
                    behaviorCard
                    if let writeError {
                        Text(writeError)
                            .font(.footnote)
                            .foregroundStyle(Theme.heart)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .glassGroup()
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .top) { titleBar }
        }
        .preferredColorScheme(.dark)
        .onAppear { syncFromDevice() }
        .onChange(of: peripheral.deviceSettings) { _, _ in syncFromDevice() }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.accent)
            Text("Device settings").displayFont(19, weight: .semibold)
                .foregroundStyle(Theme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassPanel(radius: 999)
        .padding(.horizontal, 18).padding(.top, 6)
    }

    private var notConnectedCard: some View {
        card(title: "Not connected", systemImage: "antenna.radiowaves.left.and.right.slash") {
            Text("Connect to the detector and let it finish subscribing before "
                 + "changing its settings.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private var volumeCard: some View {
        card(title: "Volume", systemImage: "speaker.wave.2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(Int(local?.volume ?? 0))%")
                    .displayFont(22).foregroundStyle(Theme.ink)
                Slider(
                    value: Binding(
                        get: { Double(local?.volume ?? 0) },
                        set: { local?.volume = UInt8($0.rounded()) }),
                    in: 0...100, step: 1,
                    onEditingChanged: { editing in if !editing { commit() } }
                )
                .tint(Theme.accent)
                .disabled(!isEditable)
            }
        }
    }

    private var brightnessCard: some View {
        card(title: "Brightness", systemImage: "sun.max.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(Int(local?.brightness ?? 0))")
                    .displayFont(22).foregroundStyle(Theme.ink)
                Slider(
                    value: Binding(
                        get: { Double(local?.brightness ?? 0) },
                        set: { local?.brightness = UInt8($0.rounded()) }),
                    in: 0...255, step: 1,
                    onEditingChanged: { editing in if !editing { commit() } }
                )
                .tint(Theme.accent)
                .disabled(!isEditable)
            }
        }
    }

    private var behaviorCard: some View {
        card(title: "Behavior", systemImage: "waveform.path") {
            VStack(spacing: 14) {
                Toggle(isOn: Binding(
                    get: { local?.heartbeatEnabled ?? false },
                    set: { local?.heartbeatEnabled = $0; commit() }
                )) {
                    Text("Heartbeat").foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .disabled(!isEditable)

                hairline

                Toggle(isOn: Binding(
                    get: { local?.batterySaverEnabled ?? false },
                    set: { local?.batterySaverEnabled = $0; commit() }
                )) {
                    Text("Battery saver").foregroundStyle(Theme.ink)
                }
                .tint(Theme.accent)
                .disabled(!isEditable)
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
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

    /// Pulls the working copy back in line with the device's confirmed
    /// state -- on first appearance, and after every read (including the
    /// read-back a write triggers). Never invents a default the device
    /// hasn't actually reported.
    private func syncFromDevice() {
        guard let deviceSettings = peripheral.deviceSettings else { return }
        local = deviceSettings
    }

    /// Commits are serialized to at most one in-flight BLE write: a commit
    /// that arrives while one is outstanding just replaces the queued value
    /// rather than racing it, so a quick drag-then-toggle always converges
    /// on the last thing the user actually asked for.
    private func commit() {
        guard let local else { return }
        if isCommitting {
            queued = local
            return
        }
        isCommitting = true
        Task { await runCommitLoop(local) }
    }

    private func runCommitLoop(_ first: DeviceSettings) async {
        var next: DeviceSettings? = first
        while let settings = next {
            do {
                try await peripheral.write(settings)
                writeError = nil
            } catch {
                writeError = Self.message(for: error)
                // Whatever the device actually confirmed (if anything)
                // arrives through `deviceSettings` regardless of outcome,
                // and `onChange` above pulls `local` back to it. This
                // covers the case where nothing was ever confirmed, so the
                // sheet stops showing an edit the device never accepted.
                local = peripheral.deviceSettings
            }
            next = queued
            queued = nil
        }
        isCommitting = false
    }

    private static func message(for error: Error) -> String {
        if let settingsError = error as? PeripheralClient.SettingsError {
            return settingsError.errorDescription ?? "The write failed."
        }
        return "The write failed: \(error.localizedDescription)"
    }
}
