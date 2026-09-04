import Foundation

/// Validation and construction of Ghostmap backend URLs.
public enum BackendURL: Sendable {

    public enum ValidationError: Error, Sendable, Equatable {
        case empty
        case malformed
        case unsupportedScheme(String)
        case missingHost
        case containsQueryOrFragment
    }

    /// The deployed backend.
    public static let productionString = "https://ghostmap-backend.vercel.app"

    /// Accepts `host`, `host/path`, `http://…` and `https://…`; defaults to `https` when the
    /// scheme is missing, lowercases scheme and host, and strips a trailing slash. Rejects
    /// anything with a query or fragment, a non-HTTP scheme, or no host.
    public static func normalized(_ raw: String) throws(ValidationError) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var components = URLComponents(string: withScheme) else { throw .malformed }
        guard let scheme = components.scheme?.lowercased() else { throw .malformed }
        guard scheme == "https" || scheme == "http" else { throw .unsupportedScheme(scheme) }
        guard let host = components.host, !host.isEmpty else { throw .missingHost }
        guard components.query == nil, components.fragment == nil else { throw .containsQueryOrFragment }
        components.scheme = scheme
        components.host = host.lowercased()
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else { throw .malformed }
        return url
    }

    public static func isValid(_ raw: String) -> Bool {
        (try? normalized(raw)) != nil
    }

    /// `base` + `path` (+ sorted query items). Query values are percent-encoded by `URLComponents`.
    public static func endpoint(base: URL, path: String, query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + suffix
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    /// A short display form for the settings screen: host plus path, without the scheme.
    public static func displayString(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else {
            return url.absoluteString
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return host + port + components.path
    }
}
