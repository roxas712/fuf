import SwiftUI

/// Routes on whether a token exists. Keychain-backed, so a returning user with
/// a stored token lands on the dashboard without signing in again.
struct RootView: View {
    @State private var signedIn = TokenStore.load() != nil

    var body: some View {
        Group {
            if signedIn {
                DashboardView { signedIn = false }
            } else {
                SignInView { signedIn = true }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: signedIn)
    }
}
