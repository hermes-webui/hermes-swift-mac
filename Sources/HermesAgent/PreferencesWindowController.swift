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
    private var testResultLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var notificationsCheckbox: NSButton!
    private var hotkeyRecorder: HotkeyRecorderView!  // Fix #41
    // Pending hotkey edits — written to UserDefaults only on Save (not immediately)
    private var pendingHotkeyKeyCode: UInt32?
    private var pendingHotkeyModifiers: UInt32?
    private var pendingHotkeyEnabled: Bool?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 628),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.center()
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

        // Connection Mode
        _ = sectionHeader("CONNECTION MODE")
        let modeLabel = NSTextField(labelWithString: "Mode")
        modeLabel.font = NSFont.systemFont(ofSize: 13)
        modeLabel.frame = NSRect(x: 24, y: y, width: 130, height: 22)
        modeLabel.alignment = .right
        content.addSubview(modeLabel)

        connectionModeSegment = NSSegmentedControl(
            labels: ["Direct (Local)", "SSH Tunnel"], trackingMode: .selectOne, target: self,
            action: #selector(modeChanged))
        connectionModeSegment.frame = NSRect(x: 164, y: y - 2, width: 300, height: 22)
        let mode = UserDefaults.standard.string(forKey: "connectionMode") ?? "direct"
        connectionModeSegment.selectedSegment = mode == "ssh" ? 1 : 0
        content.addSubview(connectionModeSegment)
        y -= 36

        let divider1 = divider()
        sshViews.append(divider1)

        // SSH Connection section (shown only in SSH mode)
        let sshHeader = sectionHeader("SSH CONNECTION")
        sshViews.append(sshHeader)
        sshHeader.isHidden = mode == "direct"

        usernameField = row("Username", placeholder: "hermes", defaultsKey: "sshUser", isSSH: true)
        usernameField.isHidden = mode == "direct"
        hostField = row("Host", placeholder: "your-server.com", defaultsKey: "sshHost", isSSH: true)
        hostField.isHidden = mode == "direct"

        let divider2 = divider()
        sshViews.append(divider2)

        // Port forwarding section
        let portHeader = sectionHeader("PORT FORWARDING")
        sshViews.append(portHeader)
        portHeader.isHidden = mode == "direct"

        localPortField = row(
            "Local port", placeholder: "8787", defaultsKey: "localPort", width: 80, isSSH: true)
        localPortField.isHidden = mode == "direct"
        remotePortField = row(
            "Remote port", placeholder: "8787", defaultsKey: "remotePort", width: 80, isSSH: true)
        remotePortField.isHidden = mode == "direct"

        _ = divider()

        // App section
        _ = sectionHeader("APP")
        targetURLField = row(
            "Target URL", placeholder: "http://localhost:8787", defaultsKey: "targetURL")

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
            defaults.set(targetURL.absoluteString, forKey: "targetURL")
        } else {
            let defaults = UserDefaults.standard
            defaults.set(connectionMode, forKey: "connectionMode")
            defaults.set(targetURL.absoluteString, forKey: "targetURL")
        }

        // Fix #41: persist pending hotkey edits if any (defer model prevents Cancel wiping them)
        if let kc = pendingHotkeyKeyCode   { UserDefaults.standard.set(Int(kc), forKey: "globalHotkeyKeyCode") }
        if let m  = pendingHotkeyModifiers  { UserDefaults.standard.set(Int(m),  forKey: "globalHotkeyModifiers") }
        if let en = pendingHotkeyEnabled    { UserDefaults.standard.set(en, forKey: "globalHotkeyEnabled") }
        close()
        onSave?()
    }

    @objc func modeChanged() {
        let isSSHMode = connectionModeSegment.selectedSegment == 1
        sshViews.forEach { $0.isHidden = !isSSHMode }
    }

    private func showValidationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Invalid value"
        alert.informativeText = message
        alert.runModal()
    }

    @objc func testConnection() {
        let urlString = targetURLField.stringValue.isEmpty
            ? (UserDefaults.standard.string(forKey: "targetURL") ?? "http://localhost:8787")
            : targetURLField.stringValue

        guard let url = URL(string: urlString) else {
            testResultLabel.stringValue = "Invalid URL"
            testResultLabel.textColor = .systemRed
            return
        }

        testResultLabel.stringValue = "Testing…"
        testResultLabel.textColor = .secondaryLabelColor

        // Use GET (not HEAD) because many dev servers return 405/501 for HEAD
        // even when they serve GET normally. Treat any HTTPURLResponse as
        // reachable regardless of status code — if TCP+HTTP completed a
        // round-trip, the server is up. Only a network-level failure (no
        // response) counts as "Unreachable".
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if response is HTTPURLResponse {
                    self.testResultLabel.stringValue = "✓ Connected"
                    self.testResultLabel.textColor = .systemGreen
                } else {
                    self.testResultLabel.stringValue = "✗ Unreachable"
                    self.testResultLabel.textColor = .systemRed
                }
            }
        }.resume()
    }

    @objc func cancel() {
        close()
    }
}
