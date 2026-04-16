# Changelog

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
