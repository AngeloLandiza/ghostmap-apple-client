import Foundation

/// Base64url (RFC 4648 §5): the base64 alphabet with `-`/`_` instead of `+`/`/` and no padding.
///
/// Used by PKCE (verifier and challenge) and by JWT inspection.
public enum Base64URL: Sendable {

    /// Encodes bytes as unpadded base64url.
    public static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// Decodes unpadded (or padded) base64url. Returns `nil` for input that is not valid base64url.
    public static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }
        var s = string.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}
