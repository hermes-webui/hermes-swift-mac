import AVFoundation
import Cocoa
import UserNotifications
import WebKit

class BrowserWindow: NSWindow {
    var onPaste: (() -> Void)?
    var onFind: (() -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrev: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+V: route to the web view paste handler — but NOT when a native
        // text field (e.g. the find bar's NSSearchField) is focused.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v",
           !(firstResponder is NSText) {
            onPaste?()
            return true
        }
        // Cmd+F: open find bar (fix #37/#45)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f" {
            onFind?()
            return true
        }
        // Cmd+G: find next; Cmd+Shift+G: find previous (fix #37/#45)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "g" {
            onFindNext?()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
           event.charactersIgnoringModifiers == "G" {
            onFindPrev?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Lets the first click on the WebView both focus it and register as a content
// click simultaneously, fixing buttons that appear unresponsive after focus moves away.
private class HermesWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class BrowserWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: HermesWebView!
    private var statusBar: NSView!

    /// Exposes the WKWebView for zoom operations called from AppDelegate menu actions.
    /// Return type is WKWebView (not the private HermesWebView subclass) so Swift's
    /// access-level rules are satisfied — callers only need .magnification anyway.
    var webViewForZoom: WKWebView? { webView }
    private var separator: NSView!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var reconnectButton: NSButton!
    private let urlString: String
    private let appTitle: String
    private let connectionMode: String
    var onReconnect: (() -> Void)?
    var onNavigationFailed: (() -> Void)?
    /// Guards against onNavigationFailed firing twice (both provisional and 5xx paths
    /// can trigger on the same load event during teardown).
    private var didReportNavigationFailure = false
    /// Tracks whether the first navigation paint has occurred, so the fade-in
    /// animation (fix #52) only fires once — not on every SPA route change.
    private var hasCompletedFirstPaint = false
    // Find bar (fix #37/#45)
    private var findBar: NSView?
    private var findField: NSSearchField?
    private var findBarVisible = false
    /// The UserDefaults autosave name for the main window frame.
    /// Used for both windowFrameAutosaveName and the derived "NSWindow Frame <name>" key.
    private static let windowAutosaveName = "HermesMainWindow"
    /// Throttle the mic-denied alert to once per app session — avoids spamming if the
    /// user hits the mic button multiple times after having denied access.
    private static var didShowMicDeniedAlert = false
    /// Set to true before programmatic close so windowDidExitFullScreen
    /// doesn't clobber the saved full-screen preference (fix #43).
    var isIntentionalClose = false

    // Health check timer for direct mode — polls /health every 30s and
    // reflects status in the window title (fix #29).
    private var healthTimer: Timer?
    private var isHealthy: Bool = true

    init(urlString: String, title: String, connectionMode: String = "direct") {
        self.urlString = urlString
        self.appTitle = title
        self.connectionMode = connectionMode

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 830),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // Fix #23 + #52: set native window background to a dark colour before
        // content loads. Using a literal dark value (not windowBackgroundColor)
        // ensures the gap between window-visible and first-paint is dark in
        // *all* colour schemes — windowBackgroundColor is white in light mode.
        window.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
        super.init(window: window)

        // Persist and restore window frame across launches.
        // Must be set on the NSWindowController (self), not on the raw NSWindow.
        // Setting it on the window before super.init is clobbered by the controller's
        // own empty windowFrameAutosaveName during its setup. The controller property
        // handles both save and restore atomically.
        self.windowFrameAutosaveName = Self.windowAutosaveName
        // First launch (no saved frame yet): center the window.
        if UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.windowAutosaveName)") == nil {
            window.center()
        }

        window.onPaste = { [weak self] in
            self?.handlePaste()
        }
        window.onFind = { [weak self] in
            self?.toggleFindBar()
        }
        window.onFindNext = { [weak self] in
            self?.findNext(forward: true)
        }
        window.onFindPrev = { [weak self] in
            self?.findNext(forward: false)
        }
        window.delegate = self

        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds
        let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0

        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.setValue(true, forKey: "javaScriptCanAccessClipboard")
        prefs.setValue(true, forKey: "DOMPasteAllowed")
        config.preferences = prefs
        let pasteScript = WKUserScript(
            source:
                "document.addEventListener('paste', function(e) { e.stopImmediatePropagation(); }, true);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(pasteScript)

        // Suppress web Notification permission prompts — native macOS notifications handle this instead
        let notificationScript = WKUserScript(
            source: "Notification.requestPermission = function(cb) { if (cb) cb('denied'); return Promise.resolve('denied'); };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(notificationScript)

        // Suppress Web Speech API so hermes-webui falls back to its MediaRecorder + /api/transcribe
        // path. WebKit's built-in webkitSpeechRecognition only uses the macOS local speech model
        // which is unreliable; the backend transcription path works correctly.
        let speechSuppressionScript = WKUserScript(
            source: "window.SpeechRecognition = undefined; window.webkitSpeechRecognition = undefined;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(speechSuppressionScript)

        // Notify Swift when the AI finishes a response (streaming settled) and
        // the window is in the background. Used for macOS notifications (#8).
        // Only fires on characterData mutations (actual text changes) that settle
        // for 3s — ignores childList/structural churn to avoid false positives
        // from scroll virtualisation, cursor blinks, etc.
        let notifyScript = WKUserScript(
            source: """
                (function() {
                    let debounceTimer = null;
                    let totalCharsAdded = 0;
                    const MIN_CHARS = 20;  // ignore tiny updates (timestamps, badges, etc.)
                    const observer = new MutationObserver((mutations) => {
                        let charsThisBatch = 0;
                        for (const m of mutations) {
                            if (m.type === 'characterData') {
                                charsThisBatch += (m.target.nodeValue || '').length;
                            }
                        }
                        if (charsThisBatch === 0) return;
                        totalCharsAdded += charsThisBatch;
                        clearTimeout(debounceTimer);
                        debounceTimer = setTimeout(() => {
                            if (document.hidden && totalCharsAdded >= MIN_CHARS) {
                                window.webkit.messageHandlers.hermesNotify.postMessage({
                                    title: 'Hermes',
                                    body: 'Your response is ready'
                                });
                            }
                            totalCharsAdded = 0;
                        }, 3000);
                    });
                    observer.observe(document.body, {
                        subtree: true, characterData: true
                    });
                })();
                """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(notifyScript)
        config.userContentController.add(self, name: "hermesNotify")

        let webFrame = NSRect(
            x: 0, y: statusBarHeight, width: bounds.width, height: bounds.height - statusBarHeight)
        webView = HermesWebView(frame: webFrame, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsMagnification = true

        // Fix #23: prevent white flash on startup in dark mode (FOUC).
        // Set the WKWebView background to match the system window background
        // before the first paint — otherwise the WebView renders white while
        // the dark theme is still loading from the server.
        if #available(macOS 12.0, *) {
            // Fix #52: match the pre-paint dark background so the overscroll gutter
            // is dark too — not white, regardless of system colour scheme.
            webView.underPageBackgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
        }
        // Fix #52: inject a documentStart script that always sets the document
        // background to match our pre-paint NSWindow dark background (#1a1a1a),
        // regardless of colour scheme. This eliminates any FOUC during the HTTP
        // round-trip — even if the window becomes visible early, both the native
        // frame and the WebView show the same dark colour.
        // Once the app's actual CSS loads, it overrides this with the correct theme.
        let darkModeScript = WKUserScript(
            source: """
                (function() {
                    document.documentElement.style.background = '#1a1a1a';
                    if (document.body) { document.body.style.background = '#1a1a1a'; }
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkModeScript)

        contentView.addSubview(webView)

        // Only add status bar in SSH mode
        if connectionMode == "ssh" {
            statusBar = NSView(
                frame: NSRect(x: 0, y: 0, width: bounds.width, height: statusBarHeight))
            statusBar.autoresizingMask = [.width]
            statusBar.wantsLayer = true
            statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            contentView.addSubview(statusBar)

            separator = NSView(
                frame: NSRect(x: 0, y: statusBarHeight - 1, width: bounds.width, height: 1))
            separator.autoresizingMask = [.width]
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            contentView.addSubview(separator)

            statusDot = NSView(frame: NSRect(x: 12, y: 9, width: 10, height: 10))
            statusDot.wantsLayer = true
            statusDot.layer?.cornerRadius = 5
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
            statusBar.addSubview(statusDot)

            statusLabel = NSTextField(labelWithString: "Connecting…")
            statusLabel.font = NSFont.systemFont(ofSize: 11)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.frame = NSRect(x: 30, y: 6, width: 500, height: 16)
            statusBar.addSubview(statusLabel)

            reconnectButton = NSButton(
                title: "Reconnect", target: self, action: #selector(reconnectTapped))
            reconnectButton.bezelStyle = .rounded
            reconnectButton.font = NSFont.systemFont(ofSize: 11)
            reconnectButton.frame = NSRect(x: bounds.width - 110, y: 2, width: 100, height: 24)
            reconnectButton.autoresizingMask = [.minXMargin]
            reconnectButton.isHidden = true
            statusBar.addSubview(reconnectButton)
        }

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }

        // Start health polling for direct mode (fix #29)
        if connectionMode == "direct" {
            updateWindowTitle(healthy: true)
            startHealthCheck()
        }
    }

    // MARK: - Paste

    func handlePaste() {
        let pb = NSPasteboard.general

        // Image paste — write to temp file and inject via fetch
        if let image = NSImage(pasteboard: pb),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {

            let base64 = png.base64EncodedString()

            // Safe: base64 encoding only produces [A-Za-z0-9+/=], no JS-special chars
            // Try multiple strategies to get the image into the web app
            let js = """
                (function() {
                    const base64 = '\(base64)';
                    const binary = atob(base64);
                    const bytes = new Uint8Array(binary.length);
                    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                    const blob = new Blob([bytes], { type: 'image/png' });
                    const file = new File([blob], 'screenshot.png', { type: 'image/png', lastModified: Date.now() });

                    // Strategy 1: fire paste event on active element with clipboardData
                    const active = document.activeElement || document.body;
                    const dt = new DataTransfer();
                    dt.items.add(file);

                    // Override clipboardData getter so web app can read items
                    const pasteEvent = new Event('paste', { bubbles: true, cancelable: true });
                    Object.defineProperty(pasteEvent, 'clipboardData', {
                        value: dt,
                        writable: false
                    });
                    active.dispatchEvent(pasteEvent);

                    // Strategy 2: also try on document and body
                    document.dispatchEvent(new Event('paste', { bubbles: true }));

                    // Strategy 3: simulate drop on active element
                    const dropDt = new DataTransfer();
                    dropDt.items.add(file);
                    const rect = active.getBoundingClientRect();
                    const cx = rect.left + rect.width / 2;
                    const cy = rect.top + rect.height / 2;
                    ['dragenter','dragover','drop'].forEach(type => {
                        const ev = new DragEvent(type, {
                            bubbles: true,
                            cancelable: true,
                            clientX: cx,
                            clientY: cy,
                            dataTransfer: dropDt
                        });
                        active.dispatchEvent(ev);
                    });

                    return 'ok';
                })();
                """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("Paste JS error: \(error)")
                } else {
                    print("Paste JS result: \(result ?? "nil")")
                }
            }

        } else if let text = pb.string(forType: .string) {
            let jsonText: String
            if let data = try? JSONEncoder().encode(text),
                let encoded = String(data: data, encoding: .utf8)
            {
                jsonText = encoded
            } else {
                jsonText = "\"\""
            }
            webView.evaluateJavaScript(
                "document.execCommand('insertText', false, \(jsonText));",
                completionHandler: nil
            )
        } else {
            webView.evaluateJavaScript("document.execCommand('paste')", completionHandler: nil)
        }
    }

    // MARK: - Status

    // MARK: Health check (direct mode, fix #29)

    private func startHealthCheck() {
        let healthURL = urlString.hasSuffix("/") ? "\(urlString)health" : "\(urlString)/health"
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.pingHealth(urlString: healthURL)
        }
    }

    func stopHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func pingHealth(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let healthy = response is HTTPURLResponse
            DispatchQueue.main.async {
                guard let self = self, healthy != self.isHealthy else { return }
                self.isHealthy = healthy
                self.updateWindowTitle(healthy: healthy)
            }
        }.resume()
    }

    private func updateWindowTitle(healthy: Bool) {
        let hostDisplay: String
        if let url = URL(string: urlString), let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            hostDisplay = "\(host)\(port)"
        } else {
            hostDisplay = urlString
        }
        let dot = healthy ? "●" : "○"
        window?.title = "\(appTitle)  \(dot) \(hostDisplay)"
        // Update Dock badge. The cast is safe — AppDelegate is always the app delegate
        // in this single-delegate architecture. A ConnectionStatusObserver protocol
        // would decouple this but adds boilerplate not warranted for a utility method.
        (NSApp.delegate as? AppDelegate)?.setOfflineBadge(!healthy)
    }

    func updateStatus(_ status: TunnelStatus, host: String, port: Int) {
        guard connectionMode == "ssh" else { return }

        DispatchQueue.main.async {
            switch status {
            case .connecting:
                self.statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
                self.statusLabel.stringValue = "Connecting…"
                self.reconnectButton.isHidden = true
            case .connected:
                self.statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                self.statusLabel.stringValue = "Tunnel connected · \(host) · port \(port)"
                self.reconnectButton.isHidden = true
                (NSApp.delegate as? AppDelegate)?.setOfflineBadge(false)
            case .disconnected:
                self.statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
                self.statusLabel.stringValue = "Tunnel disconnected · click Reconnect to retry"
                self.reconnectButton.isHidden = false
                (NSApp.delegate as? AppDelegate)?.setOfflineBadge(true)
            }
        }
    }

    @objc func reconnectTapped() {
        onReconnect?()
    }

    // MARK: - WKScriptMessageHandler (notifications)

    // Cache auth status so we don't call requestAuthorization on every message.
    private var notificationAuthGranted: Bool? = nil

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hermesNotify",
              let body = message.body as? [String: String],
              let title = body["title"],
              let text = body["body"],
              UserDefaults.standard.bool(forKey: "notificationsEnabled")
        else { return }

        let center = UNUserNotificationCenter.current()

        func postNotification() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            // Stable identifier coalesces rapid bursts — only the last one shows.
            let request = UNNotificationRequest(
                identifier: "hermes-response-ready",
                content: content,
                trigger: nil
            )
            center.add(request)
        }

        if let granted = notificationAuthGranted {
            if granted { postNotification() }
            return
        }

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationAuthGranted = granted
                if granted { postNotification() }
            }
        }
    }

    // MARK: - Zoom level restore (fix #43) + startup fade-in (fix #52)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fix #52: fade the window in on the very first successful paint.
        // Uses a bool flag (not alphaValue check) to be robust against any
        // intermediate alpha changes. Subsequent navigations (SPA routes,
        // Cmd+R reloads) see hasCompletedFirstPaint=true and skip the animation.
        if !hasCompletedFirstPaint {
            hasCompletedFirstPaint = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window?.animator().alphaValue = 1
            }
        }

        // Restore persisted zoom level. double(forKey:) returns 0.0 when unset —
        // treat any value outside the valid zoom range as "no preference".
        let saved = UserDefaults.standard.double(forKey: AppDelegate.zoomKey)
        if saved >= 0.5 && saved <= 3.0 {
            webView.magnification = saved
        }
    }

    // MARK: - Navigation failure

    // If the main-frame load can't reach hermes (server went away, tunnel
    // dropped mid-session), bail back to the small native error window rather
    // than painting an error page inside a full-size WebView.
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // Fix #52: ensure the window is visible before we close/replace it.
        // If the very first navigation fails, didFinishNavigation never fires,
        // so the window stays at alphaValue=0. Restore it so the error window
        // transition isn't invisible.
        window?.alphaValue = 1
        let nsError = error as NSError
        // NSURLErrorCancelled fires for link clicks we redirected to Safari —
        // those aren't real failures, ignore them.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }
        guard !didReportNavigationFailure else { return }
        didReportNavigationFailure = true
        onNavigationFailed?()
    }

    // Server reachable but returned 5xx — the network preflight can't catch
    // this since it only checks that *some* HTTP response came back. Surface
    // it through the same native error window as a network failure.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse,
            httpResponse.statusCode >= 500
        {
            decisionHandler(.cancel)
            guard !didReportNavigationFailure else { return }
            didReportNavigationFailure = true
            onNavigationFailed?()
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: - File upload

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: self.window!) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: - Navigation guard (issue #7)
    // Allow only localhost/127.0.0.1 navigation. All other http/https links open in
    // Safari. file:// is blocked entirely.

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // Block file:// entirely
        if scheme == "file" {
            decisionHandler(.cancel)
            return
        }

        // Allow non-http(s) schemes (about:, blob:, data:, etc.) — WebKit needs these internally
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }

        let host = url.host?.lowercased() ?? ""

        // Allow localhost and loopback
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            decisionHandler(.allow)
            return
        }

        // Allow navigation to the configured remote host (SSH mode)
        let configuredURL = UserDefaults.standard.string(forKey: "targetURL") ?? ""
        if let configuredHost = URL(string: configuredURL)?.host?.lowercased(),
            !configuredHost.isEmpty,
            host == configuredHost
        {
            decisionHandler(.allow)
            return
        }

        // Everything else opens in Safari
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    // MARK: - Window close / hide (Cmd+W hides, doesn't quit)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Cmd+W on a Dock app should hide the window, not quit.
        // Keep the app alive so the Dock icon stays and can reopen the window.
        window?.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure the WebView holds keyboard focus whenever the window is active,
        // so shortcuts like Cmd+K reach JavaScript without requiring an extra click.
        webView.becomeFirstResponder()
    }

    // MARK: - Full-screen state persistence (fix #43)

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "windowWasFullScreen")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Don't clobber the saved preference during a programmatic reconnect close.
        guard !isIntentionalClose else { return }
        UserDefaults.standard.set(false, forKey: "windowWasFullScreen")
    }

    func windowWillClose(_ notification: Notification) {
        stopHealthCheck()
        hideFindBar()
    }

    // MARK: - Find in page (fix #37/#45, Cmd+F)
    // Uses window.find() JS (macOS 12+ via WKWebView.evaluateJavaScript) with a
    // native NSSearchField overlay. NSTextFinder bridging would give a more
    // native look but requires implementing NSTextFinderClient over a WebView —
    // not worth the complexity for a thin wrapper app.

    private func toggleFindBar() {
        if findBarVisible {
            hideFindBar()
        } else {
            showFindBar()
        }
    }

    private func showFindBar() {
        guard findBar == nil, let contentView = window?.contentView else { return }
        findBarVisible = true

        let barHeight: CGFloat = 36
        let bar = NSVisualEffectView(frame: NSRect(
            x: 0, y: contentView.bounds.height - barHeight,
            width: contentView.bounds.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.blendingMode = .withinWindow
        bar.material = .headerView  // .titlebar is deprecated; .headerView is the modern equivalent
        bar.state = .active
        contentView.addSubview(bar)
        findBar = bar

        let field = NSSearchField(frame: NSRect(x: 8, y: 5, width: 220, height: 24))
        field.placeholderString = "Find in page…"
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(findFieldChanged(_:))
        bar.addSubview(field)
        findField = field

        let prevBtn = NSButton(title: "\u{2039}", target: self, action: #selector(findPrevTapped))
        prevBtn.bezelStyle = .rounded
        prevBtn.font = NSFont.systemFont(ofSize: 15)
        prevBtn.frame = NSRect(x: 234, y: 4, width: 28, height: 26)
        bar.addSubview(prevBtn)

        let nextBtn = NSButton(title: "\u{203A}", target: self, action: #selector(findNextTapped))
        nextBtn.bezelStyle = .rounded
        nextBtn.font = NSFont.systemFont(ofSize: 15)
        nextBtn.frame = NSRect(x: 264, y: 4, width: 28, height: 26)
        bar.addSubview(nextBtn)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(findDoneTapped))
        doneBtn.bezelStyle = .rounded
        doneBtn.font = NSFont.systemFont(ofSize: 12)
        doneBtn.frame = NSRect(x: 298, y: 4, width: 52, height: 26)
        bar.addSubview(doneBtn)

        // Shrink webView to make room for the bar
        webView.frame.size.height -= barHeight
        window?.makeFirstResponder(field)
    }

    private func hideFindBar() {
        guard let bar = findBar else { return }
        findBarVisible = false
        bar.removeFromSuperview()
        findBar = nil
        findField = nil
        // Restore webView height
        if let contentView = window?.contentView {
            let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0
            webView.frame = NSRect(
                x: 0, y: statusBarHeight,
                width: contentView.bounds.width,
                height: contentView.bounds.height - statusBarHeight)
        }
        window?.makeFirstResponder(webView)
    }

    // cancelOperation is sent by AppKit when the user presses Escape while
    // the find field is first responder. Closing the bar here satisfies the
    // CHANGELOG claim that Escape dismisses the bar.
    override func cancelOperation(_ sender: Any?) {
        if findBarVisible {
            hideFindBar()
        } else {
            super.cancelOperation(sender)
        }
    }

    @objc private func findFieldChanged(_ sender: NSSearchField) {
        runFind(query: sender.stringValue, forward: true)
    }

    @objc private func findNextTapped() { findNext(forward: true) }
    @objc private func findPrevTapped() { findNext(forward: false) }
    @objc private func findDoneTapped() { hideFindBar() }

    private func findNext(forward: Bool) {
        guard let q = findField?.stringValue, !q.isEmpty else {
            if !findBarVisible { showFindBar() }
            return
        }
        runFind(query: q, forward: forward)
    }

    private func runFind(query: String, forward: Bool) {
        guard !query.isEmpty else { return }
        // window.find(aString, caseSensitive, backwards, wrapAround, wholeWord, searchInFrames, showDialog)
        // Escape backslashes and single-quotes to make the query safe inside the JS string literal.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let backwards = forward ? "false" : "true"
        let js = "window.find('\(escaped)', false, \(backwards), true, false, true, false);"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Microphone / camera permissions

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let mediaType: AVMediaType = (type == .camera) ? .video : .audio
        // Always route through requestAccess — never short-circuit on .authorized.
        // requestAccess sends an XPC message to tccd on every call, which is required
        // for WebContent's capture attribution to succeed. Short-circuiting to
        // decisionHandler(.grant) when .authorized bypasses this tccd round-trip,
        // causing getUserMedia() to fail with NotAllowedError even when TCC is .authorized.
        // When already .authorized, requestAccess completes immediately (no UI, no prompt).
        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            DispatchQueue.main.async {
                decisionHandler(granted ? .grant : .deny)
                // Show a recovery alert for mic denial — once per session, not for camera.
                guard !granted, type != .camera,
                      !Self.didShowMicDeniedAlert else { return }
                Self.didShowMicDeniedAlert = true
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Enable microphone access for Hermes Agent in System Settings \u{2192} Privacy & Security \u{2192} Microphone, then reload the page."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
