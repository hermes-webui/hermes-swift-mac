import AVFoundation
import Cocoa
import UserNotifications
import WebKit

class BrowserWindow: NSWindow {
    var onPaste: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            onPaste?()
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
    private var separator: NSView!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var reconnectButton: NSButton!
    private let urlString: String
    private let appTitle: String
    private let connectionMode: String
    var onReconnect: (() -> Void)?

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
        window.center()
        super.init(window: window)

        window.onPaste = { [weak self] in
            self?.handlePaste()
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
        // Debounces DOM mutations — fires 2s after last change when page is hidden.
        let notifyScript = WKUserScript(
            source: """
                (function() {
                    let debounceTimer = null;
                    const observer = new MutationObserver(() => {
                        clearTimeout(debounceTimer);
                        debounceTimer = setTimeout(() => {
                            if (document.hidden) {
                                window.webkit.messageHandlers.hermesNotify.postMessage({
                                    title: 'Hermes',
                                    body: 'Your response is ready'
                                });
                            }
                        }, 2000);
                    });
                    observer.observe(document.body, {
                        childList: true, subtree: true, characterData: true
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
            case .disconnected:
                self.statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
                self.statusLabel.stringValue = "Tunnel disconnected · click Reconnect to retry"
                self.reconnectButton.isHidden = false
            }
        }
    }

    @objc func reconnectTapped() {
        onReconnect?()
    }

    // MARK: - WKScriptMessageHandler (notifications)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "hermesNotify",
              let body = message.body as? [String: String],
              let title = body["title"],
              let text = body["body"]
        else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "hermes-response-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - Error page (connection failed)

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let targetURL = UserDefaults.standard.string(forKey: "targetURL") ?? "http://localhost:8787"
        let mode = UserDefaults.standard.string(forKey: "connectionMode") ?? "direct"
        let isSSH = mode == "ssh"

        let tip = isSSH
            ? "The SSH tunnel may not be established, or hermes-webui may not be running on the remote server."
            : "Make sure hermes-webui is running. Start it with:<br><code>cd ~/hermes-webui-public &amp;&amp; bash start.sh</code>"

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            display: flex; align-items: center; justify-content: center;
            height: 100vh; margin: 0;
            background: #f5f5f7; color: #1d1d1f;
          }
          .card {
            background: white; border-radius: 16px;
            padding: 40px 48px; max-width: 480px; text-align: center;
            box-shadow: 0 4px 24px rgba(0,0,0,0.08);
          }
          .icon { font-size: 48px; margin-bottom: 16px; }
          h2 { margin: 0 0 8px; font-size: 20px; font-weight: 600; }
          p { margin: 0 0 12px; color: #6e6e73; font-size: 14px; line-height: 1.5; }
          code { background: #f5f5f7; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
          .url { font-size: 13px; color: #8e8e93; margin-bottom: 24px; }
          button {
            background: #0071e3; color: white; border: none;
            padding: 10px 24px; border-radius: 8px; font-size: 15px;
            cursor: pointer; font-family: inherit;
          }
          button:hover { background: #0077ed; }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="icon">⚠️</div>
          <h2>Cannot connect to Hermes</h2>
          <p class="url">\(targetURL)</p>
          <p>\(tip)</p>
          <button onclick="window.location.reload()">Try Again</button>
        </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
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

    // MARK: - Window focus

    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure the WebView holds keyboard focus whenever the window is active,
        // so shortcuts like Cmd+K reach JavaScript without requiring an extra click.
        webView.becomeFirstResponder()
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
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            decisionHandler(.grant)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { decisionHandler(granted ? .grant : .deny) }
            }
        case .denied, .restricted:
            decisionHandler(.deny)
        @unknown default:
            decisionHandler(.deny)
        }
    }
}
