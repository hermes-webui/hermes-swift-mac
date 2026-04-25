import Cocoa
import Carbon.HIToolbox

// MARK: - Hotkey recorder view (fix #41)
//
// A click-to-arm NSView that captures a key combination and displays it symbolically.
// Used in PreferencesWindowController to let the user configure the global shortcut.
//
// Usage:
//   let recorder = HotkeyRecorderView(frame: ...)
//   recorder.keyCode = UInt32(defaults.integer(forKey: "globalHotkeyKeyCode"))
//   recorder.modifiers = UInt32(defaults.integer(forKey: "globalHotkeyModifiers"))
//   recorder.onCapture = { keyCode, mods in
//       defaults.set(Int(keyCode), forKey: "globalHotkeyKeyCode")
//       defaults.set(Int(mods), forKey: "globalHotkeyModifiers")
//   }
//   recorder.onClear = {
//       defaults.set(false, forKey: "globalHotkeyEnabled")
//   }

final class HotkeyRecorderView: NSView {

    /// Called when the user presses a valid combo. keyCode and mods are Carbon values.
    var onCapture: ((_ keyCode: UInt32, _ carbonMods: UInt32) -> Void)?
    /// Called when the user clears the shortcut (presses Delete/Backspace in record mode).
    var onClear: (() -> Void)?

    /// Current key code (Carbon kVK_* constant). Set before display.
    var keyCode: UInt32 = UInt32(kVK_ANSI_H)
    /// Current modifiers (Carbon cmdKey | shiftKey etc.). Set before display.
    var modifiers: UInt32 = UInt32(cmdKey | shiftKey)
    /// Whether a shortcut is currently active (false = cleared/disabled).
    var isEnabled: Bool = true

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Bare Delete/Backspace (no modifiers) in recording mode clears the shortcut.
        // Cmd+Delete, Ctrl+Delete, etc. can still be bound as hotkeys — let them fall through.
        let usableModsForClear: NSEvent.ModifierFlags = [.command, .control, .option]
        let hasMod = !flags.intersection(usableModsForClear).isEmpty
        if !hasMod && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) {
            isEnabled = false
            isRecording = false
            needsDisplay = true
            window?.makeFirstResponder(nil)
            onClear?()
            return
        }

        // Escape cancels recording without changing the shortcut.
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            needsDisplay = true
            window?.makeFirstResponder(nil)
            return
        }

        // Require at least one of Cmd/Ctrl/Option to avoid registering plain letter keys
        // as global hotkeys (e.g. bare "h" would intercept normal typing everywhere).
        guard !flags.intersection(usableModsForClear).isEmpty else {
            NSSound.beep()
            return
        }

        keyCode = UInt32(event.keyCode)
        modifiers = HotkeyRecorderView.carbonFlags(from: flags)
        isEnabled = true
        isRecording = false
        needsDisplay = true
        window?.makeFirstResponder(nil)
        onCapture?(keyCode, modifiers)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        NSColor.separatorColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 5, yRadius: 5)
        borderPath.lineWidth = 1
        borderPath.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = "Type a shortcut\u{2026}"
            color = .secondaryLabelColor
        } else if !isEnabled {
            text = "None"
            color = .tertiaryLabelColor
        } else {
            text = HotkeyRecorderView.displayString(keyCode: keyCode, carbonMods: modifiers)
            color = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pt = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }

    // MARK: - Key display helpers

    /// Render a Carbon keycode + modifiers as macOS symbols (e.g. "\u{2318}\u{21E7}H").
    static func displayString(keyCode: UInt32, carbonMods: UInt32) -> String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "\u{2303}" }  // ⌃
        if carbonMods & UInt32(optionKey)  != 0 { s += "\u{2325}" }  // ⌥
        if carbonMods & UInt32(shiftKey)   != 0 { s += "\u{21E7}" }  // ⇧
        if carbonMods & UInt32(cmdKey)     != 0 { s += "\u{2318}" }  // ⌘
        s += keyName(for: keyCode)
        return s
    }

    // Non-printing keys mapped to Unicode symbols.
    private static let symbolicNames: [Int: String] = [
        kVK_Return:       "\u{21A9}",  // ↩
        kVK_Tab:          "\u{21E5}",  // ⇥
        kVK_Space:        "\u{2423}",  // ␣
        kVK_Delete:       "\u{232B}",  // ⌫
        kVK_ForwardDelete:"\u{2326}",  // ⌦
        kVK_Escape:       "\u{238B}",  // ⎋
        kVK_LeftArrow:    "\u{2190}",  // ←
        kVK_RightArrow:   "\u{2192}",  // →
        kVK_UpArrow:      "\u{2191}",  // ↑
        kVK_DownArrow:    "\u{2193}",  // ↓
        kVK_Home:         "\u{2196}",  // ↖
        kVK_End:          "\u{2198}",  // ↘
        kVK_PageUp:       "\u{21DE}",  // ⇞
        kVK_PageDown:     "\u{21DF}",  // ⇟
        kVK_F1:  "F1",  kVK_F2:  "F2",  kVK_F3:  "F3",  kVK_F4:  "F4",
        kVK_F5:  "F5",  kVK_F6:  "F6",  kVK_F7:  "F7",  kVK_F8:  "F8",
        kVK_F9:  "F9",  kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Convert a Carbon keycode to its display label using UCKeyTranslate (respects
    /// the current keyboard layout) for printable keys, and a symbol table for
    /// non-printing keys (arrows, function keys, etc.).
    private static func keyName(for keyCode: UInt32) -> String {
        if let sym = symbolicNames[Int(keyCode)] { return sym }

        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }

        // Get-style API: TISGetInputSourceProperty returns a +0 (unretained) reference.
        // Using takeUnretainedValue — don't release it (the input source owns it).
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0

        let result = layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLength,
                &chars
            )
        }

        guard result == noErr, actualLength > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: actualLength).uppercased()
    }

    // MARK: - Modifier conversion

    /// Convert NSEvent.ModifierFlags to Carbon modifier int for RegisterEventHotKey.
    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}
