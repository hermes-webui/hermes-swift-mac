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

// Fix #64: transparent drag view that sits atop the WKWebView in the title-bar zone.
// With .fullSizeContentView + titlebarAppearsTransparent, WKWebView covers the native
// title bar strip and intercepts all mouse events — killing native window drag.
// -webkit-app-region: drag in the web page's CSS has no effect on NSWindow dragging.
// This overlay calls window.performDrag(with:) on mouseDown in the title-bar strip,
// restoring the expected drag-to-move behaviour. The view is fully transparent
// (no layer, no drawing) so it has no visual impact. Traffic lights live in
// NSThemeFrame above contentView and are unaffected.
private class TitleBarDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Double-click: honour the system "Double-click a window's title bar to" preference.
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize": window?.miniaturize(nil)
            case "Maximize": window?.performZoom(nil)
            default: break  // "None"
            }
            return
        }
        // Single click: pass to the window's native drag-to-move handler.
        window?.performDrag(with: event)
    }
    // No hitTest override — default NSView.hitTest is correct (point is in superview coords,
    // default returns self when point is in frame, nil otherwise).
    // No isFlipped override — the view has no subviews or drawing; isFlipped is irrelevant.
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
    private(set) var urlString: String
    private let appTitle: String
    private(set) var connectionMode: String
    var onReconnect: (() -> Void)?
    var onNavigationFailed: (() -> Void)?
    /// Fired from windowWillClose so AppDelegate can prune its browserWindows array.
    /// Receives self so the delegate can match by identity (===) without holding a
    /// strong reference. Crucial for tab drag-out: AppKit retains the window briefly
    /// after it leaves a tab group, and without this callback the controller leaks.
    var onWindowWillClose: ((BrowserWindowController) -> Void)?
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
    /// Fix #64: drag overlay view — kept as a property so it can be resized on window resize.
    private var titleBarDragView: TitleBarDragView?
    /// The UserDefaults autosave name for the main window frame.
    /// Used for both windowFrameAutosaveName and the derived "NSWindow Frame <name>" key.
    private static let windowAutosaveName = "HermesMainWindow"
    /// Whether this window persists its frame. False for secondary multi-window/tab
    /// instances so they cascade from the front-most window instead of stacking on
    /// the same saved rect.
    private let useFrameAutosave: Bool
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

    /// KVO observation for window.tabbedWindows. When AppKit adds or removes a
    /// tab from the group, the tab bar appears/disappears, which shifts the
    /// window's contentLayoutRect. We resize webView so its top sits below the
    /// tab bar (preventing the tab bar from clipping the web app's title bar
    /// and chat content).
    private var tabbedWindowsObservation: NSKeyValueObservation?

    /// - Parameter useFrameAutosave: When true (default), the window persists its
    ///   frame to UserDefaults under HermesMainWindow. Only the *first* window of a
    ///   multi-window session should set this true; secondary windows pass false so
    ///   they cascade from the front-most window's frame instead of all stacking on
    ///   the same saved rect. AppKit's tab system shares the parent frame so the
    ///   parameter has no visible effect when the user prefers tabs.
    init(urlString: String, title: String, connectionMode: String = "direct",
         useFrameAutosave: Bool = true) {
        self.urlString = urlString
        self.appTitle = title
        self.connectionMode = connectionMode
        self.useFrameAutosave = useFrameAutosave

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 830),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
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

        // Fix #57: extend web content under the native title bar.
        // titleVisibility = .hidden removes the text draw; window.title stays set
        // (Window menu, Dock, accessibility, Mission Control).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Initial appearance — matches whatever the web UI is currently using
        // (tracked on AppDelegate). The theme bridge in buildUI() updates it
        // dynamically when the page reports its background color, so the
        // AppKit chrome (title bar, tab bar, traffic lights, status bar) stays
        // visually consistent with the page across light/dark/system themes.
        // Falls back to .darkAqua before the bridge has reported.
        window.appearance = (NSApp.delegate as? AppDelegate)?.currentAppearance
            ?? NSAppearance(named: .darkAqua)

        // Persist and restore window frame across launches — only for the first
        // (primary) window of the session. Secondary multi-window/tab instances skip
        // autosave so they cascade in openBrowser instead of stacking on the saved rect.
        // Must be set on the NSWindowController (self), not on the raw NSWindow.
        // Setting it on the window before super.init is clobbered by the controller's
        // own empty windowFrameAutosaveName during its setup. The controller property
        // handles both save and restore atomically.
        if useFrameAutosave {
            self.windowFrameAutosaveName = Self.windowAutosaveName
            // First launch (no saved frame yet): center the window.
            if UserDefaults.standard.object(forKey: "NSWindow Frame \(Self.windowAutosaveName)") == nil {
                window.center()
            }
        }
        // Multi-window / native tabs (#42): tabbingMode = .preferred opts THIS window
        // into AppKit's tab system regardless of the user's "Prefer Tabs When Opening
        // Documents" system preference. New windows with a matching tabbingIdentifier
        // join the current tab group automatically; the user can still pull tabs out
        // (Move Tab to New Window) or merge them back (Merge All Windows) via the
        // Window menu. The single tabbingIdentifier ensures every Hermes window can
        // merge into one tab group. Use .automatic if we ever want to honour the
        // system preference instead — current choice favours always-tabbable since
        // multi-window users tend to want both modes available regardless of pref.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "ai.get-hermes.HermesAgent.main"

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

        // Observe tab-group membership so we can shrink the webView when AppKit
        // adds a tab bar. Without this, the tab bar overlays the top of the web
        // UI (.app-titlebar and chat content) since .fullSizeContentView puts
        // webView under the title-bar zone where the tab bar renders.
        // KVO on tabbedWindows fires on the host window when any tab joins or
        // leaves the group, including this window.
        tabbedWindowsObservation = window.observe(\.tabbedWindows, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.updateWebViewLayout() }
        }
    }

    deinit {
        tabbedWindowsObservation?.invalidate()
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

        // Theme bridge: report the page's effective background color to Swift so
        // window.appearance can follow the web UI's actual theme (light / dark /
        // system). The page's background changes when the user toggles theme or
        // when the OS appearance changes (for system-tracking themes); this
        // reports on initial paint, on classList/style mutations of <html>/<body>,
        // on window focus, and on prefers-color-scheme media changes.
        let themeBridgeScript = WKUserScript(
            source: """
                (function() {
                    let lastReported = null;
                    const isOpaque = (c) =>
                        c && c !== 'transparent' && c !== 'rgba(0, 0, 0, 0)';
                    // Walk the stack of elements at a viewport pixel and return the
                    // first opaque background. Robust against web apps where <html>
                    // and <body> are transparent and the actual paint comes from a
                    // child shell (#app, <main>, etc).
                    function effectiveBackgroundAt(x, y) {
                        if (!document.elementsFromPoint) return null;
                        const els = document.elementsFromPoint(x, y);
                        for (const el of els) {
                            const bg = getComputedStyle(el).backgroundColor;
                            if (isOpaque(bg)) return bg;
                        }
                        return null;
                    }
                    function effectiveBackground() {
                        const w = window.innerWidth || 1280;
                        const h = window.innerHeight || 800;
                        // Sample a few interior points so a single oddly-coloured
                        // element under the cursor can't dominate the answer.
                        const points = [[w >> 1, h >> 1], [w >> 1, h >> 2], [w >> 2, h >> 1]];
                        for (const [x, y] of points) {
                            const bg = effectiveBackgroundAt(x, y);
                            if (bg) return bg;
                        }
                        // Fallbacks for when the document hasn't laid out yet.
                        const bodyBg = document.body ? getComputedStyle(document.body).backgroundColor : null;
                        if (isOpaque(bodyBg)) return bodyBg;
                        return getComputedStyle(document.documentElement).backgroundColor;
                    }
                    function report() {
                        const bg = effectiveBackground();
                        if (bg && bg !== lastReported) {
                            lastReported = bg;
                            window.webkit.messageHandlers.hermesTheme.postMessage(bg);
                        }
                    }
                    const observer = new MutationObserver(() => requestAnimationFrame(report));
                    function start() {
                        report();
                        observer.observe(document.documentElement, {
                            attributes: true,
                            attributeFilter: ['class', 'data-theme', 'style', 'data-mode']
                        });
                        if (document.body) {
                            observer.observe(document.body, {
                                attributes: true,
                                attributeFilter: ['class', 'data-theme', 'style', 'data-mode']
                            });
                        }
                        // Belt-and-suspenders: poll every 2s. Web apps that toggle
                        // theme via CSS-custom-property updates won't trigger our
                        // attribute-watcher, but the resulting backgroundColor change
                        // will be visible to elementsFromPoint on the next sample.
                        setInterval(report, 2000);
                    }
                    if (document.readyState === 'loading') {
                        document.addEventListener('DOMContentLoaded', start);
                    } else {
                        start();
                    }
                    window.addEventListener('focus', report);
                    const mq = window.matchMedia('(prefers-color-scheme: dark)');
                    if (mq.addEventListener) mq.addEventListener('change', report);
                    else if (mq.addListener) mq.addListener(report);
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(themeBridgeScript)
        config.userContentController.add(self, name: "hermesTheme")

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

        // Fix #57: inject default traffic light clearance at documentStart.
        // Refined to exact measured pixels in injectTrafficLightWidthVar() after didFinish.
        let trafficLightScript = WKUserScript(
            source: "document.documentElement.style.setProperty('--traffic-light-width', '80px');",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(trafficLightScript)

        // Fix #59: hide the web app's .app-titlebar-icon (SVG logo) when running in the
        // Mac wrapper. With .fullSizeContentView the icon sits right next to the traffic
        // lights and overlaps the close button. The window title and other title bar
        // controls are unaffected.
        let hideIconScript = WKUserScript(
            source: """
                (function() {
                    const s = document.createElement('style');
                    s.textContent = '.app-titlebar-icon { visibility: hidden !important; }';
                    (document.head || document.documentElement).appendChild(s);
                })();
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hideIconScript)

        contentView.addSubview(webView)

        // Fix #64: install a thin transparent drag overlay over the title-bar zone.
        // Height 38px matches .app-titlebar in the web UI. The view is added AFTER
        // webView so it is on top in z-order, intercepting mouse events before WKWebView.
        let titleBarHeight: CGFloat = 38
        // Anchor to the top of contentView (y = bounds.height - 38 to bounds.height),
        // matching the web UI's .app-titlebar which fills the same zone.
        // Note: clMaxY (contentLayoutRect.maxY) is the BOTTOM of the native title bar —
        // using clMaxY - 38 would put the overlay ~28 px below the visual title bar zone.
        // The web title bar sits at the very top: y ∈ [bounds.height-38, bounds.height].
        let dragFrame = NSRect(x: 0, y: bounds.height - titleBarHeight, width: bounds.width, height: titleBarHeight)
        let dragView = TitleBarDragView(frame: dragFrame)
        dragView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(dragView)
        titleBarDragView = dragView

        // Only add status bar in SSH mode
        if connectionMode == "ssh" {
            // NSVisualEffectView tracks effective appearance automatically, so
            // the status bar background stays in sync when the theme bridge
            // flips the window between .aqua and .darkAqua. Plain NSView with
            // a baked .cgColor would render with the WRONG colour on a
            // light-mode system because cgColor resolves against system
            // appearance, not the per-window .appearance we set.
            let bar = NSVisualEffectView(
                frame: NSRect(x: 0, y: 0, width: bounds.width, height: statusBarHeight))
            bar.autoresizingMask = [.width]
            bar.material = .titlebar
            bar.state = .active
            bar.blendingMode = .withinWindow
            statusBar = bar
            contentView.addSubview(statusBar)

            separator = NSView(
                frame: NSRect(x: 0, y: statusBarHeight - 1, width: bounds.width, height: 1))
            separator.autoresizingMask = [.width]
            separator.wantsLayer = true
            // Resolve separatorColor in the window's appearance context so we
            // get the right shade (the bridge can flip appearance later — see
            // updateAppearance — but a 1-px line is forgiving enough that we
            // don't bother re-resolving on every flip).
            window?.effectiveAppearance.performAsCurrentDrawingAppearance {
                separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
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

        // Initial layout — typically a no-op (single window has no tab bar) but
        // catches the case where this controller's window gets created into an
        // existing tab group (rare, but possible during state restoration).
        updateWebViewLayout()
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

    /// Parse a CSS colour string (`rgb(...)`, `rgba(...)`, or `#RRGGBB`/`#RGB`)
    /// and return whether its perceived luminance falls in the "dark" half. Used
    /// by the theme bridge to map a web-UI background to .darkAqua vs .aqua.
    /// Returns true (dark) on parse failure so we err on the side of preserving
    /// the dark-by-default look.
    static func cssColorIsDark(_ css: String) -> Bool {
        let s = css.trimmingCharacters(in: .whitespaces)
        var r: Double = 0, g: Double = 0, b: Double = 0
        if s.hasPrefix("#") {
            // #RGB or #RRGGBB
            let hex = String(s.dropFirst())
            func parseHex(_ str: Substring) -> Double? {
                guard let v = UInt8(str, radix: 16) else { return nil }
                return Double(v) / 255.0
            }
            if hex.count == 3 {
                guard let rr = parseHex(hex.prefix(1) + hex.prefix(1)),
                      let gg = parseHex(hex.dropFirst().prefix(1) + hex.dropFirst().prefix(1)),
                      let bb = parseHex(hex.dropFirst(2).prefix(1) + hex.dropFirst(2).prefix(1))
                else { return true }
                r = rr; g = gg; b = bb
            } else if hex.count == 6 {
                guard let rr = parseHex(hex.prefix(2)),
                      let gg = parseHex(hex.dropFirst(2).prefix(2)),
                      let bb = parseHex(hex.dropFirst(4).prefix(2))
                else { return true }
                r = rr; g = gg; b = bb
            } else { return true }
        } else if s.hasPrefix("rgb") {
            // rgb(R, G, B) or rgba(R, G, B, A) — extract first three integer-ish components
            let inside = s.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
            let parts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3,
                  let rr = Double(parts[0]),
                  let gg = Double(parts[1]),
                  let bb = Double(parts[2])
            else { return true }
            r = rr / 255; g = gg / 255; b = bb / 255
        } else {
            return true
        }
        // WCAG-ish relative luminance (linear approximation, good enough to bisect)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 0.5
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Theme bridge: web UI reports its effective background colour. Compute
        // luminance and propagate the resulting appearance to all windows via
        // AppDelegate (browser + Preferences + Error + Splash all match).
        if message.name == "hermesTheme", let css = message.body as? String {
            let isDark = Self.cssColorIsDark(css)
            let target = NSAppearance(named: isDark ? .darkAqua : .aqua)
            (NSApp.delegate as? AppDelegate)?.updateAppearance(target)
            return
        }
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

        // Fix #57: refine traffic light clearance to exact measured value.
        injectTrafficLightWidthVar()

        // Restore persisted zoom level. double(forKey:) returns 0.0 when unset —
        // treat any value outside the valid zoom range as "no preference".
        let saved = UserDefaults.standard.double(forKey: AppDelegate.zoomKey)
        if saved >= 0.5 && saved <= 3.0 {
            webView.magnification = saved
        }
    }

    /// Measures the actual right edge of the zoom (green) traffic light button and
    /// injects it as --traffic-light-width CSS custom property so the web title bar
    /// leaves correct clearance. Called after first paint and fullscreen transitions.
    private func injectTrafficLightWidthVar() {
        let reserve: CGFloat
        if let zoom = window?.standardWindowButton(.zoomButton) {
            // .frame is in NSThemeFrame coords = window-space in the title-bar strip.
            reserve = zoom.frame.maxX + 12
        } else {
            reserve = 80
        }
        let px = Int(reserve)
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--traffic-light-width', '\(px)px');",
            completionHandler: nil
        )
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
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            if httpResponse.statusCode >= 500 {
                decisionHandler(.cancel)
                guard !didReportNavigationFailure else { return }
                didReportNavigationFailure = true
                onNavigationFailed?()
                return
            }
            let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if disposition.lowercased().hasPrefix("attachment") || !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
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
        // Multi-window (#42): only the LAST live browser window hides on Cmd+W —
        // closing it for real would kill the Dock icon and force a relaunch.
        // For non-last windows, let AppKit close normally so windowWillClose fires
        // and AppDelegate prunes its browserWindows array (without that, closed
        // tabs leak as phantoms in the array and menu actions misroute to a dead
        // controller). Tab drag-out close, Cmd+W in any non-last window, and the
        // tab close button all hit this path.
        let appDelegate = NSApp.delegate as? AppDelegate
        let liveCount = appDelegate?.browserWindows.count ?? 0
        if liveCount <= 1 {
            // Last window: hide instead of close so the app stays alive in the Dock.
            // Cmd+N from there falls through to startTunnel() if needed.
            window?.orderOut(nil)
            return false
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure the WebView holds keyboard focus whenever the window is active,
        // so shortcuts like Cmd+K reach JavaScript without requiring an extra click.
        webView.becomeFirstResponder()
    }

    // MARK: - Tab-bar-aware layout

    /// Resize webView so the tab bar (when present) doesn't clip the web app's
    /// top content. With .fullSizeContentView, contentView extends to the top of
    /// the window, which means webView's top sits in the same vertical zone as
    /// AppKit's tab bar. When more than one tab is in the group, AppKit shows
    /// the bar — at which point we pin webView's top to contentLayoutRect.maxY
    /// (the bottom of the title-bar+tab-bar strip) so the web's `.app-titlebar`
    /// renders just below the tab bar instead of behind it.
    /// When the tab bar is absent (single-tab/standalone), we extend webView all
    /// the way to bounds.height so the v1.5.0 "web titlebar under transparent
    /// title bar" look is preserved.
    private func updateWebViewLayout() {
        guard let win = window, let contentView = win.contentView, webView != nil else { return }
        let groupCount = win.tabbedWindows?.count ?? 1
        let tabBarVisible = groupCount > 1
        let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0
        let topY: CGFloat = tabBarVisible
            ? win.contentLayoutRect.maxY
            : contentView.bounds.height
        let newHeight = max(0, topY - statusBarHeight)
        webView.frame = NSRect(
            x: 0, y: statusBarHeight,
            width: contentView.bounds.width, height: newHeight)
    }

    func windowDidResize(_ notification: Notification) {
        // Window resize can also change contentLayoutRect (e.g. fullscreen toggle
        // mid-resize). Recompute the tab-bar-aware webView frame on every resize.
        updateWebViewLayout()
    }

    // MARK: - Full-screen state persistence (fix #43)

    func windowDidEnterFullScreen(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "windowWasFullScreen")
        // Fix #57: in fullscreen the traffic lights are gone; reset clearance to 0.
        webView.evaluateJavaScript(
            "document.documentElement.style.setProperty('--traffic-light-width', '0px');",
            completionHandler: nil
        )
        // Fullscreen toggles the tab bar's visibility too — recompute layout.
        updateWebViewLayout()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Don't clobber the saved preference during a programmatic reconnect close.
        guard !isIntentionalClose else { return }
        // Multi-window (#42): only persist false when no OTHER browser window is
        // currently fullscreen. Without this guard, exiting fullscreen on one window
        // while others remain fullscreen would forget the preference, and on next
        // launch no window would restore to fullscreen even though one had been.
        let appDelegate = NSApp.delegate as? AppDelegate
        let othersFullScreen = appDelegate?.browserWindows.contains { other in
            other !== self && (other.window?.styleMask.contains(.fullScreen) ?? false)
        } ?? false
        if !othersFullScreen {
            UserDefaults.standard.set(false, forKey: "windowWasFullScreen")
        }
        // Fix #57: restore traffic light clearance after exiting fullscreen.
        injectTrafficLightWidthVar()
        // Tab bar visibility may have changed across the fullscreen transition.
        updateWebViewLayout()
    }

    // MARK: - Reconnect in place (fix #10)

    /// Reconnect without destroying the WKWebView, preserving cookies,
    /// localStorage, IndexedDB, and scroll position. Called by AppDelegate
    /// when a reconnect is needed and the window is still alive.
    func reconnectInPlace(targetURL newURLString: String) {
        // Reset dedup flag so a real failure on this attempt routes to error window.
        didReportNavigationFailure = false
        // Defensive: ensures windowDidExitFullScreen doesn't no-op after reconnect.
        isIntentionalClose = false
        // Stop in-flight provisional load to prevent zombie didFailProvisionalNavigation.
        webView.stopLoading()
        let sameURL = (newURLString == urlString)
        if sameURL {
            webView.reload()
        } else {
            urlString = newURLString
            if let url = URL(string: newURLString) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopHealthCheck()
        hideFindBar()
        // Notify AppDelegate so it can prune its browserWindows array. We pass self
        // so the delegate can match by identity. This fires for: user-initiated close
        // (Cmd+W on a window that's not the last), tab drag-out close, programmatic
        // close from AppDelegate (via isIntentionalClose=true in startTunnel), and
        // app termination. AppDelegate handles all four uniformly — array removal
        // is idempotent.
        onWindowWillClose?(self)
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
        // Fix #57 interaction: with .fullSizeContentView the contentView extends under
        // the title bar. Use contentLayoutRect (the area BELOW the title bar) so the
        // find bar anchors below the traffic lights, not behind them.
        let layoutTop = window.map { $0.contentLayoutRect.maxY } ?? contentView.bounds.height
        let bar = NSVisualEffectView(frame: NSRect(
            x: 0, y: layoutTop - barHeight,
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
        // Restore webView to its normal frame (below title bar, above status bar)
        if let win = window, let contentView = win.contentView {
            let statusBarHeight: CGFloat = connectionMode == "ssh" ? 28 : 0
            let layoutTop = win.contentLayoutRect.maxY
            webView.frame = NSRect(
                x: 0, y: statusBarHeight,
                width: contentView.bounds.width,
                height: layoutTop - statusBarHeight)
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

// MARK: - WKDownloadDelegate

extension BrowserWindowController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        guard let win = window else {
            completionHandler(nil)
            return
        }
        panel.beginSheetModal(for: win) { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {}

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let win = self?.window else { return }
            let alert = NSAlert()
            alert.messageText = "Download Failed"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: win)
        }
    }
}
