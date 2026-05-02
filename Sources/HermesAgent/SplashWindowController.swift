import Cocoa

class SplashWindowController: NSWindowController {

    init(title: String, subtitle: String = "Connecting…") {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.center()
        // Match the active web-UI theme tracked on AppDelegate; falls back to dark.
        window.appearance = (NSApp.delegate as? AppDelegate)?.currentAppearance
            ?? NSAppearance(named: .darkAqua)
        super.init(window: window)

        // NSVisualEffectView automatically tracks the window's appearance and
        // renders with the right window-background material — avoids the
        // "white splash on light system" bug that NSColor.windowBackgroundColor
        // .cgColor causes (cgColor resolves once against system appearance,
        // not the per-window .darkAqua we set above).
        let container = NSVisualEffectView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.material = .windowBackground
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        window.contentView?.addSubview(container)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let subtitle = NSTextField(labelWithString: subtitle)
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        container.addSubview(spinner)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 10),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: spinner.topAnchor, constant: -16),

            subtitle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
