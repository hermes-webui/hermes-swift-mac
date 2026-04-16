import AVFoundation
import Cocoa
import Speech

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
    var preferencesWindow: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupMenu()
        seedDefaultsIfNeeded()
        requestMicrophonePermission()
        requestSpeechRecognitionPermission()
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

    private func requestSpeechRecognitionPermission() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { _ in }
        case .denied, .restricted:
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Speech Recognition Access Required"
                alert.informativeText = "Hermes Agent needs speech recognition access for voice input. Enable it in System Settings → Privacy & Security → Speech Recognition."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
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
        tunnelManager?.stop()

        if connectionMode == "ssh" {
            // SSH tunnel mode
            let user = defaults.string(forKey: "sshUser") ?? defaultSSHUser
            let host = defaults.string(forKey: "sshHost") ?? defaultSSHHost
            let localPort = Int(defaults.string(forKey: "localPort") ?? defaultLocalPort) ?? 8787
            let remotePort = Int(defaults.string(forKey: "remotePort") ?? defaultRemotePort) ?? 8787

            tunnelManager = TunnelManager(
                user: user,
                host: host,
                localPort: localPort,
                remoteHost: "localhost",
                remotePort: remotePort
            )

            tunnelManager.onStatusChange = { [weak self] status in
                guard let self = self else { return }
                self.browserWindow?.updateStatus(status, host: host, port: localPort)
            }

            tunnelManager.start {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.splashWindow.close()
                    let browser = BrowserWindowController(
                        urlString: targetURL,
                        title: self.appTitle,
                        connectionMode: "ssh"
                    )
                    browser.onReconnect = { [weak self] in
                        self?.startTunnel()
                    }
                    browser.updateStatus(self.tunnelManager.status, host: host, port: localPort)
                    browser.showWindow(nil)
                    self.browserWindow = browser
                }
            }
        } else {
            // Direct mode (local)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.splashWindow.close()
                let browser = BrowserWindowController(
                    urlString: targetURL,
                    title: self.appTitle,
                    connectionMode: "direct"
                )
                browser.onReconnect = { [weak self] in
                    self?.startTunnel()
                }
                browser.showWindow(nil)
                self.browserWindow = browser
            }
        }
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

        NSApp.mainMenu = menuBar
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
