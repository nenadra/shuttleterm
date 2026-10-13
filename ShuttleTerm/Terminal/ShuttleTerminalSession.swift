//
//  ShuttleTerminalSession.swift
//  ShuttleTerm
//

import AppKit

final class ShuttleTerminalSession: NSObject, NSWindowDelegate, LocalProcessTerminalViewDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    let command: String
    let afterCommand: String
    let hostTitle: String
    let reuseKey: String
    let reconnect: Bool
    let attentionId = UUID().uuidString

    private let terminal: ShuttleTermView
    private var theme: ShuttleTerminalTheme
    private let findBar = NSView()
    private let findField = NSSearchField()
    private let findCountLabel = NSTextField(labelWithString: "")
    private var findBarHeight: NSLayoutConstraint!
    private var postedTitle = ""
    private var directory: String?
    private var running = true
    private var fontSize: CGFloat
    private var fontFamily: String
    private var commandSent = false
    private var afterSent = false
    private var findVisible = false
    private var titlebarShown = false
    private var pointerInside = false
    private weak var hoverView: HoverContentView?
    private var mouseMonitor: Any?
    private let titlebarOverlay = TitlebarOverlayView()
    private let dimOverlay = FocusDimView()
    private let focusBorder = FocusBorderView()
    private let lockOverlay = ShuttleLockOverlayView()
    private var appLocked = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let gutter: CGFloat = 12
    private var terminalPadTop: NSLayoutConstraint!
    private var terminalPadLeading: NSLayoutConstraint!
    private var terminalPadTrailing: NSLayoutConstraint!
    private var terminalPadBottom: NSLayoutConstraint!
    private var edgePad: CGFloat = 12
    private var rewritingInput = false
    private var grokPending = false
    private var grokLaunchSent = false
    private var grokDidRun = false
    private var grokPendingAt: Date?
    private var lastAltScreen = false
    private var paddingCheckWork: DispatchWorkItem?
    private var chromeDragActive = false
    private var droppedToLoginShell = false
    private var cancelReconnect = false
    private var awaitingReconnect = false
    private var reconnectWork: DispatchWorkItem?
    private var afterPoll: DispatchWorkItem?
    private var afterWatchStart: Date?
    private var lastHostOutput: Date?
    private var recentOutput = ""
    private var typedQueue: [String] = []
    private var restoring = false
    private var pendingRestoreText: String?
    private var deferredStartShell = false
    private var restoreReady = false
    private var resumeAgentOnStart = false
    private var restoredWithoutLiveAgent = false
    private var restoredGrokSessionId: String?
    private var restoredGrokCwd: String?
    private var restoredAgentKind: ShuttleAgentKind?
    private var isSnappingPad = false
    private var rebootHoldActive = false
    private var typedInputLine = ""
    private var launchingSuccessor = false
    private var chromeHovered = false
    private var commandPeeking = false
    private var chromeShowWork: DispatchWorkItem?
    private static let chromeShowDelay: TimeInterval = 0.05

    var isRunning: Bool { running }
    var themeName: String { theme.name }
    var currentFontFamily: String { fontFamily }
    var attentionTitle: String { hostTitle }
    var attentionBody: String { "Action required" }
    var isRestoring: Bool { restoring }
    var reportsBellAsAttention: Bool {
        if terminal.getTerminal().isCurrentBufferAlternate {
            return true
        }
        if restoredAgentKind != nil {
            return true
        }
        if ShuttleGrokResume.isAgentInvocation(command) {
            return true
        }
        if ShuttleGrokResume.isAgentInvocation(afterCommand) {
            return true
        }
        return false
    }

    init(
        command: String,
        title: String,
        themeName: String,
        fontName: String?,
        after: String?,
        reconnect: Bool,
        reuseKey: String,
        restoreFrame: NSRect? = nil,
        restoreBuffer: String? = nil,
        restoredFontSize: CGFloat? = nil,
        grokSessionId: String? = nil,
        grokCwd: String? = nil,
        agentKind: String? = nil
    ) {
        self.command = command
        self.afterCommand = after?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.hostTitle = title
        self.reuseKey = reuseKey
        self.reconnect = reconnect
        self.fontSize = restoredFontSize ?? 12
        self.restoredGrokSessionId = grokSessionId
        self.restoredGrokCwd = grokCwd
        self.restoredAgentKind = agentKind.flatMap(ShuttleAgentKind.init(rawValue:))
        self.theme = ShuttleTerminalTheme.named(themeName, fontName: fontName, fontSize: self.fontSize)
        self.fontFamily = theme.fontFamily

        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 440)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window = NSWindow(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 360, height: 180)
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = ""
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        window.backgroundColor = theme.background
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if restoreFrame == nil {
            window.setFrameAutosaveName("ShuttleTerm.\(reuseKey)")
        }

        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.termName = "xterm-256color"
        options.cursorStyle = .blinkUnderline
        terminal = ShuttleTermView(
            frame: NSRect(origin: .zero, size: contentRect.size),
            font: theme.font,
            options: options
        )
        terminal.titlebarChromeCapturesMouse = true

        super.init()

        window.delegate = self
        terminal.processDelegate = self
        terminal.interceptCtrlC = { [weak self] in
            self?.handleCtrlC() ?? false
        }
        terminal.onHostOutput = { [weak self] slice in
            self?.noteHostOutput(slice)
        }
        terminal.onUserInput = { [weak self] slice in
            self?.noteUserInput(slice)
        }
        if restoredAgentKind == .grok
            || (restoreBuffer == nil && (
                ShuttleGrokResume.isGrokCommand(command)
                || ShuttleGrokResume.isGrokCommand(afterCommand)
            )) {
            markGrokLaunch(sent: false)
        }
        configureTerminal()
        buildChrome()
        lockTitle()
        applyWindowChrome(force: true)
        applyFocusAppearance()
        installMouseMonitor()
        if let restoreFrame {
            window.setFrame(Self.clampedFrame(restoreFrame), display: false)
        }
        if let restoreBuffer {
            restoring = true
            let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRemote = ShuttleTermReconnect.isRemote(trimmedCmd)
            let willResumeAgent = grokSessionId != nil
                || self.restoredAgentKind != nil
            restoredWithoutLiveAgent = !willResumeAgent
            let skipAgentRetype = restoredWithoutLiveAgent && (
                ShuttleGrokResume.isAgentInvocation(command)
                || ShuttleGrokResume.isAgentInvocation(self.afterCommand)
            )
            let willRetypeLocal = !trimmedCmd.isEmpty && !isRemote && !skipAgentRetype
            if !willRetypeLocal && !(willResumeAgent && !isRemote), !restoreBuffer.isEmpty {
                pendingRestoreText = restoreBuffer
                deferredStartShell = true
            }
            resumeAgentOnStart = willResumeAgent
        }
        if !deferredStartShell {
            startShell()
        }
    }

    func makeKeyAndOrderFront() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        terminal.layoutSubtreeIfNeeded()
        alignTerminalPaddingToCells(layoutNow: true)
        restoreReady = true
        flushRestoredBufferIfNeeded()
        if ShuttleAppLock.shared.isLocked {
            window.makeFirstResponder(lockOverlay)
        } else if !findVisible {
            window.makeFirstResponder(terminal)
        }
    }

    func tile(in frame: NSRect, reveal: Bool = true) {
        window.tabbingMode = .disallowed
        let previousMin = window.minSize
        let allowed = NSSize(
            width: min(previousMin.width, max(1, frame.width)),
            height: min(previousMin.height, max(1, frame.height))
        )
        if allowed.width < previousMin.width || allowed.height < previousMin.height {
            window.minSize = allowed
        }
        window.setFrame(frame, display: true, animate: false)
        if window.minSize != previousMin {
            window.minSize = previousMin
        }
        window.contentView?.layoutSubtreeIfNeeded()
        terminal.needsLayout = true
        terminal.layoutSubtreeIfNeeded()
        alignTerminalPaddingToCells(layoutNow: true)
        applyWindowChrome(force: true)
        applyFocusAppearance()
        if reveal {
            makeKeyAndOrderFront()
        }
    }

    func sendCommandToShell(_ text: String, reveal: Bool = true) {
        guard running else { return }
        let line = text.hasSuffix("\n") ? text : text + "\n"
        let bytes = Array(line.utf8)
        terminal.send(source: terminal, data: bytes[...])
        if reveal {
            makeKeyAndOrderFront()
        }
    }

    func biggerFont() {
        applyFont(size: fontSize + 1)
    }

    func smallerFont() {
        applyFont(size: fontSize - 1)
    }

    func applyThemeNamed(_ name: String) {
        theme = ShuttleTerminalTheme.named(name, fontName: fontFamily, fontSize: fontSize)
        fontFamily = theme.fontFamily
        configureTerminal()
        window.backgroundColor = theme.background
        if let layer = window.contentView?.layer {
            layer.backgroundColor = theme.background.cgColor
        }
        if let layer = hoverView?.layer {
            layer.backgroundColor = theme.background.cgColor
        }
        terminal.font = theme.font
        terminal.caretColor = theme.foreground
        applyCaretStyle()
        applyFocusAppearance()
    }

    func applyFontNamed(_ name: String) {
        fontFamily = name
        applyFont(size: fontSize)
        theme = ShuttleTerminalTheme.named(theme.name, fontName: fontFamily, fontSize: fontSize)
    }

    func applyWindowChrome(force: Bool = false) {
        if appLocked {
            titlebarOverlay.alphaValue = 0
            return
        }
        let tabs = (window.tabbedWindows?.count ?? 1) > 1
        let always = !ShuttleTerminalController.shared.titlebarOnHover || tabs
        let show = (always || titlebarShown) && !commandHidesChrome()
        setTitlebarVisible(show)
    }

    func mouseEnteredWindow() {
        if appLocked { return }
        if ShuttleTerminalController.shared.focusOnHover, NSApp.isActive {
            window.makeKey()
            if !findVisible {
                window.makeFirstResponder(terminal)
            }
        }
    }

    func mouseMovedInWindow(at point: NSPoint) {
        if appLocked { return }
        if shouldKeepChromePinned() {
            NSCursor.arrow.set()
            return
        }
        if commandHidesChrome() {
            NSCursor.arrow.set()
            hideChromeForCommandPeek()
            return
        }
        let top = window.contentView?.bounds.maxY ?? window.frame.height
        let inChrome = point.y > top - 30
        if inChrome {
            NSCursor.arrow.set()
        }
        guard ShuttleTerminalController.shared.titlebarOnHover else {
            if inChrome != chromeHovered {
                applyTrafficLightsColored(inChrome)
            }
            return
        }
        let tabs = (window.tabbedWindows?.count ?? 1) > 1
        if tabs {
            if inChrome != chromeHovered {
                applyTrafficLightsColored(inChrome)
            }
            return
        }
        updateHoverChrome(inChrome: inChrome)
    }

    private func updateHoverChrome(inChrome: Bool) {
        if inChrome {
            if titlebarShown {
                cancelChromeShow()
                return
            }
            scheduleChromeShow()
            return
        }
        cancelChromeShow()
        if titlebarShown {
            titlebarShown = false
            setTitlebarVisible(false)
        }
    }

    private func scheduleChromeShow() {
        if chromeShowWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.revealChromeIfPointerStillInStrip()
        }
        chromeShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeShowDelay, execute: work)
    }

    private func cancelChromeShow() {
        chromeShowWork?.cancel()
        chromeShowWork = nil
    }

    private func revealChromeIfPointerStillInStrip() {
        chromeShowWork = nil
        guard ShuttleTerminalController.shared.titlebarOnHover else { return }
        guard !commandHidesChrome() else { return }
        guard pointerIsInChromeStrip() else { return }
        titlebarShown = true
        setTitlebarVisible(true)
    }

    private func pointerIsInChromeStrip() -> Bool {
        guard let content = window.contentView else { return false }
        let screenPoint = NSEvent.mouseLocation
        guard pointerIsOverWindow(screenPoint) else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = content.convert(windowPoint, from: nil)
        return point.y > content.bounds.maxY - 30
    }

    func mouseExitedWindow() {
        if shouldKeepChromePinned() { return }
        // Content-view mouseExited also fires when the pointer moves onto the
        // native traffic lights (they live in the theme frame, above content).
        if pointerIsOverWindow(NSEvent.mouseLocation) {
            handleMonitoredMouse()
            return
        }
        cancelChromeShow()
        pointerInside = false
        titlebarShown = false
        chromeHovered = false
        applyTrafficLightsColored(false)
        applyWindowChrome()
    }

    func focusFind() {
        findVisible = true
        findBar.isHidden = false
        findBarHeight.constant = 28
        window.makeFirstResponder(findField)
    }

    func hideFind() {
        findVisible = false
        findBar.isHidden = true
        findBarHeight.constant = 0
        findField.stringValue = ""
        findCountLabel.stringValue = ""
        window.makeFirstResponder(terminal)
    }

    func findNext() {
        performFind(direction: .forward)
    }

    func findPrevious() {
        performFind(direction: .backward)
    }

    func clearScrollback() {
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        running = false
        cancelReconnect = true
        awaitingReconnect = false
        rebootHoldActive = false
        reconnectWork?.cancel()
        afterPoll?.cancel()
        removeMouseMonitor()
        ShuttleAttention.shared.clear(self)
        terminal.processDelegate = nil
        terminal.terminate()
    }

    func windowDidClose(_ notification: Notification) {
        window.delegate = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ShuttleTerminalController.shared.sessionDidClose(self)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        ShuttleAttention.shared.clear(self)
        ShuttleTerminalController.shared.sessionDidBecomeKey(self)
        applyFocusAppearance()
        applyCaretStyle()
        if ShuttleAppLock.shared.isLocked {
            window.makeFirstResponder(lockOverlay)
            return
        }
        if findVisible, let editor = findField.currentEditor(), window.firstResponder === editor {
            return
        }
        if !findVisible {
            window.makeFirstResponder(terminal)
        }
        applyCaretStyle()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !shouldKeepChromePinned() {
            cancelChromeShow()
            titlebarShown = false
            applyWindowChrome()
        }
        applyCaretStyle()
        applyFocusAppearance()
    }

    func windowDidMove(_ notification: Notification) {
        ShuttleTerminalController.shared.schedulePersist()
    }

    func windowDidResize(_ notification: Notification) {
        if restoreReady {
            flushRestoredBufferIfNeeded()
        }
        if !chromeDragActive {
            ShuttleTerminalController.shared.rememberWindowSize(window.frame.size)
            applyFocusAppearance()
        }
        ShuttleTerminalController.shared.schedulePersist()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        alignTerminalPaddingToCells(layoutNow: true)
        snapWindowHeightToCells()
        alignTerminalPaddingToCells(layoutNow: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        applyFocusAppearance()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyFocusAppearance()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        lockTitle()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        self.directory = directory
        lockTitle()
        ShuttleTerminalController.shared.schedulePersist()
    }

    func bell(source: LocalProcessTerminalView) {
        ShuttleAttention.shared.noteBell(from: self)
    }

    func notify(source: LocalProcessTerminalView, title: String, body: String) {
        ShuttleAttention.shared.noteNotify(from: self)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let finish = { [weak self] in
            guard let self else { return }
            if self.launchingSuccessor {
                return
            }
            if self.droppedToLoginShell {
                self.running = false
                return
            }
            if self.rebootHoldActive {
                self.awaitingReconnect = true
                if self.reconnectWork == nil {
                    self.scheduleReconnect(after: 15)
                }
                return
            }
            if self.looksLikeRebootOutput() {
                self.beginRebootReconnect()
                return
            }
            if self.shouldReconnectAfterExit(exitCode) {
                self.scheduleReconnect()
                return
            }
            self.dropToLoginShell()
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    // MARK: - Find field

    @objc private func findNextAction(_ sender: Any?) {
        performFind(direction: .forward)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === findField && commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            performFind(direction: shift ? .backward : .forward)
            return true
        }
        if control === findField && commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hideFind()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === findField else { return }
        performFind(direction: .forward)
    }

    // MARK: - Private

    private func configureTerminal() {
        terminal.nativeForegroundColor = theme.foreground
        terminal.nativeBackgroundColor = theme.background
        terminal.caretColor = theme.foreground
        terminal.optionAsMetaKey = true
        terminal.allowMouseReporting = true
        terminal.linkHighlightMode = .always
        terminal.linkReporting = .implicit
        terminal.scrollerStyle = .overlay
        applyCaretStyle()
        if let layer = terminal.layer {
            layer.backgroundColor = theme.background.cgColor
        }
    }

    private func buildChrome() {
        let content = HoverContentView(frame: window.contentView?.bounds ?? .zero)
        content.session = self
        content.wantsLayer = true
        content.layer?.backgroundColor = theme.background.cgColor
        content.autoresizingMask = [.width, .height]
        hoverView = content

        makeFindBar()
        makeTitlebarOverlay()

        let terminalHolder = TerminalHolderView()
        terminalHolder.wantsLayer = true
        terminalHolder.layer?.backgroundColor = theme.background.cgColor
        terminalHolder.translatesAutoresizingMaskIntoConstraints = false
        terminalHolder.onLayout = { [weak self] in
            self?.alignTerminalPaddingToCells()
        }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalHolder.addSubview(terminal)

        findBar.translatesAutoresizingMaskIntoConstraints = false
        titlebarOverlay.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.wantsLayer = true
        dimOverlay.layer?.backgroundColor = NSColor.black.cgColor
        dimOverlay.alphaValue = 0
        focusBorder.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findBar)
        content.addSubview(terminalHolder)
        content.addSubview(titlebarOverlay)
        content.addSubview(dimOverlay)
        content.addSubview(focusBorder)
        lockOverlay.translatesAutoresizingMaskIntoConstraints = false
        lockOverlay.isHidden = true
        content.addSubview(lockOverlay)

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBar.isHidden = true

        let pad = grokPending ? 0 : gutter
        edgePad = pad
        terminalPadTop = terminal.topAnchor.constraint(equalTo: terminalHolder.topAnchor, constant: pad)
        terminalPadLeading = terminal.leadingAnchor.constraint(equalTo: terminalHolder.leadingAnchor, constant: pad)
        terminalPadTrailing = terminal.trailingAnchor.constraint(equalTo: terminalHolder.trailingAnchor, constant: -pad)
        terminalPadBottom = terminal.bottomAnchor.constraint(equalTo: terminalHolder.bottomAnchor, constant: -pad)

        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: content.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            findBarHeight,

            terminalHolder.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            terminalHolder.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalHolder.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHolder.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            terminalPadTop,
            terminalPadLeading,
            terminalPadTrailing,
            terminalPadBottom,

            titlebarOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            titlebarOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titlebarOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titlebarOverlay.heightAnchor.constraint(equalToConstant: 30),

            dimOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            dimOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            focusBorder.topAnchor.constraint(equalTo: content.topAnchor),
            focusBorder.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            focusBorder.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            focusBorder.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            lockOverlay.topAnchor.constraint(equalTo: content.topAnchor),
            lockOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lockOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            lockOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        window.contentView = content
        window.makeFirstResponder(terminal)
        applyAppLock(ShuttleAppLock.shared.isLocked)
    }

    func applyAppLock(_ locked: Bool) {
        appLocked = locked
        lockOverlay.isHidden = !locked
        terminal.isHidden = locked
        if locked {
            titlebarOverlay.alphaValue = 0
            window.title = "Locked"
            window.subtitle = ""
            window.sharingType = .none
            window.makeFirstResponder(lockOverlay)
        } else {
            window.sharingType = .readWrite
            lockTitle()
            applyWindowChrome(force: true)
            if window.isKeyWindow, !findVisible {
                window.makeFirstResponder(terminal)
            }
            terminal.needsDisplay = true
        }
    }

    private func makeTitlebarOverlay() {
        titlebarOverlay.session = self
        titlebarOverlay.alphaValue = 0

        titleLabel.stringValue = hostTitle
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.drawsBackground = false
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.refusesFirstResponder = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.animations = ["alphaValue": NSNull()]
        titlebarOverlay.addSubview(titleLabel)
        disableNativeTitlebarAnimations()

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titlebarOverlay.leadingAnchor, constant: 78),
            titleLabel.trailingAnchor.constraint(equalTo: titlebarOverlay.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: titlebarOverlay.centerYAnchor)
        ])
    }

    private func makeFindBar() {
        findBar.wantsLayer = true
        findBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        findField.placeholderString = "Find"
        findField.font = NSFont.systemFont(ofSize: 12)
        findField.focusRingType = .none
        findField.sendsSearchStringImmediately = true
        findField.sendsWholeSearchString = false
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findNextAction(_:))
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        findCountLabel.font = NSFont.systemFont(ofSize: 11)
        findCountLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(findField)
        stack.addArrangedSubview(findCountLabel)
        findBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: findBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor)
        ])
    }

    private func startShell() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if restoring {
            restoring = false
            if ShuttleTermReconnect.isRemote(trimmed) {
                commandSent = true
                startRemoteCommand()
                queueStartupCommands()
                scheduleTypedCommand()
                return
            }
            // Local restore uses the same login-shell + typed cmd/after path as a fresh window.
        }
        if !resumeAgentOnStart {
            if trimmed.isEmpty {
                dropToLoginShell()
                return
            }
            if restoredWithoutLiveAgent, ShuttleGrokResume.isAgentInvocation(trimmed) {
                dropToLoginShell()
                return
            }
        }
        commandSent = true
        if ShuttleTermReconnect.isRemote(trimmed) {
            startRemoteCommand()
        } else {
            startLoginShell()
        }
        queueStartupCommands()
        scheduleTypedCommand()
    }

    private func startRemoteCommand() {
        running = true
        awaitingReconnect = false
        rebootHoldActive = false
        launchingSuccessor = false
        typedInputLine = ""
        recentOutput = ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let remote = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = remote.hasPrefix("exec ") ? remote : "exec \(remote)"
        terminal.startProcess(
            executable: "/bin/bash",
            args: ["--norc", "--noprofile", "-c", script],
            environment: processEnvironment(allowHistory: false),
            execName: "bash",
            currentDirectory: home
        )
    }

    private func queueStartupCommands() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = afterCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if resumeAgentOnStart {
            resumeAgentOnStart = false
            let queue = ShuttleGrokResume.restoreQueue(
                command: command,
                after: afterCommand,
                remote: ShuttleTermReconnect.isRemote(cmd),
                sessionId: restoredGrokSessionId,
                cwd: restoredGrokCwd ?? ShuttleGrokResume.path(fromOSC: directory),
                kind: restoredAgentKind
            )
            if !queue.isEmpty {
                typedQueue = queue
                markGrokLaunchIfQueued()
                return
            }
        }
        if ShuttleTermReconnect.isRemote(cmd) {
            typedQueue = after.isEmpty ? [] : [after]
        } else {
            typedQueue = cmd.isEmpty ? [] : [cmd]
            if !after.isEmpty {
                typedQueue.append(after)
            }
        }
        if restoredWithoutLiveAgent {
            typedQueue.removeAll { ShuttleGrokResume.isAgentInvocation($0) }
        }
        markGrokLaunchIfQueued()
    }

    private func markGrokLaunchIfQueued() {
        if typedQueue.contains(where: { ShuttleGrokResume.isGrokCommand($0) }) {
            markGrokLaunch(sent: false)
            return
        }
        if grokPending, !grokLaunchSent,
           !ShuttleGrokResume.isGrokCommand(command),
           !ShuttleGrokResume.isGrokCommand(afterCommand) {
            clearGrokFullWindow()
            applyTerminalPadding(gutter)
        }
    }

    private func startLoginShell() {
        running = true
        launchingSuccessor = false
        typedInputLine = ""
        recentOutput = ""
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let execName = "-" + (shell as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: processEnvironment(allowHistory: true),
            execName: execName,
            currentDirectory: home
        )
    }

    @discardableResult
    private func handleCtrlC() -> Bool {
        guard awaitingReconnect, !droppedToLoginShell else {
            return false
        }
        cancelReconnect = true
        awaitingReconnect = false
        rebootHoldActive = false
        reconnectWork?.cancel()
        reconnectWork = nil
        afterPoll?.cancel()
        dropToLoginShell()
        terminal.terminate()
        return true
    }

    private func dropToLoginShell() {
        awaitingReconnect = false
        rebootHoldActive = false
        reconnectWork?.cancel()
        reconnectWork = nil
        afterPoll?.cancel()
        guard !droppedToLoginShell else { return }
        droppedToLoginShell = true
        clearGrokFullWindow()
        applyTerminalPadding(gutter)
        DispatchQueue.main.async { [weak self] in
            self?.startLoginShell()
        }
    }

    private func shouldReconnectAfterExit(_ rawStatus: Int32?) -> Bool {
        guard reconnect, !cancelReconnect else { return false }
        if looksLikeUnexpectedDrop() { return true }
        if looksLikeCleanLogout() { return false }
        let code = decodeWaitStatus(rawStatus)
        // ssh uses 255 for its own errors (drop, reset, refused). Any other
        // exit is the remote shell/command ending — `exit` / `logout`.
        if code == 255 { return true }
        if code == 141 { return true } // SIGPIPE
        if code == 0 || (1...254).contains(code) { return false }
        if code == 129 { return false } // SIGHUP from a closed session
        return true
    }

    private func decodeWaitStatus(_ status: Int32?) -> Int32 {
        guard let status else { return 1 }
        let stopped: Int32 = 0o177
        if status & stopped == 0 {
            return (status >> 8) & 0xff
        }
        if status & stopped != stopped {
            return 128 + (status & stopped)
        }
        return status
    }

    private func looksLikeCleanLogout() -> Bool {
        let text = stripControlSequences(recentOutput)
        let patterns = [
            #"(?i)connection to \S+ closed\.?"#,
            #"(?i)shared connection to \S+ closed"#,
            #"(?i)(?m)^logout$"#
        ]
        return matchesAny(text, patterns)
    }

    private func looksLikeRebootOutput() -> Bool {
        let text = stripControlSequences(recentOutput)
        let patterns = [
            #"(?i)the system is going down"#,
            #"(?i)the system will reboot"#,
            #"(?i)restarting system"#,
            #"(?i)system is restarting"#,
            #"(?i)(?m)^rebooting\b"#,
            #"(?i)reached target reboot"#
        ]
        return matchesAny(text, patterns)
    }

    private func looksLikeUnexpectedDrop() -> Bool {
        let text = stripControlSequences(recentOutput)
        let patterns = [
            #"(?i)broken pipe"#,
            #"(?i)connection reset"#,
            #"(?i)connection timed out"#,
            #"(?i)network is unreachable"#,
            #"(?i)no route to host"#,
            #"(?i)connection refused"#
        ]
        return matchesAny(text, patterns)
    }

    private func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        for pattern in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private func scheduleReconnect(after delay: TimeInterval = 2) {
        awaitingReconnect = true
        afterSent = false
        afterPoll?.cancel()
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.launchSuccessorProcess()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func launchSuccessorProcess() {
        guard !cancelReconnect, !droppedToLoginShell else { return }
        rebootHoldActive = false
        reconnectWork = nil
        launchingSuccessor = true
        if terminal.process.running {
            terminal.terminate()
            DispatchQueue.main.async { [weak self] in
                self?.startSuccessorProcess()
            }
        } else {
            startSuccessorProcess()
        }
    }

    private func startSuccessorProcess() {
        launchingSuccessor = false
        guard !cancelReconnect, !droppedToLoginShell else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if ShuttleTermReconnect.isRemote(trimmed) {
            startRemoteCommand()
        } else {
            startLoginShell()
        }
        queueStartupCommands()
        scheduleTypedCommand()
    }

    private func beginRebootReconnect() {
        guard !droppedToLoginShell, !cancelReconnect else { return }
        guard ShuttleTermReconnect.isRemote(command) else { return }
        guard !rebootHoldActive else { return }
        rebootHoldActive = true
        awaitingReconnect = true
        terminal.feed(text: "\r\nWill try to reconnect...(press Ctrl-C to cancel)\r\n")
        scheduleReconnect(after: 15)
    }

    private func noteUserInput(_ slice: ArraySlice<UInt8>) {
        if rewritingInput { return }
        if terminal.getTerminal().isCurrentBufferAlternate { return }
        for byte in slice {
            switch byte {
            case 0x0d, 0x0a:
                let typed = typedInputLine
                typedInputLine = ""
                if ShuttleGrokResume.isGrokCommand(typed) {
                    markGrokLaunch(sent: true)
                    rewriteTypedGrokIfNeeded(typed)
                }
                if ShuttleTermReconnect.isRemote(command), !droppedToLoginShell, !rebootHoldActive,
                   ShuttleTermReconnect.isRebootCommand(typed) || ShuttleTermReconnect.isRebootCommand(currentBufferCommandLine()) {
                    beginRebootReconnect()
                }
            case 0x08, 0x7f:
                if !typedInputLine.isEmpty {
                    typedInputLine.removeLast()
                }
            case 0x03, 0x15:
                typedInputLine = ""
            case 0x17:
                while let last = typedInputLine.last, last.isWhitespace {
                    typedInputLine.removeLast()
                }
                while let last = typedInputLine.last, !last.isWhitespace {
                    typedInputLine.removeLast()
                }
            case 0x1b:
                typedInputLine = ""
            default:
                if byte >= 32, byte < 127 {
                    typedInputLine.append(Character(UnicodeScalar(byte)))
                }
            }
        }
    }

    private func currentBufferCommandLine() -> String {
        let term = terminal.getTerminal()
        let row = term.buffer.yBase + term.buffer.y
        var chars: [Character] = []
        chars.reserveCapacity(term.cols)
        for col in 0..<term.cols {
            chars.append(term.getCharacter(col: col, row: row) ?? " ")
        }
        return String(chars)
    }

    private func processEnvironment(allowHistory: Bool) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ShuttleTerm"
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        // Vite, CRA, and similar tools auto-open the browser. That Apple Event is
        // attributed to ShuttleTerm and shows a “control Google Chrome” prompt.
        if environment["BROWSER"] == nil {
            environment["BROWSER"] = "none"
        }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            environment["TERM_PROGRAM_VERSION"] = version
        }
        if !allowHistory {
            environment["HISTFILE"] = "/dev/null"
            environment["HISTSIZE"] = "0"
            environment["HISTFILESIZE"] = "0"
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    private func scheduleTypedCommand() {
        guard !typedQueue.isEmpty else { return }
        afterSent = false
        afterWatchStart = Date()
        lastHostOutput = nil
        recentOutput = ""
        afterPoll?.cancel()
        pollAfterCommand()
    }

    private func pollAfterCommand() {
        let work = DispatchWorkItem { [weak self] in
            self?.considerSendingAfterCommand()
        }
        afterPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func considerSendingAfterCommand() {
        guard running, !afterSent, !droppedToLoginShell, !awaitingReconnect else { return }
        if terminal.getTerminal().isCurrentBufferAlternate {
            afterSent = true
            typedQueue.removeAll()
            return
        }
        let elapsed = Date().timeIntervalSince(afterWatchStart ?? Date())
        let idle = lastHostOutput.map { Date().timeIntervalSince($0) } ?? 0
        let ready = outputLooksLikePrompt() && idle >= 0.35 && elapsed >= 0.6
        if ready || elapsed >= 8 {
            afterSent = true
            sendNextTypedCommand()
            return
        }
        pollAfterCommand()
    }

    private func sendNextTypedCommand() {
        guard running, !droppedToLoginShell, !typedQueue.isEmpty else { return }
        if terminal.getTerminal().isCurrentBufferAlternate {
            typedQueue.removeAll()
            return
        }
        var next = typedQueue.removeFirst()
        if ShuttleGrokResume.isGrokCommand(next) {
            next = ShuttleGrokResume.bindGrokToExactCwd(next, cwd: grokWorkingDirectory(for: next))
            markGrokLaunch(sent: true)
        }
        rewritingInput = true
        terminal.send(txt: next)
        terminal.send([0x0d])
        rewritingInput = false
        if ShuttleGrokResume.isAgentInvocation(next) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                ShuttleTerminalController.shared.schedulePersist()
            }
        }
        if !typedQueue.isEmpty {
            scheduleTypedCommand()
        }
    }

    private func noteHostOutput(_ slice: ArraySlice<UInt8>) {
        lastHostOutput = Date()
        if let chunk = String(bytes: slice, encoding: .utf8) {
            recentOutput.append(chunk)
            if recentOutput.count > 4000 {
                recentOutput.removeFirst(recentOutput.count - 4000)
            }
        }
        if looksLikeRebootOutput() {
            beginRebootReconnect()
        }
        let alt = terminal.getTerminal().isCurrentBufferAlternate
        if alt != lastAltScreen {
            refreshTerminalPadding()
            return
        }
        if grokPending || grokDidRun || grokLaunchSent || edgePad == 0 {
            schedulePaddingRefresh()
        }
    }

    private func markGrokLaunch(sent: Bool) {
        grokPending = true
        grokPendingAt = grokPendingAt ?? Date()
        if sent {
            grokLaunchSent = true
        }
        applyTerminalPadding(0)
    }

    private func clearGrokFullWindow() {
        grokPending = false
        grokLaunchSent = false
        grokDidRun = false
        grokPendingAt = nil
        paddingCheckWork?.cancel()
        paddingCheckWork = nil
        restoredGrokSessionId = nil
        restoredGrokCwd = nil
        restoredAgentKind = nil
    }

    private func schedulePaddingRefresh() {
        paddingCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshTerminalPadding()
        }
        paddingCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func refreshTerminalPadding() {
        let alt = terminal.getTerminal().isCurrentBufferAlternate
        lastAltScreen = alt
        let running = ShuttleGrokResume.grokProcessRunning(shellPid: terminal.process.shellPid)
        if running {
            grokDidRun = true
            grokLaunchSent = true
        }
        if alt, grokPending || grokLaunchSent || grokDidRun {
            grokDidRun = true
        }
        if grokDidRun, !running, !alt {
            clearGrokFullWindow()
            applyTerminalPadding(gutter)
            ShuttleTerminalController.shared.schedulePersist()
            return
        }
        if grokLaunchSent, !grokDidRun, !running, !alt,
           let start = grokPendingAt, Date().timeIntervalSince(start) > 8 {
            clearGrokFullWindow()
            applyTerminalPadding(gutter)
            ShuttleTerminalController.shared.schedulePersist()
            return
        }
        let wantFull = grokPending || running || grokDidRun
        applyTerminalPadding(wantFull ? 0 : gutter)
        if grokDidRun, !alt {
            schedulePaddingRefresh()
        }
    }

    private func applyTerminalPadding(_ pad: CGFloat) {
        edgePad = pad
        alignTerminalPaddingToCells(layoutNow: true)
    }

    private func alignTerminalPaddingToCells(layoutNow: Bool = false) {
        guard !isSnappingPad else { return }
        guard terminalPadTop != nil else { return }
        var top = edgePad
        var bottom = edgePad
        let side = edgePad
        if edgePad > 0, let holder = terminal.superview, let cellH = terminal.cellDimension?.height, cellH > 1 {
            let holderH = holder.bounds.height
            if holderH > 1 {
                let available = max(0, holderH - 2 * edgePad)
                let leftover = available - floor(available / cellH) * cellH
                if leftover >= 1 {
                    let extraTop = floor(leftover / 2)
                    top = edgePad + extraTop
                    bottom = edgePad + (leftover - extraTop)
                }
            }
        }
        let padsChanged = terminalPadTop.constant != top
            || terminalPadLeading.constant != side
            || terminalPadTrailing.constant != -side
            || terminalPadBottom.constant != -bottom
        if padsChanged {
            terminalPadTop.constant = top
            terminalPadLeading.constant = side
            terminalPadTrailing.constant = -side
            terminalPadBottom.constant = -bottom
            if layoutNow {
                window.contentView?.layoutSubtreeIfNeeded()
                terminal.needsLayout = true
                terminal.layoutSubtreeIfNeeded()
            }
        }
    }

    private func snapWindowHeightToCells() {
        guard !isSnappingPad else { return }
        guard edgePad > 0 else { return }
        guard !window.inLiveResize else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard window.isVisible, !window.isMiniaturized else { return }
        guard let holder = terminal.superview, terminal.cellDimension != nil else { return }
        let cellH = terminal.cellDimension.height
        let holderH = holder.bounds.height
        guard cellH > 1, holderH > 1 else { return }
        let available = max(0, holderH - 2 * edgePad)
        let leftover = available - floor(available / cellH) * cellH
        guard leftover >= 1 else { return }
        let newHeight = window.frame.size.height - leftover
        guard newHeight >= window.minSize.height else { return }
        isSnappingPad = true
        defer { isSnappingPad = false }
        var frame = window.frame
        frame.size.height = newHeight
        frame.origin.y += leftover
        window.setFrame(frame, display: true, animate: false)
    }

    private func grokWorkingDirectory(for command: String) -> String? {
        ShuttleGrokResume.path(fromOSC: directory)
            ?? ShuttleGrokResume.cwdFromCommand(command)
            ?? ShuttleGrokResume.cwdFromCommand(self.command)
            ?? ShuttleGrokResume.cwdFromCommand(afterCommand)
    }

    private func rewriteTypedGrokIfNeeded(_ typed: String) {
        let bound = ShuttleGrokResume.bindGrokToExactCwd(typed, cwd: grokWorkingDirectory(for: typed))
        guard bound != typed else { return }
        rewritingInput = true
        terminal.send([0x15])
        terminal.send(txt: bound)
        rewritingInput = false
    }

    private func outputLooksLikePrompt() -> Bool {
        let stripped = stripControlSequences(recentOutput)
        guard let lastLine = stripped.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).last else {
            return false
        }
        let line = lastLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        return line.range(of: #"[#$%❯➜][#]?$"#, options: .regularExpression) != nil
    }

    private func stripControlSequences(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\u{1b}" {
                let next = text.index(after: i)
                guard next < text.endIndex else { break }
                switch text[next] {
                case "[":
                    i = text.index(after: next)
                    while i < text.endIndex {
                        let c = text[i]
                        i = text.index(after: i)
                        if ("A"..."Z").contains(c) || ("a"..."z").contains(c) { break }
                    }
                case "]":
                    i = text.index(after: next)
                    while i < text.endIndex {
                        let c = text[i]
                        i = text.index(after: i)
                        if c == "\u{7}" { break }
                        if c == "\\", i > text.startIndex, text[text.index(before: i)] == "\u{1b}" { break }
                    }
                default:
                    i = text.index(after: next)
                }
                continue
            }
            if ch == "\r" {
                i = text.index(after: i)
                continue
            }
            out.append(ch)
            i = text.index(after: i)
        }
        return out
    }

    private func lockTitle() {
        if appLocked {
            window.title = "Locked"
            window.subtitle = ""
            return
        }
        window.title = hostTitle
        titleLabel.stringValue = hostTitle
        var parts: [String] = []
        if !postedTitle.isEmpty && postedTitle != hostTitle {
            parts.append(postedTitle)
        }
        if let pretty = prettyDirectory() {
            parts.append(pretty)
        }
        window.subtitle = parts.joined(separator: " — ")
    }

    private func prettyDirectory() -> String? {
        guard let directory, let url = URL(string: directory) else { return nil }
        return url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    private func applyFont(size: CGFloat) {
        fontSize = min(max(size, 9), 72)
        let resolved = ShuttleTerminalTheme.resolveFont(named: fontFamily, size: fontSize)
        terminal.font = resolved.font
        fontFamily = resolved.family
        alignTerminalPaddingToCells(layoutNow: true)
    }

    private func installMouseMonitor() {
        removeMouseMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged
        ]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.handleCommandFlags(event.modifierFlags)
                return event
            }
            self.handleMonitoredMouse()
            if event.window == self.window {
                return self.interceptChromeMouse(event)
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        cancelChromeShow()
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func handleMonitoredMouse() {
        let screenPoint = NSEvent.mouseLocation
        if shouldKeepChromePinned() {
            pointerInside = true
            NSCursor.arrow.set()
            return
        }
        guard pointerIsOverWindow(screenPoint) else {
            if pointerInside || titlebarShown {
                mouseExitedWindow()
            }
            return
        }
        if !pointerInside {
            pointerInside = true
            mouseEnteredWindow()
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if let content = window.contentView {
            mouseMovedInWindow(at: content.convert(windowPoint, from: nil))
        }
    }

    private func handleCommandFlags(_ flags: NSEvent.ModifierFlags) {
        if shouldKeepChromePinned() { return }
        guard window.isKeyWindow || pointerInside else { return }
        if flags.contains(.command) {
            hideChromeForCommandPeek()
        } else if commandPeeking {
            commandPeeking = false
            handleMonitoredMouse()
            applyWindowChrome()
        }
    }

    private func hideChromeForCommandPeek() {
        terminal.titlebarChromeCapturesMouse = false
        guard !commandPeeking else { return }
        commandPeeking = true
        chromeHovered = false
        cancelChromeShow()
        setTitlebarVisible(false)
    }

    private func commandHidesChrome(_ flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        !shouldKeepChromePinned() && flags.contains(.command)
    }

    private func shouldKeepChromePinned() -> Bool {
        if commandPeeking { return false }
        return chromeDragActive || (NSEvent.pressedMouseButtons & 1 != 0 && titlebarShown)
    }

    func overlayShouldReceiveMouse() -> Bool {
        if chromeDragActive { return true }
        if NSEvent.modifierFlags.contains(.command) { return false }
        if !ShuttleTerminalController.shared.titlebarOnHover { return true }
        return titlebarShown
    }

    private func pointerIsOverWindow(_ screenPoint: NSPoint) -> Bool {
        var frame = window.frame
        // NSRect.contains excludes the max X/Y edges; the title bar sits on max Y.
        frame.size.width += 1
        frame.size.height += 8
        return frame.contains(screenPoint)
    }

    private func interceptChromeMouse(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            if chromeDragActive { return event }
            if event.modifierFlags.contains(.command) { return event }
            guard isEventInChrome(event) else { return event }
            if isEventOverTrafficLight(event) {
                return event
            }
            terminal.selection.active = false
            terminal.setNeedsDisplay(terminal.bounds)
            if event.clickCount >= 2 {
                window.performZoom(nil)
            } else {
                beginChromeDrag(with: event)
            }
            return nil
        case .leftMouseDragged:
            if chromeDragActive {
                terminal.selection.active = false
            }
            return event
        case .leftMouseUp:
            if chromeDragActive {
                finishChromeDrag()
            }
            return event
        default:
            return event
        }
    }

    private func isEventInChrome(_ event: NSEvent) -> Bool {
        guard let content = window.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        return point.y > content.bounds.maxY - 30
    }

    private func isEventOverTrafficLight(_ event: NSEvent) -> Bool {
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            let rect = button.convert(button.bounds.insetBy(dx: -2, dy: -2), to: nil)
            if rect.contains(event.locationInWindow) {
                return true
            }
        }
        return false
    }

    private func setTitlebarVisible(_ visible: Bool) {
        if shouldKeepChromePinned(), !visible { return }
        window.titleVisibility = .hidden
        titlebarOverlay.isHidden = false
        terminal.titlebarChromeCapturesMouse = visible && !commandHidesChrome()
        applyChromeAppearance(visible: visible)
        invalidateChromeCursorRects()
    }

    private func applyChromeAppearance(visible: Bool) {
        let alpha: CGFloat = visible ? 1 : 0
        withoutViewAnimation {
            self.titlebarOverlay.layer?.removeAllAnimations()
            // Keep the overlay view itself opaque to hit-testing. Fading
            // alphaValue to 0 lets AppKit deliver hover/clicks to the terminal
            // under the traffic-light strip, which fights chrome show/hide.
            self.titlebarOverlay.alphaValue = 1
            self.titlebarOverlay.setChromeVisible(visible)
            self.titleLabel.alphaValue = alpha
            self.applyTrafficLightAlpha(alpha)
            self.applyTrafficLightsColored(visible)
        }
    }

    private func withoutViewAnimation(_ work: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0)
            work()
            CATransaction.commit()
        }
    }

    private func disableNativeTitlebarAnimations() {
        let noAnim: [NSAnimatablePropertyKey: Any] = [
            "alphaValue": NSNull(),
            "hidden": NSNull()
        ]
        let noLayer: [String: CAAction] = [
            "opacity": NSNull(),
            "hidden": NSNull(),
            "onOrderIn": NSNull(),
            "onOrderOut": NSNull()
        ]
        titlebarOverlay.animations = noAnim
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.animations = noAnim
            button.wantsLayer = true
            button.layer?.actions = noLayer
            if let group = button.superview {
                group.animations = noAnim
                group.wantsLayer = true
                group.layer?.actions = noLayer
                if let container = group.superview {
                    container.animations = noAnim
                    container.wantsLayer = true
                    container.layer?.actions = noLayer
                }
            }
        }
    }

    private func applyTrafficLightAlpha(_ alpha: CGFloat) {
        invokeDoubleSetter(window, "setStandardWindowTitleButtonsAlphaValue:", alpha)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.animations = ["alphaValue": NSNull()]
            button.layer?.removeAllAnimations()
            button.isHidden = false
            button.alphaValue = alpha
            if let group = button.superview {
                group.animations = ["alphaValue": NSNull(), "hidden": NSNull()]
                group.layer?.removeAllAnimations()
            }
        }
    }

    private func invalidateChromeCursorRects() {
        window.invalidateCursorRects(for: terminal)
        window.invalidateCursorRects(for: titlebarOverlay)
        if let content = window.contentView {
            window.invalidateCursorRects(for: content)
        }
    }

    func beginChromeDrag(with event: NSEvent) {
        if chromeDragActive { return }
        chromeDragActive = true
        terminal.setChromeDragActive(true)
        terminal.selection.active = false
        terminal.setNeedsDisplay(terminal.bounds)
        pinChromeAppearance()
        ShuttleWindowChrome.animateSnapForDrag(window)
        if chromeDragActive, NSEvent.pressedMouseButtons & 1 != 0 {
            window.performDrag(with: Self.mouseDownEvent(for: window, from: event))
        }
        finishChromeDrag()
    }

    private func finishChromeDrag() {
        guard chromeDragActive else { return }
        chromeDragActive = false
        terminal.setChromeDragActive(false)
        ShuttleTerminalController.shared.rememberWindowSize(window.frame.size)
        applyFocusAppearance()
        handleMonitoredMouse()
    }

    private func pinChromeAppearance() {
        cancelChromeShow()
        titlebarShown = true
        pointerInside = true
        chromeHovered = true
        withoutViewAnimation {
            self.titlebarOverlay.layer?.removeAllAnimations()
            self.titlebarOverlay.alphaValue = 1
            self.titlebarOverlay.setChromeVisible(true)
            self.titleLabel.alphaValue = 1
            self.applyTrafficLightAlpha(1)
            self.forceTrafficLightsHovered()
        }
    }

    private static func mouseDownEvent(for window: NSWindow, from original: NSEvent) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: window.mouseLocationOutsideOfEventStream,
            modifierFlags: original.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: original.eventNumber,
            clickCount: 1,
            pressure: 1
        ) ?? original
    }

    func snapshot() -> ShuttleWindowSnapshot {
        let live = ShuttleGrokResume.liveSession(shellPid: terminal.process.shellPid)
        let cwd = live.flatMap { $0.cwd ?? ShuttleGrokResume.path(fromOSC: directory) }
        return ShuttleWindowSnapshot(
            cmd: command,
            after: afterCommand,
            title: hostTitle,
            theme: theme.name,
            font: fontFamily,
            fontSize: Double(fontSize),
            reconnect: reconnect,
            x: Double(window.frame.origin.x),
            y: Double(window.frame.origin.y),
            width: Double(window.frame.size.width),
            height: Double(window.frame.size.height),
            buffer: captureBuffer(),
            grokSessionId: live?.id,
            grokCwd: cwd,
            agentKind: live?.kind.rawValue
        )
    }

    private func applyCaretStyle() {
        terminal.syncCaretToKeyWindow()
    }

    private func applyFocusAppearance() {
        let focused = window.isKeyWindow
        let dark = isDarkThemeBackground()
        let dim: CGFloat = focused ? 0 : (dark ? 0.14 : 0.08)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            dimOverlay.animator().alphaValue = dim
        }
        if let layer = hoverView?.layer ?? window.contentView?.layer {
            layer.borderWidth = 0
        }
        let color: NSColor
        if focused {
            color = dark
                ? NSColor.white.withAlphaComponent(0.38)
                : NSColor.black.withAlphaComponent(0.22)
        } else {
            color = dark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.08)
        }
        focusBorder.apply(
            color: color,
            radius: windowCornerRadius(),
            scale: window.backingScaleFactor
        )
    }

    private func windowCornerRadius() -> CGFloat {
        if window.styleMask.contains(.fullScreen) { return 0 }
        let objects: [AnyObject] = [window.contentView?.superview, window].compactMap { $0 }
        for object in objects {
            for name in ["_cornerRadius", "roundedCornerRadius", "cornerRadius"] {
                let sel = NSSelectorFromString(name)
                guard object.responds(to: sel), let imp = object.method(for: sel) else { continue }
                typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
                let radius = unsafeBitCast(imp, to: Getter.self)(object, sel)
                if radius.isFinite, radius > 0.5, radius < 80 {
                    return radius
                }
            }
        }
        if #available(macOS 26.0, *) { return 16 }
        return 10
    }

    private func isDarkThemeBackground() -> Bool {
        guard let color = theme.background.usingColorSpace(.deviceRGB) else { return true }
        let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
        return luminance < 0.5
    }

    private func captureBuffer() -> String {
        let term = terminal.getTerminal()
        let buf = term.buffer
        var rows: [String] = []
        rows.reserveCapacity(buf.lines.count)
        for i in 0..<buf.lines.count {
            var line = buf.lines[i].translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: { term.getCharacter(for: $0) }
            )
            if line.contains("\0") {
                line = line.replacingOccurrences(of: "\0", with: " ")
            }
            rows.append(line)
        }
        while rows.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            rows.removeFirst()
        }
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            rows.removeLast()
        }
        if rows.count > 2000 {
            rows = Array(rows.suffix(2000))
        }
        var text = rows.joined(separator: "\n")
        if text.count > 250_000 {
            text = String(text.suffix(250_000))
            if let idx = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: idx)...])
            }
        }
        return text
    }

    private func flushRestoredBufferIfNeeded() {
        guard let text = pendingRestoreText else {
            startDeferredShellIfNeeded()
            return
        }
        let width = terminal.bounds.width
        if width <= 1 {
            return
        }
        if let cellW = terminal.cellDimension?.width, cellW > 1 {
            let expectedCols = max(1, Int(width / cellW))
            if abs(expectedCols - terminal.getTerminal().cols) > 2 {
                return
            }
        }
        pendingRestoreText = nil
        let payload = Self.restorePayload(from: text)
        if !payload.isEmpty {
            terminal.feed(text: payload)
        }
        startDeferredShellIfNeeded()
    }

    private func startDeferredShellIfNeeded() {
        guard deferredStartShell else { return }
        deferredStartShell = false
        startShell()
    }

    /// Replay saved rows as a grid: wrap off, CR+LF per row, so columns stay
    /// aligned. A lone LF would leave the cursor in the same column and shove
    /// the next row to the right.
    private static func restorePayload(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out = "\u{1b}[?7l\u{1b}[2J\u{1b}[H"
        for (index, line) in lines.enumerated() {
            out += String(line)
            if index < lines.count - 1 || !line.isEmpty {
                out += "\r\n"
            }
        }
        out += "\u{1b}[?7h"
        return out
    }

    private static func clampedFrame(_ frame: NSRect) -> NSRect {
        var f = frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        let vis = screens.first(where: { $0.intersects(f) }) ?? NSScreen.main?.visibleFrame
        guard let vis else { return f }
        f.size.width = min(max(f.width, 360), vis.width)
        f.size.height = min(max(f.height, 180), vis.height)
        if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
        if f.minX < vis.minX { f.origin.x = vis.minX }
        if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.height }
        if f.minY < vis.minY { f.origin.y = vis.minY }
        return f
    }

    private func applyTrafficLightsColored(_ on: Bool) {
        chromeHovered = on
        withoutViewAnimation {
            if on {
                self.forceTrafficLightsHovered()
            } else {
                self.forceTrafficLightsIdle()
            }
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                self.window.standardWindowButton(type)?.needsDisplay = true
            }
        }
    }

    private func forceTrafficLightsHovered() {
        if let theme = window.contentView?.superview {
            theme.layer?.removeAllAnimations()
            invokeBoolSetter(theme, "_setTemporaryMouseOutsideLeftGroup:", false)
            invokeTwoBools(theme, "_setMouseEnteredGroup:entered:", true, true)
            invokeDoubleSetter(theme, "setButtonRevealAmount:", 1)
        }
        if let group = window.standardWindowButton(.closeButton)?.superview {
            group.layer?.removeAllAnimations()
            invokeDoubleSetter(group, "setButtonRevealAmount:", 1)
            if let container = group.superview {
                container.layer?.removeAllAnimations()
                invokeDoubleSetter(container, "setButtonRevealAmount:", 1)
            }
        }
        invokeDoubleSetter(window, "setStandardWindowTitleButtonsAlphaValue:", 1)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.layer?.removeAllAnimations()
            button.isHidden = false
            button.alphaValue = 1
        }
    }

    private func forceTrafficLightsIdle() {
        if let theme = window.contentView?.superview {
            theme.layer?.removeAllAnimations()
            invokeTwoBools(theme, "_setMouseEnteredGroup:entered:", true, false)
            invokeDoubleSetter(theme, "setButtonRevealAmount:", 0)
        }
        if let group = window.standardWindowButton(.closeButton)?.superview {
            group.layer?.removeAllAnimations()
            invokeDoubleSetter(group, "setButtonRevealAmount:", 0)
            if let container = group.superview {
                container.layer?.removeAllAnimations()
                invokeDoubleSetter(container, "setButtonRevealAmount:", 0)
            }
        }
    }

    private func invokeBoolSetter(_ object: AnyObject, _ selectorName: String, _ value: Bool) {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel), let imp = object.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(object, sel, value)
    }

    private func invokeTwoBools(_ object: AnyObject, _ selectorName: String, _ a: Bool, _ b: Bool) {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel), let imp = object.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(object, sel, a, b)
    }

    private func invokeDoubleSetter(_ object: AnyObject, _ selectorName: String, _ value: CGFloat) {
        let sel = NSSelectorFromString(selectorName)
        guard object.responds(to: sel), let imp = object.method(for: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(imp, to: Fn.self)(object, sel, value)
    }

    private enum FindDirection {
        case forward, backward
    }

    private func performFind(direction: FindDirection) {
        let query = findField.stringValue
        guard !query.isEmpty else {
            findCountLabel.stringValue = ""
            return
        }
        if direction == .forward {
            _ = terminal.findNext(query)
        } else {
            _ = terminal.findPrevious(query)
        }
        let summary = terminal.searchMatchSummary(query)
        findCountLabel.stringValue = summary.total > 0 ? "\(summary.index)/\(summary.total)" : "0"
    }
}

enum ShuttleTermReconnect {
    static func isRemote(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        return ["ssh", "mosh", "autossh", "telnet", "sftp"].contains(head)
    }

    static func isRebootCommand(_ line: String) -> Bool {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = text.firstIndex(of: "#") {
            text = String(text[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        let prompt = [
            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[^\n]{0,80}?!#[ \t]*"#,
            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[^\n]{0,80}?[#$%>❯➜][#%!]?[ \t]+"#,
            #"^[%$#❯➜][ \t]+"#
        ]
        for pattern in prompt {
            if let range = text.range(of: pattern, options: .regularExpression) {
                text = String(text[range.upperBound...])
                break
            }
        }
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return false }
        let wrappers: Set<String> = ["sudo", "doas", "command", "time", "nice", "nohup"]
        while let first = tokens.first?.lowercased(), wrappers.contains(first) {
            tokens.removeFirst()
            while let flag = tokens.first, flag.hasPrefix("-") {
                tokens.removeFirst()
            }
        }
        guard let command = tokens.first else { return false }
        let base = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return base == "reboot"
    }
}

enum ShuttleWindowChrome {
    static let snapWidthFraction: CGFloat = 0.33
    static let snapHeightFraction: CGFloat = 0.285
    static let snapDuration: TimeInterval = 0.22

    static func snapForDrag(_ window: NSWindow) {
        animateSnapForDrag(window)
    }

    static func animateSnapForDrag(_ window: NSWindow, onTick: (() -> Void)? = nil) {
        interruptFrameAnimations(window)
        guard let target = snapTarget(for: window) else { return }
        let start = window.frame
        let startMouse = NSEvent.mouseLocation
        let relX = start.width > 1 ? (startMouse.x - start.minX) / start.width : 0.5
        let relY = start.height > 1 ? (startMouse.y - start.minY) / start.height : 0.85
        let startTime = ProcessInfo.processInfo.systemUptime
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let t = min(1 as CGFloat, CGFloat(elapsed / snapDuration))
            let remain = 1 - t
            let eased = 1 - remain * remain * remain
            let width = start.width + (target.width - start.width) * eased
            let height = start.height + (target.height - start.height) * eased
            applyDragFrame(window, width: width, height: height, relX: relX, relY: relY)
            onTick?()
            if t >= 1 { break }
            if NSEvent.pressedMouseButtons & 1 == 0 { break }
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 1.0 / 60.0))
        }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            applyDragFrame(window, width: target.width, height: target.height, relX: relX, relY: relY)
            onTick?()
        }
    }

    private static func interruptFrameAnimations(_ window: NSWindow) {
        let sel = NSSelectorFromString("_interruptFrameAnimations")
        guard window.responds(to: sel) else { return }
        window.perform(sel)
    }

    private static func snapTarget(for window: NSWindow) -> NSSize? {
        guard let screen = screen(for: NSEvent.mouseLocation, window: window) else { return nil }
        let vis = screen.visibleFrame
        let width = max(window.minSize.width, vis.width * snapWidthFraction)
        let height = max(window.minSize.height, vis.height * snapHeightFraction)
        let old = window.frame
        if old.width <= width || old.height <= height {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    private static func applyDragFrame(
        _ window: NSWindow,
        width: CGFloat,
        height: CGFloat,
        relX: CGFloat,
        relY: CGFloat
    ) {
        let mouse = NSEvent.mouseLocation
        var frame = NSRect(
            x: mouse.x - relX * width,
            y: mouse.y - relY * height,
            width: width,
            height: height
        )
        if let vis = screen(for: mouse, window: window)?.visibleFrame {
            if frame.maxX > vis.maxX { frame.origin.x = vis.maxX - frame.width }
            if frame.minX < vis.minX { frame.origin.x = vis.minX }
            if frame.maxY > vis.maxY { frame.origin.y = vis.maxY - frame.height }
            if frame.minY < vis.minY { frame.origin.y = vis.minY }
        }
        setFrameWithoutImplicitAnimation(window, frame)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func setFrameWithoutImplicitAnimation(_ window: NSWindow, _ frame: NSRect) {
        let sel = NSSelectorFromString("_setFrame:display:allowImplicitAnimation:stashSize:")
        if window.responds(to: sel), let imp = window.method(for: sel) {
            typealias Fn = @convention(c) (AnyObject, Selector, NSRect, Bool, Bool, Bool) -> Void
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                unsafeBitCast(imp, to: Fn.self)(window, sel, frame, true, false, false)
                CATransaction.commit()
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private static func screen(for point: NSPoint, window: NSWindow) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? window.screen ?? NSScreen.main
    }
}

private final class TerminalHolderView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class HoverContentView: NSView {
    weak var session: ShuttleTerminalSession?
    private let titlebarChromeHeight: CGFloat = 30

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let height = min(titlebarChromeHeight, bounds.height)
        let chrome = NSRect(
            x: bounds.minX,
            y: bounds.maxY - height,
            width: bounds.width,
            height: height
        )
        addCursorRect(chrome, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if location.y > bounds.maxY - titlebarChromeHeight {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        session?.mouseEnteredWindow()
        session?.mouseMovedInWindow(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        session?.mouseExitedWindow()
    }

    override func mouseMoved(with event: NSEvent) {
        session?.mouseMovedInWindow(at: convert(event.locationInWindow, from: nil))
    }
}

private final class FocusDimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

private final class FocusBorderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func apply(color: NSColor, radius: CGFloat, scale: CGFloat) {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = .clear
        layer.borderWidth = 1
        layer.borderColor = color.cgColor
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.contentsScale = max(scale, 1)
        layer.masksToBounds = true
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.masksToBounds = true
    }
}

private final class TitlebarOverlayView: NSView {
    weak var session: ShuttleTerminalSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        animations = ["alphaValue": NSNull(), "hidden": NSNull()]
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.actions = [
            "opacity": NSNull(),
            "hidden": NSNull(),
            "onOrderIn": NSNull(),
            "onOrderOut": NSNull()
        ]
    }

    func setChromeVisible(_ visible: Bool) {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(visible ? 0.55 : 0).cgColor
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }
        guard session?.overlayShouldReceiveMouse() == true else {
            return nil
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let button = trafficLightButton(at: point) {
            button.mouseDown(with: event)
            return
        }
        if event.clickCount >= 2 {
            window?.performZoom(nil)
            return
        }
        if let session {
            session.beginChromeDrag(with: event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func trafficLightButton(at point: NSPoint) -> NSButton? {
        guard let window else { return nil }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            let rect = convert(button.bounds.insetBy(dx: -2, dy: -2), from: button)
            if rect.contains(point) {
                return button
            }
        }
        return nil
    }
}
