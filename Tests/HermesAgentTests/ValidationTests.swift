import XCTest

/// Tests for URL and port validation logic used in PreferencesWindowController.
/// These mirror the validation in `save()` — if that logic changes, update tests here too.
final class URLValidationTests: XCTestCase {

    // Helper: mirrors PreferencesWindowController.save() URL check
    func isValidTargetURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return false }
        return true
    }

    func testHTTPURLAccepted() {
        XCTAssertTrue(isValidTargetURL("http://localhost:8787"))
        XCTAssertTrue(isValidTargetURL("http://127.0.0.1:8787"))
        XCTAssertTrue(isValidTargetURL("http://my-server.example.com:9000"))
    }

    func testHTTPSURLAccepted() {
        XCTAssertTrue(isValidTargetURL("https://my-server.example.com:8787"))
        XCTAssertTrue(isValidTargetURL("https://localhost:8443"))
    }

    func testJavaScriptURLRejected() {
        XCTAssertFalse(isValidTargetURL("javascript:alert(1)"))
    }

    func testFileURLRejected() {
        XCTAssertFalse(isValidTargetURL("file:///etc/passwd"))
    }

    func testDataURLRejected() {
        XCTAssertFalse(isValidTargetURL("data:text/html,<h1>hi</h1>"))
    }

    func testEmptyStringRejected() {
        XCTAssertFalse(isValidTargetURL(""))
    }

    func testBareHostRejected() {
        // No scheme — URL(string:) may succeed but scheme will be nil
        XCTAssertFalse(isValidTargetURL("localhost:8787"))
    }

    func testFTPURLRejected() {
        XCTAssertFalse(isValidTargetURL("ftp://example.com"))
    }
}

/// Tests for port validation (1–65535 inclusive).
final class PortValidationTests: XCTestCase {

    // Helper: mirrors PreferencesWindowController.save() port check
    func isValidPort(_ raw: String) -> Bool {
        guard let port = Int(raw) else { return false }
        return (1...65535).contains(port)
    }

    func testValidPorts() {
        XCTAssertTrue(isValidPort("1"))
        XCTAssertTrue(isValidPort("80"))
        XCTAssertTrue(isValidPort("443"))
        XCTAssertTrue(isValidPort("8787"))
        XCTAssertTrue(isValidPort("65535"))
    }

    func testPortZeroRejected() {
        XCTAssertFalse(isValidPort("0"))
    }

    func testPortTooHighRejected() {
        XCTAssertFalse(isValidPort("65536"))
        XCTAssertFalse(isValidPort("99999"))
    }

    func testNonNumericRejected() {
        XCTAssertFalse(isValidPort("abc"))
        XCTAssertFalse(isValidPort(""))
        XCTAssertFalse(isValidPort("8787abc"))
    }

    func testNegativeRejected() {
        XCTAssertFalse(isValidPort("-1"))
    }
}

/// Tests for SSH argument array construction — verifies security invariants.
/// These mirror TunnelManager.start() argument array.
final class SSHArgumentTests: XCTestCase {

    // Mirrors the argument array built in TunnelManager.start()
    func buildSSHArgs(user: String, host: String, localPort: Int, remoteHost: String, remotePort: Int) -> [String] {
        return [
            "-N",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "\(localPort):\(remoteHost):\(remotePort)",
            "\(user)@\(host)",
        ]
    }

    func testStrictHostKeyCheckingPresent() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("StrictHostKeyChecking=accept-new"), "StrictHostKeyChecking=accept-new must be in SSH args")
    }

    func testExitOnForwardFailurePresent() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"), "ExitOnForwardFailure=yes must be in SSH args")
    }

    func testNFlagPresent() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("-N"), "-N (no command) flag must be present")
    }

    func testPortForwardingArgFormat() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 9000, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("9000:localhost:8787"), "Port forwarding arg must be localPort:remoteHost:remotePort")
    }

    func testUserAtHostFormat() {
        let args = buildSSHArgs(user: "alice", host: "server.example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        XCTAssertTrue(args.contains("alice@server.example.com"), "SSH target must be user@host")
    }

    func testShellMetacharactersAreInertBecauseArgsArray() {
        // Process.arguments bypasses shell — metacharacters are literal.
        // This test documents and verifies the design: even adversarial input
        // produces a valid argument array (no injection because execve is used directly).
        let args = buildSSHArgs(
            user: "user; rm -rf /",
            host: "host$(whoami)",
            localPort: 8787,
            remoteHost: "localhost",
            remotePort: 8787
        )
        // The arguments array contains the literal strings — no shell expansion
        XCTAssertTrue(args.last == "user; rm -rf /@host$(whoami)",
                      "Metacharacters must be literal in the args array (no shell expansion)")
    }

    func testArgumentCount() {
        let args = buildSSHArgs(user: "hermes", host: "example.com", localPort: 8787, remoteHost: "localhost", remotePort: 8787)
        // Expected: ["-N", "-o", "StrictHostKeyChecking=accept-new", "-o", "ExitOnForwardFailure=yes", "-L", "8787:localhost:8787", "hermes@example.com"]
        XCTAssertEqual(args.count, 8, "SSH args array should have exactly 8 elements")
    }
}


/// Tests for the dark-biased appearance threshold (issue #70).
/// Mirrors `AppDelegate.appearanceForLuminance(_:)` — the rule that decides
/// whether a sampled page background is "light enough" to flip the chrome
/// to .aqua. Default-dark unless the sample is genuinely near-white.
final class AppearanceThresholdTests: XCTestCase {

    // Mirrors AppDelegate.appearanceForLuminance — returns true if the
    // luminance is high enough to flip to .aqua, false otherwise (.darkAqua).
    func isLight(_ luminance: Double) -> Bool {
        return luminance > 0.85
    }

    func testCanonicalDarkThemesStayDark() {
        // hermes-webui dark-theme `--bg` luminances:
        //   #1A1A1A (Default dark)  ≈ 0.10
        //   #1F1E1C (Sienna dark)   ≈ 0.12
        //   #0D1117 (Sisyphus dark) ≈ 0.05
        XCTAssertFalse(isLight(0.10))
        XCTAssertFalse(isLight(0.12))
        XCTAssertFalse(isLight(0.05))
    }

    func testCanonicalLightThemesGoLight() {
        // hermes-webui light-theme `--bg` luminances:
        //   #FEFCF7 (Default light) ≈ 0.99
        //   #FAF9F5 (Sienna light)  ≈ 0.98
        XCTAssertTrue(isLight(0.99))
        XCTAssertTrue(isLight(0.98))
    }

    func testMurkyMiddleStaysDark() {
        // Anything in the 0.5…0.85 range is almost certainly an overlay
        // (modal dim layer, partial mount paint, half-translucent panel).
        // Default-dark unless we have strong evidence of a near-white page.
        // This is the core regression guard for issue #70.
        XCTAssertFalse(isLight(0.50))
        XCTAssertFalse(isLight(0.65))
        XCTAssertFalse(isLight(0.80))
        XCTAssertFalse(isLight(0.85))  // Boundary: 0.85 itself stays dark
    }

    func testJustAboveThresholdGoesLight() {
        // > 0.85 — strongly light. Threshold is strict (>), not >=.
        XCTAssertTrue(isLight(0.851))
        XCTAssertTrue(isLight(0.90))
    }

    func testEdgeCases() {
        XCTAssertFalse(isLight(0.0))
        XCTAssertTrue(isLight(1.0))
    }
}

/// Tests for the /api/* navigation guard (issue #76).
/// Mirrors the path-prefix check in BrowserWindowController.webView(_:decidePolicyFor:).
/// API endpoints should never become full-page navigations — the WebUI's JS
/// treats them as fetch targets only, and JSON error responses would render
/// raw if a navigation slipped through.
final class APINavigationGuardTests: XCTestCase {

    // Mirrors BrowserWindowController.webView(_:decidePolicyFor:) check
    func shouldCancelAsAPINav(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.path.hasPrefix("/api/")
    }

    func testApiPathsAreCancelled() {
        XCTAssertTrue(shouldCancelAsAPINav("http://localhost:8787/api/sessions"))
        XCTAssertTrue(shouldCancelAsAPINav("http://localhost:8787/api/updates/apply"))
        XCTAssertTrue(shouldCancelAsAPINav("http://localhost:8787/api/chat/stream"))
        XCTAssertTrue(shouldCancelAsAPINav("https://my-server.example.com/api/anything"))
    }

    func testNonApiPathsAreAllowed() {
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/login"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/static/style.css"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/manifest.json"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/sw.js"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/health"))
    }

    func testApiPrefixIsExact() {
        // /api-docs and similar should NOT match — the prefix must be /api/
        // (with the trailing slash) so we don't false-positive on routes
        // that happen to start with the letters "api".
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api-docs"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/apidocs"))
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/apipreview"))
    }

    func testApiAtRootEdge() {
        // /api alone (no trailing slash) is ambiguous — we choose to allow it
        // because the WebUI doesn't have a bare /api endpoint and a future
        // /api landing page (docs?) shouldn't be silently blocked.
        XCTAssertFalse(shouldCancelAsAPINav("http://localhost:8787/api"))
    }
}
