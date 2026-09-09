import Foundation

/// A `DeviceInfo` notification: 46 bytes, MAC then a null-padded identifier.
///
///     [0..5]   mac
///     [6..44]  identifier, UTF-8, null-padded to 39 bytes
///     [45]     zero
///
/// Sent once per MAC per connection, immediately before that MAC's first
/// Sighting, and skipped entirely when the identifier is empty (a hidden SSID
/// has nothing to say). Treat it as a one-shot: store it, do not wait for more.
public struct DeviceLabel: Equatable, Sendable {
    public static let byteCount = 46

    public let mac: String
    /// nil rather than "" when the device sent no identifier, so an empty
    /// payload can never overwrite a label already on file.
    public let label: String?

    public init?(_ raw: [UInt8]) {
        guard raw.count == Self.byteCount else { return nil }
        mac = raw[0...5].map { String(format: "%02x", $0) }.joined(separator: ":")
        let field = Array(raw[6...44])
        let text = String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
        label = text.isEmpty ? nil : text
    }
}
