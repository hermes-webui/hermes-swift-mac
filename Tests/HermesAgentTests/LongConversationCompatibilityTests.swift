import JavaScriptCore
import XCTest

/// Regression coverage for the WKWebView-only transcript virtualization guard.
///
/// The production script lives in BrowserWindowController.swift. These tests extract
/// and execute that exact script so changes to the injected JavaScript are exercised,
/// rather than testing a hand-copied Swift model of its behavior.
final class LongConversationCompatibilityTests: XCTestCase {

    private func productionScript() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HermesAgentTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let controllerURL = repositoryRoot
            .appendingPathComponent("Sources/HermesAgent/BrowserWindowController.swift")
        let source = try String(contentsOf: controllerURL, encoding: .utf8)
        let opening = "static let longConversationWebKitCompatibilityScript = \"\"\"\n"
        let closing = "\n        \"\"\""

        guard let openingRange = source.range(of: opening),
              let closingRange = source.range(
                of: closing,
                range: openingRange.upperBound..<source.endIndex
              )
        else {
            throw NSError(
                domain: "LongConversationCompatibilityTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Compatibility script not found"]
            )
        }
        return String(source[openingRange.upperBound..<closingRange.lowerBound])
    }

    private func context(
        schedulerBody: String?,
        requestedValue: Bool,
        installTwice: Bool = false
    ) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var exception: JSValue?
        context.exceptionHandler = { _, value in exception = value }
        context.evaluateScript("var window = this;")

        let script = try productionScript()
        context.evaluateScript(script)
        if let schedulerBody {
            context.evaluateScript(
                "window._scheduleMessageVirtualMeasurementRefresh = function() { \(schedulerBody) };"
            )
        }
        context.evaluateScript("window._virtualizeTranscript = \(requestedValue);")
        if installTwice {
            context.evaluateScript(script)
        }

        XCTAssertNil(exception?.toString(), "Injected script raised a JavaScript exception")
        return context
    }

    func testKnownBuggySchedulerDisablesVirtualization() throws {
        let context = try context(
            schedulerBody: "_messageVirtualMeasurementRetryCount = 0;",
            requestedValue: true
        )

        XCTAssertFalse(context.evaluateScript("window._virtualizeTranscript").toBool())
    }

    func testFixedSchedulerPreservesServerSetting() throws {
        let context = try context(
            schedulerBody: "_messageVirtualMeasurementCycleKey=cycleKey;",
            requestedValue: true
        )

        XCTAssertTrue(context.evaluateScript("window._virtualizeTranscript").toBool())
    }

    func testMissingSchedulerFailsClosed() throws {
        let context = try context(schedulerBody: nil, requestedValue: true)

        XCTAssertFalse(context.evaluateScript("window._virtualizeTranscript").toBool())
    }

    func testDisabledServerSettingRemainsDisabled() throws {
        let context = try context(
            schedulerBody: "_messageVirtualMeasurementCycleKey=cycleKey;",
            requestedValue: false
        )

        XCTAssertFalse(context.evaluateScript("window._virtualizeTranscript").toBool())
    }

    func testRepeatedInstallationIsIdempotent() throws {
        let context = try context(
            schedulerBody: "_messageVirtualMeasurementCycleKey=cycleKey;",
            requestedValue: true,
            installTwice: true
        )

        XCTAssertTrue(context.evaluateScript("window._virtualizeTranscript").toBool())
        XCTAssertTrue(
            context.evaluateScript("window.__hermesMacLongConversationCompatibilityPatch").toBool()
        )
    }
}
