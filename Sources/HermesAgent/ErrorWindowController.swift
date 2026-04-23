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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
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
        icon.frame = NSRect(x: 0, y: 280, width: 460, height: 50)
        icon.autoresizingMask = [.width]
        content.addSubview(icon)

        let title = NSTextField(labelWithString: "Cannot connect to Hermes")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 250, width: 460, height: 24)
        title.autoresizingMask = [.width]
        content.addSubview(title)

        let urlLabel = NSTextField(labelWithString: targetURL)
        urlLabel.font = NSFont.systemFont(ofSize: 12)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.alignment = .center
        urlLabel.frame = NSRect(x: 0, y: 226, width: 460, height: 18)
        urlLabel.autoresizingMask = [.width]
        content.addSubview(urlLabel)

        let descText = mode == "ssh"
            ? "The SSH tunnel may not be established, or hermes-webui may not be running on the remote server."
            : "Make sure hermes-webui is running and listening at the URL above.\n"
              + "Run: bash start.sh (or: docker compose up -d)"
        let desc = NSTextField(wrappingLabelWithString: descText)
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.alignment = .center
        desc.frame = NSRect(x: 40, y: 140, width: 380, height: 72)
        desc.autoresizingMask = [.width]
        content.addSubview(desc)

        // "Don't have it yet?" link — only shown in direct mode for new users
        if mode == "direct" {
            let getLabel = NSTextField(labelWithString: "Don't have it yet?")
            getLabel.font = NSFont.systemFont(ofSize: 12)
            getLabel.textColor = .secondaryLabelColor
            getLabel.alignment = .center
            getLabel.frame = NSRect(x: 40, y: 110, width: 180, height: 18)
            content.addSubview(getLabel)

            let getBtn = NSButton(title: "github.com/nesquena/hermes-webui", target: self, action: #selector(openRepoURL))
            getBtn.bezelStyle = .inline
            getBtn.isBordered = false
            getBtn.contentTintColor = NSColor.linkColor
            getBtn.font = NSFont.systemFont(ofSize: 12)
            getBtn.frame = NSRect(x: 220, y: 108, width: 210, height: 20)
            content.addSubview(getBtn)
        }

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

    @objc private func openRepoURL() {
        if let url = URL(string: "https://github.com/nesquena/hermes-webui") {
            NSWorkspace.shared.open(url)
        }
    }
}
