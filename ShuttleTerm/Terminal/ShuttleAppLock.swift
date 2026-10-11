//
//  ShuttleAppLock.swift
//  ShuttleTerm
//
//  Optional extra lock: after the Mac sleeps or the screen locks, hide
//  terminal contents until Touch ID or the Mac login password succeeds.
//

import AppKit
import LocalAuthentication

@objc(ShuttleAppLock)
final class ShuttleAppLock: NSObject {
    @objc static let shared = ShuttleAppLock()

    private static let reason = "Unlock ShuttleTerm to show your open terminals."

    @objc var isEnabled = false {
        didSet {
            if !isEnabled {
                unlock()
            }
        }
    }

    @objc private(set) var isLocked = false

    private var macScreenLocked = false
    private var prompting = false
    private var authContext: LAContext?
    private var started = false

    private override init() {
        super.init()
        start()
    }

    static func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    @objc func start() {
        guard !started else { return }
        started = true

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(macWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(macDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributed.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func performWhenUnlocked(_ action: @escaping () -> Void) {
        if !isLocked {
            action()
            return
        }
        promptUnlock { success in
            if success {
                action()
            }
        }
    }

    @objc func promptUnlock() {
        promptUnlock(completion: nil)
    }

    private func promptUnlock(completion: ((Bool) -> Void)?) {
        guard isLocked else {
            completion?(true)
            return
        }
        guard !macScreenLocked else {
            completion?(false)
            return
        }
        if !Self.canAuthenticate() {
            unlock()
            completion?(true)
            return
        }
        if prompting {
            completion?(false)
            return
        }
        prompting = true
        let context = LAContext()
        context.localizedCancelTitle = "Stay Locked"
        context.localizedFallbackTitle = "Use Password"
        authContext = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Self.reason) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.prompting = false
                self.authContext = nil
                if success {
                    self.unlock()
                    completion?(true)
                } else {
                    completion?(false)
                }
            }
        }
    }

    @objc private func macWillSleep() {
        lock()
    }

    @objc private func macDidWake() {
        if isLocked && isEnabled && NSApp.isActive && !macScreenLocked {
            promptUnlock()
        }
    }

    @objc private func screenDidLock() {
        macScreenLocked = true
        lock()
    }

    @objc private func screenDidUnlock() {
        macScreenLocked = false
        if isLocked && isEnabled && NSApp.isActive {
            promptUnlock()
        }
    }

    @objc private func appDidBecomeActive() {
        if isLocked && isEnabled && !macScreenLocked {
            promptUnlock()
        }
    }

    private func lock() {
        guard isEnabled else { return }
        guard Self.canAuthenticate() else { return }
        authContext?.invalidate()
        authContext = nil
        prompting = false
        if isLocked {
            applyLockedUI()
            return
        }
        isLocked = true
        applyLockedUI()
    }

    private func unlock() {
        guard isLocked else { return }
        isLocked = false
        prompting = false
        authContext?.invalidate()
        authContext = nil
        ShuttleTerminalController.shared.applySessionAppLocks()
    }

    private func applyLockedUI() {
        ShuttleSettingsPanel.shared.hideIfOpen()
        ShuttleAboutPanel.shared.hideIfOpen()
        ShuttleAttention.shared.hideBannersForAppLock()
        ShuttleTerminalController.shared.applySessionAppLocks()
    }
}

final class ShuttleLockOverlayView: NSView {
    private let unlockButton = NSButton(title: "Unlock", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let title = NSTextField(labelWithString: "ShuttleTerm is locked")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        let detail = NSTextField(wrappingLabelWithString: "Touch ID or your Mac password unlocks the open terminals.")
        detail.font = NSFont.systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 280

        unlockButton.bezelStyle = .rounded
        unlockButton.target = self
        unlockButton.action = #selector(unlockClicked)
        unlockButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, title, detail, unlockButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        ShuttleAppLock.shared.promptUnlock()
    }

    override func keyDown(with event: NSEvent) {
        ShuttleAppLock.shared.promptUnlock()
    }

    @objc private func unlockClicked() {
        ShuttleAppLock.shared.promptUnlock()
    }
}
