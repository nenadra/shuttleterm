//
//  ShuttleAboutPanel.swift
//  ShuttleTerm
//

import AppKit

@objc(ShuttleAboutPanel)
final class ShuttleAboutPanel: NSObject, NSWindowDelegate {
    @objc static let shared = ShuttleAboutPanel()

    private var window: NSWindow?
    private var clickMonitor: Any?
    private var ignoreResignUntil: Date?

    @objc func show() {
        if window == nil {
            buildWindow()
        }
        ignoreResignUntil = Date().addingTimeInterval(0.25)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installClickMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        if let until = ignoreResignUntil, Date() < until { return }
        dismiss()
    }

    func windowWillClose(_ notification: Notification) {
        removeClickMonitor()
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return event }
            if event.window !== window {
                self.dismiss()
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    @objc func hideIfOpen() {
        dismiss()
    }

    private func dismiss() {
        guard let window, window.isVisible else { return }
        removeClickMonitor()
        window.orderOut(nil)
    }

    private func buildWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About ShuttleTerm"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 640))

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let name = NSTextField(labelWithString: "ShuttleTerm")
        name.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        name.alignment = .center

        let version = NSTextField(labelWithString: versionLine())
        version.font = NSFont.systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center

        header.addArrangedSubview(icon)
        header.addArrangedSubview(name)
        header.addArrangedSubview(version)

        let story = wrappingLabel(Self.storyText, size: 13)
        let licensesTitle = NSTextField(labelWithString: "Licenses")
        licensesTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.autohidesScrollers = true

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 496, height: 400))
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = Self.licenseBundle()
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 496, height: CGFloat.greatestFiniteMagnitude)
        text.backgroundColor = .textBackgroundColor
        scroll.documentView = text

        let content = NSStackView(views: [header, story, licensesTitle, scroll])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(18, after: header)
        content.setHuggingPriority(.defaultLow, for: .vertical)

        root.addSubview(content)
        panel.contentView = root

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            story.widthAnchor.constraint(equalTo: content.widthAnchor),
            licensesTitle.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        panel.setContentSize(NSSize(width: 540, height: 640))
        panel.center()
        window = panel
    }

    private func wrappingLabel(_ string: String, size: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = NSFont.systemFont(ofSize: size)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 496
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func versionLine() -> String {
        "Version 1.0.0"
    }

    private static let storyText = """
    I used Shuttle for years as a menubar launcher for the SSH hosts I actually open. Click, connect, get out of the way.

    When I moved to Apple Silicon I needed it to run natively on this Mac, so ShuttleTerm started as that port.

    Once the launcher was here, a built-in terminal felt obvious. Why hand every session to Terminal.app or iTerm when the same app could keep the window? SwiftTerm became that terminal. The menu, the hosts, and the session now live in one place.

    I also wanted a multi-window terminal environment that I could easily hop from window to window to work on different things.

    Enjoy!
    """

    private static func licenseBundle() -> String {
        let files = [
            ("Shuttle", "License-Shuttle"),
            ("SwiftTerm", "License-SwiftTerm"),
            ("Launch at Login", "License-LaunchAtLogin")
        ]
        return files.map { title, resource in
            let body = loadLicense(resource)
            return "=== \(title) ===\n\n\(body)"
        }.joined(separator: "\n\n")
    }

    private static func loadLicense(_ name: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "(missing \(name).txt in the app bundle)"
    }
}
