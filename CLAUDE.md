# CLAUDE.md — hermes-swift-mac

> Read this before touching any code. Native macOS app wrapping hermes-webui via WKWebView.

---

## What this project is

A native macOS menubar app that loads hermes-webui in a WKWebView. No sandboxing
(ad-hoc signed). Sparkle 2 for auto-updates. Optional SSH tunnel support via
`TunnelManager.swift`. Targets macOS 12+, ships as a universal arm64+x86_64 DMG.

**Language:** Swift 5.9  
**Build:** `bash build.sh` (local) or tag a `v*` to trigger CI DMG build  
**Tests:** `swift test` (runs `Tests/HermesAgentTests/ValidationTests.swift`)  
**CI:** `.github/workflows/build-release.yml` (release), `test.yml` (PR tests)  
**Latest release:** check `git tag --sort=-v:refname | head -1`

---

## Repo structure

```
Sources/HermesAgent/
  AppDelegate.swift               # App lifecycle, menu bar setup, Sparkle updater
  BrowserWindowController.swift   # Main WKWebView window + WKNavigationDelegate
  PreferencesWindowController.swift  # Target URL + settings
  SplashWindowController.swift    # Loading screen
  TunnelManager.swift             # Optional SSH tunnel (Process-based)
  main.swift                      # Entry point

Tests/HermesAgentTests/
  ValidationTests.swift           # URL validation, preference parsing tests

build.sh          # Local build — generates Info.plist heredoc, signs ad-hoc
Package.swift     # SPM — depends on Sparkle 2 only
Entitlements.plist  # No sandbox — ad-hoc signed
appcast.xml       # Sparkle update feed (hosted on GitHub Pages)
CHANGELOG.md      # One entry per release — update before every tag
```

---

## The rules

### Never push directly to main
All changes through a named branch + PR. Tests must pass. CHANGELOG entry required.

### SSH push required
```bash
eval $(ssh-agent -s) && ssh-add ~/.ssh/id_ed25519
git push origin <branch>
# or for tags:
git push origin v1.x.y
```
HTTPS token push fails for this repo. Always use ssh-agent.

### Plist key parity — build.sh AND CI workflow must match
Every `Info.plist` key must exist in **both** places:
- `build.sh` heredoc (lines ~60-100)
- `.github/workflows/build-release.yml` PlistBuddy block

If you add a key in one place and forget the other, local builds work but CI DMG
ships without the key — or vice versa. Check both every time.

### CHANGELOG before tagging
Update `CHANGELOG.md` before pushing a release tag. CI creates the GitHub Release
from the tag — if CHANGELOG is stale, the release notes will be wrong.

---

## WKWebView rules — read before touching BrowserWindowController.swift

### ATS (App Transport Security)
`http://localhost` is ATS-exempt automatically. Any other `http://` URL — Tailscale
IPs (`100.x.x.x`), LAN IPs, hostnames — is **blocked by default**.

Fix (already filed as issue #25):
```xml
<!-- In Info.plist heredoc in build.sh AND CI workflow -->
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSAllowsArbitraryLoadsInWebContent</key>
    <true/>
</dict>
```

### Navigation delegate — implement both failure callbacks
```swift
// MUST implement both — missing either causes silent failures
func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    handleNavigationFailure(error)
}
func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    handleNavigationFailure(error)
}

private func handleNavigationFailure(_ error: Error) {
    let code = (error as NSError).code
    if code == NSURLErrorCancelled { return }  // -999: filter cancelled navigations
    // Show error dialog with helpful message based on error code:
    // -1022: ATS blocked plain HTTP → suggest SSH tunnel or NSAllowsArbitraryLoadsInWebContent
    // -1004: Cannot connect → server not running or wrong URL
    // -1003: DNS failure
}
```

### Never navigate to file:// URLs
Only `http://` and `https://`. WKWebView with no sandbox has broad file access —
restrict navigation policy to `http`/`https` schemes only.

---

## Sparkle 2 — read before touching auto-update code

- `SUPublicEDKey` in Info.plist must match the private key used to sign `appcast.xml`
- `SUFeedURL` in Info.plist: `https://hermes-webui.github.io/hermes-swift-mac/appcast.xml`
- Sign inside-out for CI codesigning: XPC services → Sparkle.framework → app bundle
- `--preserve-metadata=entitlements` required when re-signing XPC services
- Never codesign the DMG before notarization — notarize the app bundle, then package into DMG
- XPC services removed from local builds (`build.sh` deletes them) — keep this

---

## SSH tunnel — read before touching TunnelManager.swift

```swift
// CORRECT: args as array (safe from shell injection)
process.arguments = ["-N", "-L", "8787:127.0.0.1:8787", "user@host"]

// WRONG: shell string (injection risk)
process.arguments = ["-c", "ssh -N -L 8787:127.0.0.1:8787 \(host)"]
```

Always use `StrictHostKeyChecking=yes` and `ExitOnForwardFailure=yes` in tunnel args.
Use `DispatchSource` for process signals, not polling.

---

## Known issues / open work

- **#25** — Non-localhost URLs (Tailscale IPs) silently fail due to ATS + server binding.
  Fix: add `NSAllowsArbitraryLoadsInWebContent` to Info.plist (in both build.sh and CI),
  and implement `didFailProvisionalNavigation` in `BrowserWindowController`.
  Server-side fix: `HERMES_WEBUI_HOST=0.0.0.0` in `.env`.

---

## Opus mentor — second opinion advisor

When uncertain about Swift APIs, WKWebView behavior, ATS configuration, or Sparkle
signing — ask opus before guessing:

```bash
# Pipe actual source + issue/PR body for highest-quality output
{ cat Sources/HermesAgent/BrowserWindowController.swift; cat build.sh; } \
  | claude --model claude-opus-4-7 --thinking enabled \
  --print 'Senior Swift/macOS engineer. [DESCRIBE SITUATION].
Review for: ATS config, WKNavigationDelegate completeness, Info.plist key parity, security.
Provide exact Swift code fixes.'
```

---

## Common gotchas

- **`gh pr view` is broken** — use `gh api repos/hermes-webui/hermes-swift-mac/pulls/NNN`
- **Read ALL PR comments chronologically** — a "still working" in comment 1 may be
  superseded by a ready signal in comment 2
- **Swift is not available on Linux** — all Swift builds must run on a macOS runner
- **`swift test` fails on Linux** — run tests in CI (macOS 14 runner) or on a Mac
- **Sparkle path in CI artifacts** — verify framework path with `find` before hardcoding
- **Universal binary** — build must produce arm64+x86_64. Use `swift build -c release`
  (SPM handles universal automatically on Apple Silicon with correct toolchain)
