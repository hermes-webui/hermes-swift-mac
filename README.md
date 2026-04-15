# Hermes Agent for macOS

A native macOS desktop app for [Hermes Web UI](https://github.com/nesquena/hermes-webui). Built with Swift and WKWebView — no Electron, no dependencies beyond Xcode Command Line Tools. Created by [@redsparklabs](https://github.com/redsparklabs)

## Install

### Option 1: Download the DMG (easiest)

1. Go to [Releases](https://github.com/hermes-webui/hermes-swift-mac/releases)
2. Download the latest `Hermes-Agent-vX.X.X.dmg`
3. Open the DMG and drag **Hermes Agent** to your Applications folder
4. **First launch:** macOS will show a Gatekeeper warning since the app is not code-signed. To open it:
   - Right-click the app and choose **Open**, then click **Open** in the dialog, OR
   - Run this in Terminal:
     ```bash
     xattr -dr com.apple.quarantine "/Applications/Hermes Agent.app"
     ```

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

- SSH connections use `StrictHostKeyChecking=accept-new` — new hosts are automatically added to `~/.ssh/known_hosts`, but changed host keys are rejected (protects against MITM attacks on reconnection)
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

## Credits

Based on the original native macOS app contribution by [@redsparklabs](https://github.com/redsparklabs) in [hermes-webui PR #544](https://github.com/nesquena/hermes-webui/pull/544).

## License

Same license as [hermes-webui](https://github.com/nesquena/hermes-webui).
