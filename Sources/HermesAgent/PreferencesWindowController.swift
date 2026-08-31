import Cocoa
import ServiceManagement

class PreferencesWindowController: NSWindowController {

    var onSave: (() -> Void)?

    private var connectionModeSegment: NSSegmentedControl!
    private var sshViews: [NSView] = []
    private var usernameField: NSTextField!
    private var hostField: NSTextField!
    private var localPortField: NSTextField!
    private var remotePortField: NSTextField!
    private var targetURLField: NSTextField!
    /// Replaces the Target URL field in SSH mode, where the URL is derived
    /// from the local port (the tunnel entrance) rather than typed.
    private var tunnelURLLabel: NSTextField!
    private var testResultLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var notificationsCheckbox: NSButton!
    private var hotkeyRecorder: HotkeyRecorderView!  // Fix #41
    // Pending hotkey edits — written to UserDefaults only on Save (not immediately)
    private var pendingHotkeyKeyCode: UInt32?
    private var pendingHotkeyModifiers: UInt32?
    private var pendingHotkeyEnabled: Bool?
/// Multi-line text view for custom HTTP headers (e.g. Cloudflare Access service token headers).
private var headersTextView: NSTextView!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 748),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.center()
        // Match whatever theme the web UI is currently using (tracked on AppDelegate).
        // Falls back to .darkAqua before the bridge has reported (e.g. on first launch).
        window.appearance = (NSApp.delegate as? AppDelegate)?.currentAppearance
            ?? NSAppearance(named: .darkAqua)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let content = window!.contentView!
        // Starting y must shift with the window height bump; otherwise the new
        // Notifications row pushes launchAtLogin into the Save/Cancel buttons.
        var y: CGFloat = 568

        func sectionHeader(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 24, y: y, width: 460, height: 16)
            content.addSubview(label)
            y -= 28
            return label
        }

        func row(
            _ labelText: String, placeholder: String, defaultsKey: String, width: CGFloat = 300,
            isSSH: Bool = false
        ) -> NSTextField {
            let label = NSTextField(labelWithString: labelText)
            label.font = NSFont.systemFont(ofSize: 13)
            label.frame = NSRect(x: 24, y: y, width: 130, height: 22)
            label.alignment = .right
            content.addSubview(label)
            if isSSH { sshViews.append(label) }

            let field = NSTextField()
            field.placeholderString = placeholder
            field.stringValue = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            field.font = NSFont.systemFont(ofSize: 13)
            field.frame = NSRect(x: 164, y: y, width: width, height: 22)
            field.bezelStyle = .roundedBezel
            content.addSubview(field)
            if isSSH { sshViews.append(field) }

            y -= 36
            return field
        }

        func divider() -> NSBox {
            let line = NSBox()
            line.boxType = .separator
            line.frame = NSRect(x: 24, y: y + 10, width: 472, height: 1)
            content.addSubview(line)
            y -= 20
            return line
        }

        // Tunnel mechanism. "None" = the Target URL is reachable as-is;
        // "SSH" = a forward is established first and the app loads the
        // tunnel entrance. Persisted values are "direct"/"ssh".
        _ = sectionHeader("TUNNEL")
        let modeLabel = NSTextField(labelWithString: "Tunnel")
        modeLabel.font = NSFont.systemFont(ofSize: 13)
        modeLabel.frame = NSRect(x: 24, y: y, width: 130, height: 22)
        modeLabel.alignment = .right
        content.addSubview(modeLabel)

        connectionModeSegment = NSSegmentedControl(
            labels: ["None", "SSH"], trackingMode: .selectOne, target: self,
            action: #selector(modeChanged))
        connectionModeSegment.frame = NSRect(x: 164, y: y - 2, width: 300, height: 22)
        let mode = UserDefaults.standard.string(forKey: "connectionMode") ?? "direct"
        connectionModeSegment.selectedSegment = mode == "ssh" ? 1 : 0
        content.addSubview(connectionModeSegment)
        y -= 36

        let divider1 = divider()
        sshViews.append(divider1)

        // SSH section — always visible; dimmed/disabled when tunnel is None
        // so the fixed-frame layout keeps its shape.
        let sshHeader = sectionHeader("SSH CONNECTION")
        sshViews.append(sshHeader)

        usernameField = row("Username", placeholder: "hermes", defaultsKey: "sshUser", isSSH: true)
        hostField = row("Host", placeholder: "your-server.com", defaultsKey: "sshHost", isSSH: true)

        let divider2 = divider()
        sshViews.append(divider2)

        // Port forwarding section
        let portHeader = sectionHeader("PORT FORWARDING")
        sshViews.append(portHeader)

        localPortField = row(
            "Local port", placeholder: "8787", defaultsKey: "localPort", width: 80, isSSH: true)
        remotePortField = row(
            "Remote port", placeholder: "8787", defaultsKey: "remotePort", width: 80, isSSH: true)

        _ = divider()

        // App section
        _ = sectionHeader("APP")
        targetURLField = row(
            "Target URL", placeholder: "http://localhost:8787", defaultsKey: "targetURL")
        // In SSH mode the URL is derived from the local port; a read-only
        // label can't silently disagree with the tunnel the way an editable
        // field could.
        tunnelURLLabel = NSTextField(labelWithString: "")
        tunnelURLLabel.font = NSFont.systemFont(ofSize: 13)
        tunnelURLLabel.textColor = .secondaryLabelColor
        tunnelURLLabel.frame = targetURLField.frame
        content.addSubview(tunnelURLLabel)
        // Delegate on every connection field: edits clear a stale Test
        // Connection result; the local port also drives the tunnel-URL label.
        [usernameField, hostField, localPortField, remotePortField, targetURLField]
            .forEach { $0?.delegate = self }

        // ── Custom Headers section ──
        _ = divider()
        y -= 4  // Extra spacing before section header
        _ = sectionHeader("CUSTOM HEADERS")
        y -= 4  // Extra spacing after header

        let headerLabel = NSTextField(labelWithString: "Headers (one per line: Name: Value)")
        headerLabel.font = NSFont.systemFont(ofSize: 11)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.frame = NSRect(x: 164, y: y, width: 300, height: 16)
        content.addSubview(headerLabel)
        y -= 20

        let scrollView = NSScrollView(frame: NSRect(x: 164, y: y - 72, width: 300, height: 72))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 284, height: 72))
        textView.font = NSFont(name: "Menlo", size: 11) ?? NSFont.systemFont(ofSize: 11)
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.drawsBackground = false
        // Load existing headers
        let savedHeaders = CustomHeaderURLProtocol.loadCustomHeaders()
        if !savedHeaders.isEmpty {
            textView.string = savedHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        }
        scrollView.documentView = textView
        content.addSubview(scrollView)
        headersTextView = textView

        // Note about headers
        let headerNote = NSTextField(labelWithString: "Sent with every request. For Cloudflare Access, use:\nCF-Access-Client-Id and CF-Access-Client-Secret")
        headerNote.font = NSFont.systemFont(ofSize: 10)
        headerNote.textColor = .tertiaryLabelColor
        headerNote.frame = NSRect(x: 164, y: y - 110, width: 300, height: 30)
        content.addSubview(headerNote)
        y -= 118

        // Fix #41: configurable global shortcut — replaced static label with recorder.
        let shortcutLabel = NSTextField(labelWithString: "Global shortcut:")
        shortcutLabel.font = NSFont.systemFont(ofSize: 13)
        shortcutLabel.frame = NSRect(x: 24, y: y, width: 130, height: 22)
        shortcutLabel.alignment = .right
        content.addSubview(shortcutLabel)

        let hkDefaults = UserDefaults.standard
        hotkeyRecorder = HotkeyRecorderView(frame: NSRect(x: 164, y: y - 1, width: 140, height: 24))
        hotkeyRecorder.keyCode   = UInt32(hkDefaults.integer(forKey: "globalHotkeyKeyCode"))
        hotkeyRecorder.modifiers = UInt32(hkDefaults.integer(forKey: "globalHotkeyModifiers"))
        hotkeyRecorder.isEnabled = hkDefaults.bool(forKey: "globalHotkeyEnabled")
        // Fix #41: defer UserDefaults writes to save() so Cancel discards changes.
        hotkeyRecorder.onCapture = { [weak self] keyCode, mods in
            self?.pendingHotkeyKeyCode = keyCode
            self?.pendingHotkeyModifiers = mods
            self?.pendingHotkeyEnabled = true
        }
        hotkeyRecorder.onClear = { [weak self] in
            self?.pendingHotkeyEnabled = false
        }
        content.addSubview(hotkeyRecorder)

        let hintLabel = NSTextField(labelWithString: "click to change, Delete to clear")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.frame = NSRect(x: 312, y: y + 1, width: 182, height: 20)
        content.addSubview(hintLabel)

        y -= 36

        // Notifications toggle (fix #28)
        notificationsCheckbox = NSButton(
            checkboxWithTitle: "Show a notification when a response completes while the app is in the background",
            target: self,
            action: #selector(toggleNotifications(_:)))
        notificationsCheckbox.frame = NSRect(x: 164, y: y, width: 330, height: 22)
        notificationsCheckbox.state =
            UserDefaults.standard.bool(forKey: "notificationsEnabled") ? .on : .off
        content.addSubview(notificationsCheckbox)
        y -= 36

        // Launch at Login (fix #3) — uses SMAppService (macOS 13+)
        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "Launch at login",
            target: self,
            action: #selector(toggleLaunchAtLogin(_:)))
        launchAtLoginCheckbox.frame = NSRect(x: 164, y: y, width: 300, height: 22)
        content.addSubview(launchAtLoginCheckbox)

        if #available(macOS 13.0, *) {
            launchAtLoginCheckbox.state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginCheckbox.isEnabled = false
            let note = NSTextField(labelWithString: "Requires macOS 13 or later")
            note.font = NSFont.systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.frame = NSRect(x: 294, y: y, width: 210, height: 22)
            content.addSubview(note)
        }
        y -= 36

        // Buttons
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 254, y: 16, width: 90, height: 32)
        content.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save & Reconnect", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: 356, y: 16, width: 140, height: 32)
        content.addSubview(saveBtn)

        let testBtn = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: 24, y: 16, width: 130, height: 32)
        content.addSubview(testBtn)

        testResultLabel = NSTextField(labelWithString: "")
        testResultLabel.font = NSFont.systemFont(ofSize: 11)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.frame = NSRect(x: 164, y: 22, width: 90, height: 16)
        content.addSubview(testResultLabel)

        // Apply the initial dim/enable + Target URL swap for the saved mode.
        modeChanged()
    }

    // MARK: - Notifications toggle (fix #28)

    @objc func toggleNotifications(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "notificationsEnabled")
    }

    // MARK: - Launch at login (fix #3)

    @objc func toggleLaunchAtLogin(_ sender: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        let wantEnabled = sender.state == .on
        Task { @MainActor in
            do {
                if wantEnabled {
                    if service.status != .enabled { try service.register() }
                } else {
                    if service.status == .enabled { try await service.unregister() }
                }
                // Re-sync UI to authoritative status (handles .requiresApproval)
                sender.state = (service.status == .enabled) ? .on : .off
                if service.status == .requiresApproval {
                    let alert = NSAlert()
                    alert.messageText = "Approval required"
                    alert.informativeText =
                        "Enable Hermes in System Settings → General → Login Items."
                    alert.runModal()
                }
            } catch {
                sender.state = (service.status == .enabled) ? .on : .off
                let alert = NSAlert()
                alert.messageText = "Couldn't update Launch at Login"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Save

    @objc func save() {
        let connectionMode = connectionModeSegment.selectedSegment == 0 ? "direct" : "ssh"

        if connectionMode == "ssh" {
            guard !usernameField.stringValue.isEmpty,
                !hostField.stringValue.isEmpty,
                !localPortField.stringValue.isEmpty,
                !remotePortField.stringValue.isEmpty
            else {
                let alert = NSAlert()
                alert.messageText = "Missing SSH fields"
                alert.informativeText = "Please fill in all SSH settings."
                alert.runModal()
                return
            }

            guard TunnelManager.isValidSSHIdentifier(usernameField.stringValue),
                TunnelManager.isValidSSHIdentifier(hostField.stringValue)
            else {
                showValidationError(
                    "Username and host may not start with \"-\" or contain spaces.")
                return
            }

            guard let localPort = Int(localPortField.stringValue), (1...65535).contains(localPort)
            else {
                showValidationError("Local port must be a number between 1 and 65535.")
                return
            }

            guard let remotePort = Int(remotePortField.stringValue),
                (1...65535).contains(remotePort)
            else {
                showValidationError("Remote port must be a number between 1 and 65535.")
                return
            }

            let defaults = UserDefaults.standard
            defaults.set(connectionMode, forKey: "connectionMode")
            defaults.set(usernameField.stringValue, forKey: "sshUser")
            defaults.set(hostField.stringValue, forKey: "sshHost")
            defaults.set(String(localPort), forKey: "localPort")
            defaults.set(String(remotePort), forKey: "remotePort")
            // targetURL intentionally untouched: SSH mode always loads the
            // tunnel entrance (AppDelegate.effectiveTargetURL), and the stored
            // value is kept for when the user switches back to Direct.
        } else {
            guard !targetURLField.stringValue.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "Missing fields"
                alert.informativeText = "Please fill in the Target URL."
                alert.runModal()
                return
            }

            guard let targetURL = URL(string: targetURLField.stringValue),
                let scheme = targetURL.scheme?.lowercased(),
                ["http", "https"].contains(scheme)
            else {
                showValidationError("Target URL must be a valid http:// or https:// URL.")
                return
            }

            // Plain http to a non-loopback host sends credentials and session
            // data unencrypted — require a one-time acknowledgment per host.
            // Loopback is exempt: nothing leaves the machine, and the SSH
            // tunnel entrance must never prompt.
            if scheme == "http",
                let host = targetURL.host?.lowercased(),
                !Self.isLoopbackHost(host),
                !acknowledgedPlaintextHosts.contains(host)
            {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Unencrypted connection"
                alert.informativeText =
                    "\"\(host)\" will be reached over plain HTTP — credentials, cookies, "
                    + "and chat data will cross the network unencrypted.\n\n"
                    + "Continue only if the path to the server is already protected "
                    + "(Tailscale, VPN, trusted LAN). Otherwise use an https:// URL "
                    + "or the SSH tunnel option.\n\n"
                    + "You won't be asked again for this host."
                alert.addButton(withTitle: "Use HTTP Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                UserDefaults.standard.set(
                    acknowledgedPlaintextHosts + [host], forKey: Self.plaintextHostsKey)
            }

            let defaults = UserDefaults.standard
            defaults.set(connectionMode, forKey: "connectionMode")
            defaults.set(targetURL.absoluteString, forKey: "targetURL")
        }

        // Fix #41: persist pending hotkey edits if any (defer model prevents Cancel wiping them)
        if let kc = pendingHotkeyKeyCode   { UserDefaults.standard.set(Int(kc), forKey: "globalHotkeyKeyCode") }
        if let m  = pendingHotkeyModifiers  { UserDefaults.standard.set(Int(m),  forKey: "globalHotkeyModifiers") }
        if let en = pendingHotkeyEnabled    { UserDefaults.standard.set(en, forKey: "globalHotkeyEnabled") }

        // Persist custom headers from the text view
        let headerLines = headersTextView.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let parsedHeaders: [(name: String, value: String)] = headerLines.compactMap { line in
            guard let colonIndex = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[colonIndex...].dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, value)
        }
        CustomHeaderURLProtocol.saveCustomHeaders(parsedHeaders)

        close()
        onSave?()
    }

    @objc func modeChanged() {
        let isSSHMode = connectionModeSegment.selectedSegment == 1
        // Dim rather than hide so the fixed-frame layout keeps its shape;
        // disable inputs so a dimmed field can't take focus or edits.
        sshViews.forEach { view in
            view.alphaValue = isSSHMode ? 1.0 : 0.35
            if let field = view as? NSTextField, field.isBezeled {
                field.isEnabled = isSSHMode
            }
        }
        targetURLField.isHidden = isSSHMode
        tunnelURLLabel.isHidden = !isSSHMode
        refreshTunnelURLLabel()
        // A test result only describes the settings that were tested.
        clearTestResult()
    }

    private func clearTestResult() {
        testResultLabel.stringValue = ""
        testResultLabel.toolTip = nil
    }

    private func refreshTunnelURLLabel() {
        let port = Int(localPortField.stringValue) ?? 8787
        tunnelURLLabel.stringValue = "http://127.0.0.1:\(port)  (via SSH tunnel)"
    }

    // MARK: - Plaintext-HTTP acknowledgment

    private static let plaintextHostsKey = "plaintextAcknowledgedHosts"

    private var acknowledgedPlaintextHosts: [String] {
        UserDefaults.standard.stringArray(forKey: Self.plaintextHostsKey) ?? []
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Invalid value"
        alert.informativeText = message
        alert.runModal()
    }

    @objc func testConnection() {
        let isSSHMode = connectionModeSegment.selectedSegment == 1

        if isSSHMode {
            // Hermes lives on the remote loopback — the only route to it is
            // a tunnel. Stage 1 verifies auth with a real non-interactive
            // login; stage 2 probes /health through the live tunnel when it
            // matches these settings, otherwise through a temporary forward.
            let host = hostField.stringValue
            let user = usernameField.stringValue
            guard TunnelManager.isValidSSHIdentifier(user),
                TunnelManager.isValidSSHIdentifier(host)
            else {
                testResultLabel.stringValue = "Bad user/host"
                testResultLabel.textColor = .systemRed
                testResultLabel.toolTip =
                    "Username and host must be non-empty and may not start "
                    + "with \"-\" or contain spaces."
                return
            }
            testResultLabel.stringValue = "Testing SSH…"
            testResultLabel.textColor = .secondaryLabelColor
            TunnelManager.testAuth(user: user, host: host) { [weak self] authResult in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch authResult {
                    case .unreachable:
                        self.testResultLabel.stringValue = "✗ No SSH"
                        self.testResultLabel.textColor = .systemRed
                        self.testResultLabel.toolTip =
                            "No usable SSH session with \(host) — connection refused, "
                            + "timed out, or host key problem."
                        return
                    case .authFailed:
                        self.testResultLabel.stringValue = "✗ Auth failed"
                        self.testResultLabel.textColor = .systemRed
                        self.testResultLabel.toolTip =
                            "\(host) speaks SSH but refused key auth for \"\(user)\". "
                            + "The tunnel needs passwordless keys — set them up with: "
                            + "ssh-copy-id \(user)@\(host)"
                        return
                    case .authenticated:
                        break
                    }
                    // The live tunnel can only vouch for the fields when every
                    // forward-shaping setting matches what it was built from.
                    let defaults = UserDefaults.standard
                    let tunnelUp =
                        (NSApp.delegate as? AppDelegate)?.tunnelManager?.status == .connected
                    let fieldPort = self.localPortField.stringValue
                    guard tunnelUp,
                        defaults.string(forKey: "connectionMode") == "ssh",
                        defaults.string(forKey: "sshHost") == host,
                        defaults.string(forKey: "sshUser") == user,
                        defaults.string(forKey: "localPort") == fieldPort,
                        defaults.string(forKey: "remotePort")
                            == self.remotePortField.stringValue,
                        let port = Int(fieldPort)
                    else {
                        // No matching live tunnel: verify end-to-end through
                        // a temporary forward built from the field settings.
                        guard let localPort = Int(fieldPort),
                            (1...65535).contains(localPort),
                            let remotePort = Int(self.remotePortField.stringValue),
                            (1...65535).contains(remotePort)
                        else {
                            self.testResultLabel.stringValue = "✗ Bad port"
                            self.testResultLabel.textColor = .systemRed
                            self.testResultLabel.toolTip =
                                "Ports must be numbers between 1 and 65535."
                            return
                        }
                        // If the app's own live tunnel holds the configured
                        // local port, test through an ephemeral port instead:
                        // Save & Reconnect frees the real one by stopping the
                        // old tunnel. A foreign process on the port still
                        // reports "✗ Port busy" via testForward's pre-check.
                        var testLocalPort = localPort
                        if tunnelUp,
                            defaults.string(forKey: "connectionMode") == "ssh",
                            defaults.string(forKey: "localPort") == fieldPort,
                            let ephemeral = TunnelManager.freeEphemeralPort()
                        {
                            testLocalPort = ephemeral
                        }
                        self.testResultLabel.stringValue = "Testing tunnel…"
                        self.testResultLabel.textColor = .secondaryLabelColor
                        TunnelManager.testForward(
                            user: user, host: host,
                            localPort: testLocalPort, remotePort: remotePort
                        ) { forwardResult in
                            DispatchQueue.main.async {
                                switch forwardResult {
                                case .healthy:
                                    self.testResultLabel.stringValue = "✓ Hermes OK"
                                    self.testResultLabel.textColor = .systemGreen
                                    self.testResultLabel.toolTip =
                                        "SSH auth, port forward, and /health all verified "
                                        + "end-to-end with these settings (via a temporary "
                                        + "tunnel, now closed)."
                                case .reachableNoHealth:
                                    self.testResultLabel.stringValue = "◐ No /health"
                                    self.testResultLabel.textColor = .systemOrange
                                    self.testResultLabel.toolTip =
                                        "SSH auth and the forward work, but /health didn't "
                                        + "verify through the tunnel — is hermes running on "
                                        + "the remote at 127.0.0.1:\(remotePort)?"
                                case .localPortBusy:
                                    self.testResultLabel.stringValue = "✗ Port busy"
                                    self.testResultLabel.textColor = .systemRed
                                    self.testResultLabel.toolTip =
                                        "Local port \(localPort) is already in use on this "
                                        + "Mac — choose a different local port."
                                case .forwardFailed:
                                    self.testResultLabel.stringValue = "✗ No forward"
                                    self.testResultLabel.textColor = .systemRed
                                    self.testResultLabel.toolTip =
                                        "SSH authenticated, but the port forward could not "
                                        + "be established."
                                }
                            }
                        }
                        return
                    }
                    self.testResultLabel.stringValue = "Testing tunnel…"
                    self.testResultLabel.textColor = .secondaryLabelColor
                    ReachabilityProbe.probeHealth(
                        urlString: "http://127.0.0.1:\(port)", timeout: 5
                    ) { result in
                        DispatchQueue.main.async {
                            switch result {
                            case .healthy:
                                self.testResultLabel.stringValue = "✓ Hermes OK"
                                self.testResultLabel.textColor = .systemGreen
                                self.testResultLabel.toolTip =
                                    "/health verified end-to-end through the running tunnel."
                            case .reachable:
                                self.testResultLabel.stringValue = "◐ No /health"
                                self.testResultLabel.textColor = .systemOrange
                                self.testResultLabel.toolTip =
                                    "The tunnel entrance answers but /health didn't verify — "
                                    + "is hermes running on the remote side?"
                            case .unreachable:
                                self.testResultLabel.stringValue = "✗ Tunnel dead"
                                self.testResultLabel.textColor = .systemOrange
                                self.testResultLabel.toolTip =
                                    "SSH auth works, but nothing responded through the tunnel "
                                    + "entrance on 127.0.0.1:\(port). The forward may have died — "
                                    + "Save & Reconnect to rebuild it."
                            }
                        }
                    }
                }
            }
            return
        }

        let urlString = targetURLField.stringValue.isEmpty
            ? (UserDefaults.standard.string(forKey: "targetURL") ?? "http://localhost:8787")
            : targetURLField.stringValue

        guard URL(string: urlString)?.host != nil else {
            testResultLabel.stringValue = "Invalid URL"
            testResultLabel.textColor = .systemRed
            return
        }

        testResultLabel.stringValue = "Testing…"
        testResultLabel.textColor = .secondaryLabelColor

        // Tri-state: /health verified · port open but /health unverified
        // (reverse proxy up, hermes down — or not a hermes at all) · dead.
        ReachabilityProbe.probeHealth(urlString: urlString, timeout: 5) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .healthy:
                    self.testResultLabel.stringValue = "✓ Hermes OK"
                    self.testResultLabel.textColor = .systemGreen
                    self.testResultLabel.toolTip = "/health answered — verified hermes server."
                case .reachable:
                    self.testResultLabel.stringValue = "◐ No /health"
                    self.testResultLabel.textColor = .systemOrange
                    self.testResultLabel.toolTip =
                        "The port accepts connections but /health didn't verify — "
                        + "possibly a reverse proxy in front of a stopped hermes, "
                        + "or a different service on this port."
                case .unreachable:
                    self.testResultLabel.stringValue = "✗ Unreachable"
                    self.testResultLabel.textColor = .systemRed
                    self.testResultLabel.toolTip = "Nothing is accepting connections at this host/port."
                }
            }
        }
    }

    @objc func cancel() {
        close()
    }
}

extension PreferencesWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // Any edit invalidates a previous Test Connection result.
        clearTestResult()
        // Keep the derived tunnel-URL label in sync while the local port is typed.
        if (obj.object as? NSTextField) === localPortField {
            refreshTunnelURLLabel()
        }
    }
}
