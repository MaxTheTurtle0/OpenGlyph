import Foundation
import XCTest
@testable import OpenGlyphCore

final class OCRRecoveryPolicyTests: XCTestCase {
    private func configuration(_ language: String = "en-US", revision: Int = 3) -> OCRRecoveryPolicy.Configuration {
        OCRRecoveryPolicy.Configuration(language: language, revision: revision)
    }

    func testTwoRecoveriesActivateCooldownWithoutExtendingItOnReads() {
        var now: TimeInterval = 0
        let policy = OCRRecoveryPolicy(clock: { now })
        let key = configuration()
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertFalse(policy.shouldUseFast(for: key))
        now = 1
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertTrue(policy.shouldUseFast(for: key))
        now = 60.9
        XCTAssertTrue(policy.shouldUseFast(for: key))
        now = 61
        XCTAssertFalse(policy.shouldUseFast(for: key))
        // A failed periodic Accurate probe with successful Fast recovery gets
        // another bounded interval, rather than retrying on every capture.
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertTrue(policy.shouldUseFast(for: key))
        now = 121
        XCTAssertFalse(policy.shouldUseFast(for: key))
    }

    func testResetRestoresAccurateAndClearsFailureStreak() {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let key = configuration()
        policy.recordRecoveredComputeFailure(for: key)
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertTrue(policy.shouldUseFast(for: key))
        policy.reset(for: key)
        XCTAssertFalse(policy.shouldUseFast(for: key))
        XCTAssertEqual(policy.configurationCount, 0)
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertFalse(policy.shouldUseFast(for: key))
    }

    func testIsolatedFailuresOutsideWindowDoNotActivateCooldown() {
        var now: TimeInterval = 0
        let policy = OCRRecoveryPolicy(clock: { now })
        let key = configuration()
        policy.recordRecoveredComputeFailure(for: key)
        now = 121
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertFalse(policy.shouldUseFast(for: key))
    }

    func testLongIdlePeriodDiscardsAnExpiredCooldownFailureStreak() {
        var now: TimeInterval = 0
        let policy = OCRRecoveryPolicy(clock: { now })
        let key = configuration()
        policy.recordRecoveredComputeFailure(for: key)
        policy.recordRecoveredComputeFailure(for: key)
        now = 121
        XCTAssertFalse(policy.shouldUseFast(for: key))
        policy.recordRecoveredComputeFailure(for: key)
        XCTAssertFalse(policy.shouldUseFast(for: key))
    }

    func testLanguageRevisionAndAutomaticLocaleConfigurationsAreIsolated() {
        let policy = OCRRecoveryPolicy(clock: { 0 })
        let explicit = configuration()
        let automatic = OCRRecoveryPolicy.Configuration(language: nil, revision: 3,
                                                        preferredLanguages: ["en-US"], localeIdentifier: "en_US")
        for key in [explicit, automatic] {
            policy.recordRecoveredComputeFailure(for: key)
            policy.recordRecoveredComputeFailure(for: key)
            XCTAssertTrue(policy.shouldUseFast(for: key))
        }
        XCTAssertFalse(policy.shouldUseFast(for: configuration("de-DE")))
        XCTAssertFalse(policy.shouldUseFast(for: configuration(revision: 2)))
        XCTAssertFalse(policy.shouldUseFast(for: .init(language: nil, revision: 3,
                                                      preferredLanguages: ["de-DE"], localeIdentifier: "en_US")))
        XCTAssertFalse(policy.shouldUseFast(for: .init(language: nil, revision: 3,
                                                      preferredLanguages: ["en-US"], localeIdentifier: "de_DE")))
        XCTAssertEqual(automatic, .init(language: "auto", revision: 3,
                                        preferredLanguages: ["en-US"], localeIdentifier: "en_US"))
        XCTAssertEqual(explicit, .init(language: "en-US", revision: 3,
                                       preferredLanguages: ["de-DE"], localeIdentifier: "de_DE"))
    }

    func testCacheEvictsLeastRecentlyUsedConfiguration() {
        let policy = OCRRecoveryPolicy(capacity: 3, clock: { 0 })
        let keys = (0..<4).map { configuration("language-\($0)") }
        for key in keys.prefix(3) { policy.recordRecoveredComputeFailure(for: key) }
        XCTAssertFalse(policy.shouldUseFast(for: keys[0])) // Keep the first key recent.
        policy.recordRecoveredComputeFailure(for: keys[3])
        XCTAssertEqual(policy.configurationCount, 3)
        policy.recordRecoveredComputeFailure(for: keys[0])
        XCTAssertTrue(policy.shouldUseFast(for: keys[0]))
        policy.recordRecoveredComputeFailure(for: keys[1])
        XCTAssertFalse(policy.shouldUseFast(for: keys[1])) // Evicted key starts a new streak.
        XCTAssertEqual(policy.configurationCount, 3)
    }

    func testConcurrentUpdatesKeepCacheBounded() {
        let policy = OCRRecoveryPolicy(capacity: 8)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            let key = OCRRecoveryPolicy.Configuration(language: "language-\(index % 20)", revision: 3)
            policy.recordRecoveredComputeFailure(for: key)
            _ = policy.shouldUseFast(for: key)
            if index.isMultiple(of: 3) { policy.reset(for: key) }
        }
        XCTAssertLessThanOrEqual(policy.configurationCount, 8)
    }
}
