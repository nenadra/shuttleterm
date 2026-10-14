//
//  ShuttleAttention.swift
//  ShuttleTerm
//
//  One system-style banner and one Notification Center item per terminal
//  window that needs a response. Hovering that window or clicking Close
//  dismisses it. The Dock badge is that window count. Badge and notification
//  center APIs run off the main thread so this ad-hoc signed app does not
//  deadlock against usernoted/TCC at launch.
//

import AppKit
import UserNotifications

@objc(ShuttleAttention)
final class ShuttleAttention: NSObject, UNUserNotificationCenterDelegate {
    @objc static let shared = ShuttleAttention()

    private var pendingIds = Set<String>()
    private var pendingOrder: [String] = []
    private var banners: [String: NSPanel] = [:]
    private let notifyQueue = DispatchQueue(label: "shuttleterm.attention.notify", qos: .userInitiated)
    private var didPrepare = false
    private var notifyReady = false
    private var queuedPosts: [(identifier: String, title: String, body: String, count: Int)] = []

    private override init() {
        super.init()
    }

    @objc func prepare() {
        onMain { [weak self] in
            guard let self, !self.didPrepare else { return }
            self.didPrepare = true
            UNUserNotificationCenter.current().delegate = self
            self.notifyQueue.async {
                let center = UNUserNotificationCenter.current()
                center.getNotificationSettings { settings in
                    self.notifyQueue.async {
                        self.applyAuthorization(settings.authorizationStatus, center: center)
                    }
                }
                self.notifyQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.notifyReady else { return }
                    self.notifyReady = true
                    self.flushQueuedNotifications()
                }
            }
        }
    }

    private func applyAuthorization(_ status: UNAuthorizationStatus, center: UNUserNotificationCenter) {
        switch status {
        case .authorized, .provisional:
            notifyReady = true
            flushQueuedNotifications()
        case .denied:
            notifyReady = true
            queuedPosts.removeAll()
        case .notDetermined:
            center.requestAuthorization(options: [.badge, .alert]) { granted, _ in
                self.notifyQueue.async {
                    self.notifyReady = true
                    if granted {
                        self.flushQueuedNotifications()
                    } else {
                        self.queuedPosts.removeAll()
                    }
                }
            }
        default:
            notifyReady = true
            flushQueuedNotifications()
        }
    }

    func hideBannersForAppLock() {
        onMain {
            for id in Array(self.banners.keys) {
                self.hideBanner(id)
            }
        }
    }

    func noteBell(from session: ShuttleTerminalSession) {
        onMain {
            if session.isRestoring { return }
            if session.suppressesAttention { return }
            if ShuttleAppLock.shared.isLocked {
                self.raiseLocked(session: session)
                return
            }
            if session.window.isKeyWindow && NSApp.isActive {
                NSSound.beep()
                return
            }
            if session.reportsBellAsAttention {
                self.raise(session: session, title: session.attentionTitle, body: session.attentionBody)
            } else {
                NSSound.beep()
            }
        }
    }

    func noteNotify(from session: ShuttleTerminalSession, title: String? = nil, body: String? = nil) {
        onMain {
            if session.isRestoring { return }
            if session.suppressesAttention { return }
            if ShuttleAppLock.shared.isLocked {
                self.raiseLocked(session: session)
                return
            }
            if session.window.isKeyWindow && NSApp.isActive {
                return
            }
            self.raise(
                session: session,
                title: Self.resolvedTitle(title, session: session),
                body: Self.resolvedBody(body, session: session)
            )
        }
    }

    func noteBackgroundWait(from session: ShuttleTerminalSession) {
        onMain {
            if session.isRestoring { return }
            if session.suppressesAttention { return }
            if ShuttleAppLock.shared.isLocked {
                self.raiseLocked(session: session)
                return
            }
            self.raise(session: session, title: session.attentionTitle, body: session.attentionBody)
        }
    }

    private static func resolvedTitle(_ title: String?, session: ShuttleTerminalSession) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? session.attentionTitle : trimmed
    }

    private static func resolvedBody(_ body: String?, session: ShuttleTerminalSession) -> String {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? session.attentionBody : trimmed
    }

    private func raiseLocked(session: ShuttleTerminalSession) {
        insertPending(session.attentionId)
        refreshBadge()
        postWindowNotification(
            attentionId: session.attentionId,
            title: session.attentionTitle,
            body: session.attentionBody
        )
    }

    func clear(_ session: ShuttleTerminalSession) {
        onMain {
            self.drop(attentionId: session.attentionId)
        }
    }

    private func raise(session: ShuttleTerminalSession, title: String, body: String) {
        if session.suppressesAttention { return }
        prepare()
        let id = session.attentionId
        insertPending(id)
        refreshBadge()
        NSApp.requestUserAttention(.informationalRequest)
        postWindowNotification(attentionId: id, title: title, body: body)
        if let panel = banners[id], let view = panel.contentView as? AttentionBannerView {
            view.titleText = title
            view.bodyText = body
            layoutBanners()
        } else {
            showBanner(attentionId: id, title: title, body: body)
        }
    }

    private func insertPending(_ id: String) {
        if pendingIds.insert(id).inserted {
            pendingOrder.append(id)
        }
    }

    private func drop(attentionId: String) {
        pendingIds.remove(attentionId)
        pendingOrder.removeAll { $0 == attentionId }
        hideBanner(attentionId)
        refreshBadge()
        removeWindowNotification(attentionId)
    }

    private func showBanner(attentionId: String, title: String, body: String) {
        hideBanner(attentionId)
        let size = AttentionBannerView.bannerSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.identifier = NSUserInterfaceItemIdentifier(attentionId)

        let view = AttentionBannerView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        view.titleText = title
        view.bodyText = body
        view.onActivate = { [weak self] in
            if let session = ShuttleTerminalController.shared.session(attentionId: attentionId) {
                session.makeKeyAndOrderFront()
                self?.clear(session)
            } else {
                self?.drop(attentionId: attentionId)
            }
        }
        view.onDismiss = { [weak self] in
            if let session = ShuttleTerminalController.shared.session(attentionId: attentionId) {
                session.markAttentionDismissed()
                self?.clear(session)
            } else {
                self?.drop(attentionId: attentionId)
            }
        }
        panel.contentView = view
        banners[attentionId] = panel
        layoutBanners()
        panel.orderFrontRegardless()
    }

    private func hideBanner(_ attentionId: String) {
        banners.removeValue(forKey: attentionId)?.orderOut(nil)
        layoutBanners()
    }

    private func layoutBanners() {
        var yByScreen: [ObjectIdentifier: CGFloat] = [:]
        for id in pendingOrder.reversed() {
            guard let panel = banners[id] else { continue }
            let session = ShuttleTerminalController.shared.session(attentionId: id)
            let nsScreen = session?.window.screen ?? NSScreen.main
            let vis = ShuttleWindowChrome.workspace(on: nsScreen)
            let key = ObjectIdentifier(nsScreen ?? panel)
            var y = yByScreen[key] ?? vis.maxY - 16
            let size = panel.frame.size
            y -= size.height
            let x = max(vis.minX + 16, vis.maxX - size.width - 16)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.orderFrontRegardless()
            y -= 10
            yByScreen[key] = y
        }
    }

    private func refreshBadge() {
        let count = pendingIds.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        NSApp.dockTile.display()
        notifyQueue.async {
            if #available(macOS 13.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: { _ in })
            }
        }
    }

    private func notificationIdentifier(_ attentionId: String) -> String {
        "shuttleterm.window.\(attentionId)"
    }

    private func postWindowNotification(attentionId: String, title: String, body: String) {
        let count = pendingIds.count
        let identifier = notificationIdentifier(attentionId)
        notifyQueue.async {
            if !self.notifyReady {
                self.queuedPosts.removeAll { $0.identifier == identifier }
                self.queuedPosts.append((identifier, title, body, count))
                return
            }
            self.deliverNotification(identifier: identifier, title: title, body: body, count: count)
        }
    }

    private func flushQueuedNotifications() {
        let queued = queuedPosts
        queuedPosts.removeAll()
        for item in queued {
            deliverNotification(
                identifier: item.identifier,
                title: item.title,
                body: item.body,
                count: item.count
            )
        }
    }

    private func deliverNotification(identifier: String, title: String, body: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.badge = NSNumber(value: count)
        content.sound = nil
        content.threadIdentifier = identifier
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .active
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: { _ in })
    }

    private func removeWindowNotification(_ attentionId: String) {
        let identifier = notificationIdentifier(attentionId)
        let count = pendingIds.count
        notifyQueue.async {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            if #available(macOS 13.0, *) {
                center.setBadgeCount(count, withCompletionHandler: { _ in })
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 14.0, *) {
            completionHandler([.list])
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let prefix = "shuttleterm.window."
        let attentionId = identifier.hasPrefix(prefix)
            ? String(identifier.dropFirst(prefix.count))
            : identifier
        onMain {
            if let session = ShuttleTerminalController.shared.session(attentionId: attentionId) {
                session.makeKeyAndOrderFront()
                self.clear(session)
            } else {
                self.drop(attentionId: attentionId)
            }
            completionHandler()
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

private final class AttentionBannerView: NSView {
    static let bannerSize = NSSize(width: 344, height: 82)

    var titleText = "" {
        didSet { titleLabel.stringValue = titleText }
    }
    var bodyText = "" {
        didSet { bodyLabel.stringValue = bodyText }
    }
    var onActivate: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let closeButton = BannerCloseButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 7
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false

        let appLabel = NSTextField(labelWithString: "ShuttleTerm")
        appLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        appLabel.textColor = .secondaryLabelColor
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bodyLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [appLabel, titleLabel, bodyLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(textStack)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onActivate?()
        }
    }

    @objc private func dismissClicked() {
        onDismiss?()
    }
}

private final class BannerCloseButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(config)
        contentTintColor = .secondaryLabelColor
        toolTip = "Close"
        setAccessibilityLabel("Close")
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        applyFill()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        applyFill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    private func applyFill() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
    }
}
