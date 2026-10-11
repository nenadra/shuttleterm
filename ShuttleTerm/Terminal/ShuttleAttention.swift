//
//  ShuttleAttention.swift
//  ShuttleTerm
//
//  Dock badge and a lightweight AppKit banner when a terminal session needs
//  attention. Badge authorization is requested off the main thread so the app
//  appears in System Settings → Notifications with Badge App Icon. Calling
//  UNUserNotificationCenter on the main thread at launch can deadlock this
//  ad-hoc signed app against usernoted/TCC.
//

import AppKit
import UserNotifications

@objc(ShuttleAttention)
final class ShuttleAttention: NSObject {
    @objc static let shared = ShuttleAttention()

    private var pendingIds = Set<String>()
    private var banners: [String: NSPanel] = [:]
    private var bannerDismissWork: [String: DispatchWorkItem] = [:]
    private let notifyQueue = DispatchQueue(label: "shuttleterm.attention.notify")
    private var didPrepare = false

    private override init() {
        super.init()
    }

    @objc func prepare() {
        notifyQueue.async { [weak self] in
            guard let self, !self.didPrepare else { return }
            self.didPrepare = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { _, _ in }
        }
    }

    func hideBannersForAppLock() {
        onMain {
            for id in Array(self.banners.keys) {
                self.dismissBanner(id)
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
        pendingIds.insert(session.attentionId)
        refreshBadge()
    }

    func clear(_ session: ShuttleTerminalSession) {
        onMain {
            self.drop(attentionId: session.attentionId)
        }
    }

    private func raise(session: ShuttleTerminalSession, title: String, body: String) {
        prepare()
        let id = session.attentionId
        pendingIds.insert(id)
        refreshBadge()
        NSApp.requestUserAttention(.informationalRequest)
        if banners[id] != nil {
            scheduleBannerDismiss(attentionId: id)
            return
        }
        showBanner(attentionId: id, title: title, body: body)
    }

    private func drop(attentionId: String) {
        pendingIds.remove(attentionId)
        dismissBanner(attentionId)
        refreshBadge()
    }

    private func showBanner(attentionId: String, title: String, body: String) {
        dismissBanner(attentionId)
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
        scheduleBannerDismiss(attentionId: attentionId)
    }

    private func scheduleBannerDismiss(attentionId: String) {
        bannerDismissWork[attentionId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.bannerDismissWork[attentionId] = nil
            self?.dismissBanner(attentionId)
        }
        bannerDismissWork[attentionId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func dismissBanner(_ attentionId: String) {
        bannerDismissWork[attentionId]?.cancel()
        bannerDismissWork[attentionId] = nil
        banners.removeValue(forKey: attentionId)?.orderOut(nil)
        layoutBanners()
    }

    private func layoutBanners() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        var y = screen.maxY - 16
        for panel in banners.values {
            let size = panel.frame.size
            y -= size.height
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: y))
            y -= 8
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
