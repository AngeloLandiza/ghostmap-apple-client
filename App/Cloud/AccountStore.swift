import Foundation
import MapCore
import Observation
import UIKit
import os

/// The signed-in Ghostmap account and this phone's identity.
///
/// The backend token lives in the keychain (`StoredCredentials`), where `GhostmapAPI` reads it per
/// request; this type owns the *observable* view of it for SwiftUI. Signing in is
/// Google → `id_token` → `POST /v1/auth/google` → keychain.
@Observable
@MainActor
final class AccountStore {

    enum Phase: Sendable, Equatable {
        case idle
        /// The Google consent screen is up, or the backend is being called.
        case signingIn
        /// `GET /v1/auth/me` is refreshing the account.
        case refreshing
    }

    private(set) var user: GhostmapUser?
    private(set) var role: GhostmapRole?
    private(set) var tokenExpiry: Date?
    private(set) var phase: Phase = .idle
    /// Human-readable text for the last failure, cleared when a new attempt starts.
    private(set) var lastError: String?

    /// This installation's identity, generated once and kept in the keychain.
    let deviceID: UUID
    let deviceName: String

    private let api: GhostmapAPI
    private let log = SessionLogger.osLogger(.cloud)

    init(api: GhostmapAPI, deviceName: String = UIDevice.current.name) {
        self.api = api
        self.deviceName = deviceName
        self.deviceID = DeviceIdentityStore.loadOrCreate()
        restoreFromKeychain()
    }

    // MARK: - Derived state

    var isSignedIn: Bool { role != nil }
    var isBusy: Bool { phase != .idle }
    /// True when there is a token but it has run out; the UI offers signing in again.
    var isTokenExpired: Bool {
        guard let tokenExpiry else { return false }
        return tokenExpiry <= Date()
    }
    /// A `device` token may create maps and stream keyframes; a `user` token may only watch.
    var canMap: Bool { role?.canMap ?? false }
    var isGoogleConfigured: Bool { GoogleSignIn.isConfigured }

    /// This phone as the backend wants it.
    var deviceIdentity: DeviceIdentity {
        DeviceIdentity(id: deviceID, name: deviceName)
    }

    // MARK: - Actions

    /// Signs in with Google and exchanges the id token for a backend token.
    ///
    /// - Parameters:
    ///   - asMapper: send this phone's identity, asking for a `device` token.
    ///   - alwaysChooseAccount: use a private browser session so the account chooser appears.
    @discardableResult
    func signInWithGoogle(asMapper: Bool, alwaysChooseAccount: Bool = false) async -> Bool {
        guard phase == .idle else { return false }
        lastError = nil
        phase = .signingIn
        defer { phase = .idle }

        guard let google = GoogleSignIn() else {
            lastError = GoogleSignInError.notConfigured.localizedDescription
            return false
        }
        let outcome: GoogleSignIn.Outcome
        do {
            outcome = try await google.signIn(prefersEphemeralSession: alwaysChooseAccount)
        } catch {
            // A cancelled sign-in is not worth an error banner.
            lastError = error == .cancelled ? nil : error.localizedDescription
            return false
        }

        do {
            let auth = try await api.signInWithGoogle(idToken: outcome.idToken, device: asMapper ? deviceIdentity : nil)
            apply(auth)
            log.notice("signed in as \(auth.role.rawValue, privacy: .public)")
            return true
        } catch {
            lastError = error.localizedDescription
            log.error("backend sign-in failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Re-reads the account from `GET /v1/auth/me`. Clears the session when the token is rejected.
    func refresh() async {
        guard isSignedIn, phase == .idle else { return }
        phase = .refreshing
        defer { phase = .idle }
        do {
            let me = try await api.me()
            role = me.role
            if let user = me.user { self.user = user }
            persist()
        } catch {
            if error.requiresSignIn {
                log.notice("stored token rejected; signing out")
                signOut()
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// Forgets the token and the account. The device identity survives, so signing in again
    /// reuses the same device row on the backend.
    func signOut() {
        user = nil
        role = nil
        tokenExpiry = nil
        lastError = nil
        do {
            try StoredCredentials.clear()
        } catch {
            log.error("clearing credentials failed: \(String(describing: error), privacy: .public)")
        }
    }

    func clearError() { lastError = nil }

    // MARK: - Persistence

    private func apply(_ auth: AuthResponse) {
        user = auth.user
        role = auth.role
        tokenExpiry = auth.expiresAt
        let credentials = StoredCredentials(
            token: auth.token,
            expiresAt: auth.expiresAt,
            role: auth.role,
            deviceId: auth.deviceId,
            user: auth.user
        )
        do {
            try credentials.save()
        } catch {
            lastError = "The sign-in could not be saved to the keychain."
            log.error("saving credentials failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes the refreshed account back next to the unchanged token.
    private func persist() {
        guard var credentials = StoredCredentials.load() else { return }
        credentials.role = role ?? credentials.role
        credentials.user = user ?? credentials.user
        do {
            try credentials.save()
        } catch {
            log.error("updating credentials failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func restoreFromKeychain() {
        guard let credentials = StoredCredentials.load() else { return }
        user = credentials.user
        role = credentials.role
        tokenExpiry = credentials.expiresAt
        if credentials.isExpired() {
            log.notice("stored backend token has expired")
        }
    }
}

/// This installation's UUID.
///
/// The keychain is the primary home (it survives reinstalls, which is what the backend's device
/// row wants). If the keychain is unavailable — it can be, in a simulator without an entitlement —
/// the id falls back to `UserDefaults` so the app still has a stable identity for this install.
enum DeviceIdentityStore {
    private static let defaultsKey = "tech.alandiza.roommapper.deviceID"

    static func loadOrCreate(defaults: UserDefaults = .standard) -> UUID {
        let log = SessionLogger.osLogger(.cloud)
        if let stored = try? Keychain.string(for: .deviceIdentity), let id = UUID(uuidString: stored) {
            return id
        }
        if let stored = defaults.string(forKey: defaultsKey), let id = UUID(uuidString: stored) {
            try? Keychain.setString(id.uuidString, for: .deviceIdentity)
            return id
        }
        let id = UUID()
        do {
            try Keychain.setString(id.uuidString, for: .deviceIdentity)
        } catch {
            log.error("keychain unavailable for the device id: \(String(describing: error), privacy: .public)")
        }
        defaults.set(id.uuidString, forKey: defaultsKey)
        log.notice("generated a device identity")
        return id
    }
}
