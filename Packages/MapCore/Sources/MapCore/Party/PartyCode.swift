import Foundation

/// Party invite codes, share links and the `ghostmap://join/<code>` URL scheme.
///
/// The backend mints 8 uppercase RFC 4648 base32 characters (`A-Z`, `2-7`) and normalises the same
/// way (`normalizeInviteCode` in `src/lib/parties.ts`): trim, uppercase, drop spaces and dashes.
/// This type adds the two substitutions a person typing a code off a screen actually makes — `0`
/// for `O` and `1` for `I` — because neither digit exists in the alphabet, so the mapping can never
/// turn one valid code into another.
public enum PartyCode: Sendable {

    /// How many characters a code has.
    public static let length = 8
    /// RFC 4648 base32, uppercase, no padding — the alphabet the backend generates from.
    public static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    /// The app's custom URL scheme (`CFBundleURLTypes` in Info.plist).
    public static let urlScheme = "ghostmap"
    /// The host of a join link: `ghostmap://join/<code>`, and the path segment of a share link.
    public static let joinPath = "join"

    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case wrongLength(Int)
        case invalidCharacter(Character)

        public var description: String {
            switch self {
            case .empty:
                return "Enter the party code."
            case .wrongLength(let count):
                return "A party code has \(PartyCode.length) characters (you entered \(count))."
            case .invalidCharacter(let character):
                return "\"\(character)\" is not part of a party code."
            }
        }
    }

    /// Trims, uppercases, removes spaces, dashes and underscores, and folds `0` → `O`, `1` → `I`.
    /// Does not check the length, so it is safe to call on every keystroke.
    public static func normalized(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw.uppercased() {
            switch character {
            case " ", "-", "_", "\t", "\n":
                continue
            case "0":
                out.append("O")
            case "1":
                out.append("I")
            default:
                out.append(character)
            }
        }
        return out
    }

    /// The normalised code, or the reason it cannot be one.
    public static func validated(_ raw: String) throws(ValidationError) -> String {
        let code = normalized(raw)
        guard !code.isEmpty else { throw .empty }
        guard code.count == length else { throw .wrongLength(code.count) }
        for character in code where !alphabet.contains(character) {
            throw .invalidCharacter(character)
        }
        return code
    }

    public static func isValid(_ raw: String) -> Bool {
        (try? validated(raw)) != nil
    }

    /// `ABCD2345` → `ABCD 2345`, which is how the party screen shows it.
    public static func formatted(_ raw: String) -> String {
        let code = normalized(raw)
        guard code.count == length else { return code }
        let middle = code.index(code.startIndex, offsetBy: length / 2)
        return code[code.startIndex..<middle] + " " + code[middle...]
    }

    /// `ghostmap://join/<code>`, the link the QR code carries when there is no dashboard URL.
    public static func appURL(code: String) -> URL? {
        guard let code = try? validated(code) else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = joinPath
        components.path = "/" + code
        return components.url
    }

    /// The code in `ghostmap://join/<code>` or in any `…/join/<code>` share link, or nil.
    ///
    /// Both spellings the URL parser can produce are accepted: `ghostmap://join/CODE` (host `join`,
    /// path `/CODE`) and `ghostmap:join/CODE` (no host, path `join/CODE`).
    public static func code(from url: URL) -> String? {
        var segments = url.path.split(separator: "/").map(String.init)
        if let host = url.host, !host.isEmpty { segments.insert(host, at: 0) }
        guard let last = segments.last else { return nil }
        // Only accept the last segment when it really follows a `join` segment (or is the whole path
        // of a `ghostmap://` URL), so an unrelated deep link does not look like an invite.
        let isJoin = segments.count >= 2 && segments[segments.count - 2].lowercased() == joinPath
        guard isJoin || (segments.count == 1 && url.scheme?.lowercased() == urlScheme) else { return nil }
        return try? validated(last)
    }
}
