import MapCore
import SwiftUI

/// Backend and account settings, opened from the map list toolbar.
///
/// Everything here is optional: with no backend and no account the app keeps working exactly as
/// before, capturing to the phone only.
struct SettingsView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""
    @State private var urlError: String?
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                accountSection
                uploadSection
                markerSection
                deviceSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                urlText = env.cloud.backendURLString
                await env.account.refresh()
            }
        }
    }

    // MARK: - Backend

    @ViewBuilder
    private var backendSection: some View {
        Section {
            TextField("https://ghostmap-backend.vercel.app", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { commitURL() }
                .onChange(of: urlText) { _, _ in
                    urlError = nil
                    testResult = nil
                }
            if let urlError {
                Label(urlError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button {
                    commitURL()
                    testConnection()
                } label: {
                    if isTesting {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Testing…") }
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(isTesting)
                Spacer(minLength: 0)
                if urlText != BackendURL.productionString {
                    Button("Default") {
                        urlText = BackendURL.productionString
                        commitURL()
                    }
                    .font(.footnote)
                }
            }
            switch testResult {
            case .success(let detail):
                Label(detail, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failure(let detail):
                Label(detail, systemImage: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        } header: {
            Text("Backend")
        } footer: {
            Text("Maps and parties are stored on this server. Leave it at the default unless you run your own.")
        }
    }

    private func commitURL() {
        do {
            let url = try env.setBackendURL(urlText)
            urlText = url.absoluteString
            urlError = nil
        } catch {
            urlError = message(for: error)
        }
    }

    private func message(for error: BackendURL.ValidationError) -> String {
        switch error {
        case .empty: return "Enter the backend address."
        case .malformed: return "That is not a valid address."
        case .unsupportedScheme(let scheme): return "\(scheme):// is not supported — use https."
        case .missingHost: return "The address needs a host name."
        case .containsQueryOrFragment: return "Remove the query or fragment from the address."
        }
    }

    private func testConnection() {
        guard urlError == nil else { return }
        isTesting = true
        testResult = nil
        Task {
            do {
                let health = try await env.api.health()
                var parts: [String] = []
                if let version = health.version { parts.append("v\(version)") }
                if let region = health.region { parts.append(region) }
                if health.configured == false { parts.append("not fully configured") }
                testResult = .success(parts.isEmpty ? "Reachable" : "Reachable · " + parts.joined(separator: " · "))
            } catch {
                testResult = .failure(error.localizedDescription)
            }
            isTesting = false
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if env.account.isSignedIn {
                accountCard
                if env.account.isTokenExpired {
                    signInButton
                }
                Button("Sign out", role: .destructive) { env.account.signOut() }
            } else {
                Toggle("Sign in as this phone", isOn: Binding(
                    get: { env.cloud.signInAsMapper },
                    set: { env.cloud.signInAsMapper = $0 }
                ))
                Toggle("Always choose account", isOn: Binding(
                    get: { env.cloud.alwaysChooseAccount },
                    set: { env.cloud.alwaysChooseAccount = $0 }
                ))
                signInButton
            }
            if let error = env.account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Account")
        } footer: {
            if !env.account.isGoogleConfigured {
                Text("This build has no Google client id. Set GhostmapGoogleClientID (and the matching URL scheme) in App/Resources/Info.plist — see docs/USAGE.md.")
            } else if env.account.isSignedIn {
                Text(env.account.canMap
                     ? "This phone can upload maps and join parties as a mapper."
                     : "Signed in as a viewer: you can watch parties but not upload from this phone.")
            } else {
                Text("Signing in as this phone gets a 30-day device token that may upload maps and stream keyframes. Without it you get a 7-day viewer token.")
            }
        }
    }

    // MARK: - Cloud upload

    @ViewBuilder
    private var uploadSection: some View {
        Section {
            Toggle("Upload maps to cloud", isOn: Binding(
                get: { env.cloud.autoUpload },
                set: { env.cloud.autoUpload = $0 }
            ))
            .disabled(!env.account.canMap)
        } header: {
            Text("Cloud maps")
        } footer: {
            Text(env.account.canMap
                 ? "Every map uploads to the backend right after it saves. You can also upload — or re-upload — one map at a time from its detail screen."
                 : "Sign in as this phone above to turn this on. You can still upload an individual map from its detail screen once you are signed in.")
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        Button {
            Task {
                await env.account.signInWithGoogle(
                    asMapper: env.cloud.signInAsMapper,
                    alwaysChooseAccount: env.cloud.alwaysChooseAccount
                )
            }
        } label: {
            HStack(spacing: 10) {
                if env.account.phase == .signingIn {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.badge.key.fill")
                }
                Text("Sign in with Google")
            }
        }
        .disabled(!env.account.isGoogleConfigured || env.account.isBusy)
    }

    @ViewBuilder
    private var accountCard: some View {
        HStack(spacing: 12) {
            avatar
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(env.account.user?.displayName ?? "Signed in")
                    .font(.headline)
                    .lineLimit(1)
                if let email = env.account.user?.email, !email.isEmpty {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let role = env.account.role {
                        Text(role.rawValue)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    if let expiry = env.account.tokenExpiry {
                        Text(env.account.isTokenExpired ? "expired" : "until \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(env.account.isTokenExpired ? .red : .secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if env.account.phase == .refreshing { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if let picture = env.account.user?.pictureUrl, let url = URL(string: picture) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                avatarPlaceholder
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.25)
            Image(systemName: "person.fill").foregroundStyle(.secondary)
        }
    }

    // MARK: - Marker origin

    /// Centimetres, so the stepper works in whole printable units instead of metres.
    private var markerCentimetres: Binding<Int> {
        Binding(
            get: { Int((env.settings.markerPhysicalWidth * 100).rounded()) },
            set: { env.settings.markerWidthMeters = MarkerReference.clampWidth(Double($0) / 100) }
        )
    }

    @ViewBuilder
    private var markerSection: some View {
        Section {
            Toggle("Use a printed marker", isOn: Binding(
                get: { env.settings.markerOrigin },
                set: { env.settings.markerOrigin = $0 }
            ))
            Stepper(value: markerCentimetres,
                    in: Int(MarkerReference.minimumWidth * 100)...Int(MarkerReference.maximumWidth * 100)) {
                LabeledContent("Marker size", value: "\(markerCentimetres.wrappedValue) cm")
            }
            .disabled(!env.settings.markerOrigin)
            if markerCentimetres.wrappedValue != Int(MarkerReference.defaultWidth * 100) {
                Button("Reset to \(Int(MarkerReference.defaultWidth * 100)) cm") {
                    env.settings.markerWidthMeters = MarkerReference.defaultWidth
                }
                .font(.footnote)
            }
            MarkerShareButton()
        } header: {
            Text("Marker origin")
        } footer: {
            MarkerGuide()
        }
    }

    // MARK: - Device

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            LabeledContent("Name", value: env.account.deviceName)
            LabeledContent("Identity", value: String(env.account.deviceID.uuidString.prefix(8)).lowercased())
        } header: {
            Text("This phone")
        } footer: {
            Text("The identity is generated once and kept in the keychain, so the backend recognises this phone across reinstalls. Signing out does not change it.")
        }
    }
}
