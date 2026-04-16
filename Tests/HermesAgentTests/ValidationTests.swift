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
