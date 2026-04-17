import Cocoa

/// Small native window shown when the app can't reach hermes-webui — either
/// the SSH tunnel failed, or the direct HTTP preflight failed. Keeps the UI
/// compact (no giant empty WebView) and uses native buttons so the Try Again
/// flow is always wired up correctly.
class ErrorWindowController: NSWindowController {

    var onRetry: (() -> Void)?
    var onOpenPreferences: (() -> Void)?

    init(appTitle: String, targetURL: String, mode: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = appTitle
        window.center()
        super.init(window: window)

        guard let content = window.contentView else { return }

        let icon = NSTextField(labelWithString: "⚠️")
        icon.font = NSFont.systemFont(ofSize: 40)
        icon.alignment = .center
        icon.frame = NSRect(x: 0, y: 240, width: 460, height: 50)
        icon.autoresizingMask = [.width]
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "Cannot connect to Hermes")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 210, width: 460, height: 24)
        title.autoresizingMask = [.width]
        content.addSubview(title)

        let urlLabel = NSTextField(labelWithString: targetURL)
        urlLabel.font = NSFont.systemFont(ofSize: 12)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.alignment = .center
        urlLabel.frame = NSRect(x: 0, y: 186, width: 460, height: 18)
        urlLabel.autoresizingMask = [.width]
        content.addSubview(urlLabel)

        let descText = mode == "ssh"
            ? "The SSH tunnel may not be established, or hermes-webui may not be running on the remote server."
            : "Make sure hermes-webui is running on the target URL. Start it with:\ncd ~/hermes-webui-public && bash start.sh"
        let desc = NSTextField(wrappingLabelWithString: descText)
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 40, y: 100, width: 380, height: 72)
        desc.autoresizingMask = [.width]
        content.addSubview(desc)

        let retryBtn = NSButton(title: "Try Again", target: self, action: #selector(retryTapped))
        retryBtn.bezelStyle = .rounded
        retryBtn.keyEquivalent = "\r"
        retryBtn.frame = NSRect(x: 320, y: 24, width: 120, height: 32)
        content.addSubview(retryBtn)

        let prefsBtn = NSButton(
            title: "Preferences…", target: self, action: #selector(prefsTapped))
        prefsBtn.bezelStyle = .rounded
        prefsBtn.frame = NSRect(x: 190, y: 24, width: 120, height: 32)
        content.addSubview(prefsBtn)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func retryTapped() { onRetry?() }
    @objc private func prefsTapped() { onOpenPreferences?() }
}
