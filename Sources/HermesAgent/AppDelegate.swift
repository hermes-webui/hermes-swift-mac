import AVFoundation
import Carbon.HIToolbox
import Cocoa
import Network
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {

    let appTitle = "Hermes Agent"

    let defaultSSHUser = "hermes"
    let defaultSSHHost = "your-server.com"
    let defaultLocalPort = "8787"
    let defaultRemotePort = "8787"
    let defaultTargetURL = "http://localhost:8787"

    var tunnelManager: TunnelManager!
    var splashWindow: SplashWindowController!
    /// Tracks the next cascade origin for non-first windows. Set by
    /// `cascadeTopLeft(from:)` in openBrowser so rapid Cmd+N produces a clean diagonal
    /// stack rather than every new window cascading from the same key-window position.
    /// Reset to nil whenever the array empties (no live windows → next opening is "first").
    private var nextCascadePoint: NSPoint?
    /// Active browser windows. Multiple windows enable concurrent sessions;
    /// AppKit's window-tabbing system groups them when the user prefers tabs.
    /// Order: most-recently-opened last. The "key" window for menu actions is
    /// derived from NSApp.keyWindow when present, falling back to the array tail.
    var browserWindows: [BrowserWindowController] = []
    /// The browser window targeted by menu actions (Find, Zoom, Reload, etc).
    /// Returns the front-most browser window if focused, otherwise the most
    /// recently opened one. Returns nil only when no browser window is open
    /// (e.g. error state).
    var keyBrowserWindow: BrowserWindowController? {
        if let w = NSApp.keyWindow?.windowController as? BrowserWindowController {
            return w
        }
        if let w = NSApp.mainWindow?.windowController as? BrowserWindowController {
            return w
        }
        return browserWindows.last
    }
    var errorWindow: ErrorWindowController?
    var preferencesWindow: PreferencesWindowController?
    var updaterController: SPUStandardUpdaterController!

    /// The appearance currently in effect for all Hermes windows. Updated by
    /// BrowserWindowController's theme bridge each time the web UI reports a new
    /// background colour. New windows (Preferences, Error, Splash, secondary
    /// browser) read this on init so they open in the matching theme. Defaults
    /// to .darkAqua so the very first window is dark before the bridge fires
    /// (matches the hardcoded #1a1a1a pre-paint background).
    var currentAppearance: NSAppearance? = NSAppearance(named: .darkAqua)

    /// The window background colour matching the current web-UI theme. Used as
    /// `NSWindow.backgroundColor` on browser windows so the tab-bar strip
    /// blends with the page instead of showing through the hardcoded
    /// pre-paint #1a1a1a. Defaults to that #1a1a1a so the very first window
    /// looks right before the bridge fires.
    var currentBackgroundColor: NSColor =
        NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)

    /// Apply a new appearance + window background colour to every Hermes window.
    /// Called by the BrowserWindowController theme bridge when the web UI
    /// reports a new background.
    func updateAppearance(_ appearance: NSAppearance?, backgroundColor: NSColor? = nil) {
        let appearanceChanged = appearance?.name != currentAppearance?.name
        let bgChanged = backgroundColor != nil && backgroundColor != currentBackgroundColor
        guard appearanceChanged || bgChanged else { return }
        if appearanceChanged { currentAppearance = appearance }
        if let bg = backgroundColor { currentBackgroundColor = bg }
        for browser in browserWindows {
            if appearanceChanged { browser.window?.appearance = appearance }
            if let bg = backgroundColor {
                browser.window?.backgroundColor = bg
                // Push the colour through to the SSH footer so it matches the
                // tab-bar strip (which paints with window.backgroundColor) one
                // to one — same RGB for every chrome surface.
                browser.applyChromeBackgroundColor(bg)
            }
        }
        if appearanceChanged {
            preferencesWindow?.window?.appearance = appearance
            errorWindow?.window?.appearance = appearance
            splashWindow?.window?.appearance = appearance
        }
        // Persist so next launch + new tabs/windows can open with the last-seen
        // theme instead of flashing dark while the bridge re-checks.
        if bgChanged { persistCurrentTheme() }
    }

    // MARK: - Theme cache (UserDefaults)

    private static let themeCacheKeyR = "themeCacheRed"
    private static let themeCacheKeyG = "themeCacheGreen"
    private static let themeCacheKeyB = "themeCacheBlue"
    private static let themeCacheKeyTimestamp = "themeCacheTimestamp"
    /// How fresh the cache must be to be trusted on launch. Beyond this we
    /// fall back to .darkAqua / #1a1a1a (the safe default that matches the
    /// pre-paint dark background, avoiding a white-flash for new users).
    private static let themeCacheStaleness: TimeInterval = 7 * 24 * 3600

    /// Restore currentAppearance + currentBackgroundColor from UserDefaults if
    /// the cache is fresh enough. Called once at applicationDidFinishLaunching
    /// before startTunnel so the splash and the first browser window open with
    /// the last-seen theme.
    func loadCachedTheme() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.themeCacheKeyTimestamp) != nil else { return }
        let timestamp = defaults.double(forKey: Self.themeCacheKeyTimestamp)
        let age = Date().timeIntervalSince1970 - timestamp
        guard age >= 0, age < Self.themeCacheStaleness else { return }
        let r = defaults.double(forKey: Self.themeCacheKeyR)
        let g = defaults.double(forKey: Self.themeCacheKeyG)
        let b = defaults.double(forKey: Self.themeCacheKeyB)
        // Sanity: stored components live in [0, 1]. Reject anything else and
        // keep the .darkAqua/#1a1a1a defaults so a corrupted store can't
        // produce a transparent or oversaturated chrome colour.
        guard (0.0...1.0).contains(r), (0.0...1.0).contains(g), (0.0...1.0).contains(b)
        else { return }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let isDark = luminance < 0.5
        currentAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        currentBackgroundColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Write currentBackgroundColor + a fresh timestamp to UserDefaults.
    private func persistCurrentTheme() {
        // Convert to sRGB to lock in stable component values regardless of the
        // colour space the bridge happened to construct (calibrated vs sRGB).
        let sRGB = currentBackgroundColor.usingColorSpace(.sRGB) ?? currentBackgroundColor
        let defaults = UserDefaults.standard
        defaults.set(Double(sRGB.redComponent), forKey: Self.themeCacheKeyR)
        defaults.set(Double(sRGB.greenComponent), forKey: Self.themeCacheKeyG)
        defaults.set(Double(sRGB.blueComponent), forKey: Self.themeCacheKeyB)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.themeCacheKeyTimestamp)
    }

    // Global hotkey state (fix #6, Carbon-based — no Accessibility permission required)
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?

    // NWPathMonitor auto-reconnect (fix #38)
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "hermes.network.monitor")
    private var lastPathStatus: NWPath.Status = .satisfied
    private var pendingReconnect: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Register non-persistent defaults so users upgrading from v1.1.0
        // (where notifications were always on) don't silently lose them.
        // seedDefaultsIfNeeded only persists on first-ever launch.
        UserDefaults.standard.register(defaults: [
            "notificationsEnabled": true,
            // Fix #41: default global hotkey = Cmd+Shift+H
            "globalHotkeyKeyCode": kVK_ANSI_H,
            "globalHotkeyModifiers": Int(cmdKey | shiftKey),
            "globalHotkeyEnabled": true,
        ])

        // Initialize Sparkle updater — feed URL comes from SUFeedURL in Info.plist
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        setupMenu()
        seedDefaultsIfNeeded()
        // Restore last-seen theme before any window opens so the splash and the
        // first browser window paint with the right colour instead of flashing
        // dark while the bridge runs its first sample.
        loadCachedTheme()
        warmUpCaptureSubsystem()
        setupGlobalHotkey()
        startTunnel()
        startPathMonitor()
    }


    func seedDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "sshUser") == nil {
            defaults.set(defaultSSHUser, forKey: "sshUser")
            defaults.set(defaultSSHHost, forKey: "sshHost")
            defaults.set(defaultLocalPort, forKey: "localPort")
            defaults.set(defaultRemotePort, forKey: "remotePort")
            defaults.set(defaultTargetURL, forKey: "targetURL")
            defaults.set("direct", forKey: "connectionMode")
        }
    }

    func startTunnel() {
        let defaults = UserDefaults.standard
        let connectionMode = defaults.string(forKey: "connectionMode") ?? "direct"
        let targetURL = defaults.string(forKey: "targetURL") ?? defaultTargetURL

        let splashSubtitle = connectionMode == "ssh" ? "Establishing SSH tunnel…" : "Connecting…"
        splashWindow = SplashWindowController(title: appTitle, subtitle: splashSubtitle)
        splashWindow.showWindow(nil)
        // Fix #10 (multi-window): reuse all browser windows in place when the connection
        // mode hasn't changed — preserves WKWebView state (cookies, scroll, in-flight chat)
        // for every open session. A mode switch (direct↔ssh) must rebuild every window so
        // the status-bar UI matches the new mode. We snapshot the array because openBrowser
        // and showErrorWindow can mutate browserWindows during the reconnect flow.
        let reuseWindows = !browserWindows.isEmpty &&
            browserWindows.allSatisfy { $0.connectionMode == connectionMode }
        if reuseWindows {
            browserWindows.forEach { $0.window?.orderOut(nil) }
        } else {
            browserWindows.forEach { win in
                win.isIntentionalClose = true
                win.close()
            }
            browserWindows.removeAll()
            nextCascadePoint = nil
        }
        errorWindow?.close()
        errorWindow = nil
        tunnelManager?.stop()

        if connectionMode == "ssh" {
            let user = defaults.string(forKey: "sshUser") ?? defaultSSHUser
            let host = defaults.string(forKey: "sshHost") ?? defaultSSHHost
            let localPort = Int(defaults.string(forKey: "localPort") ?? defaultLocalPort) ?? 8787
            let remotePort = Int(defaults.string(forKey: "remotePort") ?? defaultRemotePort) ?? 8787

            // Forward to 127.0.0.1 rather than "localhost" on the remote side.
            // On some servers /etc/hosts maps "localhost" to ::1 first, so ssh
            // would try [::1]:<port> and miss IPv4-only dev servers (hermes-webui
            // binds to 127.0.0.1 by default), resulting in a connection reset.
            tunnelManager = TunnelManager(
                user: user,
                host: host,
                localPort: localPort,
                remoteHost: "127.0.0.1",
                remotePort: remotePort
            )

            tunnelManager.onStatusChange = { [weak self] status in
                guard let self = self else { return }
                self.browserWindows.forEach { $0.updateStatus(status, host: host, port: localPort) }
            }

            tunnelManager.start {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.splashWindow.close()
                    if self.tunnelManager.status == .connected {
                        if reuseWindows && !self.browserWindows.isEmpty {
                            // Fix #10: reuse every existing WKWebView for session continuity.
                            for win in self.browserWindows {
                                win.reconnectInPlace(targetURL: targetURL)
                            }
                            self.browserWindows.last?.window?.makeKeyAndOrderFront(nil)
                            self.setOfflineBadge(false)
                        } else {
                            self.openBrowser(
                                targetURL: targetURL,
                                mode: "ssh",
                                sshHost: host,
                                localPort: localPort
                            )
                        }
                    } else {
                        // Reconnect failed: drop the hidden windows so showErrorWindow's
                        // close-all sweep operates on a clean array.
                        self.browserWindows.removeAll()
                        self.showErrorWindow(targetURL: targetURL, mode: "ssh")
                    }
                }
            }
        } else {
            preflightHTTP(urlString: targetURL) { reachable in
                DispatchQueue.main.async {
                    self.splashWindow.close()
                    if reachable {
                        if reuseWindows && !self.browserWindows.isEmpty {
                            // Fix #10: reuse every existing WKWebView for session continuity.
                            for win in self.browserWindows {
                                win.reconnectInPlace(targetURL: targetURL)
                            }
                            self.browserWindows.last?.window?.makeKeyAndOrderFront(nil)
                            self.setOfflineBadge(false)
                        } else {
                            self.openBrowser(
                                targetURL: targetURL,
                                mode: "direct",
                                sshHost: nil,
                                localPort: nil
                            )
                        }
                    } else {
                        self.browserWindows.removeAll()
                        self.showErrorWindow(targetURL: targetURL, mode: "direct")
                    }
                }
            }
        }
    }

    /// Opens a new browser window. The first window in a session uses the persisted
    /// frame autosave (HermesMainWindow); subsequent windows cascade from the front-most
    /// window's frame so the user can see they stacked. With `tabbingMode = .preferred`,
    /// AppKit groups windows into native tabs when the user's "Prefer Tabs" system
    /// preference is on.
    @discardableResult
    private func openBrowser(
        targetURL: String, mode: String, sshHost: String?, localPort: Int?,
        asTab: Bool = false
    ) -> BrowserWindowController {
        let isFirstWindow = browserWindows.isEmpty
        let browser = BrowserWindowController(
            urlString: targetURL,
            title: appTitle,
            connectionMode: mode,
            useFrameAutosave: isFirstWindow
        )
        // Cmd+N (asTab=false, non-first): force a separate window even though the
        // window's tabbingMode is .preferred. Setting .disallowed at show-time
        // bypasses the auto-tab decision; we restore .preferred immediately after
        // so the user can later use Window → Merge All Windows. The first window
        // has no existing tab group to join, so this guard is a no-op for it.
        if !asTab && !isFirstWindow {
            browser.window?.tabbingMode = .disallowed
        }
        browser.onReconnect = { [weak self] in
            self?.startTunnel()
        }
        browser.onNavigationFailed = { [weak self, weak browser] in
            // Multi-window: a single window's nav failure shouldn't tear down the others.
            // Drop just the failing window from the array. If it was the last one, escalate
            // to the error screen so the user sees a clear "can't reach the server" state.
            // Both `self` and `browser` are weak — the closure is stored on the controller
            // it would otherwise capture, which would create a controller→closure→controller
            // retain cycle leaking the WKWebView for the lifetime of the app.
            guard let self = self, let browser = browser else { return }
            self.browserWindows.removeAll { $0 === browser }
            browser.isIntentionalClose = true
            browser.close()
            if self.browserWindows.isEmpty {
                self.showErrorWindow(targetURL: targetURL, mode: mode)
            }
        }
        // Notify on close so we can prune browserWindows. Crucial: without this, dragging
        // a tab out, closing it, then opening a new tab would leak the closed controller
        // and AppKit would still send menu validations to a dead WKWebView.
        browser.onWindowWillClose = { [weak self] closing in
            self?.browserWindows.removeAll { $0 === closing }
        }
        if mode == "ssh", let host = sshHost, let port = localPort {
            browser.updateStatus(tunnelManager.status, host: host, port: port)
        }

        // Tabbing decision for non-first windows. We use the explicit
        // addTabbedWindow API for Cmd+T rather than relying on tabbingMode =
        // .preferred auto-tab — the auto-tab path is flaky when other state
        // (e.g. a recently .disallowed sibling, or a prior cascade frame
        // change) interferes with AppKit's heuristic, which manifests as Cmd+T
        // opening a separate window instead of joining the existing tab group.
        // For Cmd+N we still set .disallowed at show-time so the new window
        // shows standalone, and restore .preferred afterwards so the user can
        // later merge via Window → Merge All Windows.
        if !isFirstWindow {
            if asTab,
               let host = (NSApp.keyWindow ?? browserWindows.last?.window),
               let newWindow = browser.window {
                host.addTabbedWindow(newWindow, ordered: .above)
            } else if !asTab {
                browser.window?.tabbingMode = .disallowed
                // Cascade only for separate windows; tabs share the parent frame.
                if let win = browser.window,
                   let anchor = (NSApp.keyWindow ?? browserWindows.last?.window) {
                    win.setFrame(anchor.frame, display: false)
                    let from = nextCascadePoint
                        ?? NSPoint(x: anchor.frame.minX, y: anchor.frame.maxY)
                    nextCascadePoint = win.cascadeTopLeft(from: from)
                }
            }
        }

        // Fix #52: set alphaValue=0 BEFORE showWindow on the very first window only
        // — prevents the brief visible-at-full-opacity tick on app launch. For
        // subsequent windows/tabs (#42), starting at alpha 0 would hide the content
        // area while AppKit's tab bar already shows the new tab as active, which
        // reads as a flash to the user. Non-first windows fade implicitly via the
        // normal cascade — no fade-in animation needed.
        if isFirstWindow {
            browser.window?.alphaValue = 0
        }
        browser.showWindow(nil)
        browserWindows.append(browser)

        // Cmd+N path: restore .preferred after showing standalone so the user can
        // later merge this window into the tab group via Window → Merge All Windows.
        // tabbingMode is consulted at show-time for the auto-tab decision; setting
        // it back to .preferred after show doesn't pull this window into a tab group.
        if !asTab && !isFirstWindow {
            DispatchQueue.main.async {
                browser.window?.tabbingMode = .preferred
            }
        }

        // Restore full-screen state (fix #43) — only on the very first window of the
        // session. Subsequent windows opened by Cmd+N inherit the system default; the
        // user can full-screen them individually.
        if isFirstWindow && UserDefaults.standard.bool(forKey: "windowWasFullScreen") {
            DispatchQueue.main.async {
                if browser.window?.styleMask.contains(.fullScreen) == false {
                    browser.window?.toggleFullScreen(nil)
                }
            }
        }

        // Clear offline badge when connected (fix #39)
        setOfflineBadge(false)
        return browser
    }

    /// Cmd+N — open a new separate window. Always opens standalone, even if other
    /// browser windows are already grouped into native tabs. The user can later
    /// merge it into the existing tab group via Window → Merge All Windows.
    @objc func newBrowserWindow() {
        openNewBrowserSession(asTab: false)
    }

    /// Cmd+T — open a new tab in the front-most browser window's tab group.
    /// AppKit's tabbing system (windows share `tabbingIdentifier` + .preferred mode)
    /// auto-joins the new window into the existing group.
    @objc func newBrowserTab() {
        openNewBrowserSession(asTab: true)
    }

    /// AppKit's tab-bar "+" button forwards through the responder chain looking
    /// for `newWindowForTab(_:)`. Implementing it on AppDelegate (which is in the
    /// chain via NSApp) wires the plus button to the new-tab flow specifically —
    /// the "+" button is conceptually the same as Cmd+T, not Cmd+N.
    @objc func newWindowForTab(_ sender: Any?) {
        newBrowserTab()
    }

    /// Shared entry point for new-window and new-tab actions. Refuses to open
    /// when there's no live connection (avoids instant-fail windows). When
    /// asTab=false, openBrowser sets .disallowed at show-time so the new window
    /// stays standalone instead of auto-joining the existing tab group.
    private func openNewBrowserSession(asTab: Bool) {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "connectionMode") ?? "direct"
        let targetURL = defaults.string(forKey: "targetURL") ?? defaultTargetURL
        if mode == "ssh" && tunnelManager?.status != .connected { return }
        if mode == "direct" && browserWindows.isEmpty {
            // No live first window in direct mode either — let startTunnel handle it.
            startTunnel()
            return
        }
        let host = mode == "ssh" ? defaults.string(forKey: "sshHost") : nil
        let port = mode == "ssh"
            ? Int(defaults.string(forKey: "localPort") ?? defaultLocalPort)
            : nil
        openBrowser(
            targetURL: targetURL, mode: mode, sshHost: host, localPort: port, asTab: asTab)
    }

    private func showErrorWindow(targetURL: String, mode: String) {
        // Error state is global — close every browser window. The user reconnects
        // via the error window's Retry button, which calls startTunnel() and reopens
        // a single browser window. Multi-window state is intentionally not restored:
        // the connection failure could be persistent and we don't want N error windows.
        for win in browserWindows {
            win.isIntentionalClose = true
            win.close()
        }
        browserWindows.removeAll()
        nextCascadePoint = nil
        let err = ErrorWindowController(
            appTitle: appTitle,
            targetURL: targetURL,
            mode: mode
        )
        err.onRetry = { [weak self] in
            self?.errorWindow?.close()
            self?.errorWindow = nil
            self?.startTunnel()
        }
        err.onOpenPreferences = { [weak self] in
            self?.openPreferences()
        }
        err.showWindow(nil)
        err.window?.makeKeyAndOrderFront(nil)
        errorWindow = err

        // Show offline badge when in error state (fix #39)
        setOfflineBadge(true)
    }

    /// Verify the target URL answers HTTP before opening the main browser.
    /// Any HTTPURLResponse (including 4xx/5xx) counts as reachable — we only
    /// fail on transport errors (connection refused, reset, timeout).
    private func preflightHTTP(
        urlString: String, timeout: TimeInterval = 4.0,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion(response is HTTPURLResponse)
        }.resume()
    }

    // MARK: - Dock badge (fix #39)

    func setOfflineBadge(_ offline: Bool) {
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = offline ? "!" : nil
        }
    }

    // MARK: - NWPathMonitor auto-reconnect (fix #38)

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let previous = self.lastPathStatus
                self.lastPathStatus = path.status
                // Only react to unsatisfied → satisfied transitions.
                guard previous != .satisfied, path.status == .satisfied else { return }
                self.scheduleAutoReconnect()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func scheduleAutoReconnect() {
        // NOTE: This fires on network-link restoration (WiFi up, VPN connected, etc.),
        // not on backend-health events. If the server is down but the network is healthy,
        // no extra reconnect attempts fire — the path stays .satisfied so this is never called.
        pendingReconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let inErrorState = self.errorWindow != nil
                || self.tunnelManager?.status == .disconnected
            guard inErrorState else { return }
            NSLog("[HermesAgent] Network came back — auto-reconnecting")
            self.startTunnel()
        }
        pendingReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: - AVFoundation warm-up

    /// Primes AVFoundation's TCC authorization path in the host process at launch.
    /// Required so the WebContent XPC process can complete its mic capture attribution.
    ///
    /// AVCaptureDevice.requestAccess sends an explicit message to tccd even when already
    /// .authorized (completion fires immediately, no UI). AVCaptureDevice.default(for:)
    /// only queries IOKit — it does NOT contact tccd and does NOT prime the attribution chain.
    /// Only runs when TCC is already .authorized to avoid showing a prompt at launch.
    private func warmUpCaptureSubsystem() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }  // fires immediately, no UI
    }

    func setupMenu() {
        let menuBar = NSMenu()

        // File menu — Cmd+N "New Window" is the multi-window entry point. AppKit's
        // tab system also responds to this when "Prefer Tabs" is on, opening a new tab
        // in the current group instead.
        let appMenuItem = NSMenuItem()
        menuBar.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "About \(appTitle)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appTitle)", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        // File menu — multi-window entry points (Cmd+N new window, Cmd+T new tab).
        // AppKit auto-injects the "Show Tab Bar" / "Show All Tabs" / "Move Tab to New
        // Window" / "Merge All Windows" items into the Window menu when tabbingMode is
        // set on a window — we don't need to add those manually.
        let fileMenuItem = NSMenuItem()
        menuBar.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(
            withTitle: "New Window", action: #selector(newBrowserWindow), keyEquivalent: "n")
        let newTabItem = NSMenuItem(
            title: "New Tab", action: #selector(newBrowserTab), keyEquivalent: "t")
        fileMenu.addItem(newTabItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        menuBar.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Find submenu (fix #37/#45 — makes Cmd+F discoverable via menu)
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(
            withTitle: "Find…", action: #selector(openFind), keyEquivalent: "f")
        let findNextItem = NSMenuItem(
            title: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        findMenu.addItem(findNextItem)
        let findPrevItem = NSMenuItem(
            title: "Find Previous", action: #selector(findPrev), keyEquivalent: "G")
        findPrevItem.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findPrevItem)
        findMenuItem.submenu = findMenu
        editMenu.addItem(findMenuItem)
        let windowMenuItem = NSMenuItem()
        menuBar.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Show Hermes", action: #selector(showMainWindow), keyEquivalent: "H")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        // Designating windowMenu as NSApp.windowsMenu makes AppKit auto-populate
        // it with the list of open browser windows AND auto-inject "Show Tab Bar",
        // "Show All Tabs", "Move Tab to New Window", and "Merge All Windows" items
        // for windows whose tabbingMode is .preferred. Must be set before any
        // browser window opens so AppKit observes window-add events from the start.
        NSApp.windowsMenu = windowMenu

        let viewMenuItem = NSMenuItem()
        menuBar.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(
            withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(
            withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(
            withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "")

        NSApp.mainMenu = menuBar
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Show window (mirrors global hotkey Cmd+Shift+H, fix #35)

    @objc func showMainWindow() {
        // Bring the front-most browser window to focus; if no browser window
        // exists (rare — e.g. mid-reconnect), open one.
        if let win = keyBrowserWindow {
            win.showWindow(nil)
            win.window?.makeKeyAndOrderFront(nil)
        } else if !browserWindows.isEmpty {
            browserWindows.last?.showWindow(nil)
            browserWindows.last?.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Page reload (fix — Cmd+R)

    @objc func reloadPage() {
        keyBrowserWindow?.webViewForZoom?.reload()
    }

    // MARK: - Find forwarding (fix #37/#45 — menu items delegate to BrowserWindowController)

    @objc func openFind() {
        // Toggle the find bar in the front-most browser window — if already open,
        // Cmd+F closes it (standard macOS behaviour).
        (keyBrowserWindow?.window as? BrowserWindow)?.onFind?()
    }

    @objc func findNext() {
        (keyBrowserWindow?.window as? BrowserWindow)?.onFindNext?()
    }

    @objc func findPrev() {
        (keyBrowserWindow?.window as? BrowserWindow)?.onFindPrev?()
    }

    // MARK: - Open in system browser (bonus feature)

    @objc func openInBrowser() {
        let urlString = UserDefaults.standard.string(forKey: "targetURL") ?? "http://localhost:8787"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - View zoom (fix #24, #43 — zoom level persisted)

    static let zoomKey = "webViewMagnification"

    @objc func zoomIn() {
        guard let webView = keyBrowserWindow?.webViewForZoom else { return }
        webView.magnification = min(webView.magnification + 0.1, 3.0)
        UserDefaults.standard.set(webView.magnification, forKey: Self.zoomKey)
    }

    @objc func zoomOut() {
        guard let webView = keyBrowserWindow?.webViewForZoom else { return }
        webView.magnification = max(webView.magnification - 0.1, 0.5)
        UserDefaults.standard.set(webView.magnification, forKey: Self.zoomKey)
    }

    @objc func zoomReset() {
        keyBrowserWindow?.webViewForZoom?.magnification = 1.0
        UserDefaults.standard.set(1.0, forKey: Self.zoomKey)
    }

    @objc func openPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
            preferencesWindow?.onSave = { [weak self] in
                self?.reloadGlobalHotkey()  // Fix #41: apply new hotkey from UserDefaults
                self?.preferencesWindow = nil
                self?.startTunnel()
            }
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Global hotkey Cmd+Shift+H (fix #6)
    // Uses Carbon RegisterEventHotKey — works without Accessibility permission,
    // fires from any app immediately on first launch.

    // MARK: - Global hotkey (configurable, fix #6 + #41)

    private func setupGlobalHotkey() {
        let defaults = UserDefaults.standard
        // Fix #41: check enabled flag; skip registration when user cleared the shortcut.
        guard defaults.bool(forKey: "globalHotkeyEnabled") else { return }
        let keyCode = UInt32(defaults.integer(forKey: "globalHotkeyKeyCode"))
        let mods    = UInt32(defaults.integer(forKey: "globalHotkeyModifiers"))

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // passUnretained is safe: NSApp owns its delegate for the app lifetime,
        // and the handler is removed in applicationWillTerminate before teardown.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // InstallApplicationEventHandler is a C macro Swift can't import — call
        // the underlying InstallEventHandler with GetApplicationEventTarget() directly.
        // Install only once; carbonEventHandler is reused on reloadGlobalHotkey.
        if carbonEventHandler == nil {
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let ptr = userData else { return noErr }
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
                    DispatchQueue.main.async {
                        // Focus the front-most browser window; do nothing if none
                        // exist (user is on splash/error and the global hotkey is
                        // a poor moment to spawn a window the user can't yet use).
                        if let win = delegate.keyBrowserWindow {
                            win.showWindow(nil)
                            win.window?.makeKeyAndOrderFront(nil)
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    return noErr
                },
                1, &eventSpec, selfPtr, &carbonEventHandler
            )
        }
        let hkID = EventHotKeyID(signature: OSType(0x4845_524D), id: 1)  // 'HERM'
        let status = RegisterEventHotKey(
            keyCode,
            mods,
            hkID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )
        if status != noErr {
            NSLog("[HermesAgent] RegisterEventHotKey failed (OSStatus %d)", status)
        }
    }

    /// Re-register the global hotkey with the current UserDefaults values.
    /// Called from Preferences save when the user changes the shortcut.
    /// Only unregisters the hotkey ref — the event handler stays installed.
    func reloadGlobalHotkey() {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
        setupGlobalHotkey()
        // Warn the user if the new shortcut couldn't be registered
        // (e.g. Cmd+Space is claimed by Spotlight).
        if UserDefaults.standard.bool(forKey: "globalHotkeyEnabled") && carbonHotKeyRef == nil {
            let alert = NSAlert()
            alert.messageText = "Shortcut unavailable"
            alert.informativeText = "This shortcut is already claimed by another app. Try a different combination."
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pathMonitor.cancel()
        pendingReconnect?.cancel()
        tunnelManager?.stop()
        // Clean up Carbon hotkey registration and release the retained self pointer.
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
            carbonEventHandler = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        // Window hidden via Cmd+W should not quit the app — keep running in Dock.
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon when all windows are hidden brings the front-most
        // one back. With multi-window, we surface the most-recently-active one;
        // the user can then expose others via the Window menu or tab bar.
        if !flag, let win = (keyBrowserWindow ?? browserWindows.last) {
            win.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
