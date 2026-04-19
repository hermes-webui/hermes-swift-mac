import AVFoundation
import Cocoa
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Initialize Sparkle updater — feed URL comes from SUFeedURL in Info.plist
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        setupMenu()
        seedDefaultsIfNeeded()
        requestMicrophonePermission()
        startTunnel()
    }

    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied:
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Hermes Agent needs microphone access for voice input. Enable it in System Settings → Privacy & Security → Microphone."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        default:
            break
        }
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
        browserWindow?.close()
        browserWindow = nil
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
                        self.openBrowser(
                            targetURL: targetURL,
                            mode: "ssh",
                            sshHost: host,
                            localPort: localPort
                        )
                    } else {
                        self.showErrorWindow(targetURL: targetURL, mode: "ssh")
                    }
                }
            }
        } else {
            preflightHTTP(urlString: targetURL) { reachable in
                DispatchQueue.main.async {
                    self.splashWindow.close()
                    if reachable {
                        self.openBrowser(
                            targetURL: targetURL,
                            mode: "direct",
                            sshHost: nil,
                            localPort: nil
                        )
                    } else {
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
        browser.showWindow(nil)
        browserWindow = browser
    }

    private func showErrorWindow(targetURL: String, mode: String) {
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

        let windowMenuItem = NSMenuItem()
        menuBar.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")

        let viewMenuItem = NSMenuItem()
        menuBar.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(
            withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(
            withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(
            withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")

        NSApp.mainMenu = menuBar
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - View zoom (fix #24)

    @objc func zoomIn() {
        guard let webView = browserWindow?.webViewForZoom else { return }
        webView.magnification = min(webView.magnification + 0.1, 3.0)
    }

    @objc func zoomOut() {
        guard let webView = browserWindow?.webViewForZoom else { return }
        webView.magnification = max(webView.magnification - 0.1, 0.5)
    }

    @objc func zoomReset() {
        browserWindow?.webViewForZoom?.magnification = 1.0
    }

    @objc func openPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
            preferencesWindow?.onSave = { [weak self] in
                self?.preferencesWindow = nil
                self?.startTunnel()
            }
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tunnelManager?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        return true
    }
}
