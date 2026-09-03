import Foundation
import simd
import XCTest
@testable import MapCore

final class KeyframePolicyTests: XCTestCase {

    // MARK: - Helpers

    /// Identity rotation, translated `meters` along +X.
    private func translated(_ meters: Float) -> Pose {
        Pose(translation: SIMD3<Float>(meters, 0, 0))
    }

    /// At the origin, rotated `degrees` about +Y.
    private func rotatedY(_ degrees: Float) -> Pose {
        Pose(translation: .zero, rotation: simd_quatf(angle: degrees * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
    }

    /// A `.normal`-mode policy that has already accepted `.first` at `Pose.identity`, t = 10 s.
    private func primedPolicy(config: KeyframePolicy.Config = .default) -> KeyframePolicy {
        var policy = KeyframePolicy(config: config)
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10, tracking: .normal), .keyframe(.first))
        XCTAssertEqual(policy.keyframeCount, 1)
        return policy
    }

    // MARK: - Config

    func testDefaultConfigValues() {
        let config = KeyframePolicy.Config.default
        // Product spec: 0.15 m, 12°, 0.75 s, tracking must be normal.
        XCTAssertEqual(config.translationThresholdMeters, 0.15)
        XCTAssertEqual(config.rotationThresholdDegrees, 12)
        XCTAssertEqual(config.maxInterval, 0.75)
        XCTAssertTrue(config.requireNormalTracking)
    }

    func testConfigInitDefaultsMatchDefault() {
        XCTAssertEqual(KeyframePolicy.Config(), .default)
    }

    func testConfigInitStoresExplicitValues() {
        let config = KeyframePolicy.Config(translationThresholdMeters: 0.05,
                                           rotationThresholdDegrees: 3,
                                           maxInterval: 0.2,
                                           requireNormalTracking: false)
        XCTAssertEqual(config.translationThresholdMeters, 0.05)
        XCTAssertEqual(config.rotationThresholdDegrees, 3)
        XCTAssertEqual(config.maxInterval, 0.2)
        XCTAssertFalse(config.requireNormalTracking)
        XCTAssertNotEqual(config, .default)
    }

    // MARK: - Initial state

    func testInitialState() {
        let policy = KeyframePolicy()
        XCTAssertEqual(policy.config, .default)
        XCTAssertEqual(policy.mode, .normal)
        XCTAssertNil(policy.lastKeyframePose)
        XCTAssertNil(policy.lastKeyframeTime)
        XCTAssertEqual(policy.keyframeCount, 0)
    }

    func testInitStoresCustomConfig() {
        let config = KeyframePolicy.Config(translationThresholdMeters: 0.5)
        let policy = KeyframePolicy(config: config)
        XCTAssertEqual(policy.config, config)
        XCTAssertEqual(policy.config.translationThresholdMeters, 0.5)
    }

    // MARK: - First frame and tracking gate

    func testFirstFrameWithNormalTrackingIsFirstKeyframe() {
        var policy = KeyframePolicy()
        let pose = translated(1.5)
        XCTAssertEqual(policy.evaluate(pose: pose, timestamp: 3.25, tracking: .normal), .keyframe(.first))
        // One keyframe recorded at exactly the evaluated pose/time.
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframePose, pose)
        XCTAssertEqual(policy.lastKeyframeTime, 3.25)
    }

    func testFirstFrameWithLimitedTrackingIsSkipped() {
        var policy = KeyframePolicy()
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 1, tracking: .limited(.initializing)),
                       .skip(.trackingNotNormal))
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 2, tracking: .limited(.excessiveMotion)),
                       .skip(.trackingNotNormal))
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 3, tracking: .notAvailable),
                       .skip(.trackingNotNormal))
        // Nothing recorded.
        XCTAssertEqual(policy.keyframeCount, 0)
        XCTAssertNil(policy.lastKeyframePose)
        XCTAssertNil(policy.lastKeyframeTime)
    }

    func testRequireNormalTrackingFalseAcceptsLimitedTracking() {
        var policy = KeyframePolicy(config: KeyframePolicy.Config(requireNormalTracking: false))
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10, tracking: .limited(.excessiveMotion)),
                       .keyframe(.first))
        XCTAssertEqual(policy.keyframeCount, 1)
        // 0.2 m > 0.15 m with tracking not available: still a keyframe because the gate is off.
        XCTAssertEqual(policy.evaluate(pose: translated(0.2), timestamp: 10.1, tracking: .notAvailable),
                       .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 2)
    }

    func testTrackingLossAfterKeyframeIsSkippedWithoutChangingState() {
        var policy = primedPolicy()
        // 1 m of motion, but tracking is limited: skipped and nothing recorded.
        XCTAssertEqual(policy.evaluate(pose: translated(1), timestamp: 10.1, tracking: .limited(.relocalizing)),
                       .skip(.trackingNotNormal))
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframePose, .identity)
        XCTAssertEqual(policy.lastKeyframeTime, 10)
        // Once tracking recovers the same motion is judged against the pre-loss keyframe: 1 m > 0.15 m.
        XCTAssertEqual(policy.evaluate(pose: translated(1), timestamp: 10.2, tracking: .normal),
                       .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 2)
    }

    // MARK: - Translation gate

    func testTranslationExactlyAtThresholdIsSkipped() {
        var policy = primedPolicy()
        // distance = sqrt(0.15² + 0 + 0) = 0.15, not strictly > 0.15; rotation 0° ≤ 12°; dt = 10.1 − 10 = 0.1 < 0.75.
        XCTAssertEqual(policy.evaluate(pose: translated(0.15), timestamp: 10.1, tracking: .normal),
                       .skip(.belowThresholds))
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframePose, .identity)
        XCTAssertEqual(policy.lastKeyframeTime, 10)
    }

    func testTranslationJustAboveThresholdIsKeyframe() {
        var policy = primedPolicy()
        // distance = 0.151 > 0.15.
        XCTAssertEqual(policy.evaluate(pose: translated(0.151), timestamp: 10.1, tracking: .normal),
                       .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 2)
        XCTAssertEqual(policy.lastKeyframePose, translated(0.151))
        XCTAssertEqual(policy.lastKeyframeTime, 10.1)
    }

    func testTranslationUsesEuclideanDistance() {
        var policy = primedPolicy()
        // sqrt(0.08² · 3) = sqrt(0.0192) = 0.1386 < 0.15 → skip.
        XCTAssertEqual(policy.evaluate(pose: Pose(translation: SIMD3<Float>(0.08, 0.08, 0.08)), timestamp: 10.1, tracking: .normal),
                       .skip(.belowThresholds))
        // sqrt(0.1² · 3) = sqrt(0.03) = 0.1732 > 0.15 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: Pose(translation: SIMD3<Float>(0.1, 0.1, 0.1)), timestamp: 10.2, tracking: .normal),
                       .keyframe(.translation))
    }

    func testTranslationIsMeasuredFromLastKeyframeNotOrigin() {
        var policy = primedPolicy()
        // 0.5 − 0 = 0.5 > 0.15 → keyframe; last pose becomes x = 0.5.
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 10.1, tracking: .normal), .keyframe(.translation))
        // 0.6 − 0.5 = 0.1 ≤ 0.15 → skip (would be a keyframe if measured from the origin).
        XCTAssertEqual(policy.evaluate(pose: translated(0.6), timestamp: 10.2, tracking: .normal), .skip(.belowThresholds))
        // 0.66 − 0.5 = 0.16 > 0.15 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: translated(0.66), timestamp: 10.3, tracking: .normal), .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 3)
        XCTAssertEqual(policy.lastKeyframePose, translated(0.66))
    }

    // MARK: - Rotation gate

    func testRotationExactlyAtThresholdIsSkipped() {
        var policy = primedPolicy()
        // Ideal angle = 2·acos(cos 6°) = 12°. Pose.rotationAngleDegrees round-trips the quaternion
        // through the rotation matrix in Float and measures 11.999977°, which is not strictly > 12°;
        // translation 0 ≤ 0.15; dt = 0.1 < 0.75.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(12), timestamp: 10.1, tracking: .normal),
                       .skip(.belowThresholds))
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframePose, .identity)
    }

    func testRotationEqualToThresholdIsNotAKeyframeAndJustBelowThresholdIs() {
        // Pin the threshold to the exact measured angle so the strict `>` is tested independent of Float noise.
        let measured = Pose.identity.rotationAngleDegrees(to: rotatedY(12))
        XCTAssertEqual(measured, 12, accuracy: 1e-3)   // 2·acos(cos 6°) = 12°, ± Float round-trip noise

        var equal = primedPolicy(config: KeyframePolicy.Config(rotationThresholdDegrees: measured))
        XCTAssertEqual(equal.evaluate(pose: rotatedY(12), timestamp: 10.1, tracking: .normal), .skip(.belowThresholds))

        var below = primedPolicy(config: KeyframePolicy.Config(rotationThresholdDegrees: measured.nextDown))
        XCTAssertEqual(below.evaluate(pose: rotatedY(12), timestamp: 10.1, tracking: .normal), .keyframe(.rotation))
    }

    func testRotationJustAboveThresholdIsKeyframe() {
        var policy = primedPolicy()
        // 12.1° (measures 12.099995°) > 12° → keyframe.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(12.1), timestamp: 10.1, tracking: .normal),
                       .keyframe(.rotation))
        XCTAssertEqual(policy.keyframeCount, 2)
        XCTAssertEqual(policy.lastKeyframePose, rotatedY(12.1))
        XCTAssertEqual(policy.lastKeyframeTime, 10.1)
    }

    func testRotationAboutOtherAxesCounts() {
        var policy = primedPolicy()
        let aboutX = Pose(translation: .zero, rotation: simd_quatf(angle: 15 * .pi / 180, axis: SIMD3<Float>(1, 0, 0)))
        // 15° > 12° about X.
        XCTAssertEqual(policy.evaluate(pose: aboutX, timestamp: 10.1, tracking: .normal), .keyframe(.rotation))
        let aboutZ = Pose(translation: .zero, rotation: simd_quatf(angle: 15 * .pi / 180, axis: SIMD3<Float>(0, 0, 1)))
        // X(15°) → Z(15°): relative angle = 2·acos(cos²7.5°) ≈ 21.2° > 12°.
        XCTAssertEqual(policy.evaluate(pose: aboutZ, timestamp: 10.2, tracking: .normal), .keyframe(.rotation))
    }

    func testRotationIsMeasuredFromLastKeyframe() {
        var policy = primedPolicy()
        // 20° − 0° = 20° > 12° → keyframe; last pose becomes 20°.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(20), timestamp: 10.1, tracking: .normal), .keyframe(.rotation))
        // 25° − 20° = 5° ≤ 12° → skip (25° from the origin would have been a keyframe).
        XCTAssertEqual(policy.evaluate(pose: rotatedY(25), timestamp: 10.2, tracking: .normal), .skip(.belowThresholds))
        // 33° − 20° = 13° > 12° → keyframe.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(33), timestamp: 10.3, tracking: .normal), .keyframe(.rotation))
        XCTAssertEqual(policy.keyframeCount, 3)
        XCTAssertEqual(policy.lastKeyframePose, rotatedY(33))
    }

    // MARK: - Elapsed gate

    func testElapsedExactlyAtMaxIntervalIsKeyframe() {
        var policy = primedPolicy()
        // No motion; dt = 10.75 − 10 = 0.75 ≥ 0.75 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10.75, tracking: .normal), .keyframe(.elapsed))
        XCTAssertEqual(policy.keyframeCount, 2)
        XCTAssertEqual(policy.lastKeyframeTime, 10.75)
        XCTAssertEqual(policy.lastKeyframePose, .identity)
    }

    func testElapsedJustBelowMaxIntervalIsSkipped() {
        var policy = primedPolicy()
        // dt = 10.749 − 10 = 0.749 < 0.75 → skip; last time stays 10.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10.749, tracking: .normal), .skip(.belowThresholds))
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframeTime, 10)
    }

    func testElapsedIsMeasuredFromLastKeyframe() {
        var policy = primedPolicy()
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10.75, tracking: .normal), .keyframe(.elapsed))
        // 11.4 − 10.75 = 0.65 < 0.75 → skip (1.4 s since the first keyframe would have qualified).
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 11.4, tracking: .normal), .skip(.belowThresholds))
        // 11.5 − 10.75 = 0.75 ≥ 0.75 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 11.5, tracking: .normal), .keyframe(.elapsed))
        XCTAssertEqual(policy.keyframeCount, 3)
        XCTAssertEqual(policy.lastKeyframeTime, 11.5)
    }

    func testTimestampBeforeLastKeyframeNeverElapses() {
        var policy = primedPolicy()
        // dt = 5 − 10 = −5 < 0.75 → skip; the last keyframe time is untouched.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 5, tracking: .normal), .skip(.belowThresholds))
        XCTAssertEqual(policy.lastKeyframeTime, 10)
        // dt = 10.75 − 10 = 0.75 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10.75, tracking: .normal), .keyframe(.elapsed))
    }

    // MARK: - Gate priority

    func testTranslationTakesPriorityOverRotation() {
        var policy = primedPolicy()
        // 0.5 m > 0.15 m and 30° > 12°: translation is checked first.
        let both = Pose(translation: SIMD3<Float>(0.5, 0, 0),
                        rotation: simd_quatf(angle: 30 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        XCTAssertEqual(policy.evaluate(pose: both, timestamp: 10.1, tracking: .normal), .keyframe(.translation))
        XCTAssertEqual(policy.lastKeyframePose, both)
    }

    func testTranslationTakesPriorityOverElapsed() {
        var policy = primedPolicy()
        // 0.5 m > 0.15 m and dt = 20 − 10 = 10 s ≥ 0.75 s: translation wins.
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 20, tracking: .normal), .keyframe(.translation))
    }

    func testRotationTakesPriorityOverElapsed() {
        var policy = primedPolicy()
        // 30° > 12° and dt = 10 s ≥ 0.75 s: rotation wins.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(30), timestamp: 20, tracking: .normal), .keyframe(.rotation))
    }

    func testTrackingGateTakesPriorityOverMotionAndElapsed() {
        var policy = primedPolicy()
        // Huge motion and dt, but tracking is not normal.
        let both = Pose(translation: SIMD3<Float>(5, 0, 0),
                        rotation: simd_quatf(angle: 90 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        XCTAssertEqual(policy.evaluate(pose: both, timestamp: 100, tracking: .limited(.insufficientFeatures)),
                       .skip(.trackingNotNormal))
        XCTAssertEqual(policy.keyframeCount, 1)
    }

    // MARK: - Halved mode

    func testHalvedDoublesTranslationThreshold() {
        var policy = primedPolicy()
        policy.mode = .halved
        // Threshold 0.15 · 2 = 0.30 m. 0.2 ≤ 0.3 → skip.
        XCTAssertEqual(policy.evaluate(pose: translated(0.2), timestamp: 10.1, tracking: .normal), .skip(.belowThresholds))
        // 0.3 = 0.3, not strictly greater → skip.
        XCTAssertEqual(policy.evaluate(pose: translated(0.3), timestamp: 10.2, tracking: .normal), .skip(.belowThresholds))
        // 0.31 > 0.3 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: translated(0.31), timestamp: 10.3, tracking: .normal), .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 2)
        XCTAssertEqual(policy.lastKeyframePose, translated(0.31))
    }

    func testHalvedDoublesRotationThreshold() {
        var policy = primedPolicy()
        policy.mode = .halved
        // Threshold 12 · 2 = 24°. 20° (measures 20.000015°) ≤ 24° → skip.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(20), timestamp: 10.1, tracking: .normal), .skip(.belowThresholds))
        // 24° (measures 23.999989°) not strictly > 24° → skip.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(24), timestamp: 10.2, tracking: .normal), .skip(.belowThresholds))
        // 25° (measures 25.000002°) > 24° → keyframe.
        XCTAssertEqual(policy.evaluate(pose: rotatedY(25), timestamp: 10.3, tracking: .normal), .keyframe(.rotation))
        XCTAssertEqual(policy.keyframeCount, 2)
    }

    func testHalvedDoublesMaxInterval() {
        var policy = primedPolicy()
        policy.mode = .halved
        // Threshold 0.75 · 2 = 1.5 s. dt = 11.4 − 10 = 1.4 < 1.5 → skip.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 11.4, tracking: .normal), .skip(.belowThresholds))
        // dt = 11.5 − 10 = 1.5 ≥ 1.5 → keyframe.
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 11.5, tracking: .normal), .keyframe(.elapsed))
        XCTAssertEqual(policy.keyframeCount, 2)
        XCTAssertEqual(policy.lastKeyframeTime, 11.5)
    }

    func testHalvedFirstFrameIsStillFirstKeyframe() {
        var policy = KeyframePolicy()
        policy.mode = .halved
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10, tracking: .normal), .keyframe(.first))
        XCTAssertEqual(policy.keyframeCount, 1)
    }

    func testHalvedStillRequiresNormalTracking() {
        var policy = primedPolicy()
        policy.mode = .halved
        XCTAssertEqual(policy.evaluate(pose: translated(1), timestamp: 10.1, tracking: .limited(.initializing)),
                       .skip(.trackingNotNormal))
    }

    func testEffectiveConfigPerMode() {
        var policy = KeyframePolicy(config: KeyframePolicy.Config(translationThresholdMeters: 0.1,
                                                                  rotationThresholdDegrees: 5,
                                                                  maxInterval: 0.5,
                                                                  requireNormalTracking: false))
        // Normal: unchanged.
        XCTAssertEqual(policy.effectiveConfig, policy.config)
        // Halved: 0.1·2 = 0.2, 5·2 = 10, 0.5·2 = 1.0; requireNormalTracking untouched.
        policy.mode = .halved
        XCTAssertEqual(policy.effectiveConfig.translationThresholdMeters, 0.2)
        XCTAssertEqual(policy.effectiveConfig.rotationThresholdDegrees, 10)
        XCTAssertEqual(policy.effectiveConfig.maxInterval, 1.0)
        XCTAssertFalse(policy.effectiveConfig.requireNormalTracking)
        // Paused: unchanged (no frame is evaluated anyway).
        policy.mode = .paused
        XCTAssertEqual(policy.effectiveConfig, policy.config)
    }

    func testEffectiveConfigDefaultHalved() {
        var policy = KeyframePolicy()
        policy.mode = .halved
        // 0.15·2 = 0.30 m, 12·2 = 24°, 0.75·2 = 1.5 s.
        XCTAssertEqual(policy.effectiveConfig,
                       KeyframePolicy.Config(translationThresholdMeters: 0.3, rotationThresholdDegrees: 24, maxInterval: 1.5))
    }

    // MARK: - Paused mode

    func testPausedSkipsLargeMotionWithoutChangingState() {
        var policy = primedPolicy()
        policy.mode = .paused
        let huge = Pose(translation: SIMD3<Float>(5, 5, 5),
                        rotation: simd_quatf(angle: 90 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        // 8.66 m, 90°, dt = 90 s: every gate would fire, but paused wins.
        XCTAssertEqual(policy.evaluate(pose: huge, timestamp: 100, tracking: .normal), .skip(.paused))
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframePose, .identity)
        XCTAssertEqual(policy.lastKeyframeTime, 10)
    }

    func testPausedSkipsFirstFrame() {
        var policy = KeyframePolicy()
        policy.mode = .paused
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10, tracking: .normal), .skip(.paused))
        XCTAssertEqual(policy.keyframeCount, 0)
        XCTAssertNil(policy.lastKeyframePose)
        XCTAssertNil(policy.lastKeyframeTime)
    }

    func testPausedTakesPriorityOverTrackingGate() {
        var policy = KeyframePolicy()
        policy.mode = .paused
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 10, tracking: .limited(.excessiveMotion)), .skip(.paused))
    }

    func testResumingAfterPauseJudgesAgainstPrePauseKeyframe() {
        var policy = primedPolicy()
        policy.mode = .paused
        XCTAssertEqual(policy.evaluate(pose: translated(0.2), timestamp: 10.1, tracking: .normal), .skip(.paused))
        policy.mode = .normal
        // 0.2 − 0 = 0.2 > 0.15 measured from the keyframe recorded before the pause.
        XCTAssertEqual(policy.evaluate(pose: translated(0.2), timestamp: 10.2, tracking: .normal), .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 2)
        XCTAssertEqual(policy.lastKeyframeTime, 10.2)
    }

    // MARK: - reset()

    func testResetClearsHistoryButKeepsConfigAndMode() {
        let config = KeyframePolicy.Config(translationThresholdMeters: 0.05, rotationThresholdDegrees: 3, maxInterval: 0.2)
        var policy = primedPolicy(config: config)
        policy.mode = .halved
        // 0.5 > 0.05·2 = 0.1 → second keyframe.
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 10.1, tracking: .normal), .keyframe(.translation))
        XCTAssertEqual(policy.keyframeCount, 2)

        policy.reset()
        XCTAssertNil(policy.lastKeyframePose)
        XCTAssertNil(policy.lastKeyframeTime)
        XCTAssertEqual(policy.keyframeCount, 0)
        XCTAssertEqual(policy.config, config)
        XCTAssertEqual(policy.mode, .halved)

        // Next frame is .first again, even with zero motion relative to the previous keyframe pose.
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 50, tracking: .normal), .keyframe(.first))
        XCTAssertEqual(policy.keyframeCount, 1)
        XCTAssertEqual(policy.lastKeyframePose, translated(0.5))
        XCTAssertEqual(policy.lastKeyframeTime, 50)
    }

    func testResetOnFreshPolicyIsHarmless() {
        var policy = KeyframePolicy()
        policy.reset()
        XCTAssertNil(policy.lastKeyframePose)
        XCTAssertNil(policy.lastKeyframeTime)
        XCTAssertEqual(policy.keyframeCount, 0)
        XCTAssertEqual(policy.evaluate(pose: .identity, timestamp: 0, tracking: .normal), .keyframe(.first))
    }

    // MARK: - State bookkeeping

    func testLastKeyframePoseAndTimeUpdateOnlyOnKeyframes() {
        var policy = primedPolicy()
        // Skip: 0.1 ≤ 0.15 → history unchanged.
        XCTAssertEqual(policy.evaluate(pose: translated(0.1), timestamp: 10.1, tracking: .normal), .skip(.belowThresholds))
        XCTAssertEqual(policy.lastKeyframePose, .identity)
        XCTAssertEqual(policy.lastKeyframeTime, 10)
        // Keyframe: 0.5 > 0.15 → history moves.
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 10.2, tracking: .normal), .keyframe(.translation))
        XCTAssertEqual(policy.lastKeyframePose, translated(0.5))
        XCTAssertEqual(policy.lastKeyframeTime, 10.2)
        // Skip: 0.55 − 0.5 = 0.05 ≤ 0.15 → history unchanged.
        XCTAssertEqual(policy.evaluate(pose: translated(0.55), timestamp: 10.3, tracking: .normal), .skip(.belowThresholds))
        XCTAssertEqual(policy.lastKeyframePose, translated(0.5))
        XCTAssertEqual(policy.lastKeyframeTime, 10.2)
        XCTAssertEqual(policy.keyframeCount, 2)
    }

    func testKeyframeCountCountsEveryReason() {
        var policy = primedPolicy()                                                                    // first → 1
        XCTAssertEqual(policy.evaluate(pose: translated(0.05), timestamp: 10.1, tracking: .normal), .skip(.belowThresholds))
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 10.2, tracking: .normal), .keyframe(.translation))  // → 2
        XCTAssertEqual(policy.evaluate(pose: translated(0.5), timestamp: 10.3, tracking: .normal), .skip(.belowThresholds))
        let turned = Pose(translation: SIMD3<Float>(0.5, 0, 0),
                          rotation: simd_quatf(angle: 30 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        XCTAssertEqual(policy.evaluate(pose: turned, timestamp: 10.4, tracking: .normal), .keyframe(.rotation))         // → 3
        XCTAssertEqual(policy.evaluate(pose: turned, timestamp: 11.0, tracking: .normal), .skip(.belowThresholds))       // 0.6 < 0.75
        XCTAssertEqual(policy.evaluate(pose: turned, timestamp: 11.15, tracking: .normal), .keyframe(.elapsed))          // 0.75 → 4
        XCTAssertEqual(policy.keyframeCount, 4)
    }

    func testCustomThresholds() {
        var policy = primedPolicy(config: KeyframePolicy.Config(translationThresholdMeters: 0.05,
                                                                rotationThresholdDegrees: 3,
                                                                maxInterval: 0.2))
        // 0.06 > 0.05 → translation.
        XCTAssertEqual(policy.evaluate(pose: translated(0.06), timestamp: 10.01, tracking: .normal), .keyframe(.translation))
        // 4° > 3° relative to the previous keyframe (which had no rotation) → rotation.
        let turned = Pose(translation: SIMD3<Float>(0.06, 0, 0), rotation: simd_quatf(angle: 4 * .pi / 180, axis: SIMD3<Float>(0, 1, 0)))
        XCTAssertEqual(policy.evaluate(pose: turned, timestamp: 10.02, tracking: .normal), .keyframe(.rotation))
        // dt = 10.22 − 10.02 = 0.2 ≥ 0.2 → elapsed.
        XCTAssertEqual(policy.evaluate(pose: turned, timestamp: 10.22, tracking: .normal), .keyframe(.elapsed))
        XCTAssertEqual(policy.keyframeCount, 4)
    }

    // MARK: - Decision equality

    func testDecisionEquality() {
        XCTAssertEqual(KeyframePolicy.Decision.keyframe(.first), .keyframe(.first))
        XCTAssertNotEqual(KeyframePolicy.Decision.keyframe(.first), .keyframe(.elapsed))
        XCTAssertNotEqual(KeyframePolicy.Decision.keyframe(.translation), .keyframe(.rotation))
        XCTAssertEqual(KeyframePolicy.Decision.skip(.paused), .skip(.paused))
        XCTAssertNotEqual(KeyframePolicy.Decision.skip(.paused), .skip(.trackingNotNormal))
        XCTAssertNotEqual(KeyframePolicy.Decision.skip(.belowThresholds), .keyframe(.first))
    }

    func testPolicyIsSendableValue() {
        // Compile-time check that the policy crosses isolation boundaries as a value.
        let policy: any Sendable = KeyframePolicy()
        XCTAssertNotNil(policy)
    }
}
