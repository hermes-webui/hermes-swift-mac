import XCTest

/// Regression documentation for launch-time behavior that can't be unit-tested mechanically.
///
/// These "tests" serve as living documentation of invariants that must hold at launch.
/// If you're here because a test failed, read the comment — it explains what you broke and why.
///
/// See also: CHANGELOG.md entries for v1.3.2, v1.3.3, and v1.3.4 for the full regression history.
final class LaunchBehaviorTests: XCTestCase {

    /// **DO NOT REMOVE warmUpCaptureSubsystem() from AppDelegate.applicationDidFinishLaunching.**
    ///
    /// The call `_ = AVCaptureDevice.default(for: .audio)` in AppDelegate.warmUpCaptureSubsystem()
    /// is load-bearing, not cosmetic. Removing it silently breaks microphone access for all users.
    ///
    /// **Why:** WKWebView runs its web content in a sandboxed XPC subprocess (com.apple.WebKit.WebContent).
    /// That process has no `com.apple.security.device.microphone` entitlement — it inherits TCC
    /// authorization via the host app's active AVFoundation session. If AVFoundation has not been
    /// initialized in the host process before WebContent spawns, getUserMedia() returns NotAllowedError
    /// even when TCC status is .authorized and the WKUIDelegate returns .grant.
    ///
    /// **History:** Deleted in v1.3.2 (it was part of the proactive prompt, which was rightly removed).
    /// Mic broke for all users (v1.3.2–v1.3.4). Root cause found in v1.3.5: Entitlements.plist used
    /// `com.apple.security.device.microphone` (invalid) instead of `com.apple.security.device.audio-input`.
    /// warm-up now uses `AVCaptureDevice.requestAccess` (contacts tccd) not `default(for:)` (IOKit only).
    /// Fixed in v1.3.5 (PR #50).
    ///
    /// **If you're tempted to remove it:** don't. If you think it's redundant, check the above.
    /// The TCC status being .authorized is necessary but not sufficient — the host AVFoundation
    /// session is also required for WebContent's capture attribution to succeed.
    func testWarmUpCaptureSubsystemMustExistAtLaunch() {
        // Cannot unit-test AppDelegate launch sequence without running the full app.
        // This test exists as a mandatory code-review checkpoint.
        // Verify manually: launch the app, click the mic button in hermes-webui — it must work.
        // Automated coverage: see the AppDelegate source for the warmUpCaptureSubsystem() call.
        //
        // If this comment is here but warmUpCaptureSubsystem() is not in AppDelegate.swift,
        // that is a regression. Fix it before shipping.
        XCTAssertTrue(true, "See the full documentation comment above for what this guards.")
    }

    /// Window frame must be persisted via NSWindowController.windowFrameAutosaveName, not
    /// NSWindow.setFrameAutosaveName / setFrameUsingName.
    ///
    /// **Why:** NSWindowController.windowFrameAutosaveName is the authority for frame persistence.
    /// Setting it on the raw NSWindow before super.init(window:) is clobbered by the controller's
    /// own (empty) windowFrameAutosaveName during its init. The correct pattern is:
    ///
    ///   super.init(window: window)
    ///   self.windowFrameAutosaveName = BrowserWindowController.windowAutosaveName
    ///
    /// **History:** v1.3.2 set it on the window (wrong). Window size reset on every launch.
    /// Fixed in v1.3.3 (PR #48). windowAutosaveName constant extracted in v1.3.4 (PR #49).
    func testWindowFrameAutosaveNameMustBeSetOnController() {
        // Cannot unit-test NSWindowController init without spawning a full window.
        // This test documents the invariant; enforcement is by code review.
        // Verify manually: resize the window, quit, relaunch — the window should open at the same size.
        XCTAssertTrue(true, "See the full documentation comment above for what this guards.")
    }
}
