# Hermes Agent for macOS

A native macOS desktop app for [Hermes Web UI](https://github.com/nesquena/hermes-webui). Built with Swift and WKWebView — no Electron, no dependencies beyond Xcode Command Line Tools. Created by [@redsparklabs](https://github.com/redsparklabs)

<img width="1470" height="922" alt="Screenshot 2026-04-16 at 12 01 18 AM" src="https://github.com/user-attachments/assets/8e704e62-c736-4827-ba50-c41a21d9922f" />

## Install

### Option 1: Download the DMG (easiest)

1. Go to [Releases](https://github.com/hermes-webui/hermes-swift-mac/releases)
2. Download the latest `Hermes-Agent-vX.X.X.dmg`
3. Open the DMG and drag **Hermes Agent** to your Applications folder
4. Launch the app — no Gatekeeper warning, no extra steps required

> **Note:** v1.0.4 and later are signed with a Developer ID certificate and notarized by Apple. macOS will open them without any warning. If you downloaded an older version and see a Gatekeeper prompt, upgrade to the latest release.

### Option 2: Build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/hermes-webui/hermes-swift-mac.git
cd hermes-swift-mac
./build.sh
```

This compiles the app, bundles it with the icon, and installs it to `/Applications/Hermes Agent.app`.

## Connection Modes

The app supports two ways to connect to Hermes Web UI:

### Direct (Local) — default

Connect directly to a local Hermes Web UI instance. The default URL is `http://localhost:8787`. Use this if you run hermes-webui on your own machine.

### SSH Tunnel

Connect to a remote Hermes Web UI through an encrypted SSH tunnel. The app manages the SSH process lifecycle — starting the tunnel on launch, monitoring it, and tearing it down on quit. Configure your SSH credentials in Preferences.

Switch between modes in **Preferences** (⌘,) → **Connection Mode**.

## Features

- Native macOS app with Dock icon and standard menu bar
- WKWebView browser — loads the Hermes Web UI directly, no external browser needed
- Direct local mode (default) or SSH tunnel mode for remote servers
- Clipboard integration — paste text and images (⌘V) into the web UI
- File upload support via the paperclip button
- Native Preferences window (⌘,) for all connection settings
- Splash screen while connecting
- Status bar with live tunnel state and one-click reconnect (SSH mode)
- Graceful shutdown — SSH tunnel is always cleaned up on quit (⌘Q)
- Edit menu with Undo, Redo, Cut, Copy, Paste, Select All
- Reliable focus handling — clicks and keyboard shortcuts (Cmd+K etc.) work immediately after switching windows, with no extra click required
- Voice input support — microphone permission is requested at first launch; if denied, a native alert links directly to System Settings → Microphone
- **Auto-update** — app checks for new versions on launch and shows a native update dialog; also available via the app menu → Check for Updates…
- **Navigation guard** — external links open in Safari instead of inside the app; file:// URLs are blocked entirely
- **Signed and notarized** — no Gatekeeper warning on first launch (v1.0.4+)

## Configuration

Open **Preferences** (⌘,) to configure:

| Setting | Description |
|---------|-------------|
| **Connection Mode** | Direct (local) or SSH Tunnel |
| **Target URL** | URL to load in the browser (default: `http://localhost:8787`) |
| **Username** | SSH username (SSH mode only) |
| **Host** | SSH server hostname (SSH mode only) |
| **Local Port** | Port on your machine for the tunnel (SSH mode only) |
| **Remote Port** | Port on the server where hermes-webui runs (SSH mode only) |

Settings persist across launches via macOS UserDefaults.

## SSH Security

- SSH connections use `StrictHostKeyChecking=accept-new` — on the **first** connection to a new host, the host key is automatically added to `~/.ssh/known_hosts`. On all subsequent connections, a changed host key is rejected (protects against MITM attacks after the first connection)
- `ExitOnForwardFailure=yes` — the tunnel fails immediately if port forwarding can't be established (no silent failures)
- SSH key authentication is required — configure your SSH keys before using tunnel mode

## Requirements

- macOS 12+ (Monterey or later)
- For building from source: Xcode Command Line Tools
- For SSH tunnel mode: SSH key auth configured for your server

## Architecture

```
Sources/HermesAgent/
├── main.swift                      — Entry point, signal handling (DispatchSource)
├── AppDelegate.swift               — App lifecycle, menu, tunnel orchestration
├── BrowserWindowController.swift   — WKWebView window, clipboard, status bar
├── TunnelManager.swift             — SSH process management, port probe, monitoring
├── PreferencesWindowController.swift — Settings UI with mode switching
└── SplashWindowController.swift    — Launch splash screen
```

| File | Purpose |
|------|---------|
| `Package.swift` | Swift Package Manager manifest (macOS 12+, Swift 5.9+) |
| `build.sh` | Build script — compiles, bundles .app, converts icon, installs |
| `Hermes Icon.png` | Source icon (converted to .icns at build time) |
| `Tests/HermesAgentTests/` | Unit tests for validation and SSH argument logic — run with `swift test` |

## Releasing

To cut a new signed+notarized release, run from a clean `main`:

```bash
scripts/release.sh v1.0.6
```

The script pushes `main` first, then pushes the tag as a separate `git push`. This is deliberate: if you push a new commit on `main` and its tag together (e.g. `git push --follow-tags`), GitHub sometimes delivers only one of the two push events and the Build and Release workflow silently doesn't fire. Splitting the pushes avoids that race — see the v1.0.5 incident where the tag landed on origin but neither CI workflow ran and the release had to be kicked off manually with `workflow_dispatch`.

If a tag push ever fails to trigger the workflow, you can still build that tag manually: **Actions → Build and Release macOS App → Run workflow → enter the tag**.

## Troubleshooting

**"Connection refused" or blank page in Direct mode**
Hermes Web UI is not running on the configured URL. Start it first:
```bash
cd ~/hermes-webui-public && bash start.sh
```
Then use **Preferences → Reconnect** (or ⌘, → Save & Reconnect) to reload.

**Gatekeeper blocks the app on first launch**
You're likely running a version older than v1.0.4. Upgrade to the latest release — v1.0.4+ is signed and notarized and opens without any warning. If you must use an older build, right-click → Open → Open, or run:
```bash
xattr -dr com.apple.quarantine "/Applications/Hermes Agent.app"
```

**SSH tunnel shows "disconnected" immediately**
- Verify SSH key auth works in Terminal: `ssh user@your-server`
- Check that hermes-webui is running on the remote port you configured
- The remote port must match where hermes-webui listens (default: 8787)

**Voice input not working / microphone denied**
macOS requires explicit permission. On first launch, the system dialog should appear automatically. If you denied it:
1. Open **System Settings → Privacy & Security → Microphone**
2. Enable the toggle for **Hermes Agent**
3. Restart the app

**App icon looks blurry**
Run `killall Dock` after building from source to refresh the icon cache.

## Credits

Based on the original native macOS app contribution by [@redsparklabs](https://github.com/redsparklabs) in [hermes-webui PR #544](https://github.com/nesquena/hermes-webui/pull/544).

## License

Same license as [hermes-webui](https://github.com/nesquena/hermes-webui).
