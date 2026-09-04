import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) parameters for the OAuth 2.0 authorization-code flow.
///
/// Only the `S256` method is produced: `code_challenge = base64url(SHA256(ascii(code_verifier)))`.
/// The verifier is 43–128 characters from the unreserved set `[A-Za-z0-9-._~]`.
public struct PKCE: Sendable, Equatable {
    /// The value of `code_challenge_method`.
    public static let challengeMethod = "S256"
    public static let minVerifierLength = 43
    public static let maxVerifierLength = 128

    /// The secret sent to the token endpoint as `code_verifier`.
    public let verifier: String
    /// The public value sent to the authorization endpoint as `code_challenge`.
    public let challenge: String

    /// Wraps an existing verifier. Returns `nil` if it does not satisfy RFC 7636 §4.1.
    public init?(verifier: String) {
        guard PKCE.isValidVerifier(verifier) else { return nil }
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    private init(unchecked verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// Generates a fresh pair. `byteCount` bytes of entropy become a base64url verifier
    /// (32 bytes → 43 characters, the RFC minimum and the recommended size).
    ///
    /// `randomBytes` is injectable so tests can pin the output; it must return exactly the
    /// requested number of bytes. A generator that returns too few bytes is topped up from the
    /// system generator rather than producing an invalid verifier.
    public static func generate(byteCount: Int = 32, randomBytes: (Int) -> Data = PKCE.secureRandomBytes) -> PKCE {
        let count = Swift.max(32, Swift.min(byteCount, 90))
        var verifier = Base64URL.encode(randomBytes(count))
        verifier.removeAll { !isUnreserved($0) }
        while verifier.count < minVerifierLength {
            verifier += Base64URL.encode(secureRandomBytes(32))
        }
        if verifier.count > maxVerifierLength {
            verifier = String(verifier.prefix(maxVerifierLength))
        }
        return PKCE(unchecked: verifier)
    }

    /// `base64url(SHA256(verifier))`.
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func isValidVerifier(_ verifier: String) -> Bool {
        guard verifier.count >= minVerifierLength, verifier.count <= maxVerifierLength else { return false }
        return verifier.allSatisfy(isUnreserved)
    }

    /// Cryptographically secure bytes from the system generator (`SystemRandomNumberGenerator`).
    public static func secureRandomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(Swift.max(0, count))
        for _ in 0..<Swift.max(0, count) {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return Data(bytes)
    }

    /// An opaque random value suitable for the OAuth `state` and OpenID `nonce` parameters.
    public static func randomURLSafeString(byteCount: Int = 24, randomBytes: (Int) -> Data = PKCE.secureRandomBytes) -> String {
        Base64URL.encode(randomBytes(Swift.max(8, byteCount)))
    }

    private static func isUnreserved(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "." || c == "_" || c == "~")
    }
}
