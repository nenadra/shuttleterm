//
//  ShuttleTerminalController.swift
//  ShuttleTerm
//
//  ObjC entry point used by AppDelegate when a host is opened. Owns every
//  Shuttle terminal window and installs Terminal.app-like menus.
//

import AppKit

@objc(ShuttleTerminalController)
final class ShuttleTerminalController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    @objc static let shared = ShuttleTerminalController()

    private var sessions: [ShuttleTerminalSession] = []
    private weak var keySession: ShuttleTerminalSession?
    private var menusInstalled = false
    private weak var themeMenu: NSMenu?
    private weak var fontMenu: NSMenu?
    private var helpWindow: NSWindow?
    private weak var splitMenu: NSMenu?
    private weak var menubarSplitMenu: NSMenu?
    private weak var displaySizeMenu: NSMenu?
    private weak var menubarDisplaySizeMenu: NSMenu?
    private var spaceRestackWork: DispatchWorkItem?
    private var scrollMonitor: Any?

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            self?.handleWorkspaceScroll(event) ?? event
        }
    }

    @objc private func activeSpaceDidChange(_ notification: Notification) {
        restackWindowsOnActiveSpace()
        spaceRestackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restackWindowsOnActiveSpace()
        }
        spaceRestackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Raise terminal windows that already belong to the current Space so they
    /// are not left behind another app after a Mission Control swipe (for
    /// example returning from a fullscreen Calendar).
    @objc func restackWindowsOnActiveSpace() {
        let onSpace = sessions.filter {
            $0.window.isVisible && !$0.window.isMiniaturized && $0.window.isOnActiveSpace
        }
        guard !onSpace.isEmpty else { return }
        activateApplication()
        for session in onSpace.sorted(by: { $0.window.orderedIndex > $1.window.orderedIndex }) {
            session.window.orderFrontRegardless()
        }
        let key = keySession.flatMap { session in
            onSpace.contains(where: { $0 === session }) ? session : nil
        } ?? onSpace.last
        key?.window.makeKeyAndOrderFront(nil)
    }

    private enum AlignEdge: Int {
        case right = 1
        case left = 2
        case top = 3
        case bottom = 4

        var title: String {
            switch self {
            case .right: return "Align Right"
            case .left: return "Align Left"
            case .top: return "Align Top"
            case .bottom: return "Align Bottom"
            }
        }
    }

    @objc var focusOnHover = false {
        didSet { sessions.forEach { $0.applyWindowChrome(force: true) } }
    }
    @objc var titlebarOnHover = true {
        didSet { sessions.forEach { $0.applyWindowChrome(force: true) } }
    }
    @objc var reconnectRemote = true
    @objc var restoreWindows = true
    /// `"5x4"` or `"4x3"`. Controls how many align cells fit on an edge.
    @objc var alignGrid = "5x4"
    /// `"full"`, `"left"`, or `"right"`. Limits windows to that part of the screen.
    @objc var displaySize = "full"
    private var workspacePan: CGFloat = 0
    private var workspacePanning = false
    private var workspaceLayoutActive = false
    private var panSnapWork: DispatchWorkItem?
    private var panGestureOrigin: CGFloat?
    private var panAnimTimer: Timer?
    private var panAnimStart: CGFloat = 0
    private var panAnimTarget: CGFloat = 0
    private var panAnimStartTime: TimeInterval = 0
    private var pageDotsPanel: NSPanel?
    private var pageDotsView: WorkspacePageDotsView?
    private var pageDotsHideWork: DispatchWorkItem?
    private var pageDotsHovered = false
    var isApplyingWorkspaceLayout: Bool { workspaceLayoutActive || workspacePanning }
    private var lastLayout: LastLayout?
    private var lastAlignEdge: AlignEdge?
    private var persistWork: DispatchWorkItem?
    private var lastWindowSize: NSSize?

    private enum LastLayout {
        case split
        case align(AlignEdge)
    }

    @objc func activateApplication() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func applySessionAppLocks() {
        let locked = ShuttleAppLock.shared.isLocked
        sessions.forEach { $0.applyAppLock(locked) }
    }

    @objc(openHostConfig:)
    func openHostConfig(_ config: NSDictionary) {
        ShuttleAppLock.shared.performWhenUnlocked { [weak self] in
            self?.openHostConfigNow(config)
        }
    }

    private func openHostConfigNow(_ config: NSDictionary) {
        installMenusIfNeeded()

        let command = string(config, "cmd")
        let after = string(config, "after")
        let theme = string(config, "theme")
        let font = string(config, "font")
        var title = string(config, "name")
        if title.isEmpty {
            title = string(config, "title")
        }
        if title.isEmpty {
            title = command.isEmpty ? "ShuttleTerm" : command
        }
        let reconnect = reconnectFlag(config, command: command)
        let reuseKey = "\(title)\u{1e}\(command)\u{1e}\(after)"

        let session = ShuttleTerminalSession(
            command: command,
            title: title,
            themeName: theme,
            fontName: font.isEmpty ? nil : font,
            after: after.isEmpty ? nil : after,
            reconnect: reconnect,
            reuseKey: reuseKey
        )
        sessions.append(session)
        cascade(session.window)
        if ShuttleWindowChrome.usesHalfDisplay {
            session.applyHalfDisplayWindowLock(true)
        }
        session.makeKeyAndOrderFront()
        keySession = session
        refreshSplitMenus()
        schedulePersist()
    }

    @objc func promptAndRunCommand(_ sender: Any?) {
        ShuttleAppLock.shared.performWhenUnlocked { [weak self] in
            self?.promptAndRunCommandNow()
        }
    }

    private func promptAndRunCommandNow() {
        installMenusIfNeeded()
        let alert = NSAlert()
        alert.messageText = "Run Command"
        alert.informativeText = "Opens a ShuttleTerm window and runs the command. Example: ls ~/Projects"
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "ls {something}"
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        openHostConfig([
            "cmd": command,
            "title": command
        ] as NSDictionary)
    }

    @objc func splitFromMenu(_ sender: NSMenuItem) {
        splitIntoGrid(count: sender.tag)
    }

    @objc(splitIntoGridWithCount:)
    func splitIntoGrid(count: Int) {
        installMenusIfNeeded()
        let open = sessions.filter { isWorkspaceOpen($0) }
        guard !open.isEmpty else { return }
        lastLayout = .split
        let n = min(max(count, 1), min(20, open.count))
        tilePreservingPositions(chooseWindowsForSplit(from: open, count: n))
    }

    func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistOpenWindows()
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc func applyDefaultTheme(_ name: String) {
        sessions.forEach { $0.applyThemeNamed(name) }
        refreshAppearanceMenus()
        schedulePersist()
    }

    @objc func applyDefaultFont(_ name: String) {
        sessions.forEach { $0.applyFontNamed(name) }
        refreshAppearanceMenus()
        schedulePersist()
    }

    @objc func applyAlignGrid(_ grid: String) {
        alignGrid = grid.lowercased() == "4x3" ? "4x3" : "5x4"
        if ShuttleWindowChrome.usesHalfDisplay {
            switch lastLayout {
            case .align(let edge):
                alignWindows(edge, raise: false)
            default:
                resnapHalfDisplayGrid()
            }
            sessions.forEach { $0.applyHalfDisplayWindowLock(true) }
        } else {
            alignWindows(lastAlignEdge ?? .right, raise: false)
        }
        ShuttleSettingsPanel.shared.bringToFrontIfOpen()
    }

    @objc func applyDisplaySize(_ value: String) {
        displaySize = ShuttleWindowChrome.normalizedDisplaySize(value)
        workspacePan = 0
        panSnapWork?.cancel()
        panAnimTimer?.invalidate()
        panAnimTimer = nil
        panGestureOrigin = nil
        workspacePanning = false
        if !ShuttleWindowChrome.usesHalfDisplay {
            hidePageDots()
            unparkWorkspaceWindows()
            for session in sessions {
                session.layoutFrame = nil
                session.applyHalfDisplayWindowLock(false)
            }
            for session in sessions where session.window.isVisible && !session.window.isMiniaturized {
                ShuttleWindowChrome.constrain(session.window, magnetic: false)
            }
        } else {
            for session in sessions where session.window.isMiniaturized {
                session.window.deminiaturize(nil)
            }
            adoptHalfDisplayFrames()
            sessions.forEach { $0.applyHalfDisplayWindowLock(true) }
        }
        persistDisplaySize(displaySize)
        refreshDisplaySizeMenus()
        ShuttleSettingsPanel.shared.syncDisplaySizeControl()
        schedulePersist()
        ShuttleSettingsPanel.shared.bringToFrontIfOpen()
    }

    private func persistDisplaySize(_ value: String) {
        let json = ShuttleHostStore.loadJSON()
        json["display_size"] = value
        ShuttleHostStore.saveJSON(json)
    }

    private func handleWorkspaceScroll(_ event: NSEvent) -> NSEvent? {
        guard ShuttleWindowChrome.usesHalfDisplay else { return event }
        guard eventBelongsToWorkspace(event) else { return event }
        let screen = event.window?.screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return event }

        if event.type == .swipe {
            let dx = event.deltaX
            guard abs(dx) >= 0.5 else { return event }
            goToAdjacentPage(dx > 0 ? 1 : -1, on: screen)
            return nil
        }

        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if abs(dx) < 0.2, event.modifierFlags.contains(.shift) {
            dx = dy
            dy = 0
        }
        let gestureDone = event.momentumPhase == .ended
            || event.phase == .cancelled
            || event.momentumPhase == .cancelled
        let began = event.phase == .began
        let horizontal = abs(dx) >= 0.2 && abs(dx) >= abs(dy)
        if began {
            panGestureOrigin = workspacePan
        }
        let paging = workspacePanning || horizontal
        guard paging else {
            return event
        }
        if !event.hasPreciseScrollingDeltas {
            goToAdjacentPage(dx < 0 ? 1 : -1, on: screen)
            return nil
        }
        if horizontal {
            _ = panWindows(on: screen, dx: dx)
        }
        showPageDots(on: screen, linger: false)
        if gestureDone {
            panSnapWork?.cancel()
            snapWorkspacePan(on: screen)
        } else {
            schedulePanSnap(on: screen)
        }
        return nil
    }

    private func eventBelongsToWorkspace(_ event: NSEvent) -> Bool {
        if let window = event.window {
            if window === pageDotsPanel { return true }
            return sessions.contains(where: { $0.window === window })
        }
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) ?? NSScreen.main
        return ShuttleWindowChrome.workspace(on: screen).contains(loc)
    }

    private func schedulePanSnap(on screen: NSScreen) {
        panSnapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.snapWorkspacePan(on: screen)
        }
        panSnapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @discardableResult
    private func panWindows(on screen: NSScreen, dx: CGFloat) -> Bool {
        panAnimTimer?.invalidate()
        panAnimTimer = nil
        let group = workspaceGroup(on: screen)
        guard !group.isEmpty else { return false }
        captureLayoutFrames(group)
        let view = ShuttleWindowChrome.workspace(on: screen)
        let content = layoutUnion(group)
        guard content.width > view.width + 1 else { return false }
        let (lo, hi) = panRange(content: content, viewport: view)
        let next = min(max(workspacePan + dx, lo), hi)
        guard abs(next - workspacePan) >= 0.2 else { return false }
        workspacePanning = true
        workspacePan = next
        placeWorkspaceWindows(group, viewport: view)
        schedulePersist()
        return true
    }

    private func snapWorkspacePan(on screen: NSScreen?) {
        panSnapWork?.cancel()
        panSnapWork = nil
        defer {
            workspacePanning = false
            panGestureOrigin = nil
        }
        guard ShuttleWindowChrome.usesHalfDisplay, let screen else { return }
        let group = workspaceGroup(on: screen)
        guard !group.isEmpty else { return }
        captureLayoutFrames(group)
        let view = ShuttleWindowChrome.workspace(on: screen)
        let content = layoutUnion(group)
        let stops = pageStops(content: content, viewport: view)
        guard stops.count > 1 else {
            placeWorkspaceWindows(group, viewport: view)
            hidePageDots()
            return
        }
        workspacePan = snappedPagePan(stops: stops)
        workspaceLayoutActive = true
        placeWorkspaceWindows(group, viewport: view)
        workspaceLayoutActive = false
        showPageDots(on: screen, linger: true)
        schedulePersist()
    }

    private func pageStops(on screen: NSScreen) -> [CGFloat] {
        let group = workspaceGroup(on: screen)
        captureLayoutFrames(group)
        return pageStops(
            content: layoutUnion(group),
            viewport: ShuttleWindowChrome.workspace(on: screen)
        )
    }

    /// Left-to-right pages: index 0 shows the leftmost layout (highest pan).
    private func pageStops(content: NSRect, viewport: NSRect) -> [CGFloat] {
        let (lo, hi) = panRange(content: content, viewport: viewport)
        let width = max(viewport.width, 1)
        if hi - lo < 8 { return [lo] }
        var stops: [CGFloat] = []
        var pan = hi
        while pan > lo + 8 {
            stops.append(pan)
            pan -= width
        }
        stops.append(lo)
        return stops
    }

    private func nearestPageIndex(_ stops: [CGFloat], to pan: CGFloat? = nil) -> Int {
        guard !stops.isEmpty else { return 0 }
        let value = pan ?? workspacePan
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (index, stop) in stops.enumerated() {
            let dist = abs(stop - value)
            if dist < bestDist {
                bestDist = dist
                best = index
            }
        }
        return best
    }

    private func snappedPagePan(stops: [CGFloat]) -> CGFloat {
        guard !stops.isEmpty else { return workspacePan }
        let nearest = nearestPageIndex(stops)
        guard let origin = panGestureOrigin else {
            return stops[nearest]
        }
        let originIndex = nearestPageIndex(stops, to: origin)
        if nearest != originIndex {
            return stops[nearest]
        }
        let spacing = originIndex + 1 < stops.count
            ? abs(stops[originIndex] - stops[originIndex + 1])
            : abs(stops[originIndex] - (originIndex > 0 ? stops[originIndex - 1] : stops[originIndex]))
        let commit = max(24, spacing * 0.18)
        let traveled = workspacePan - origin
        if traveled < -commit {
            return stops[min(originIndex + 1, stops.count - 1)]
        }
        if traveled > commit {
            return stops[max(originIndex - 1, 0)]
        }
        return stops[originIndex]
    }

    private func goToAdjacentPage(_ delta: Int, on screen: NSScreen) {
        let stops = pageStops(on: screen)
        guard stops.count > 1 else { return }
        goToPage(nearestPageIndex(stops) + delta, on: screen)
    }

    private func goToPage(_ index: Int, on screen: NSScreen) {
        let stops = pageStops(on: screen)
        guard !stops.isEmpty else { return }
        let page = min(max(index, 0), stops.count - 1)
        panGestureOrigin = nil
        animateWorkspacePan(to: stops[page], on: screen)
    }

    private func animateWorkspacePan(to target: CGFloat, on screen: NSScreen) {
        panSnapWork?.cancel()
        panAnimTimer?.invalidate()
        let group = workspaceGroup(on: screen)
        captureLayoutFrames(group)
        let view = ShuttleWindowChrome.workspace(on: screen)
        let content = layoutUnion(group)
        let (lo, hi) = panRange(content: content, viewport: view)
        let clamped = min(max(target, lo), hi)
        if abs(clamped - workspacePan) < 0.5 {
            workspacePan = clamped
            workspaceLayoutActive = true
            placeWorkspaceWindows(group, viewport: view)
            workspaceLayoutActive = false
            workspacePanning = false
            showPageDots(on: screen, linger: true)
            schedulePersist()
            return
        }
        panAnimStart = workspacePan
        panAnimTarget = clamped
        panAnimStartTime = ProcessInfo.processInfo.systemUptime
        workspacePanning = true
        showPageDots(on: screen, linger: false)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let u = min(1, (ProcessInfo.processInfo.systemUptime - self.panAnimStartTime) / 0.22)
            let eased = 1 - (1 - u) * (1 - u) * (1 - u)
            self.workspacePan = self.panAnimStart + (self.panAnimTarget - self.panAnimStart) * CGFloat(eased)
            self.placeWorkspaceWindows(self.workspaceGroup(on: screen), viewport: ShuttleWindowChrome.workspace(on: screen))
            self.showPageDots(on: screen, linger: false)
            if u >= 1 {
                timer.invalidate()
                self.panAnimTimer = nil
                self.workspacePan = self.panAnimTarget
                self.workspacePanning = false
                self.showPageDots(on: screen, linger: true)
                self.schedulePersist()
            }
        }
        panAnimTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showPageDots(on screen: NSScreen?, linger: Bool) {
        guard ShuttleWindowChrome.usesHalfDisplay, let screen else {
            hidePageDots()
            return
        }
        let view = ShuttleWindowChrome.workspace(on: screen)
        let stops = pageStops(on: screen)
        guard stops.count > 1 else {
            hidePageDots()
            return
        }
        let dots = ensurePageDots()
        dots.pageCount = stops.count
        dots.currentPage = nearestPageIndex(stops)
        dots.onSelect = { [weak self] page in
            self?.goToPage(page, on: screen)
        }
        let size = WorkspacePageDotsView.size(for: stops.count)
        let frame = NSRect(
            x: view.midX - size.width / 2,
            y: view.minY + 14,
            width: size.width,
            height: size.height
        )
        pageDotsPanel?.setFrame(frame, display: true)
        pageDotsPanel?.orderFrontRegardless()
        pageDotsHideWork?.cancel()
        guard linger, !pageDotsHovered else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pageDotsHovered, !self.workspacePanning else { return }
            self.hidePageDots()
        }
        pageDotsHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func hidePageDots() {
        pageDotsHideWork?.cancel()
        pageDotsHideWork = nil
        pageDotsHovered = false
        pageDotsPanel?.orderOut(nil)
    }

    private func ensurePageDots() -> WorkspacePageDotsView {
        if let pageDotsView {
            return pageDotsView
        }
        let dots = WorkspacePageDotsView(frame: .zero)
        dots.onHover = { [weak self] hovering in
            guard let self else { return }
            self.pageDotsHovered = hovering
            if hovering {
                self.pageDotsHideWork?.cancel()
            } else if !self.workspacePanning {
                self.showPageDots(on: self.pageDotsPanel?.screen, linger: true)
            }
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.identifier = NSUserInterfaceItemIdentifier("shuttleterm.workspace.pages")
        panel.contentView = dots
        pageDotsPanel = panel
        pageDotsView = dots
        return dots
    }

    private func panRange(content: NSRect, viewport: NSRect) -> (CGFloat, CGFloat) {
        let alignLeft = viewport.minX - content.minX
        let alignRight = viewport.maxX - content.maxX
        return (min(alignLeft, alignRight), max(alignLeft, alignRight))
    }

    private func workspaceGroup(on screen: NSScreen) -> [ShuttleTerminalSession] {
        let view = ShuttleWindowChrome.workspace(on: screen)
        return sessions.filter {
            !$0.window.isMiniaturized
                && !$0.window.styleMask.contains(.fullScreen)
                && (
                    $0.window.screen === screen
                        || $0.workspaceParked
                        || view.intersects($0.window.frame)
                        || ($0.layoutFrame.map { view.intersects($0) || ShuttleWindowChrome.layoutBounds(on: screen).intersects($0) } ?? false)
                )
        }
    }

    private func captureLayoutFrames(_ group: [ShuttleTerminalSession]) {
        for session in group where session.layoutFrame == nil {
            var frame = session.window.frame
            frame.origin.x -= workspacePan
            session.layoutFrame = frame
        }
    }

    private func layoutUnion(_ group: [ShuttleTerminalSession]) -> NSRect {
        var union: NSRect?
        for session in group {
            let frame = session.layoutFrame ?? session.window.frame
            union = union.map { $0.union(frame) } ?? frame
        }
        return union ?? .zero
    }

    private func placeWorkspaceWindows() {
        guard ShuttleWindowChrome.usesHalfDisplay else { return }
        workspaceLayoutActive = true
        let groups = Dictionary(grouping: sessions.filter { !$0.window.isMiniaturized }) { session -> ObjectIdentifier in
            let screen = session.window.screen ?? NSScreen.main ?? NSScreen.screens.first
            return ObjectIdentifier(screen ?? session.window)
        }
        for group in groups.values {
            let screen = group[0].window.screen ?? NSScreen.main
            placeWorkspaceWindows(group, viewport: ShuttleWindowChrome.workspace(on: screen))
        }
        workspaceLayoutActive = false
    }

    private func placeWorkspaceWindows(_ group: [ShuttleTerminalSession], viewport view: NSRect) {
        var shown: [(ShuttleTerminalSession, NSRect)] = []
        for session in group {
            guard var frame = session.layoutFrame else { continue }
            frame.origin.x += workspacePan
            if frame.maxY > view.maxY { frame.origin.y = view.maxY - frame.height }
            if frame.minY < view.minY { frame.origin.y = view.minY }
            if ShuttleWindowChrome.carouselShows(frame, in: view) {
                shown.append((session, frame))
            } else {
                parkWorkspaceWindow(session)
            }
        }
        for (session, frame) in shown {
            let current = session.window.frame
            let sizeChanged = abs(current.width - frame.width) > 1
                || abs(current.height - frame.height) > 1
            let moved = abs(current.minX - frame.minX) > 0.5
                || abs(current.minY - frame.minY) > 0.5
            if session.workspaceParked || !session.window.isVisible || sizeChanged {
                session.tile(in: frame, reveal: false)
                session.window.orderFrontRegardless()
            } else if moved {
                session.window.setFrame(frame, display: true, animate: false)
            }
            session.workspaceParked = false
        }
    }

    /// Snap each window to an Align-grid cell, keep those already in the chosen
    /// half, and hide the rest until a swipe pans them in.
    private func adoptHalfDisplayFrames() {
        guard ShuttleWindowChrome.usesHalfDisplay else { return }
        workspaceLayoutActive = true
        workspacePan = 0
        let groups = Dictionary(grouping: sessions.filter { !$0.window.isMiniaturized }) { session -> ObjectIdentifier in
            let screen = session.window.screen ?? NSScreen.main ?? NSScreen.screens.first
            return ObjectIdentifier(screen ?? session.window)
        }
        for group in groups.values {
            let screen = group[0].window.screen ?? NSScreen.main
            let view = ShuttleWindowChrome.workspace(on: screen)
            for session in group {
                session.layoutFrame = session.window.isVisible
                    ? session.window.frame
                    : (session.layoutFrame ?? session.window.frame)
            }
            snapGroupToGrid(group, on: screen)
            let insideCount = group.filter {
                ShuttleWindowChrome.carouselShows(
                    ($0.layoutFrame ?? $0.window.frame).offsetBy(dx: workspacePan, dy: 0),
                    in: view
                )
            }.count
            if insideCount == 0 {
                shiftGroupIntoHalf(group, viewport: view)
            }
            placeWorkspaceWindows(group, viewport: view)
            showPageDots(on: screen, linger: true)
        }
        workspaceLayoutActive = false
    }

    private func resnapHalfDisplayGrid() {
        guard ShuttleWindowChrome.usesHalfDisplay else { return }
        workspaceLayoutActive = true
        let groups = Dictionary(grouping: sessions.filter { !$0.window.isMiniaturized }) { session -> ObjectIdentifier in
            let screen = session.window.screen ?? NSScreen.main ?? NSScreen.screens.first
            return ObjectIdentifier(screen ?? session.window)
        }
        for group in groups.values {
            let screen = group[0].window.screen ?? NSScreen.main
            snapGroupToGrid(group, on: screen)
            placeWorkspaceWindows(group, viewport: ShuttleWindowChrome.workspace(on: screen))
            showPageDots(on: screen, linger: true)
        }
        workspaceLayoutActive = false
    }

    /// Place each window on the nearest free Align-grid cell (full-screen cell size).
    private func snapGroupToGrid(_ group: [ShuttleTerminalSession], on screen: NSScreen?) {
        let vis = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let (cols, rows) = alignGridSize()
        var taken = Set<String>()
        func key(_ col: Int, _ row: Int) -> String { "\(col),\(row)" }
        let ordered = group.sorted { a, b in
            let fa = a.layoutFrame ?? a.window.frame
            let fb = b.layoutFrame ?? b.window.frame
            if abs(fa.maxY - fb.maxY) > 20 { return fa.maxY > fb.maxY }
            return fa.minX < fb.minX
        }
        var overflow = 0
        let half = ShuttleWindowChrome.normalizedDisplaySize(displaySize)
        for session in ordered {
            let frame = session.layoutFrame ?? session.window.frame
            var col = Int(floor((frame.midX - vis.minX) / max(vis.width, 1) * CGFloat(cols)))
            var row = Int(floor((frame.midY - vis.minY) / max(vis.height, 1) * CGFloat(rows)))
            col = min(max(col, 0), max(cols - 1, 0))
            row = min(max(row, 0), max(rows - 1, 0))
            if taken.contains(key(col, row)) {
                if let free = nearestFreeCell(col: col, row: row, cols: cols, rows: rows, taken: taken) {
                    col = free.0
                    row = free.1
                } else {
                    overflow += 1
                    col = half == "left" ? -overflow : cols - 1 + overflow
                }
            }
            taken.insert(key(col, row))
            session.layoutFrame = cellFrame(vis: vis, cols: cols, rows: rows, col: col, rowFromBottom: row)
        }
    }

    private func nearestFreeCell(
        col: Int,
        row: Int,
        cols: Int,
        rows: Int,
        taken: Set<String>
    ) -> (Int, Int)? {
        func key(_ c: Int, _ r: Int) -> String { "\(c),\(r)" }
        let maxDist = max(cols, rows)
        for dist in 1...maxDist {
            for dc in -dist...dist {
                for dr in -dist...dist {
                    if max(abs(dc), abs(dr)) != dist { continue }
                    let c = col + dc
                    let r = row + dr
                    if c < 0 || r < 0 || c >= cols || r >= rows { continue }
                    if !taken.contains(key(c, r)) { return (c, r) }
                }
            }
        }
        return nil
    }

    func gridCellSize(on screen: NSScreen?) -> NSSize {
        let vis = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let (cols, rows) = alignGridSize()
        return NSSize(
            width: vis.width / CGFloat(max(cols, 1)),
            height: vis.height / CGFloat(max(rows, 1))
        )
    }

    /// When every window sits in the other half, slide the group as a unit into
    /// the chosen half so relative positions stay the same.
    private func shiftGroupIntoHalf(_ group: [ShuttleTerminalSession], viewport view: NSRect) {
        var union: NSRect?
        for session in group {
            let frame = session.layoutFrame ?? session.window.frame
            union = union.map { $0.union(frame) } ?? frame
        }
        guard let union, union.width > 1 else { return }
        let size = ShuttleWindowChrome.normalizedDisplaySize(displaySize)
        let dx = size == "left"
            ? view.maxX - union.maxX
            : view.minX - union.minX
        guard abs(dx) >= 1 else { return }
        for session in group {
            guard var frame = session.layoutFrame else { continue }
            frame.origin.x += dx
            session.layoutFrame = frame
        }
    }

    private func parkWorkspaceWindow(_ session: ShuttleTerminalSession) {
        session.workspaceParked = true
        if session.window.isVisible {
            session.window.orderOut(nil)
        }
    }

    private func unparkWorkspaceWindows() {
        workspaceLayoutActive = true
        for session in sessions where session.workspaceParked {
            session.workspaceParked = false
            session.window.orderFrontRegardless()
        }
        workspaceLayoutActive = false
    }

    func syncLayoutFrame(_ session: ShuttleTerminalSession) {
        guard ShuttleWindowChrome.usesHalfDisplay else { return }
        var frame = session.window.frame
        frame.origin.x -= workspacePan
        session.layoutFrame = frame
    }

    func revealInWorkspace(_ session: ShuttleTerminalSession) {
        guard ShuttleWindowChrome.usesHalfDisplay else { return }
        captureLayoutFrames([session])
        guard let layout = session.layoutFrame else { return }
        let view = ShuttleWindowChrome.workspace(for: session.window)
        let shown = layout.offsetBy(dx: workspacePan, dy: 0)
        if shown.minX >= view.minX - 1, shown.maxX <= view.maxX + 1 {
            if session.workspaceParked {
                workspaceLayoutActive = true
                placeWorkspaceWindows([session], viewport: view)
                workspaceLayoutActive = false
            }
            return
        }
        let target: CGFloat
        if layout.width >= view.width - 1 {
            target = view.minX - layout.minX
        } else if shown.minX < view.minX {
            target = view.minX - layout.minX
        } else {
            target = view.maxX - layout.maxX
        }
        let nsScreen = session.window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let content: NSRect
        if let nsScreen {
            content = layoutUnion(workspaceGroup(on: nsScreen))
        } else {
            content = layout
        }
        let (lo, hi) = panRange(content: content.width > 1 ? content : layout, viewport: view)
        workspacePan = min(max(target, lo), hi)
        placeWorkspaceWindows()
    }

    @objc func persistOpenWindows() {
        persistWork?.cancel()
        persistWork = nil
        guard restoreWindows else { return }
        let snaps = sessions.filter { isWorkspaceOpen($0) }.map { $0.snapshot() }
        ShuttleSessionStore.save(snaps)
    }

    @objc func restoreSavedWindowsIfEnabled() -> Bool {
        guard restoreWindows else { return false }
        let snaps = ShuttleSessionStore.load()
        guard !snaps.isEmpty else { return false }
        installMenusIfNeeded()
        for snap in snaps {
            restoreSnapshot(snap)
        }
        if ShuttleWindowChrome.usesHalfDisplay {
            adoptHalfDisplayFrames()
            sessions.forEach { $0.applyHalfDisplayWindowLock(true) }
        }
        refreshSplitMenus()
        return true
    }

    private func restoreSnapshot(_ snap: ShuttleWindowSnapshot) {
        let reuseKey = "\(snap.title)\u{1e}\(snap.cmd)\u{1e}\(snap.after)"
        let session = ShuttleTerminalSession(
            command: snap.cmd,
            title: snap.title.isEmpty ? "ShuttleTerm" : snap.title,
            themeName: snap.theme,
            fontName: snap.font.isEmpty ? nil : snap.font,
            after: snap.after.isEmpty ? nil : snap.after,
            reconnect: snap.reconnect,
            reuseKey: reuseKey,
            restoreFrame: snap.frame,
            restoreBuffer: snap.buffer,
            restoredFontSize: CGFloat(snap.fontSize),
            grokSessionId: snap.grokSessionId,
            grokCwd: snap.grokCwd,
            agentKind: snap.agentKind
        )
        sessions.append(session)
        session.makeKeyAndOrderFront()
        keySession = session
        if ShuttleWindowChrome.usesHalfDisplay {
            session.applyHalfDisplayWindowLock(true)
        }
    }

    func sessionDidClose(_ session: ShuttleTerminalSession) {
        if !ShuttleWindowChrome.usesHalfDisplay {
            rememberWindowSize(session.window.frame.size)
        }
        ShuttleAttention.shared.clear(session)
        sessions.removeAll { $0 === session }
        if keySession === session {
            keySession = sessions.last
        }
        refreshSplitMenus()
        persistOpenWindows()
        if sessions.isEmpty {
            hidePageDots()
        } else {
            showPageDots(on: session.window.screen ?? NSScreen.main, linger: true)
        }
    }

    func session(attentionId: String) -> ShuttleTerminalSession? {
        sessions.first { $0.attentionId == attentionId }
    }

    func rememberWindowSize(_ size: NSSize) {
        guard size.width >= 360, size.height >= 180 else { return }
        lastWindowSize = size
    }

    @objc var visibleWindowCount: Int {
        sessions.filter { isWorkspaceOpen($0) }.count
    }

    private func isWorkspaceOpen(_ session: ShuttleTerminalSession) -> Bool {
        (session.window.isVisible || session.workspaceParked) && !session.window.isMiniaturized
    }

    @objc func attachMenubarSplitMenu(_ menu: NSMenu) {
        menu.delegate = self
        menubarSplitMenu = menu
        fillSplitMenu(menu)
    }

    @objc func attachMenubarAlignMenu(_ menu: NSMenu) {
        fillAlignMenu(menu)
    }

    @objc func attachMenubarDisplaySizeMenu(_ menu: NSMenu) {
        menu.delegate = self
        menubarDisplaySizeMenu = menu
        fillDisplaySizeMenu(menu)
    }

    @objc func fillSplitMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = visibleWindowCount
        guard open >= 2 else { return }
        for n in 2...open {
            let item = NSMenuItem(title: "Split \(n)", action: #selector(splitFromMenu(_:)), keyEquivalent: "")
            item.tag = n
            item.target = self
            menu.addItem(item)
        }
    }

    private func fillAlignMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for edge in [AlignEdge.right, .left, .top, .bottom] {
            let item = NSMenuItem(title: edge.title, action: #selector(alignFromMenu(_:)), keyEquivalent: "")
            item.tag = edge.rawValue
            item.target = self
            menu.addItem(item)
        }
    }

    private func fillDisplaySizeMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = ShuttleWindowChrome.normalizedDisplaySize(displaySize)
        for (title, value) in [
            ("Full", "full"),
            ("Left half", "left"),
            ("Right half", "right")
        ] {
            let item = NSMenuItem(title: title, action: #selector(displaySizeFromMenu(_:)), keyEquivalent: "")
            item.representedObject = value
            item.target = self
            item.state = current == value ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func displaySizeFromMenu(_ sender: NSMenuItem) {
        let value = (sender.representedObject as? String) ?? sender.title
        applyDisplaySize(value)
    }

    @objc func refreshDisplaySizeMenus() {
        if let displaySizeMenu {
            fillDisplaySizeMenu(displaySizeMenu)
        }
        if let menubarDisplaySizeMenu {
            fillDisplaySizeMenu(menubarDisplaySizeMenu)
        }
    }

    @objc func alignFromMenu(_ sender: NSMenuItem) {
        guard let edge = AlignEdge(rawValue: sender.tag) else { return }
        alignWindows(edge)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Split" {
            fillSplitMenu(menu)
        }
        if menu.title == "App Display Size" {
            fillDisplaySizeMenu(menu)
        }
    }

    @objc func refreshSplitMenus() {
        if let splitMenu {
            fillSplitMenu(splitMenu)
        }
        if let menubarSplitMenu {
            fillSplitMenu(menubarSplitMenu)
        }
    }

    func sessionDidBecomeKey(_ session: ShuttleTerminalSession) {
        keySession = session
        refreshAppearanceMenus()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if ShuttleAppLock.shared.isLocked {
            if menuItem.action == #selector(showHelp(_:)) ||
                menuItem.action == #selector(newWindow(_:)) ||
                menuItem.action == #selector(promptAndRunCommand(_:)) {
                return true
            }
            return false
        }
        if menuItem.action == #selector(applyThemeFromMenu(_:)) {
            menuItem.state = keySession?.themeName == menuItem.title ? .on : .off
            return keySession != nil
        }
        if menuItem.action == #selector(applyFontFromMenu(_:)) {
            menuItem.state = keySession?.currentFontFamily.caseInsensitiveCompare(menuItem.title) == .orderedSame ? .on : .off
            return keySession != nil
        }
        if menuItem.title == "Split" {
            return visibleWindowCount >= 2
        }
        if menuItem.title == "Align" || menuItem.action == #selector(alignFromMenu(_:)) {
            return visibleWindowCount >= 1
        }
        if menuItem.action == #selector(NSWindow.performMiniaturize(_:))
            || menuItem.action == #selector(NSWindow.performZoom(_:)) {
            return !ShuttleWindowChrome.usesHalfDisplay && keySession != nil
        }
        if menuItem.title == "App Display Size" || menuItem.action == #selector(displaySizeFromMenu(_:)) {
            if menuItem.action == #selector(displaySizeFromMenu(_:)) {
                let value = (menuItem.representedObject as? String)
                    ?? ShuttleWindowChrome.normalizedDisplaySize(menuItem.title)
                menuItem.state = ShuttleWindowChrome.normalizedDisplaySize(displaySize) == value ? .on : .off
            }
            return true
        }
        if menuItem.action == #selector(newWindow(_:)) ||
            menuItem.action == #selector(promptAndRunCommand(_:)) ||
            menuItem.action == #selector(splitFromMenu(_:)) ||
            menuItem.action == #selector(showHelp(_:)) {
            return true
        }
        return keySession != nil
    }

    private func chooseWindowsForSplit(from open: [ShuttleTerminalSession], count: Int) -> [ShuttleTerminalSession] {
        if open.count <= count { return open }
        let key = keySession ?? open.last!
        let keyScreen = key.window.screen
        let keyCenter = NSPoint(x: key.window.frame.midX, y: key.window.frame.midY)
        func distance(_ session: ShuttleTerminalSession) -> CGFloat {
            let dx = session.window.frame.midX - keyCenter.x
            let dy = session.window.frame.midY - keyCenter.y
            return dx * dx + dy * dy
        }
        let same = open.filter { $0.window.screen === keyScreen }.sorted { distance($0) < distance($1) }
        let others = open.filter { $0.window.screen !== keyScreen }.sorted { distance($0) < distance($1) }
        return Array((same + others).prefix(count))
    }

    private func tilePreservingPositions(_ tiles: [ShuttleTerminalSession]) {
        guard !tiles.isEmpty else { return }
        let groups = Dictionary(grouping: tiles) { session -> ObjectIdentifier in
            let screen = session.window.screen ?? NSScreen.main ?? NSScreen.screens.first
            return ObjectIdentifier(screen ?? session.window)
        }
        for group in groups.values {
            tileGroup(group)
        }
        tiles.last?.makeKeyAndOrderFront()
    }

    private func tileGroup(_ tiles: [ShuttleTerminalSession]) {
        guard !tiles.isEmpty else { return }
        if ShuttleWindowChrome.usesHalfDisplay {
            tileGroupOnGrid(tiles)
            return
        }
        let nsScreen = tiles[0].window.screen ?? NSScreen.main
        let layout = ShuttleWindowChrome.layoutBounds(on: nsScreen)
        let view = ShuttleWindowChrome.workspace(on: nsScreen)
        var union = layout
        if !ShuttleWindowChrome.usesHalfDisplay {
            union = tiles[0].window.frame
            for session in tiles.dropFirst() {
                union = union.union(session.window.frame)
            }
            union = union.intersection(layout)
            let minW = max(min(360, layout.width), layout.width * ShuttleWindowChrome.snapWidthFraction)
            let minH = max(min(180, layout.height), layout.height * ShuttleWindowChrome.snapHeightFraction)
            if union.width < minW || union.height < minH {
                union = layout
            }
        }
        let sorted = sortVisual(tiles)
        let (cols, rows) = gridForUnion(count: sorted.count, union: union)
        let gap: CGFloat = 4
        let cellW = (union.width - gap * CGFloat(cols + 1)) / CGFloat(max(cols, 1))
        let cellH = (union.height - gap * CGFloat(rows + 1)) / CGFloat(max(rows, 1))
        workspaceLayoutActive = true
        workspacePan = 0
        for (index, session) in sorted.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = union.minX + gap + CGFloat(col) * (cellW + gap)
            let y = union.maxY - gap - CGFloat(row + 1) * cellH - CGFloat(row) * gap
            let frame = NSRect(x: x, y: y, width: max(cellW, 120), height: max(cellH, 80))
            session.layoutFrame = frame
        }
        placeWorkspaceWindows(sorted, viewport: view)
        workspaceLayoutActive = false
        showPageDots(on: nsScreen, linger: true)
    }

    private func sortVisual(_ tiles: [ShuttleTerminalSession]) -> [ShuttleTerminalSession] {
        tiles.sorted { a, b in
            let fa = a.window.frame
            let fb = b.window.frame
            if abs(fa.maxY - fb.maxY) > 40 {
                return fa.maxY > fb.maxY
            }
            return fa.minX < fb.minX
        }
    }

    private func gridForUnion(count: Int, union: NSRect) -> (cols: Int, rows: Int) {
        if count <= 1 { return (1, 1) }
        if count == 2 {
            return union.width >= union.height ? (2, 1) : (1, 2)
        }
        var bestCols = 1
        var bestRows = count
        var bestScore = Double.greatestFiniteMagnitude
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = union.width / CGFloat(cols)
            let cellH = union.height / CGFloat(max(rows, 1))
            let cellAspect = Double(cellW / max(cellH, 1))
            let leftover = Double(cols * rows - count)
            let score = abs(log(max(cellAspect, 0.01))) + leftover * 0.2
            if score < bestScore {
                bestScore = score
                bestCols = cols
                bestRows = rows
            }
        }
        return (bestCols, bestRows)
    }

    private func alignWindows(_ edge: AlignEdge, raise: Bool = true) {
        installMenusIfNeeded()
        let open = sessions.filter {
            isWorkspaceOpen($0) && !$0.window.styleMask.contains(.fullScreen)
        }
        guard !open.isEmpty else { return }
        lastLayout = .align(edge)
        lastAlignEdge = edge
        let groups = Dictionary(grouping: open) { session -> ObjectIdentifier in
            let screen = session.window.screen ?? NSScreen.main ?? NSScreen.screens.first
            return ObjectIdentifier(screen ?? session.window)
        }
        for group in groups.values {
            alignGroup(group, edge: edge)
        }
        if raise {
            activateApplication()
            let visible = open.filter { !$0.workspaceParked && $0.window.isVisible }
            (keySession.flatMap { session in visible.contains(where: { $0 === session }) ? session : nil }
                ?? visible.last
                ?? open.last)?.makeKeyAndOrderFront()
        }
        if ShuttleWindowChrome.usesHalfDisplay {
            open.forEach { $0.applyHalfDisplayWindowLock(true) }
        }
        schedulePersist()
    }

    /// Split in half mode keeps Align-grid cell size and fills free cells.
    private func tileGroupOnGrid(_ tiles: [ShuttleTerminalSession]) {
        let nsScreen = tiles[0].window.screen ?? NSScreen.main
        let vis = nsScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let view = ShuttleWindowChrome.workspace(on: nsScreen)
        let (cols, rows) = alignGridSize()
        func key(_ col: Int, _ row: Int) -> String { "\(col),\(row)" }
        var taken = Set<String>()
        for other in sessions where !tiles.contains(where: { $0 === other }) {
            let frame = other.layoutFrame ?? other.window.frame
            let col = Int(floor((frame.midX - vis.minX) / max(vis.width, 1) * CGFloat(cols)))
            let row = Int(floor((frame.midY - vis.minY) / max(vis.height, 1) * CGFloat(rows)))
            taken.insert(key(col, row))
        }
        var cells: [NSRect] = []
        for rowFromTop in 0..<rows {
            let row = rows - 1 - rowFromTop
            for col in 0..<cols {
                if taken.contains(key(col, row)) { continue }
                cells.append(cellFrame(vis: vis, cols: cols, rows: rows, col: col, rowFromBottom: row))
            }
        }
        let viewCells = cells.filter { ShuttleWindowChrome.carouselShows($0, in: view) }
        let overflowCells = cells.filter { !ShuttleWindowChrome.carouselShows($0, in: view) }
        let orderedCells = viewCells + overflowCells
        let half = ShuttleWindowChrome.normalizedDisplaySize(displaySize)
        let sorted = sortVisual(tiles)
        workspaceLayoutActive = true
        workspacePan = 0
        var extra = 0
        for (index, session) in sorted.enumerated() {
            if index < orderedCells.count {
                session.layoutFrame = orderedCells[index]
            } else {
                extra += 1
                let col = half == "left" ? -extra : cols - 1 + extra
                session.layoutFrame = cellFrame(
                    vis: vis,
                    cols: cols,
                    rows: rows,
                    col: col,
                    rowFromBottom: max(rows - 1, 0)
                )
            }
        }
        placeWorkspaceWindows(sorted, viewport: view)
        workspaceLayoutActive = false
        sorted.forEach { $0.applyHalfDisplayWindowLock(true) }
        showPageDots(on: nsScreen, linger: true)
    }

    private func alignGroup(_ tiles: [ShuttleTerminalSession], edge: AlignEdge) {
        guard !tiles.isEmpty else { return }
        let nsScreen = tiles[0].window.screen ?? NSScreen.main
        let layout = ShuttleWindowChrome.layoutBounds(on: nsScreen)
        let view = ShuttleWindowChrome.workspace(on: nsScreen)
        let (cols, rows) = alignGridSize()
        let ordered = orderForAlign(tiles, edge: edge, cols: cols, rows: rows)
        workspaceLayoutActive = true
        for (index, session) in ordered.enumerated() {
            let frame = alignFrame(vis: layout, cols: cols, rows: rows, index: index, edge: edge)
            session.layoutFrame = frame
        }
        let content = layoutUnion(ordered)
        let (lo, hi) = panRange(content: content, viewport: view)
        switch edge {
        case .left, .top:
            workspacePan = min(max(view.minX - content.minX, lo), hi)
        case .right, .bottom:
            workspacePan = min(max(view.maxX - content.maxX, lo), hi)
        }
        placeWorkspaceWindows(ordered, viewport: view)
        workspaceLayoutActive = false
        showPageDots(on: nsScreen, linger: true)
    }

    /// Keep current relative positions: pick the next strip of windows from the
    /// aligned edge, then fill that strip in the same order Align uses.
    private func orderForAlign(
        _ tiles: [ShuttleTerminalSession],
        edge: AlignEdge,
        cols: Int,
        rows: Int
    ) -> [ShuttleTerminalSession] {
        var remaining = tiles
        var ordered: [ShuttleTerminalSession] = []
        switch edge {
        case .right:
            var column = 0
            while !remaining.isEmpty {
                remaining.sort {
                    if abs($0.window.frame.midX - $1.window.frame.midX) > 40 {
                        return $0.window.frame.midX > $1.window.frame.midX
                    }
                    return $0.window.frame.maxY > $1.window.frame.maxY
                }
                let take = takePrefix(&remaining, rows)
                if column == 0 {
                    ordered += take.sorted { $0.window.frame.maxY > $1.window.frame.maxY }
                } else {
                    ordered += take.sorted { $0.window.frame.minY < $1.window.frame.minY }
                }
                column += 1
            }
        case .left:
            var column = 0
            while !remaining.isEmpty {
                remaining.sort {
                    if abs($0.window.frame.midX - $1.window.frame.midX) > 40 {
                        return $0.window.frame.midX < $1.window.frame.midX
                    }
                    return $0.window.frame.maxY > $1.window.frame.maxY
                }
                let take = takePrefix(&remaining, rows)
                if column == 0 {
                    ordered += take.sorted { $0.window.frame.maxY > $1.window.frame.maxY }
                } else {
                    ordered += take.sorted { $0.window.frame.minY < $1.window.frame.minY }
                }
                column += 1
            }
        case .top:
            while !remaining.isEmpty {
                remaining.sort {
                    if abs($0.window.frame.midY - $1.window.frame.midY) > 40 {
                        return $0.window.frame.midY > $1.window.frame.midY
                    }
                    return $0.window.frame.minX < $1.window.frame.minX
                }
                let take = takePrefix(&remaining, cols)
                ordered += take.sorted { $0.window.frame.minX < $1.window.frame.minX }
            }
        case .bottom:
            while !remaining.isEmpty {
                remaining.sort {
                    if abs($0.window.frame.midY - $1.window.frame.midY) > 40 {
                        return $0.window.frame.midY < $1.window.frame.midY
                    }
                    return $0.window.frame.minX < $1.window.frame.minX
                }
                let take = takePrefix(&remaining, cols)
                ordered += take.sorted { $0.window.frame.minX < $1.window.frame.minX }
            }
        }
        return ordered
    }

    private func takePrefix(_ tiles: inout [ShuttleTerminalSession], _ count: Int) -> [ShuttleTerminalSession] {
        let n = min(max(count, 1), tiles.count)
        let taken = Array(tiles.prefix(n))
        tiles.removeFirst(n)
        return taken
    }

    private func alignGridSize() -> (cols: Int, rows: Int) {
        if alignGrid.lowercased() == "4x3" {
            return (4, 3)
        }
        return (5, 4)
    }

    /// Right/Left: first column fills the aligned edge top-to-bottom (`rows` equal
    /// heights). Further columns sit toward the opposite edge and fill bottom-to-top.
    /// Top/Bottom: first row fills the aligned edge left-to-right (`cols` equal
    /// widths). Further rows sit toward the opposite edge, also left-to-right.
    private func alignFrame(
        vis: NSRect,
        cols: Int,
        rows: Int,
        index: Int,
        edge: AlignEdge
    ) -> NSRect {
        let cols = max(cols, 1)
        let rows = max(rows, 1)
        let col: Int
        let rowFromBottom: Int
        switch edge {
        case .right:
            let colFromRight = index / rows
            let slot = index % rows
            col = max(0, cols - 1 - colFromRight)
            rowFromBottom = colFromRight == 0 ? (rows - 1 - slot) : slot
        case .left:
            let colFromLeft = index / rows
            let slot = index % rows
            col = min(cols - 1, colFromLeft)
            rowFromBottom = colFromLeft == 0 ? (rows - 1 - slot) : slot
        case .top:
            let rowFromTop = index / cols
            col = index % cols
            rowFromBottom = max(0, rows - 1 - rowFromTop)
        case .bottom:
            let rowFromBottomIndex = index / cols
            col = index % cols
            rowFromBottom = min(rows - 1, rowFromBottomIndex)
        }
        return cellFrame(vis: vis, cols: cols, rows: rows, col: col, rowFromBottom: rowFromBottom)
    }

    private func cellFrame(vis: NSRect, cols: Int, rows: Int, col: Int, rowFromBottom: Int) -> NSRect {
        let x0 = vis.minX + vis.width * CGFloat(col) / CGFloat(cols)
        let x1 = vis.minX + vis.width * CGFloat(col + 1) / CGFloat(cols)
        let y0 = vis.minY + vis.height * CGFloat(rowFromBottom) / CGFloat(rows)
        let y1 = vis.minY + vis.height * CGFloat(rowFromBottom + 1) / CGFloat(rows)
        return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func cascade(_ window: NSWindow) {
        if ShuttleWindowChrome.usesHalfDisplay,
           let session = sessions.last, session.window === window {
            placeOnFreeGridCell(session, inViewport: true)
            return
        }
        if let size = sizeForNewWindow() {
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: false)
        }
        rememberWindowSize(window.frame.size)
        let offset = CGFloat(sessions.count) * 22
        let screen = ShuttleWindowChrome.workspace(on: window.screen ?? NSScreen.main)
        var frame = window.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        var origin = NSPoint(
            x: screen.minX + 80 + offset,
            y: screen.maxY - frame.height - 80 - offset
        )
        if origin.x + frame.width > screen.maxX {
            origin.x = screen.maxX - frame.width
        }
        if origin.x < screen.minX {
            origin.x = screen.minX
        }
        if origin.y < screen.minY {
            origin.y = screen.minY
        }
        frame.origin = origin
        window.setFrame(frame, display: false)
        if let session = sessions.last, session.window === window {
            session.layoutFrame = frame.offsetBy(dx: -workspacePan, dy: 0)
            session.workspaceParked = false
        }
    }

    private func placeOnFreeGridCell(_ session: ShuttleTerminalSession, inViewport: Bool) {
        let screen = session.window.screen ?? NSScreen.main
        let vis = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let view = ShuttleWindowChrome.workspace(on: screen)
        let (cols, rows) = alignGridSize()
        var taken = Set<String>()
        for other in sessions where other !== session {
            let frame = other.layoutFrame ?? other.window.frame
            let col = Int(floor((frame.midX - vis.minX) / max(vis.width, 1) * CGFloat(cols)))
            let row = Int(floor((frame.midY - vis.minY) / max(vis.height, 1) * CGFloat(rows)))
            taken.insert("\(col),\(row)")
        }
        var placed: NSRect?
        for rowFromTop in 0..<rows {
            let row = rows - 1 - rowFromTop
            for col in 0..<cols {
                if taken.contains("\(col),\(row)") { continue }
                let cell = cellFrame(vis: vis, cols: cols, rows: rows, col: col, rowFromBottom: row)
                if inViewport, !ShuttleWindowChrome.carouselShows(cell, in: view) { continue }
                placed = cell
                break
            }
            if placed != nil { break }
        }
        let frame = placed ?? cellFrame(vis: vis, cols: cols, rows: rows, col: 0, rowFromBottom: rows - 1)
        session.layoutFrame = frame.offsetBy(dx: -workspacePan, dy: 0)
        workspaceLayoutActive = true
        placeWorkspaceWindows([session], viewport: view)
        workspaceLayoutActive = false
    }

    private func sizeForNewWindow() -> NSSize? {
        if let previous = sessions.dropLast().reversed().first(where: { $0.window.isVisible }) {
            return previous.window.frame.size
        }
        return lastWindowSize
    }

    private func reconnectFlag(_ config: NSDictionary, command: String) -> Bool {
        if let value = config["reconnect"], !(value is NSNull) {
            if let flag = value as? Bool { return flag }
            if let number = value as? NSNumber { return number.boolValue }
        }
        return reconnectRemote && ShuttleTermReconnect.isRemote(command)
    }

    private func string(_ config: NSDictionary, _ key: String) -> String {
        guard let value = config[key], !(value is NSNull) else { return "" }
        if let text = value as? String, text != "(null)" {
            return text
        }
        return ""
    }

    private func installMenusIfNeeded() {
        guard !menusInstalled, let mainMenu = NSApp.mainMenu else { return }
        menusInstalled = true

        let themeSub = NSMenu(title: "Theme")
        for name in ShuttleTerminalTheme.paletteNames {
            let item = NSMenuItem(title: name, action: #selector(applyThemeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            themeSub.addItem(item)
        }
        let themeRoot = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeRoot.submenu = themeSub
        themeMenu = themeSub

        let fontSub = NSMenu(title: "Font")
        for name in ShuttleTerminalTheme.installedFontNames() {
            let item = NSMenuItem(title: name, action: #selector(applyFontFromMenu(_:)), keyEquivalent: "")
            item.target = self
            fontSub.addItem(item)
        }
        let fontRoot = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontRoot.submenu = fontSub
        fontMenu = fontSub

        let file = makeMenu(
            title: "File",
            items: [
                ("New Window", #selector(newWindow(_:)), "n")
            ]
        )
        let edit = makeMenu(
            title: "Edit",
            items: [
                ("Cut", #selector(cutSelection(_:)), "x"),
                ("Copy", #selector(copySelection(_:)), "c"),
                ("Paste", #selector(pasteClipboard(_:)), "v"),
                ("Select All", #selector(NSText.selectAll(_:)), "a"),
                nil,
                ("Find…", #selector(findInTerminal(_:)), "f"),
                ("Find Next", #selector(findNext(_:)), "g"),
                ("Find Previous", #selector(findPrevious(_:)), "G")
            ]
        )
        let view = makeMenu(
            title: "View",
            items: [
                ("Bigger Font", #selector(biggerFont(_:)), "+"),
                ("Smaller Font", #selector(smallerFont(_:)), "-")
            ]
        )
        view.submenu?.addItem(.separator())
        view.submenu?.addItem(themeRoot)
        view.submenu?.addItem(fontRoot)

        let windowMenu = makeMenu(
            title: "Window",
            items: [
                ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                ("Zoom", #selector(NSWindow.performZoom(_:)), nil),
                nil,
                ("Close", #selector(NSWindow.performClose(_:)), "w")
            ]
        )
        let splitSub = NSMenu(title: "Split")
        splitSub.delegate = self
        fillSplitMenu(splitSub)
        splitMenu = splitSub
        let splitRoot = NSMenuItem(title: "Split", action: nil, keyEquivalent: "")
        splitRoot.submenu = splitSub
        let alignSub = NSMenu(title: "Align")
        fillAlignMenu(alignSub)
        let alignRoot = NSMenuItem(title: "Align", action: nil, keyEquivalent: "")
        alignRoot.submenu = alignSub
        let displaySub = NSMenu(title: "App Display Size")
        displaySub.delegate = self
        fillDisplaySizeMenu(displaySub)
        displaySizeMenu = displaySub
        let displayRoot = NSMenuItem(title: "App Display Size", action: nil, keyEquivalent: "")
        displayRoot.submenu = displaySub
        windowMenu.submenu?.addItem(.separator())
        windowMenu.submenu?.addItem(splitRoot)
        windowMenu.submenu?.addItem(alignRoot)
        windowMenu.submenu?.addItem(displayRoot)

        let terminal = makeMenu(
            title: "Terminal",
            items: [
                ("Clear Scrollback", #selector(clearScrollback(_:)), "k"),
                nil,
                ("Run Command…", #selector(promptAndRunCommand(_:)), "r")
            ]
        )

        mainMenu.insertItem(file, at: min(1, mainMenu.numberOfItems))
        mainMenu.insertItem(edit, at: min(2, mainMenu.numberOfItems))
        mainMenu.insertItem(view, at: min(3, mainMenu.numberOfItems))
        mainMenu.insertItem(terminal, at: min(4, mainMenu.numberOfItems))
        mainMenu.insertItem(windowMenu, at: min(5, mainMenu.numberOfItems))
        NSApp.windowsMenu = windowMenu.submenu
        ensureHelpMenu(in: mainMenu)
    }

    @objc func newWindow(_ sender: Any?) {
        openHostConfig([
            "cmd": "",
            "name": "ShuttleTerm"
        ] as NSDictionary)
    }

    @objc func ensureAppMenus() {
        installMenusIfNeeded()
        ensureHelpMenu()
    }

    private func refreshAppearanceMenus() {
        themeMenu?.items.forEach { item in
            item.state = keySession?.themeName == item.title ? .on : .off
        }
        fontMenu?.items.forEach { item in
            item.state = keySession?.currentFontFamily.caseInsensitiveCompare(item.title) == .orderedSame ? .on : .off
        }
    }

    private func makeMenu(title: String, items: [(String, Selector, String?)?]) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        let firstResponderSelectors: Set<String> = [
            String(describing: #selector(NSText.copy(_:))),
            String(describing: #selector(NSText.paste(_:))),
            String(describing: #selector(NSText.selectAll(_:))),
            String(describing: #selector(NSWindow.performMiniaturize(_:))),
            String(describing: #selector(NSWindow.performZoom(_:))),
            String(describing: #selector(NSWindow.performClose(_:)))
        ]
        for item in items {
            if let item = item {
                let modifiers: NSEvent.ModifierFlags = (item.2?.count == 1 && item.2?.uppercased() == item.2 && item.2 != "+")
                    ? [.command, .shift]
                    : [.command]
                let menuItem = NSMenuItem(title: item.0, action: item.1, keyEquivalent: item.2?.lowercased() ?? "")
                if item.2 != nil {
                    menuItem.keyEquivalentModifierMask = modifiers
                    if item.2 == "+" {
                        menuItem.keyEquivalent = "="
                        menuItem.keyEquivalentModifierMask = [.command]
                    }
                }
                if firstResponderSelectors.contains(String(describing: item.1)) {
                    menuItem.target = nil
                } else {
                    menuItem.target = self
                }
                menu.addItem(menuItem)
            } else {
                menu.addItem(.separator())
            }
        }
        root.submenu = menu
        return root
    }

    @objc func ensureHelpMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        ensureHelpMenu(in: mainMenu)
    }

    private func ensureHelpMenu(in mainMenu: NSMenu) {
        if let existing = mainMenu.items.first(where: { $0.title == "Help" }) {
            if existing.submenu?.items.contains(where: { $0.title == "About ShuttleTerm" }) != true {
                let about = NSMenuItem(title: "About ShuttleTerm", action: #selector(showAbout(_:)), keyEquivalent: "")
                about.target = self
                existing.submenu?.insertItem(about, at: 0)
            }
            return
        }
        let help = makeMenu(
            title: "Help",
            items: [
                ("About ShuttleTerm", #selector(showAbout(_:)), nil),
                ("ShuttleTerm Help", #selector(showHelp(_:)), "?")
            ]
        )
        hideAutomaticMenuImages(in: help.submenu)
        mainMenu.addItem(help)
    }

    private func hideAutomaticMenuImages(in menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            let dummy = NSImage(size: NSSize(width: 1, height: 1))
            item.image = dummy
            item.image = nil
            item.attributedTitle = nil
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .hidden
            }
            hideAutomaticMenuImages(in: item.submenu)
        }
    }

    @objc func showAbout(_ sender: Any?) {
        ShuttleAboutPanel.shared.show()
    }

    @objc func showHelp(_ sender: Any?) {
        if let helpWindow, helpWindow.isVisible {
            helpWindow.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "ShuttleTerm Help"
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = false
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = Self.helpText
        text.autoresizingMask = [.width, .height]
        text.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = text
        panel.contentView = scroll
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        helpWindow = panel
    }

    private static let helpText = """
    ShuttleTerm
    Menubar and Dock terminal launcher. Hosts: ~/.shuttleterm.json
    About ShuttleTerm (ShuttleTerm menu) tells the origin story and lists licenses.
    App options and the host list live in Settings. Hosts also appear in File
    (after New Window) and in the status item. Run Command is in Terminal;
    Split and Align are in Window. The JSON file is created automatically;
    see examples/shuttleterm.json in the project.

    JSON — global
      "default_theme": "Homebrew"
      "default_font": "Menlo"
      "focus_on_hover": true | false    focus a window when the pointer enters it
      "titlebar": "hover" | "always"    hide the title bar until hover
      "reconnect": true | false         auto-reconnect ssh/mosh/telnet on drop
                                        (not after exit or logout)
      "restore_windows": true | false   reopen terminal windows on launch
                                        coding-agent sessions resume where they left off
      "launch_at_login": true | false
      "lock_after_sleep": true | false  hide terminals after sleep or screen lock
                                        until Touch ID or the Mac password
      "align_grid": "5x4" | "4x3"       cells used by Align Right/Left/Top/Bottom
      "display_size": "full" | "left" | "right"
                                        keep windows on the full screen or one half.
                                        Switching from full keeps current window
                                        positions, then snaps each to an Align-grid
                                        cell. Minimize and resize are off on a half;
                                        swipe pages hidden windows in.
      "startup" hosts open when the app launches
                                        (skipped when restored windows exist)

    Split tiles the open windows using their current screens and positions.
    Align Right, Left, Top, or Bottom stacks windows on that edge of the display.
    Align grid (Settings: 5×4 or 4×3) is how many cells fit in a row or column.
    Align keeps each window’s current relative position.
    Changing Align grid in Settings re-applies Align immediately.
    App display size (status menu, Window menu, or Settings: Full, Left half,
    Right half) limits Align, Split,
    snap, and dragging to that part of the screen. Switching from Full to a half
    keeps each window where it is, then snaps it to an Align-grid cell (full-screen
    cell size). Minimize and resize are off; drag the title bar to move. Windows
    already in that half stay put, and the rest stay hidden until a two-finger
    swipe (or Shift+wheel) pages them in. Dots overlay the bottom of a window
    while you swipe. On a half, Align uses full-screen cell sizes so the strip
    is wider than the half.
    Full-screen coding-agent sessions fill the window (inner padding is
    removed while they run).

    JSON — per host
      "name", "cmd", "after", "theme", "font"
      "startup": true
      "reconnect": true | false

    JSON — groups
      Wrap hosts in a named array to split the menubar into submenus:
      { "Work": [ { "name": "...", "cmd": "..." } ] }
      Settings: Add Group, or set Group in the host editor.

    Mouse
      Drag the top bar to move the window
      Drag below the bar to select     Double-click a word     Triple-click a line
      Right-click Copy / Paste
      ⌘N new terminal window
      ⌘C copy    ⌘V paste    ⌘A select all
      ⌘F find    ⌘G find next
      Reconnecting: Ctrl-C cancels, twice closes the window
      Otherwise Ctrl-C goes to the remote app (ssh/shell)

    Attention
      An unfocused session that needs input badges the Dock and shows a
      notification with the host name and “Action required”.
      Hover the window, click Close, or focus it to dismiss.
      Dock badge: System Settings → Notifications → ShuttleTerm → Badge App Icon.

    Each host opens in its own window (File menu or the status item).
    Split lists only counts that match the number of open windows.
    Align and App Display Size are in the Window menu and the status menu, just after Split.
    Each window has its own font and background (View → Theme / Font).
    """

    @objc private func cutSelection(_ sender: Any?) {
        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: sender)
    }

    @objc private func copySelection(_ sender: Any?) {
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
    }

    @objc private func pasteClipboard(_ sender: Any?) {
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    @objc private func applyThemeFromMenu(_ sender: NSMenuItem) {
        keySession?.applyThemeNamed(sender.title)
        refreshAppearanceMenus()
    }

    @objc private func applyFontFromMenu(_ sender: NSMenuItem) {
        keySession?.applyFontNamed(sender.title)
        refreshAppearanceMenus()
    }

    @objc private func findInTerminal(_ sender: Any?) {
        keySession?.focusFind()
    }

    @objc private func findNext(_ sender: Any?) {
        if keySession == nil { return }
        keySession?.findNext()
    }

    @objc private func findPrevious(_ sender: Any?) {
        keySession?.findPrevious()
    }

    @objc private func biggerFont(_ sender: Any?) {
        keySession?.biggerFont()
    }

    @objc private func smallerFont(_ sender: Any?) {
        keySession?.smallerFont()
    }

    @objc private func clearScrollback(_ sender: Any?) {
        keySession?.clearScrollback()
    }
}

private final class WorkspacePageDotsView: NSView {
    static let dot: CGFloat = 8
    static let gap: CGFloat = 9
    static let padX: CGFloat = 12
    static let padY: CGFloat = 8

    var pageCount = 1 {
        didSet { needsDisplay = true }
    }
    var currentPage = 0 {
        didSet { needsDisplay = true }
    }
    var onSelect: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?

    static func size(for count: Int) -> NSSize {
        let n = CGFloat(max(count, 1))
        return NSSize(
            width: padX * 2 + n * dot + max(n - 1, 0) * gap,
            height: padY * 2 + dot
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let inner = max(bounds.width - Self.padX * 2, 1)
        let idx = Int(((x - Self.padX) / inner) * CGFloat(max(pageCount, 1)))
        onSelect?(min(max(idx, 0), pageCount - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.42).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        for index in 0..<max(pageCount, 1) {
            let x = Self.padX + CGFloat(index) * (Self.dot + Self.gap)
            let y = (bounds.height - Self.dot) / 2
            let rect = NSRect(x: x, y: y, width: Self.dot, height: Self.dot)
            let dot = NSBezierPath(ovalIn: rect)
            if index == currentPage {
                NSColor.white.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.38).setFill()
            }
            dot.fill()
        }
    }
}

struct ShuttleWindowSnapshot: Codable {
    var cmd: String
    var after: String
    var title: String
    var theme: String
    var font: String
    var fontSize: Double
    var reconnect: Bool
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var buffer: String
    var grokSessionId: String?
    var grokCwd: String?
    var agentKind: String?

    var frame: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }
}

enum ShuttleSessionStore {
    static func url() -> URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.shuttleterm.sessions.json")
    }

    static func load() -> [ShuttleWindowSnapshot] {
        guard let data = try? Data(contentsOf: url()),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.windows
    }

    static func save(_ windows: [ShuttleWindowSnapshot]) {
        let file = File(windows: windows)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(file) {
            try? data.write(to: url(), options: .atomic)
        }
    }

    private struct File: Codable {
        var windows: [ShuttleWindowSnapshot]
    }
}
