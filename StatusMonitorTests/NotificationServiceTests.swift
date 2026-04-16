import XCTest
import UserNotifications
@testable import StatusMonitor

/// Tests the pure `makeRequest` builder. Covers the notification-shape
/// invariants the audit flagged as zero-coverage: severity→sound selection,
/// degrade vs. improve copy, title truncation edges, userInfo contents,
/// stable identifier for flap coalescing.
final class NotificationServiceTests: XCTestCase {

    private let providerId = UUID()

    private func make(from: ComponentStatus,
                      to: ComponentStatus,
                      incident: String? = nil,
                      provider: String = "TestService") -> UNNotificationRequest {
        NotificationService.makeRequest(
            providerId: providerId,
            provider: provider,
            from: from,
            to: to,
            incident: incident
        )
    }

    // MARK: - Identifier (stable per provider — audit fix)

    func testIdentifierIsStablePerProvider() {
        let r1 = make(from: .operational, to: .majorOutage)
        let r2 = make(from: .majorOutage, to: .operational)
        XCTAssertEqual(r1.identifier, r2.identifier,
                       "Identifier must be stable per providerId so successive notifications REPLACE each other")
        XCTAssertTrue(r1.identifier.contains(providerId.uuidString))
    }

    func testIdentifiersDifferAcrossProviders() {
        let a = NotificationService.makeRequest(providerId: UUID(), provider: "A",
                                                from: .operational, to: .majorOutage, incident: nil)
        let b = NotificationService.makeRequest(providerId: UUID(), provider: "B",
                                                from: .operational, to: .majorOutage, incident: nil)
        XCTAssertNotEqual(a.identifier, b.identifier)
    }

    // MARK: - Title

    func testTitleContainsProviderAndStatus() {
        let req = make(from: .operational, to: .majorOutage, provider: "GitHub")
        XCTAssertEqual(req.content.title, "GitHub: Major Outage")
    }

    // MARK: - Body

    func testBodyPrefersIncidentNameWhenProvided() {
        let req = make(from: .operational, to: .majorOutage, incident: "API 5xx spike in us-east")
        XCTAssertEqual(req.content.body, "API 5xx spike in us-east")
    }

    func testBodyTruncatesIncidentAt200Characters() {
        let longIncident = String(repeating: "x", count: 500)
        let req = make(from: .operational, to: .majorOutage, incident: longIncident)
        XCTAssertEqual(req.content.body.count, 200)
    }

    func testBodyDegradedCopyWhenNoIncident() {
        let req = make(from: .operational, to: .degradedPerformance)
        XCTAssertEqual(req.content.body, "Status degraded from Operational to Degraded")
    }

    func testBodyImprovedCopyWhenRecovering() {
        let req = make(from: .majorOutage, to: .operational)
        XCTAssertEqual(req.content.body, "Status improved to Operational")
    }

    // MARK: - Sound

    func testMajorOutageUsesCriticalSound() {
        let req = make(from: .operational, to: .majorOutage)
        XCTAssertEqual(req.content.sound, .defaultCritical)
    }

    func testNonCriticalNonGreenUsesDefaultSound() {
        let req = make(from: .operational, to: .degradedPerformance)
        XCTAssertEqual(req.content.sound, .default)
    }

    func testRecoveryToOperationalIsSilent() {
        let req = make(from: .majorOutage, to: .operational)
        XCTAssertNil(req.content.sound,
                     "Recovery notifications shouldn't play a sound — the user just got a red one a moment ago")
    }

    // MARK: - userInfo (deep-link payload)

    func testUserInfoCarriesProviderIdAsString() {
        let req = make(from: .operational, to: .majorOutage)
        XCTAssertEqual(req.content.userInfo["providerId"] as? String, providerId.uuidString)
    }

    // MARK: - Unicode / edge cases

    func testProviderNameWithEmojiIsPreservedInTitle() {
        let req = make(from: .operational, to: .majorOutage, provider: "🚀 Rocket API")
        XCTAssertTrue(req.content.title.contains("🚀 Rocket API"))
    }

    func testIncidentTruncationDoesNotCrashOnMultibyteBoundary() {
        // 100 flag emojis — each is 8 UTF-16 code units. Regression guard
        // against a naïve `incident.prefix(200)` that splits a grapheme.
        let flag = "🇺🇳"
        let longIncident = String(repeating: flag, count: 100)
        _ = make(from: .operational, to: .majorOutage, incident: longIncident)
        // If the line above didn't crash, we're good.
    }
}
