import Foundation

/// A participant colour, as the backend hands it out (`PARTICIPANT_COLORS` in `src/lib/parties.ts`):
/// eight hex strings handed out in join order and kept across rejoins.
///
/// The app uses it three ways: the dot next to a name, the tint mixed into a peer's streamed points
/// so two clouds can be told apart, and the peer's frustum colour.
public struct PartyColor: Sendable, Equatable, Hashable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#38bdf8`, `38bdf8`, `#38BDF8FF` (alpha ignored) and the 3-digit short form all parse.
    /// Returns nil for anything else.
    public init?(hex raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        let digits = Array(text)
        guard digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        func value(_ index: Int) -> UInt8? {
            guard let high = digits[index].hexDigitValue, let low = digits[index + 1].hexDigitValue else { return nil }
            return UInt8(high << 4 | low)
        }
        switch digits.count {
        case 3:
            guard let r = digits[0].hexDigitValue, let g = digits[1].hexDigitValue, let b = digits[2].hexDigitValue else { return nil }
            self.init(r: UInt8(r << 4 | r), g: UInt8(g << 4 | g), b: UInt8(b << 4 | b))
        case 6, 8:
            guard let r = value(0), let g = value(2), let b = value(4) else { return nil }
            self.init(r: r, g: g, b: b)
        default:
            return nil
        }
    }

    /// The backend's palette, in join order.
    public static let palette: [PartyColor] = [
        PartyColor(r: 0x38, g: 0xbd, b: 0xf8),
        PartyColor(r: 0xf4, g: 0x72, b: 0xb6),
        PartyColor(r: 0xfa, g: 0xcc, b: 0x15),
        PartyColor(r: 0x4a, g: 0xde, b: 0x80),
        PartyColor(r: 0xa7, g: 0x8b, b: 0xfa),
        PartyColor(r: 0xfb, g: 0x92, b: 0x3c),
        PartyColor(r: 0x22, g: 0xd3, b: 0xee),
        PartyColor(r: 0xf8, g: 0x71, b: 0x71),
    ]

    /// The palette entry for a join index, wrapping. Used when a participant row carries no colour.
    public static func palette(index: Int) -> PartyColor {
        let count = palette.count
        let wrapped = ((index % count) + count) % count
        return palette[wrapped]
    }

    /// The participant's colour: the hex the backend sent when it parses, otherwise the palette
    /// entry for `index` so every peer still gets a distinct, stable colour offline.
    public static func resolve(hex: String?, index: Int) -> PartyColor {
        if let hex, let parsed = PartyColor(hex: hex) { return parsed }
        return palette(index: index)
    }

    public var hexString: String {
        String(format: "#%02x%02x%02x", Int(r), Int(g), Int(b))
    }

    /// Components in `0...1`, for SwiftUI and Metal.
    public var components: (r: Float, g: Float, b: Float) {
        (Float(r) / 255, Float(g) / 255, Float(b) / 255)
    }

    /// `PackedPoint`-style RGBA (`r | g << 8 | b << 16 | a << 24`).
    public func packedColor(alpha: UInt8 = 255) -> UInt32 {
        PackedPoint.packColor(r: r, g: g, b: b, a: alpha)
    }

    /// Blends a captured colour toward this one. `mix` 0 keeps the photograph, 1 replaces it with
    /// the flat party colour; the default keeps enough of the original that surfaces are still
    /// readable while the owner stays obvious.
    public func tint(r source: UInt8, g sourceG: UInt8, b sourceB: UInt8, mix: Float = 0.55) -> (r: UInt8, g: UInt8, b: UInt8) {
        let k = min(max(mix, 0), 1)
        func blend(_ a: UInt8, _ b: UInt8) -> UInt8 {
            let value = Float(a) * (1 - k) + Float(b) * k
            return UInt8(min(255, max(0, value.rounded())))
        }
        return (blend(source, r), blend(sourceG, g), blend(sourceB, b))
    }

    /// The same blend applied to a packed point, keeping its position.
    public func tinted(_ point: PackedPoint, mix: Float = 0.55) -> PackedPoint {
        let (r, g, b) = tint(r: point.r, g: point.g, b: point.b, mix: mix)
        return PackedPoint(position: point.position, r: r, g: g, b: b, a: point.a)
    }
}
