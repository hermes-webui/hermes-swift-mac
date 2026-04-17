# Changelog

## [v1.0.4] — 2026-04-16

### Added
- Sparkle 2 auto-update support — app now checks `https://get-hermes.ai/appcast.xml` on launch and shows a native update dialog when a new version is available. A "Check for Updates…" menu item is available under the app menu at any time. (PR #21, closes #17)
- `Entitlements.plist` — hardened runtime entitlements for network access and microphone. Required for notarization. App remains unsandboxed so SSH tunnel (NSTask) continues to work. (PR #21)
- `appcast.xml` template in repo root — Sparkle update feed published at `https://get-hermes.ai/appcast.xml`. (PR #21)

### Fixed
- WKWebView navigation guard — external links (any http/https URL that is not localhost or the configured SSH host) now open in Safari instead of navigating inside the app. `file://` URLs are blocked entirely. (PR #21, closes #7)

### Changed
- CI release workflow now imports a Developer ID Application certificate, signs the app with hardened runtime, notarizes via `notarytool`, and staples the ticket to the DMG. Users on v1.0.4+ will no longer see the Gatekeeper "unidentified developer" warning on first launch. (PR #21)
- CI generates a Sparkle ed25519 signature for each DMG and embeds it in the release notes for appcast maintenance. (PR #21)

## [v1.0.3] — 2026-04-16

### Added
- Microphone permission prompt at app launch — macOS shows the system dialog on first run before the user touches the mic button. If previously denied, a native alert appears with an "Open System Settings" button linking directly to Privacy & Security → Microphone. (PR #18, fixes #16, by @redsparklabs)
- `requestMediaCapturePermissionFor` WKUIDelegate method — WKWebView now forwards microphone access requests through the macOS TCC authorization lifecycle before granting or denying `getUserMedia`. Without this, the browser `getUserMedia` call silently fails even when system permission is granted. (PR #18, fixes #16, by @redsparklabs)
- `NSMicrophoneUsageDescription` added to Info.plist (both build.sh and CI workflow) — macOS requires this string to show the system microphone permission dialog. Previously present only in build.sh, now also in the CI workflow so downloaded DMGs work correctly. (PR #18, fixes #16)

### Fixed
- Web notification permission prompts suppressed — a WKUserScript overrides `Notification.requestPermission` to always resolve as "denied", preventing browser-style permission dialogs from appearing inside the native wrapper. UNUserNotificationCenter is the correct path for response alerts in a native app. (PR #18, fixes #14, by @redsparklabs)
- `webkitSpeechRecognition` suppressed via WKUserScript — forces hermes-webui to fall back to its MediaRecorder + `/api/transcribe` backend path, which works reliably. WebKit's built-in local speech model is slow and inconsistent. (PR #18, by @redsparklabs)

All notable changes to Hermes Agent for macOS are documented here.

## [v1.0.2] — 2026-04-16

### Fixed
- Buttons like "New conversation" had no effect when the WebView lost focus; the first click was consumed entirely by focus restoration and never reached JavaScript. Fixed by subclassing `WKWebView` as `HermesWebView` and overriding `acceptsFirstMouse` to return `true`, so a refocusing click also registers as content interaction. (PR #19, fixes #13, by @redsparklabs)
- Keyboard shortcuts (Cmd+K, etc.) required an extra click after switching away and back. Fixed by implementing `NSWindowDelegate.windowDidBecomeKey` to restore WebView keyboard focus whenever the window becomes key. (PR #19, by @redsparklabs)

## [v1.0.1] — 2026-04-15

### Fixed
- `CFBundleShortVersionString` missing from `build.sh` — locally-built apps showed an empty version string in About dialog and Finder Get Info. Now set from the version argument. (PR #1)
- `SplashWindowController` container view did not resize with the window — missing `autoresizingMask = [.width, .height]`. Fixed. (PR #1)

### Changed
- README improvements: added install instructions, Gatekeeper workaround, SSH security section, architecture table, troubleshooting guide. (PR #1)

## [v1.0.0] — 2026-04-15

Initial public release.

- Native macOS app wrapping Hermes Web UI in a WKWebView window — no Electron, no dependencies beyond Xcode Command Line Tools
- Direct (local) mode connecting to `http://localhost:8787` by default
- SSH tunnel mode with full lifecycle management — start, monitor, reconnect, graceful teardown on quit
- Clipboard integration: paste text (JSON-encoded for safety) and images (base64, in-memory) via Cmd+V
- File upload support via the native open panel
- Native Preferences window (Cmd+,) with port validation and scheme enforcement
- Splash screen while connecting or establishing the SSH tunnel
- Status bar with live tunnel state and one-click Reconnect button (SSH mode only)
- Edit menu for Undo, Redo, Cut, Copy, Paste, Select All (required for WKWebView responder chain)
- Safe signal handling via DispatchSource (SIGTERM, SIGINT)
- SSH security: `StrictHostKeyChecking=accept-new`, `ExitOnForwardFailure=yes`, `Process.arguments` array (no shell injection)
- Universal binary (arm64 + x86_64) built and released via GitHub Actions on tag push
- Created by [@redsparklabs](https://github.com/redsparklabs)
