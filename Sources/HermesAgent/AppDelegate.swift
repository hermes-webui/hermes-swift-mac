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
    var browserWindow: BrowserWindowController?
    var errorWindow: ErrorWindowController?
    var preferencesWindow: PreferencesWindowController?
    var updaterController: SPUStandardUpdaterController!

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
        // Fix #10: if the browser window is alive AND the connection mode hasn't changed,
        // hide it (orderOut) and reuse the WKWebView to preserve session state.
        // A mode switch (direct↔ssh) must rebuild the window to get the correct status bar.
        let reuseWindow = browserWindow != nil &&
            browserWindow?.connectionMode == connectionMode
        if reuseWindow {
            browserWindow?.window?.orderOut(nil)
        } else {
            browserWindow?.isIntentionalClose = true
            browserWindow?.close()
            browserWindow = nil
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
                self.browserWindow?.updateStatus(status, host: host, port: localPort)
            }

            tunnelManager.start {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.splashWindow.close()
                    if self.tunnelManager.status == .connected {
                        if reuseWindow, let existing = self.browserWindow {
                            // Fix #10: reuse existing WKWebView for session continuity.
                            existing.reconnectInPlace(targetURL: targetURL)
                            existing.window?.makeKeyAndOrderFront(nil)
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
                        self.browserWindow = nil  // abandon the hidden window
                        self.showErrorWindow(targetURL: targetURL, mode: "ssh")
                    }
                }
            }
        } else {
            preflightHTTP(urlString: targetURL) { reachable in
                DispatchQueue.main.async {
                    self.splashWindow.close()
                    if reachable {
                        if reuseWindow, let existing = self.browserWindow {
                            // Fix #10: reuse existing WKWebView for session continuity.
                            existing.reconnectInPlace(targetURL: targetURL)
                            existing.window?.makeKeyAndOrderFront(nil)
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
                        self.browserWindow = nil  // abandon the hidden window
                        self.showErrorWindow(targetURL: targetURL, mode: "direct")
                    }
                }
            }
        }
    }

    private func openBrowser(
        targetURL: String, mode: String, sshHost: String?, localPort: Int?
    ) {
        let browser = BrowserWindowController(
            urlString: targetURL,
            title: appTitle,
            connectionMode: mode
        )
        browser.onReconnect = { [weak self] in
            self?.startTunnel()
        }
        browser.onNavigationFailed = { [weak self] in
            self?.browserWindow?.close()
            self?.browserWindow = nil
            self?.showErrorWindow(targetURL: targetURL, mode: mode)
        }
        if mode == "ssh", let host = sshHost, let port = localPort {
            browser.updateStatus(tunnelManager.status, host: host, port: port)
        }
        // Fix #52: set alphaValue=0 BEFORE showWindow — prevents a brief
        // visible-at-full-opacity tick. The window fades in on first WKWebView paint.
        // backgroundColor is already set to #1a1a1a in BrowserWindowController.init.
        browser.window?.alphaValue = 0
        browser.showWindow(nil)
        browserWindow = browser

        // Restore full-screen state (fix #43)
        if UserDefaults.standard.bool(forKey: "windowWasFullScreen") {
            DispatchQueue.main.async {
                if browser.window?.styleMask.contains(.fullScreen) == false {
                    browser.window?.toggleFullScreen(nil)
                }
            }
        }

        // Clear offline badge when connected (fix #39)
        setOfflineBadge(false)
    }

    private func showErrorWindow(targetURL: String, mode: String) {
        browserWindow?.isIntentionalClose = true
        browserWindow?.close()
        browserWindow = nil
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
        browserWindow?.showWindow(nil)
        browserWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Page reload (fix — Cmd+R)

    @objc func reloadPage() {
        browserWindow?.webViewForZoom?.reload()
    }

    // MARK: - Find forwarding (fix #37/#45 — menu items delegate to BrowserWindowController)

    @objc func openFind() {
        // Toggle the find bar — if already open, Cmd+F closes it (standard macOS behaviour)
        (browserWindow?.window as? BrowserWindow)?.onFind?()
    }

    @objc func findNext() {
        (browserWindow?.window as? BrowserWindow)?.onFindNext?()
    }

    @objc func findPrev() {
        (browserWindow?.window as? BrowserWindow)?.onFindPrev?()
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
        guard let webView = browserWindow?.webViewForZoom else { return }
        webView.magnification = min(webView.magnification + 0.1, 3.0)
        UserDefaults.standard.set(webView.magnification, forKey: Self.zoomKey)
    }

    @objc func zoomOut() {
        guard let webView = browserWindow?.webViewForZoom else { return }
        webView.magnification = max(webView.magnification - 0.1, 0.5)
        UserDefaults.standard.set(webView.magnification, forKey: Self.zoomKey)
    }

    @objc func zoomReset() {
        browserWindow?.webViewForZoom?.magnification = 1.0
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
                        delegate.browserWindow?.showWindow(nil)
                        delegate.browserWindow?.window?.makeKeyAndOrderFront(nil)
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
        // Clicking the Dock icon when the window is hidden brings it back.
        if !flag {
            browserWindow?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
