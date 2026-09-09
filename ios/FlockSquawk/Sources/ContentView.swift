import SwiftUI
import FlockCore

/// Task 11 scaffold. Its only job is to prove the app target builds, links
/// FlockCore, and runs on the device before any hardware code exists.
/// Tasks 12-16 replace this with the real session UI.
struct ContentView: View {
    /// Decoded here, not asserted in a test, because the point is proving the
    /// package is genuinely linked into the app binary -- a build can succeed
    /// with a package that is declared but never actually used.
    private var wireCheck: String {
        var raw = [UInt8](repeating: 0, count: 20)
        raw[4] = 0xB4; raw[5] = 0x1E; raw[6] = 0x52
        raw[7] = 0x0A; raw[8] = 0x0B; raw[9] = 0x0C
        raw[10] = 0xB7                      // -73
        guard let r = SightingRecord(raw) else { return "decode failed" }
        return "\(r.macString) at \(r.rssi) dBm"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
            Text("FlockSquawk").font(.title2.bold())
            Text("FlockCore linked").foregroundStyle(.secondary)
            Text(wireCheck).font(.caption.monospaced())
        }
        .padding()
    }
}
