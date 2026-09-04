import Foundation
import MapCore

/// Backend-related preferences, persisted in `UserDefaults` (nothing secret lives here — the
/// token and the device identity are in the keychain).
struct CloudSettings: Sendable, Equatable {
    /// The backend the app talks to. Stored as typed, normalised on save.
    var backendURLString: String = BackendURL.productionString
    /// Sign in as *this phone* (a 30-day `device` token that may map) rather than as a viewer.
    var signInAsMapper = true
    /// Show the account chooser every time instead of reusing the browser's Google session.
    var alwaysChooseAccount = false
    /// Upload every map to the backend right after it finalizes (Phase 2 §5). Off by default: a
    /// map always stays on the phone either way, so this only matters to a signed-in mapper who
    /// wants the round trip automatic. `MapDetailView`'s Upload button works regardless.
    var autoUpload = false

    /// The validated URL, or `nil` when the field holds something unusable.
    var backendURL: URL? { try? BackendURL.normalized(backendURLString) }

    /// The URL to talk to, falling back to production when the stored string is unusable.
    static func resolvedURL(_ raw: String) throws(BackendURL.ValidationError) -> URL {
        if let url = try? BackendURL.normalized(raw) { return url }
        return try BackendURL.normalized(BackendURL.productionString)
    }

    private static let key = "tech.alandiza.roommapper.cloudSettings"

    static func load(defaults: UserDefaults = .standard) -> CloudSettings {
        guard let d = defaults.dictionary(forKey: key) else { return CloudSettings() }
        var s = CloudSettings()
        if let url = d["backendURLString"] as? String, !url.isEmpty { s.backendURLString = url }
        s.signInAsMapper = d["signInAsMapper"] as? Bool ?? s.signInAsMapper
        s.alwaysChooseAccount = d["alwaysChooseAccount"] as? Bool ?? s.alwaysChooseAccount
        s.autoUpload = d["autoUpload"] as? Bool ?? s.autoUpload
        return s
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set([
            "backendURLString": backendURLString,
            "signInAsMapper": signInAsMapper,
            "alwaysChooseAccount": alwaysChooseAccount,
            "autoUpload": autoUpload,
        ], forKey: CloudSettings.key)
    }
}
