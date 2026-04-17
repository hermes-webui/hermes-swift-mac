# Hermes Agent for macOS

A native macOS desktop app for [Hermes Web UI](https://github.com/nesquena/hermes-webui). Built with Swift and WKWebView — no Electron, no dependencies beyond Xcode Command Line Tools. Created by [@redsparklabs](https://github.com/redsparklabs)

<img width="1470" height="922" alt="Hermes Agent screenshot" src="https://github.com/user-attachments/assets/8e704e62-c736-4827-ba50-c41a21d9922f" />

---

## What you need

Hermes Agent is a native window for [Hermes Web UI](https://github.com/nesquena/hermes-webui). The app itself is just a wrapper — it needs Hermes Web UI running somewhere to be useful. Without it you'll see a connection error on launch.

**Required:** Hermes Web UI running on your Mac or a remote server.
**Optional for remote servers:** SSH key authentication configured for that server.
**macOS:** 12 (Monterey) or later.

---

## Setup

Pick the path that matches where you're starting from.

### Path 1 — New to Hermes: install everything locally

First, get Hermes Web UI running on your Mac:

```bash
git clone https://github.com/nesquena/hermes-webui.git ~/hermes-webui-public
cd ~/hermes-webui-public
bash start.sh
```

This starts the Hermes server at `http://localhost:8787`. Follow the [Hermes Web UI README](https://github.com/nesquena/hermes-webui#readme) to configure your API keys during first-run onboarding.

Then install Hermes Agent:

1. Download the latest `Hermes-Agent-vX.X.X.dmg` from [Releases](https://github.com/hermes-webui/hermes-swift-mac/releases)
2. Open the DMG and drag **Hermes Agent** to your Applications folder
3. Launch the app — it connects to `http://localhost:8787` by default, which is exactly where you just started Hermes Web UI

No configuration needed. It works out of the box.

---

### Path 2 — Already have Hermes Web UI running locally

If Hermes Web UI is already running on your Mac:

1. Download the latest DMG from [Releases](https://github.com/hermes-webui/hermes-swift-mac/releases)
2. Drag **Hermes Agent** to Applications and launch it

The default Target URL is `http://localhost:8787`. If you run Hermes on a different port, open **Preferences** (⌘,), update the Target URL, and click **Save & Reconnect**.

You can verify the connection before saving with the **Test Connection** button.

---

### Path 3 — Hermes Web UI on a remote server

If Hermes Web UI runs on a server you access via SSH:

**Before you start:** make sure SSH key authentication is working for that server — `ssh user@your-server` should connect without a password prompt.

1. Download the latest DMG from [Releases](https://github.com/hermes-webui/hermes-swift-mac/releases)
2. Drag **Hermes Agent** to Applications and launch it
3. Open **Preferences** (⌘,)
4. Set **Connection Mode** to **SSH Tunnel**
5. Fill in:
   - **Username** — your SSH username on the remote server
   - **Host** — the server's hostname or IP address
   - **Local Port** — port on your Mac (default: 8787)
   - **Remote Port** — port where Hermes Web UI runs on the server (default: 8787)
6. Click **Test Connection** to verify, then **Save & Reconnect**

The app opens an SSH tunnel on launch, monitors it, and tears it down cleanly on quit. The status bar at the bottom of the window shows tunnel state and a one-click Reconnect button if the connection drops.

---

## Install options

### Download the DMG (recommended)

Go to [Releases](https://github.com/hermes-webui/hermes-swift-mac/releases), download the latest DMG, open it, and drag Hermes Agent to your Applications folder. The app is signed with a Developer ID certificate and notarized by Apple — no Gatekeeper warning.

### Build from source

Requires Xcode Command Line Tools:

```bash
xcode-select --install   # if not already installed

git clone https://github.com/hermes-webui/hermes-swift-mac.git
cd hermes-swift-mac
./build.sh
```

This compiles the app, bundles it with the icon, and installs it to `/Applications/Hermes Agent.app`.

---

## Features

- Native macOS app — Dock icon, standard menu bar, works like any Mac app
- Loads Hermes Web UI in a WKWebView window (no browser needed, no Electron)
- Direct mode for local Hermes instances, SSH tunnel mode for remote servers
- Clipboard integration — paste text and images (⌘V) directly into the chat
- File upload via the paperclip button
- Preferences window (⌘,) with Test Connection button to verify before saving
- Status bar showing live tunnel state (SSH mode) with one-click reconnect
- macOS notifications when an AI response finishes while the window is in the background
- Voice input — microphone permission requested on first use
- External links open in Safari, not inside the app
- Auto-update via Sparkle — checks for new versions on launch, or use app menu → Check for Updates…
- Signed and notarized — no Gatekeeper warning on first launch

---

## Configuration

Open **Preferences** (⌘,):

| Setting | Description |
|---------|-------------|
| **Connection Mode** | Direct (local) or SSH Tunnel |
| **Target URL** | URL to load (default: `http://localhost:8787`) |
| **Username** | SSH username (SSH mode only) |
| **Host** | SSH server hostname or IP (SSH mode only) |
| **Local Port** | Port on your Mac for the tunnel (SSH mode only) |
| **Remote Port** | Port where Hermes Web UI listens on the server (SSH mode only) |

Settings persist across launches.

---

## SSH security

- `StrictHostKeyChecking=accept-new` — on the first connection to a new host, the key is added to `~/.ssh/known_hosts` automatically. On all later connections, a changed host key is rejected, protecting against MITM attacks after the first connect.
- `ExitOnForwardFailure=yes` — the tunnel fails immediately if port forwarding can't be established rather than connecting silently with a broken tunnel.
- SSH key authentication is required — password auth is not supported.

---

## Troubleshooting

**Connection error or blank page on launch**
Hermes Web UI isn't running. If you're using Direct mode, start it:
```bash
cd ~/hermes-webui-public && bash start.sh
```
Then open Preferences and click **Save & Reconnect**, or just relaunch the app.

**"Unreachable" in Test Connection**
- Direct mode: Hermes Web UI isn't running on the configured URL. Check the URL and port.
- SSH mode: Hermes Web UI isn't running on the remote server, or SSH key auth isn't configured. Test with `ssh user@your-server` in Terminal first.

**SSH tunnel shows "disconnected" immediately**
- `ssh user@your-server` should work without a password in Terminal. If it prompts for one, set up SSH key auth first.
- The remote port must match where Hermes Web UI is actually listening (default: 8787).

**Voice input not working**
macOS requires explicit permission. On first launch a system dialog appears — if you denied it:
1. Open **System Settings → Privacy & Security → Microphone**
2. Enable **Hermes Agent**
3. Restart the app

**Gatekeeper blocks the app**
You're on a version older than v1.0.4. Download the latest release — v1.0.4 and later open without any warning.

**App icon looks blurry after building from source**
Run `killall Dock` to refresh the icon cache.

---

## Architecture

```
Sources/HermesAgent/
├── main.swift                        — Entry point, signal handling
├── AppDelegate.swift                 — App lifecycle, menu, Sparkle updater
├── BrowserWindowController.swift     — WKWebView window, clipboard, notifications, error page
├── TunnelManager.swift               — SSH process management, port probe, monitoring
├── PreferencesWindowController.swift — Settings UI, test connection
└── SplashWindowController.swift      — Launch splash screen
```

| File | Purpose |
|------|---------|
| `Package.swift` | Swift Package Manager manifest (macOS 12+, Swift 5.9+) |
| `build.sh` | Build script — compiles, bundles .app, converts icon, installs to /Applications |
| `scripts/release.sh` | Release helper — pushes main then tag separately to ensure CI fires |
| `Tests/HermesAgentTests/` | Unit tests — run with `swift test` |

---

## Releasing

To cut a new signed and notarized release from a clean `main`:

```bash
scripts/release.sh v1.0.9
```

The script pushes `main` first, then the tag as a separate `git push`. This matters: if you push a commit and its tag together (e.g. `git push --follow-tags`), GitHub sometimes drops one of the push events and the Build and Release workflow silently doesn't fire. Splitting the pushes avoids that.

If a tag push doesn't trigger the workflow within two minutes, kick it off manually: **Actions → Build and Release macOS App → Run workflow → enter the tag**.

---

## Credits

Based on the original native macOS app contribution by [@redsparklabs](https://github.com/redsparklabs) in [hermes-webui PR #544](https://github.com/nesquena/hermes-webui/pull/544).

## License

Same license as [hermes-webui](https://github.com/nesquena/hermes-webui).
