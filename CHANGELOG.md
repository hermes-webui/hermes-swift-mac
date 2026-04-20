# Changelog

## [v1.3.6] — 2026-04-20

### Fixed
- **`build.sh` now embeds entitlements in local ad-hoc builds** — `codesign` in `build.sh`
  was signing without `--entitlements Entitlements.plist`, so locally-built `.app` bundles
  never had any embedded entitlements (including `com.apple.security.device.audio-input`).
  CI was correct (it already passed `--entitlements`). Local builds now embed the same
  entitlements as CI-signed DMGs, making mic and other entitlement-gated features testable
  without a full CI run. (reviewer follow-up from #50)
- **Stale comment in `LaunchBehaviorTests`** — the warm-up regression history comment still
  referenced `default(for:)` and omitted the v1.3.5 entitlement root cause. Updated to
  accurately describe the fix history through v1.3.5. (reviewer follow-up from #50)

## [v1.3.5] — 2026-04-20

### Fixed
- **Microphone actually works — root cause finally found** — the `Entitlements.plist` had
  `com.apple.security.device.microphone` which is not a valid hardened-runtime entitlement
  key and is silently ignored by the codesigner. The correct key is
  `com.apple.security.device.audio-input`. Every DMG since the beginning of the project was
  signed without the actual mic entitlement, making `getUserMedia()` fail at the OS level
  regardless of TCC status. Fixed in `Entitlements.plist`. CI applies the plist via
  `--entitlements Entitlements.plist` so the fix propagates automatically.
- **WKUIDelegate mic delegate no longer short-circuits on `.authorized`** — the previous
  implementation checked `AVCaptureDevice.authorizationStatus` and called
  `decisionHandler(.grant)` directly when `.authorized`, bypassing `requestAccess`. That
  bypass skips the XPC message to `tccd` that WebContent needs for its capture attribution
  to succeed. The delegate now always routes through `AVCaptureDevice.requestAccess` — when
  already `.authorized` it completes immediately with no UI, when `.notDetermined` it shows
  the OS prompt, when `.denied` it shows the recovery alert. (user-reported)
- **`warmUpCaptureSubsystem` now uses `requestAccess` instead of `AVCaptureDevice.default`** —
  `default(for: .audio)` only queries IOKit and does not contact `tccd`. `requestAccess`
  sends the XPC message that primes the attribution chain for WebContent.

### Added
- **Regression documentation tests** — `LaunchBehaviorTests.swift` with documented invariants
  for `warmUpCaptureSubsystem` and the window frame autosave pattern. Tests pass trivially
  but carry the full regression history so future refactors cannot delete these invariants
  silently. Test count: 20 → 22. (reviewer follow-up from #49)

## [v1.3.4] — 2026-04-20

### Fixed
- **Microphone actually works again** — `getUserMedia()` was failing with `NotAllowedError`
  even when TCC was `.authorized` (mic enabled in System Settings). Root cause: removing the
  launch-time `requestMicrophonePermission()` call in v1.3.2 also removed its undocumented
  side effect of initialising AVFoundation in the host process. The WebContent XPC process
  has no `audio-input` entitlement of its own and inherits TCC attribution via the host's
  active AVFoundation session. Without that session, capture fails at the platform layer
  regardless of the delegate returning `.grant`. Fixed: `warmUpCaptureSubsystem()` calls
  `AVCaptureDevice.default(for: .audio)` silently at launch — no UI, no prompt, no change
  in UX — purely to establish the attribution chain that WebContent inherits.
  (user-reported regression since v1.3.2)
- **Shared window autosave name constant** — `"HermesMainWindow"` appeared twice in
  `BrowserWindowController`: once as the `windowFrameAutosaveName` value and once embedded
  in the derived UserDefaults key `"NSWindow Frame HermesMainWindow"`. Extracted to
  `private static let windowAutosaveName`. The derived key is now interpolated from the
  constant, eliminating the drift risk. (reviewer follow-up from #48)

## [v1.3.3] — 2026-04-20

### Fixed
- **Microphone "access denied" error after v1.3.2 upgrade** — v1.3.2 correctly removed the
  aggressive launch-time mic prompt, but also inadvertently removed the recovery path for users
  whose TCC permission was already `.denied`. Those users got silent failure with no way back.
  Fixed: the `.denied` branch now calls `decisionHandler(.deny)` immediately (so WebKit doesn't
  wait) and then shows a single "Open System Settings" alert pointing to Privacy & Security →
  Microphone. Throttled to once per app session so it can't spam. (user-reported regression from v1.3.2)
- **Window size still resetting to default after v1.3.2** — the v1.3.2 fix called
  `setFrameAutosaveName` and `setFrameUsingName` on the raw `NSWindow` before `super.init`.
  `NSWindowController` has its own `windowFrameAutosaveName` property that both saves and
  restores the frame — when the controller initialises, its default empty value overwrote the
  window-level setting, so subsequent resizes were never persisted. Fixed: removed the window-level
  calls and set `self.windowFrameAutosaveName = "HermesMainWindow"` on the controller after
  `super.init`. AppKit now manages save and restore atomically. `center()` is guarded to
  first-launch only. (user-reported regression from v1.3.2)

## [v1.3.2] — 2026-04-20

### Fixed
- **Microphone permission prompt no longer appears on every launch** — removed the proactive
  `requestMicrophonePermission()` call from `applicationDidFinishLaunching`. That call fired
  on every launch and, once the user had denied mic access, showed an `NSAlert` on *every*
  subsequent launch regardless of whether the mic was needed. The `WKUIDelegate` method
  `requestMediaCapturePermissionFor` already handles mic grants correctly and lazily — the
  OS prompt only appears the first time the user actually clicks the mic button in the web UI.
  (user-reported)
- **Window size now persists across launches** — for programmatically created `NSWindow`
  instances, `setFrameAutosaveName` saves future frame changes but does not restore the
  previously saved frame on re-creation. Added `setFrameUsingName("HermesMainWindow")`
  immediately after the autosave call; `center()` now only runs on first launch (when no
  saved frame exists). Last used size and position are preserved across restarts. (user-reported)
- **Navigation failure double-fire guard** — both `didFailProvisionalNavigation` and the
  5xx `decidePolicyFor navigationResponse` handler can fire on the same failing load event
  during teardown. Added `didReportNavigationFailure` flag so the error window is only
  opened once per navigation attempt.

## [v1.3.1] — 2026-04-20

### Fixed
- **Shared zoom key constant** — `"webViewMagnification"` was defined as a private static
  in `AppDelegate` and duplicated as a bare string literal in `BrowserWindowController`.
  Made `AppDelegate.zoomKey` internal so `BrowserWindowController` references the single source
  of truth. (reviewer follow-up from #44)
- **NWPathMonitor reconnect scope documented** — added inline comment to `scheduleAutoReconnect`
  clarifying that it fires on network-link events only, not backend-health events.
- **`(NSApp.delegate as? AppDelegate)` cast comment** — acknowledged the intentional coupling
  and why a full protocol abstraction isn't warranted here.

## [v1.3.0] — 2026-04-20

### Added
- **Auto-reconnect on network restore (NWPathMonitor)** — when WiFi drops and comes back,
  or a VPN connects, the app automatically re-attempts connection without any manual click.
  Only fires when the app is already in an error or disconnected state; no action is taken
  if the backend is simply down with a healthy network. Uses `Network.framework`
  `NWPathMonitor`, no Accessibility permission required. (closes #38)
- **Zoom level persistence** — zoom level (Cmd++/Cmd+-/Cmd+0) is now saved to UserDefaults
  and restored after every page load, including reconnects. (part of closes #43)
- **Full-screen state persistence** — if the app was in full-screen when quit, it returns to
  full-screen on next launch. Uses `NSWindowDelegate` `windowDidEnterFullScreen`/
  `windowDidExitFullScreen` callbacks. (part of closes #43)
- **Dock icon badge when offline** — the Dock icon shows a "!" badge when the backend is
  unreachable (direct mode health check failure or SSH tunnel disconnects). Clears
  automatically when the connection is restored. Visible even when the window is hidden. (closes #39)
- **View → Open in Browser** — opens the configured Hermes URL in the system default browser.
  Useful for comparison or debugging without changing any settings.

## [v1.2.2] — 2026-04-20

### Fixed
- **Preferences window truncation** — widened window from 480 to 520px. "Save & Reconnect" button width increased (100 → 140px) so the label no longer clips. Notification checkbox width increased (290 → 330px) to fit the full label. All section headers, dividers, and input fields scaled accordingly. (fixes #34)

### Added
- **Window → Show Hermes (⌘⇧H)** — menu item in the Window menu that mirrors the global hotkey, making it discoverable. Teaches the shortcut to users who scan menus. (fixes #35)
- **Preferences: global shortcut label** — read-only "Global shortcut: ⌘⇧H — bring Hermes forward from any app" row in the APP section of Preferences. (fixes #35)
- **README: Keyboard shortcuts table** — new section listing all six keyboard shortcuts including the global ⌘⇧H. (fixes #35)

## [v1.2.1] — 2026-04-20

### Fixed
- **RegisterEventHotKey OSStatus now checked** — if Cmd+Shift+H is already claimed by another app (Alfred, Raycast, etc.), a diagnostic `NSLog` fires instead of silently no-opping. Surfaced by the v1.2.0 independent review.
- **Redundant `notificationsEnabled` seed removed** — `seedDefaultsIfNeeded()` was setting `notificationsEnabled` alongside `UserDefaults.standard.register(defaults:)`, which already covers both fresh installs and upgrades. The seed in `register(defaults:)` is the authoritative one; the duplicate in `seedDefaultsIfNeeded` is removed.
- **Notifications checkbox init cleaned up** — `target` and `action` are now set in the `NSButton` initializer directly, removing the redundant two-line post-init reassignment.

## [v1.2.0] — 2026-04-20

### Fixed
- **Notification copy** — preferences toggle now reads "Show a notification when a response completes while the **app** is in the background" — replacing the old "tab" wording left over from browser context. The toggle is wired to a new UserDefaults key (`notificationsEnabled`, default on) so users can disable native notifications. (fixes #28)

### Added
- **Cmd+,** — opens Preferences (standard macOS keyboard shortcut). Already wired; documented here explicitly.
- **Cmd+R** — reloads the WebUI page via a new View → Reload menu item.
- **Cmd+W** — hides the window instead of quitting. App stays running in the Dock; clicking the Dock icon brings it back. `applicationShouldTerminateAfterLastWindowClosed` returns `false` and `applicationShouldHandleReopen` re-surfaces the window.
- **Window position memory** — `setFrameAutosaveName("HermesMainWindow")` restores last size and position on every launch.
- **Global hotkey Cmd+Shift+H** — brings Hermes forward from any app using Carbon `RegisterEventHotKey`. No Accessibility permission required; works on first launch. (closes #6)

## [v1.1.0] — 2026-04-19

### Added
- **Launch at login** — Preferences now includes a "Launch at login" checkbox (macOS 13+, SMAppService). Correctly handles `.requiresApproval` state and shows a System Settings nudge. Disabled with an inline note on macOS 12. (fixes #3)
- **View zoom — Cmd+/Cmd− keyboard shortcuts** — new View menu with Zoom In, Zoom Out, and Actual Size. Pinch-to-zoom was already enabled; this adds keyboard control. (fixes #24)
- **Connection status in window title** — direct-mode window title now shows the active backend host and a live indicator (● connected / ○ offline). A 30-second health poll detects when the backend goes away without a full page reload. (fixes #29)

### Fixed
- **Non-localhost URLs silently failing** — plain `http://` to Tailscale IPs, LAN addresses, and custom hostnames was blocked by App Transport Security in WKWebView. Added `NSAllowsArbitraryLoadsInWebContent` to Info.plist (both `build.sh` and CI workflow). URLSession (used for connection preflight) keeps default ATS restrictions. (fixes #25)
- **Dark mode white flash on startup** — WKWebView rendered white before the dark theme loaded. Set `underPageBackgroundColor` to `.windowBackgroundColor` (macOS 12+) and added a `documentStart` userScript to set the HTML background before first paint. (fixes #23)
- **Error screen didn't name the backend repo** — first-time users who hit "Cannot connect" had no way to find the backend. Added a clickable "github.com/nesquena/hermes-webui" link to the error screen in direct mode. (fixes #27)

## [v1.0.9] — 2026-04-16

### Fixed
- **SSH tunnel silently broken on servers where `localhost` resolves to IPv6 first** — the tunnel forwarded to `localhost:<port>` on the remote side, but many Linux systems map `localhost` to `::1` ahead of `127.0.0.1` in `/etc/hosts`. Combined with the common case of dev servers binding only to IPv4 `127.0.0.1`, ssh would connect to `[::1]:<port>` and get "connection reset" on every request — while the local port check happily reported "Tunnel connected". The forward now always targets `127.0.0.1`, matching what most dev servers bind to.
- **"Tunnel connected" shown even when the tunnel was end-to-end broken** — readiness check used to be a local TCP connect to the forwarded port, which ssh accepts immediately regardless of whether the far end is reachable. Replaced with an HTTP round-trip probe so the status reflects what the browser will actually experience.
- **Try Again button on the connection-error screen led to a permanent white window** — the HTML error page was loaded with a nil base URL, so `window.location.reload()` reloaded `about:blank`. Replaced the WebView error page with a small native error window whose Try Again button re-runs the full connection flow.

### Changed
- **Connection failures show a compact native window instead of a full-size WebView error page.** The main browser window only opens after the app has verified the server responds — an HTTP preflight runs in direct mode, and in SSH mode the tunnel's HTTP probe gates the browser. If either fails, a small native "Cannot connect" window appears with Try Again and Preferences… buttons.

## [v1.0.8] — 2026-04-17

### Fixed
- **Test Connection false "Unreachable"** — clicking Test Connection against a running server often showed "✗ Unreachable" even when the server was working. Two bugs: the probe used a `HEAD` request (many dev servers return 405/501 for HEAD even when GET works), and the success range was restricted to HTTP 200–399 (so a 404 or 500 falsely showed as unreachable). Now uses GET and treats any HTTP response as reachable — only an actual network failure shows ✗.
- **App icon rendered with a white chrome frame in the Dock** — the source PNG had a ~260 px opaque light-gray margin around the squircle, which showed up as a pale tile behind the icon on dark Dock backgrounds. Replaced with a properly cropped icon where the squircle fills the full canvas edge-to-edge and the area outside the rounded corners is genuinely transparent.

### Changed
- **Release notes now mirror the CHANGELOG.** The GitHub release body (and therefore Sparkle's "update available" dialog) now starts with a "What's changed" section auto-extracted from this file for the matching version tag, so users can see the actual list of fixes instead of generic download boilerplate. New releases without a CHANGELOG entry show a clear placeholder.

## [v1.0.7] — 2026-04-17

### Fixed
- **Auto-update "error launching the installer"** — clicking **Install Update** from the Sparkle dialog failed with "An error occurred while launching the installer" because the app was shipping Sparkle's sandboxed XPC services (`Downloader.xpc`, `Installer.xpc`) despite not being sandboxed itself. Per Sparkle's own docs, XPC services are only for sandboxed apps; shipping them in a non-sandboxed app causes launchd to reject the XPC launch. With the XPCs removed from the embedded framework, Sparkle falls back to its in-process installer path, which is the supported flow for non-sandboxed apps.

## [v1.0.6] — 2026-04-17

### Added
- macOS notifications (#8) — when a response finishes while the app window is in the background, a native macOS notification appears. Permission is requested on first trigger. Works via a debounced MutationObserver injected into the WebView.
- Test Connection button in Preferences (#4) — click to verify the target URL is reachable before saving. Shows "✓ Connected" or "✗ Unreachable" inline with a 5-second timeout. Works for both direct and SSH tunnel modes.

### Fixed
- White screen on failed connection (#12) — if the WebView cannot reach the server, a helpful error page now loads instead of a blank white screen. Shows the target URL, mode-specific guidance (direct: start command, SSH: tunnel check), and a Try Again button.

## [v1.0.4] — 2026-04-16

### Added
- Sparkle 2 auto-update support — app now checks `https://hermes-webui.github.io/hermes-swift-mac/appcast.xml` on launch and shows a native update dialog when a new version is available. A "Check for Updates…" menu item is available under the app menu at any time. (PR #21, closes #17)
- `Entitlements.plist` — hardened runtime entitlements for network access and microphone. Required for notarization. App remains unsandboxed so SSH tunnel (NSTask) continues to work. (PR #21)
- `appcast.xml` template in repo root — Sparkle update feed published at `https://hermes-webui.github.io/hermes-swift-mac/appcast.xml`. (PR #21)

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
