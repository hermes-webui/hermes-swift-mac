import HermesAgentCore
import XCTest

/// Regression coverage for the page-zoom policy behind ⌘+/⌘-/⌘0.
final class ZoomLevelTests: XCTestCase {

    func testIdentityIsOneHundredPercent() {
        XCTAssertEqual(ZoomLevel.identity.factor, 1.0)
    }

    func testSingleStepUpAndDown() {
        XCTAssertEqual(ZoomLevel.identity.increased().factor, 1.1)
        XCTAssertEqual(ZoomLevel.identity.decreased().factor, 0.9)
    }

    /// Ten presses each way must land exactly on 100%; `factor + 0.1` drifts.
    func testRepeatedStepsStayExactlyOnTheGrid() {
        var level = ZoomLevel.identity
        for _ in 0..<10 { level = level.increased() }
        XCTAssertEqual(level.factor, 2.0)

        for _ in 0..<10 { level = level.decreased() }
        XCTAssertEqual(level.factor, 1.0)
    }

    func testStepsClampAtBothEnds() {
        var high = ZoomLevel.identity
        for _ in 0..<40 { high = high.increased() }
        XCTAssertEqual(high.factor, ZoomLevel.maximumFactor)
        XCTAssertTrue(high.isMaximum)
        XCTAssertEqual(high.increased().factor, ZoomLevel.maximumFactor)

        var low = ZoomLevel.identity
        for _ in 0..<40 { low = low.decreased() }
        XCTAssertEqual(low.factor, ZoomLevel.minimumFactor)
        XCTAssertTrue(low.isMinimum)
        XCTAssertEqual(low.decreased().factor, ZoomLevel.minimumFactor)
    }

    func testOffGridValuesQuantizeToNearestStep() {
        XCTAssertEqual(ZoomLevel(clamping: 1.04).factor, 1.0)
        XCTAssertEqual(ZoomLevel(clamping: 1.06).factor, 1.1)
        XCTAssertEqual(ZoomLevel(clamping: 1.25).factor, 1.3)
    }

    func testNonFiniteValuesFallBackToIdentity() {
        XCTAssertEqual(ZoomLevel(clamping: .nan).factor, 1.0)
        XCTAssertEqual(ZoomLevel(clamping: .infinity).factor, 1.0)
    }

    func testOutOfRangeValuesClampInsteadOfTrapping() {
        XCTAssertEqual(ZoomLevel(clamping: -5).factor, ZoomLevel.minimumFactor)
        XCTAssertEqual(ZoomLevel(clamping: 99).factor, ZoomLevel.maximumFactor)
    }

    /// `UserDefaults` reports 0 for an absent key; restoring that would render at 0%.
    func testRestoringRejectsUnusableStoredValues() {
        XCTAssertNil(ZoomLevel(restoring: 0))
        XCTAssertNil(ZoomLevel(restoring: -1))
        XCTAssertNil(ZoomLevel(restoring: 3.5))
        XCTAssertNil(ZoomLevel(restoring: .nan))
        XCTAssertNil(ZoomLevel(restoring: .infinity))
    }

    func testRestoringAcceptsInRangeValues() {
        XCTAssertEqual(ZoomLevel(restoring: 1.4)?.factor, 1.4)
        XCTAssertEqual(ZoomLevel(restoring: 0.5)?.factor, 0.5)
        XCTAssertEqual(ZoomLevel(restoring: 3.0)?.factor, 3.0)
    }
}

/// Persistence, including migration from the magnification value of earlier releases.
final class ZoomPreferencesTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "HermesAgentTests.ZoomPreferences.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func storedValue(forKey key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }

    func testMissingValueLoadsIdentity() {
        XCTAssertEqual(ZoomPreferences(defaults: defaults).load().factor, 1.0)
    }

    func testSaveRoundTripsThroughTheCurrentKey() {
        let preferences = ZoomPreferences(defaults: defaults)
        preferences.save(ZoomLevel(clamping: 1.3))

        XCTAssertEqual(preferences.load().factor, 1.3)
        XCTAssertEqual(storedValue(forKey: ZoomPreferences.currentKey), 1.3)
    }

    func testLegacyMagnificationValueIsMigrated() {
        // Written by the pre-page-zoom releases (v1.1.0–v1.7.3).
        defaults.set(1.4, forKey: ZoomPreferences.legacyKey)

        XCTAssertEqual(ZoomPreferences(defaults: defaults).load().factor, 1.4)
    }

    func testCurrentKeyWinsOverLegacyValue() {
        defaults.set(1.4, forKey: ZoomPreferences.legacyKey)
        defaults.set(0.8, forKey: ZoomPreferences.currentKey)

        XCTAssertEqual(ZoomPreferences(defaults: defaults).load().factor, 0.8)
    }

    func testZeroLegacyValueIsIgnored() {
        // 0 is what `double(forKey:)` reports for a key that was never written.
        defaults.set(0.0, forKey: ZoomPreferences.legacyKey)

        XCTAssertEqual(ZoomPreferences(defaults: defaults).load().factor, 1.0)
    }

    func testNonNumericLegacyValueIsIgnored() {
        defaults.set("large", forKey: ZoomPreferences.legacyKey)

        XCTAssertEqual(ZoomPreferences(defaults: defaults).load().factor, 1.0)
    }

    func testSavingDoesNotRewriteTheLegacyKey() {
        defaults.set(1.4, forKey: ZoomPreferences.legacyKey)
        let preferences = ZoomPreferences(defaults: defaults)

        preferences.save(.identity)

        XCTAssertEqual(storedValue(forKey: ZoomPreferences.legacyKey), 1.4)
        XCTAssertEqual(preferences.load().factor, 1.0)
    }
}

/// Guards the WebKit API choice itself: no UI-test harness exists, so — as with
/// `LongConversationCompatibilityTests` — this checks the production sources.
final class PageZoomWiringTests: XCTestCase {

    private func productionSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HermesAgentTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testViewMenuActionsApplyPageZoom() throws {
        let appDelegate = try productionSource("Sources/HermesAgent/AppDelegate.swift")

        XCTAssertTrue(
            appDelegate.contains("webView.pageZoom ="),
            "⌘+/⌘-/⌘0 must use pageZoom"
        )
        XCTAssertFalse(
            appDelegate.contains(".magnification ="),
            "magnification scales a fixed layout and must not drive zoom"
        )
    }

    func testNativeMagnificationStaysDisabled() throws {
        let controller = try productionSource("Sources/HermesAgent/BrowserWindowController.swift")

        XCTAssertTrue(
            controller.contains("webView.pageZoom = CGFloat("),
            "the saved zoom must be applied as pageZoom before the page is shown"
        )
        XCTAssertFalse(
            controller.contains(".magnification ="),
            "restoring magnification reintroduces the non-reflowing zoom"
        )
        XCTAssertFalse(
            controller.contains("allowsMagnification = true"),
            "pinch would compose with pageZoom and leave ⌘0 off 100%"
        )
    }
}
