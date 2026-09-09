import Foundation

/// Exchanges your backend credentials for a bearer token.
///
/// This is the website account (the `users` table), not the launcher's game
/// account. They are separate identities with separate tokens; a game token
/// will not authenticate here.
struct LoginService {
    /// Read from Info.plist, which xcodegen fills from `BACKEND_BASE_URL` in
    /// `Signing.local.xcconfig` -- gitignored, like the signing team.
    ///
    /// **That setting must use `$(SLASH)` for the double slash**, because
    /// xcconfig treats `//` as a comment and silently truncates
    /// `https://host` to `https:` with no warning at build or run time. The
    /// fatalError below is what turns that into something legible. The
    /// committed default is a placeholder: this is a public repo and it should
    /// not name anyone's deployment, and anyone else running their own backend
    /// needs to point it somewhere else anyway.
    static let baseURL: URL = {
        let s = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        guard let s, !s.isEmpty, let url = URL(string: s) else {
            fatalError("BackendBaseURL is unset. Copy Signing.local.xcconfig.example "
                     + "to Signing.local.xcconfig, set BACKEND_BASE_URL, and re-run "
                     + "`xcodegen generate`.")
        }
        return url
    }()

    struct Credentials { let user: String; let pass: String }

    enum LoginError: Error, LocalizedError {
        case badCredentials
        case noToken
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .badCredentials: "Incorrect username or password."
            case .noToken: "The server accepted the login but issued no token."
            case .server(let code): "The server returned \(code)."
            }
        }
    }

    /// Returns the token and stores it. The password is never persisted.
    static func logIn(_ c: Credentials) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["user": c.user, "pass": c.pass])

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw LoginError.badCredentials }
        guard status == 200 else { throw LoginError.server(status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw LoginError.noToken
        }
        TokenStore.save(token)
        return token
    }
}
