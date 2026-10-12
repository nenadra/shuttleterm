//
//  ShuttleAttention.swift
//  ShuttleTerm
//
//  One banner and one Notification Center item per terminal window that needs
//  a response. The Dock badge is that window count. Badge and notification
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
    private let notifyQueue = DispatchQueue(label: "shuttleterm.attention.notify")
    private var didPrepare = false

    private override init() {
        super.init()
    }

    @objc func prepare() {
        notifyQueue.async { [weak self] in
            guard let self, !self.didPrepare else { return }
            self.didPrepare = true
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.badge, .alert]) { _, _ in }
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

    func noteNotify(from session: ShuttleTerminalSession) {
        onMain {
            if session.isRestoring { return }
            if ShuttleAppLock.shared.isLocked {
                self.raiseLocked(session: session)
                return
            }
            if session.window.isKeyWindow && NSApp.isActive {
                return
            }
            self.raise(session: session, title: session.attentionTitle, body: session.attentionBody)
        }
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
        prepare()
        let id = session.attentionId
        insertPending(id)
        refreshBadge()
        NSApp.requestUserAttention(.informationalRequest)
        postWindowNotification(attentionId: id, title: title, body: body)
        if banners[id] == nil {
            showBanner(attentionId: id, title: title, body: body)
        } else {
            layoutBanners()
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 76),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.identifier = NSUserInterfaceItemIdentifier(attentionId)

        let view = AttentionBannerView(frame: NSRect(x: 0, y: 0, width: 360, height: 76))
        view.titleText = title
        view.bodyText = body
        view.onClick = { [weak self] in
            if let session = ShuttleTerminalController.shared.session(attentionId: attentionId) {
                session.makeKeyAndOrderFront()
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
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var y = screen.maxY - 16
        for id in pendingOrder.reversed() {
            guard let panel = banners[id] else { continue }
            let size = panel.frame.size
            y -= size.height
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: y))
            panel.orderFrontRegardless()
            y -= 10
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
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.badge = NSNumber(value: count)
            content.sound = nil
            content.threadIdentifier = attentionId
            if #available(macOS 12.0, *) {
                content.interruptionLevel = .passive
            }
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: { _ in })
        }
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
        completionHandler([])
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
    var titleText = "" {
        didSet { needsDisplay = true }
    }
    var bodyText = "" {
        didSet { needsDisplay = true }
    }
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(
            string: titleText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        let body = NSAttributedString(
            string: bodyText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1)
            ]
        )
        title.draw(in: NSRect(x: 16, y: 40, width: bounds.width - 32, height: 22))
        body.draw(in: NSRect(x: 16, y: 14, width: bounds.width - 32, height: 24))
    }
}
