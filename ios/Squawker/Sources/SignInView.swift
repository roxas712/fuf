import SwiftUI

/// Sign-in gate. Sightings belong to a website account, so nothing else in the
/// app is reachable until there is a token to upload with.
struct SignInView: View {
    var onSignedIn: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    private enum Field { case user, pass }

    var body: some View {
        ZStack {
            Theme.background
            ScrollView {
                VStack(spacing: 28) {
                    header
                    form
                    endpointNote
                }
                .padding(.horizontal, 22)
                .padding(.top, 64)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(0.35), .clear],
                                         center: .center, startRadius: 2, endRadius: 60))
                    .frame(width: 120, height: 120)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: Theme.glow, radius: 18)
            }
            Text("Squawker").displayFont(36, weight: .bold).foregroundStyle(Theme.ink)
            Text("Surveillance camera sightings, mapped.")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            field(icon: "person", placeholder: "Username", text: $username, secure: false)
                .focused($focus, equals: .user)
                .submitLabel(.next)
                .onSubmit { focus = .pass }

            field(icon: "lock", placeholder: "Password", text: $password, secure: true)
                .focused($focus, equals: .pass)
                .submitLabel(.go)
                .onSubmit(signIn)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.heart)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            Button(action: signIn) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(Theme.void) }
                    Text(busy ? "Signing in" : "Sign in").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .background(canSubmit ? Theme.accent : Theme.bg3,
                        in: .rect(cornerRadius: Theme.R.md, style: .continuous))
            .foregroundStyle(canSubmit ? Theme.void : Theme.faint)
            .shadow(color: canSubmit ? Theme.glow.opacity(0.5) : .clear, radius: 16, y: 6)
            .disabled(!canSubmit)
            .animation(.easeOut(duration: 0.18), value: canSubmit)
        }
        .padding(20)
        .glassPanel()
    }

    private var endpointNote: some View {
        // Shown because pointing the app at the wrong server is otherwise
        // invisible until a login mysteriously fails.
        Label(LoginService.baseURL.host() ?? LoginService.baseURL.absoluteString,
              systemImage: "link")
            .font(.caption).foregroundStyle(Theme.faint)
    }

    private func field(icon: String, placeholder: String,
                       text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(Theme.faint).frame(width: 18)
            Group {
                if secure {
                    SecureField("", text: text, prompt: prompt(placeholder))
                } else {
                    TextField("", text: text, prompt: prompt(placeholder))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(Theme.bg2.opacity(0.7),
                    in: .rect(cornerRadius: Theme.R.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.sm, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
    }

    private func prompt(_ s: String) -> Text {
        Text(s).foregroundColor(Theme.faint)
    }

    private var canSubmit: Bool { !username.isEmpty && !password.isEmpty && !busy }

    private func signIn() {
        guard canSubmit else { return }
        busy = true
        error = nil
        focus = nil
        Task {
            do {
                _ = try await LoginService.logIn(.init(user: username, pass: password))
                password = ""                       // never kept past the exchange
                onSignedIn()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
