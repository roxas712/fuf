import Foundation

public struct HTTPReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The seam that keeps `Uploader` testable with no network. `URLSession` is not
/// mockable directly without subclassing its internals; a protocol this narrow
/// is cheaper and states exactly what the uploader needs.
public protocol HTTPClient: Sendable {
    func post(url: URL, body: Data, bearer: String?) async throws -> HTTPReply
}

/// The real transport.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func post(url: URL, body: Data, bearer: String?) async throws -> HTTPReply {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPReply(status: status, body: data)
    }
}
