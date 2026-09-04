import CoreImage
import CoreImage.CIFilterBuiltins
import MapCore
import SwiftUI
import UIKit

extension Color {
    init(_ party: PartyColor) {
        let (r, g, b) = party.components
        self.init(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: 1)
    }
}

/// The QR code for a party's share link, rendered with CoreImage (no dependency, no network).
enum PartyQRCode {
    /// A crisp black-on-white QR image, or nil when CoreImage cannot render one.
    ///
    /// `CIQRCodeGenerator` produces a tiny bitmap (one pixel per module), so it is scaled up with
    /// nearest-neighbour before rasterising; interpolating would blur the modules and break scans.
    static func image(for url: URL, side: CGFloat = 240) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        // "M" corrects ~15 % of the symbol, which survives a phone screen photographed at an angle.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, side / max(output.extent.width, 1))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Create, join, watch and leave a party.
///
/// Presented as a sheet from the map list and from the capture screen. Everything it needs comes
/// from ``PartySession``; with no account or no network it explains what is missing instead of
/// failing, and capture keeps working either way.
struct PartyView: View {
    let env: AppEnvironment
    /// A code handed in by a `ghostmap://join/<code>` link, pre-filled into the join field.
    var initialCode: String?

    @Environment(\.dismiss) private var dismiss
    @State private var partyName = ""
    @State private var codeEntry = ""
    @State private var maxParticipants = 4
    @State private var summary: SessionByCodeResponse?
    @State private var isPreviewing = false
    @State private var confirmEnd = false
    @State private var didPrefill = false

    private var party: PartySession { env.party }

    var body: some View {
        NavigationStack {
            Form {
                if party.isActive {
                    activeSections
                } else {
                    if !env.account.isSignedIn { signInSection }
                    createSection
                    joinSection
                    if let remembered = party.remembered { rejoinSection(remembered) }
                }
                if let error = party.lastError, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(party.isActive ? "Party" : "Parties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await prepare() }
            .refreshable { await party.refresh() }
            .alert("End this party?", isPresented: $confirmEnd) {
                Button("End party", role: .destructive) { Task { await party.end() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everyone stops streaming and the party can no longer be joined. Maps already captured stay on each phone.")
            }
        }
    }

    private func prepare() async {
        guard !didPrefill else { return }
        didPrefill = true
        if partyName.isEmpty { partyName = Self.defaultName() }
        if let code = initialCode ?? env.pendingJoinCode {
            codeEntry = PartyCode.formatted(code)
            env.pendingJoinCode = nil
            await lookUp()
        }
        if party.isActive { await party.refresh() }
    }

    static func defaultName() -> String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        return "Party \(time)"
    }

    // MARK: - Not signed in

    @ViewBuilder
    private var signInSection: some View {
        Section {
            Label("Sign in to start or join a party", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.callout)
        } footer: {
            Text("Parties need a Ghostmap account: open Settings and sign in with Google. Signing in as this phone also lets it stream keyframes; a viewer account can watch only.")
        }
    }

    // MARK: - Create

    @ViewBuilder
    private var createSection: some View {
        Section {
            TextField("Party name", text: $partyName)
                .submitLabel(.done)
            Stepper(value: $maxParticipants, in: 1...8) {
                LabeledContent("Max phones", value: "\(maxParticipants)")
            }
            Button {
                Task { await party.create(name: trimmedName, markerOrigin: env.settings.markerOrigin, maxParticipants: maxParticipants) }
            } label: {
                HStack(spacing: 8) {
                    if party.phase == .creating { ProgressView().controlSize(.small) }
                    Text("Start a party")
                }
            }
            .disabled(!env.account.isSignedIn || party.isBusy || trimmedName.isEmpty)
        } header: {
            Text("Start")
        } footer: {
            Text(env.settings.markerOrigin
                 ? "The party's origin is the printed marker, so every phone that sees the same sheet shares one coordinate frame. Print docs/ghostmap-marker.pdf and tape it up before you start."
                 : "Marker origin is off in Settings, so the party's origin is where this phone started. Other phones' clouds will not line up with yours until you turn it on.")
        }
    }

    private var trimmedName: String { partyName.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Join

    @ViewBuilder
    private var joinSection: some View {
        Section {
            TextField("ABCD 2345", text: $codeEntry)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.title3, design: .monospaced))
                .submitLabel(.join)
                .onSubmit { Task { await lookUp() } }
                .onChange(of: codeEntry) { _, new in
                    let normalized = PartyCode.normalized(new)
                    let formatted = PartyCode.formatted(normalized)
                    if formatted != new { codeEntry = formatted }
                    summary = nil
                }
            if let summary {
                partySummary(summary)
            }
            Button {
                Task {
                    // First tap looks the code up so the party can be identified before joining it;
                    // the second tap joins.
                    if summary == nil {
                        await lookUp()
                        return
                    }
                    guard summary?.canJoin != false else { return }
                    if await party.join(code: codeEntry) { dismiss() }
                }
            } label: {
                HStack(spacing: 8) {
                    if party.phase == .joining || isPreviewing { ProgressView().controlSize(.small) }
                    Text(summary == nil ? "Look up code" : "Join party")
                }
            }
            .disabled(!env.account.isSignedIn || party.isBusy || !PartyCode.isValid(codeEntry))
        } header: {
            Text("Join")
        } footer: {
            Text("Type the 8-character code, or open the party's link — \(PartyCode.urlScheme)://join/CODE and the dashboard's share link both open this app.")
        }
    }

    private func lookUp() async {
        guard PartyCode.isValid(codeEntry), env.account.isSignedIn else { return }
        isPreviewing = true
        summary = await party.preview(code: codeEntry)
        isPreviewing = false
    }

    @ViewBuilder
    private func partySummary(_ summary: SessionByCodeResponse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.session.name).font(.headline).lineLimit(1)
            Text("\(summary.session.participantCount ?? 0)/\(summary.session.maxParticipants ?? 4) phones · \(summary.session.status.rawValue)"
                 + (summary.session.ownerName.map { " · \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            if !summary.canJoin {
                Label(summary.reason?.message ?? "This party cannot be joined.", systemImage: "hand.raised.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func rejoinSection(_ membership: PartyMembership) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(membership.name).font(.headline).lineLimit(1)
                Text(membership.code.map { PartyCode.formatted($0) } ?? membership.sessionID.prefix(8).description)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Button("Rejoin") { Task { if await party.rejoin() { dismiss() } } }
                .disabled(!env.account.isSignedIn || party.isBusy)
            Button("Forget", role: .destructive) { party.forgetRemembered() }
                .font(.footnote)
        } header: {
            Text("Last party")
        } footer: {
            Text("Rejoining keeps the colour and the place you had. It is always allowed while the party is still running.")
        }
    }

    // MARK: - Active party

    @ViewBuilder
    private var activeSections: some View {
        Section {
            codeCard
        } header: {
            Text(party.session?.name ?? "Party")
        }

        if let link = party.joinLink {
            Section {
                shareCard(link)
            } header: {
                Text("Invite")
            } footer: {
                Text("Scan the code with another phone, or send the link. Anyone with a Ghostmap account can watch; a phone signed in as itself can also map.")
            }
        }

        Section {
            ForEach(party.activeParticipants) { participant in
                participantRow(participant)
            }
        } header: {
            Text("Participants (\(party.participantCount)/\(party.maxParticipants))")
        }

        Section {
            LabeledContent("Live updates", value: connectionLabel)
            LabeledContent("Keyframes streamed", value: "\(party.streamStats.streamed)")
            if party.streamStats.dropped + party.streamStats.failed > 0 {
                LabeledContent("Dropped", value: "\(party.streamStats.dropped + party.streamStats.failed)")
                    .foregroundStyle(.orange)
            }
            if party.streamStats.partial > 0 {
                LabeledContent("Without depth", value: "\(party.streamStats.partial)")
            }
            LabeledContent("Poses published", value: "\(party.publishedPoses)")
            LabeledContent("Peers' points", value: Format.count(party.peers.totalPoints))
        } header: {
            Text("This phone")
        } footer: {
            Text(party.canStream
                 ? "Keyframes stream while a recording is running. Point at the marker so your poses are in the party's frame."
                 : "This phone is in the party as a viewer, so it does not stream keyframes. Sign in as this phone in Settings to map into a party.")
        }

        Section {
            Button("Leave party", role: .destructive) { Task { await party.leave(); dismiss() } }
                .disabled(party.isBusy)
            if party.canEnd {
                Button("End party for everyone", role: .destructive) { confirmEnd = true }
                    .disabled(party.isBusy)
            }
        }
    }

    @ViewBuilder
    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(connectionColor).frame(width: 8, height: 8)
                Text(PartyCode.formatted(party.inviteCode ?? ""))
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = party.inviteCode
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy the party code")
            }
            Text(originLabel).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func shareCard(_ link: URL) -> some View {
        VStack(spacing: 10) {
            if let image = PartyQRCode.image(for: link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("QR code for the party link")
            }
            ShareLink(item: link) {
                Label("Share link", systemImage: "square.and.arrow.up")
            }
            Text(link.absoluteString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func participantRow(_ participant: SessionParticipant) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(party.colour(for: participant)))
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(participant)).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(participant.kind == .device ? "mapper" : "viewer")
                    if participant.role == .leader { Text("· leader") }
                    if let peer = peer(for: participant) {
                        Text("· \(Format.count(peer.pointCount)) pts")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isMe(participant) {
                Text("you").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            } else if let peer = peer(for: participant) {
                Circle().fill(peer.isStale ? Color.gray : Color.green).frame(width: 7, height: 7)
                    .accessibilityLabel(peer.isStale ? "idle" : "streaming")
            }
        }
        .padding(.vertical, 2)
    }

    private func isMe(_ participant: SessionParticipant) -> Bool {
        participant.id == party.me?.id
    }

    private func peer(for participant: SessionParticipant) -> PeerCloud? {
        guard let deviceID = participant.deviceId else { return nil }
        return party.peers.peer(deviceID: deviceID)
    }

    private func displayName(_ participant: SessionParticipant) -> String {
        if let name = participant.displayName, !name.isEmpty { return name }
        if isMe(participant) { return env.account.user?.displayName ?? "This phone" }
        if let deviceID = participant.deviceId { return PeerCloudStore.shortName(for: deviceID) }
        return "Viewer"
    }

    private var originLabel: String {
        switch party.session?.origin?.type {
        case "marker": return "Origin: printed marker \(party.session?.origin?.markerId ?? MarkerReference.name)"
        case "session-start": return "Origin: the creator's session start — clouds will not line up between phones"
        default: return "Origin: unknown"
        }
    }

    private var connectionLabel: String {
        switch party.connection {
        case .offline: return "off"
        case .connecting: return "connecting…"
        case .live: return "live"
        case .degraded(let reason): return reason
        }
    }

    private var connectionColor: Color {
        switch party.connection {
        case .live: return .green
        case .connecting: return .yellow
        case .degraded: return .orange
        case .offline: return .gray
        }
    }
}

/// The pill on the capture screen and the toolbar item on the map list.
struct PartyBadge: View {
    let party: PartySession

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: party.isActive ? "person.2.fill" : "person.2")
            if party.isActive {
                Text(PartyCode.formatted(party.inviteCode ?? ""))
                    .font(.caption.monospaced().weight(.semibold))
                Text("\(party.participantCount)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color(party.myColor ?? PartyColor.palette[0]).opacity(0.35), in: Capsule())
            } else {
                Text("Party").font(.caption.weight(.semibold))
            }
        }
    }
}
