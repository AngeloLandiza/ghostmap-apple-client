import Foundation
import MapCore
import Metal
import Observation
import os
import simd

/// One party peer's live cloud: the points their keyframes carried, tinted with their party colour,
/// plus the pose their camera last reported.
///
/// Positions arrive in the party's **origin** frame (the marker frame when the party has one), which
/// is not this phone's ARKit world frame — the renderers multiply by `world_from_origin` before
/// drawing, so nothing here has to know about the local frame.
@Observable
@MainActor
final class PeerCloud: Identifiable {
    /// How many points one peer's cloud holds before the oldest are dropped.
    static let capacity = 150_000

    nonisolated let deviceID: String
    nonisolated var id: String { deviceID }

    var displayName: String
    var color: PartyColor
    var userID: String?
    private(set) var pointCount = 0
    private(set) var keyframes = 0
    /// `origin_from_camera` of the peer's most recent `pose` (or keyframe) message.
    private(set) var latestPose: simd_float4x4?
    /// False while that peer has not seen the marker, so its points are in its own world frame.
    private(set) var aligned = true
    private(set) var lastSeen = Date()

    /// GPU mirror, read by both renderers.
    @ObservationIgnored let buffer: SharedPointBuffer
    /// CPU truth in insertion order, so the oldest points can be dropped when the cloud is full.
    @ObservationIgnored private var ring: [PackedPoint] = []

    init(deviceID: String, displayName: String, color: PartyColor, device: MTLDevice, capacity: Int = PeerCloud.capacity) throws {
        self.deviceID = deviceID
        self.displayName = displayName
        self.color = color
        self.buffer = try SharedPointBuffer(device: device, capacity: capacity)
        self.ring.reserveCapacity(min(capacity, 8192))
    }

    var isStale: Bool { Date().timeIntervalSince(lastSeen) > 15 }

    /// Adds one keyframe's inline points, dropping the oldest when the cloud is full.
    ///
    /// The common path is a plain append. Only a wrap rewrites the whole buffer, and with 2 000
    /// points per keyframe at a few hertz that happens once every ~25 s per peer — far enough apart
    /// that `SharedPointBuffer`'s double-buffer swap is never re-entered inside one frame.
    func ingest(points: [PackedPoint]) {
        lastSeen = Date()
        guard !points.isEmpty else { return }
        let capacity = buffer.capacity
        if ring.count + points.count <= capacity {
            ring.append(contentsOf: points)
            buffer.append(points)
        } else {
            let kept = Array(points.suffix(capacity))
            let overflow = ring.count + kept.count - capacity
            if overflow > 0 { ring.removeFirst(min(overflow, ring.count)) }
            ring.append(contentsOf: kept)
            do {
                try buffer.replaceAll(ring)
            } catch {
                PeerCloudStore.log.error("peer cloud replace failed: \(String(describing: error), privacy: .public)")
                ring.removeAll(keepingCapacity: true)
                buffer.removeAll()
            }
        }
        pointCount = ring.count
    }

    func note(pose: simd_float4x4, aligned: Bool) {
        latestPose = pose
        self.aligned = aligned
        lastSeen = Date()
    }

    func noteKeyframes(_ count: Int) {
        keyframes += count
        lastSeen = Date()
    }

    func removeAll() {
        ring.removeAll(keepingCapacity: true)
        buffer.removeAll()
        pointCount = 0
        keyframes = 0
        latestPose = nil
    }
}

/// Every peer in the party except this phone.
///
/// `PartySession` feeds it the realtime `keyframes` and `pose` messages; the two renderers read
/// `peers` each frame. Messages from this device are dropped on the way in — the backend fans a
/// device's own keyframes back out over the channel, and drawing them again would double every
/// point this phone already has in the global cloud.
@Observable
@MainActor
final class PeerCloudStore {
    static let log = SessionLogger.osLogger(.cloud)
    /// How many peers the renderers draw; the party cap is 8 participants, so 7 peers plus slack.
    static let maxPeers = 8

    /// This phone's device id, whose echoed messages are ignored.
    var ownDeviceID: String?
    private(set) var peers: [PeerCloud] = []
    /// Messages skipped because they came from this device.
    private(set) var ignoredOwnMessages = 0
    /// Messages skipped because the party already had ``maxPeers`` peers.
    private(set) var overflowMessages = 0

    private let device: MTLDevice
    private var index: [String: PeerCloud] = [:]

    init(device: MTLDevice, ownDeviceID: String? = nil) {
        self.device = device
        self.ownDeviceID = ownDeviceID
    }

    var totalPoints: Int { peers.reduce(0) { $0 + $1.pointCount } }
    var totalKeyframes: Int { peers.reduce(0) { $0 + $1.keyframes } }
    var isEmpty: Bool { peers.isEmpty }

    func peer(deviceID: String) -> PeerCloud? { index[deviceID.lowercased()] }

    /// The peer for a device id, created on first sight. Nil for this device, for an empty id, and
    /// once the cap is reached.
    @discardableResult
    func peer(deviceID raw: String, displayName: String?, color: PartyColor?, userID: String? = nil) -> PeerCloud? {
        let deviceID = raw.lowercased()
        guard !deviceID.isEmpty else { return nil }
        guard deviceID != ownDeviceID?.lowercased() else {
            ignoredOwnMessages += 1
            return nil
        }
        if let existing = index[deviceID] {
            if let displayName, !displayName.isEmpty, existing.displayName != displayName { existing.displayName = displayName }
            if let color, existing.color != color { existing.color = color }
            if let userID, existing.userID != userID { existing.userID = userID }
            return existing
        }
        guard peers.count < Self.maxPeers else {
            overflowMessages += 1
            return nil
        }
        let colour = color ?? PartyColor.palette(index: peers.count + 1)
        do {
            let peer = try PeerCloud(deviceID: deviceID,
                                     displayName: displayName ?? PeerCloudStore.shortName(for: deviceID),
                                     color: colour,
                                     device: device)
            peer.userID = userID
            peers.append(peer)
            index[deviceID] = peer
            Self.log.notice("party peer joined the view: \(PeerCloudStore.shortName(for: deviceID), privacy: .public)")
            return peer
        } catch {
            Self.log.error("peer cloud allocation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Refreshes names and colours from the party's participant rows.
    func apply(participants: [SessionParticipant]) {
        for (offset, participant) in participants.enumerated() {
            guard let deviceID = participant.deviceId?.lowercased(), deviceID != ownDeviceID?.lowercased() else { continue }
            guard participant.kind == .device else { continue }
            guard let peer = index[deviceID] else { continue }
            peer.color = PartyColor.resolve(hex: participant.color, index: offset)
            if let name = participant.displayName, !name.isEmpty { peer.displayName = name }
            peer.userID = participant.userId
        }
    }

    func remove(deviceID raw: String) {
        let deviceID = raw.lowercased()
        guard index.removeValue(forKey: deviceID) != nil else { return }
        peers.removeAll { $0.deviceID == deviceID }
    }

    func removeAll() {
        for peer in peers { peer.removeAll() }
        peers.removeAll()
        index.removeAll()
        ignoredOwnMessages = 0
        overflowMessages = 0
    }

    /// The last 6 characters of a device UUID, which is enough to tell two phones apart in the UI.
    static func shortName(for deviceID: String) -> String {
        let tail = deviceID.replacingOccurrences(of: "-", with: "").suffix(6)
        return tail.isEmpty ? "peer" : "Phone \(tail.uppercased())"
    }
}
