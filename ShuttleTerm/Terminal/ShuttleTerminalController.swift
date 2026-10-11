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
    private var spaceRestackWork: DispatchWorkItem?

    private override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
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
        let open = sessions.filter { $0.window.isVisible }
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
        alignWindows(lastAlignEdge ?? .right, raise: false)
        ShuttleSettingsPanel.shared.bringToFrontIfOpen()
    }

    @objc func persistOpenWindows() {
        persistWork?.cancel()
        persistWork = nil
        guard restoreWindows else { return }
        let snaps = sessions.filter { $0.window.isVisible }.map { $0.snapshot() }
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
    }

    func sessionDidClose(_ session: ShuttleTerminalSession) {
        rememberWindowSize(session.window.frame.size)
        ShuttleAttention.shared.clear(session)
        sessions.removeAll { $0 === session }
        if keySession === session {
            keySession = sessions.last
        }
        refreshSplitMenus()
        persistOpenWindows()
    }

    func session(attentionId: String) -> ShuttleTerminalSession? {
        sessions.first { $0.attentionId == attentionId }
    }

    func rememberWindowSize(_ size: NSSize) {
        guard size.width >= 360, size.height >= 180 else { return }
        lastWindowSize = size
    }

    @objc var visibleWindowCount: Int {
        sessions.filter { $0.window.isVisible }.count
    }

    @objc func attachMenubarSplitMenu(_ menu: NSMenu) {
        menu.delegate = self
        menubarSplitMenu = menu
        fillSplitMenu(menu)
    }

    @objc func attachMenubarAlignMenu(_ menu: NSMenu) {
        fillAlignMenu(menu)
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

    @objc func alignFromMenu(_ sender: NSMenuItem) {
        guard let edge = AlignEdge(rawValue: sender.tag) else { return }
        alignWindows(edge)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Split" {
            fillSplitMenu(menu)
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
        let screen = tiles[0].window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var union = tiles[0].window.frame
        for session in tiles.dropFirst() {
            union = union.union(session.window.frame)
        }
        union = union.intersection(screen)
        let minW = max(360, screen.width * ShuttleWindowChrome.snapWidthFraction)
        let minH = max(180, screen.height * ShuttleWindowChrome.snapHeightFraction)
        if union.width < minW || union.height < minH {
            union = screen
        }
        let sorted = sortVisual(tiles)
        let (cols, rows) = gridForUnion(count: sorted.count, union: union)
        let gap: CGFloat = 4
        let cellW = (union.width - gap * CGFloat(cols + 1)) / CGFloat(max(cols, 1))
        let cellH = (union.height - gap * CGFloat(rows + 1)) / CGFloat(max(rows, 1))
        for (index, session) in sorted.enumerated() {
            let col = index % cols
            let row = index / cols
            let x = union.minX + gap + CGFloat(col) * (cellW + gap)
            let y = union.maxY - gap - CGFloat(row + 1) * cellH - CGFloat(row) * gap
            session.tile(in: NSRect(x: x, y: y, width: max(cellW, 120), height: max(cellH, 80)))
        }
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
            $0.window.isVisible && !$0.window.isMiniaturized && !$0.window.styleMask.contains(.fullScreen)
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
            for session in open {
                session.window.orderFrontRegardless()
            }
            (keySession ?? open.last)?.makeKeyAndOrderFront()
        }
        schedulePersist()
    }

    private func alignGroup(_ tiles: [ShuttleTerminalSession], edge: AlignEdge) {
        guard !tiles.isEmpty else { return }
        let screen = tiles[0].window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let (cols, rows) = alignGridSize()
        let ordered = orderForAlign(tiles, edge: edge, cols: cols, rows: rows)
        for (index, session) in ordered.enumerated() {
            let frame = alignFrame(vis: vis, cols: cols, rows: rows, index: index, edge: edge)
            session.tile(in: frame, reveal: false)
        }
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
        if let size = sizeForNewWindow() {
            var frame = window.frame
            frame.size = size
            window.setFrame(frame, display: false)
        }
        rememberWindowSize(window.frame.size)
        let offset = CGFloat(sessions.count) * 22
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let screen {
            var origin = NSPoint(
                x: screen.minX + 80 + offset,
                y: screen.maxY - window.frame.height - 80 - offset
            )
            if origin.x + window.frame.width > screen.maxX {
                origin.x = screen.maxX - window.frame.width
            }
            if origin.y < screen.minY {
                origin.y = screen.minY
            }
            window.setFrameOrigin(origin)
        }
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
        windowMenu.submenu?.addItem(.separator())
        windowMenu.submenu?.addItem(splitRoot)
        windowMenu.submenu?.addItem(alignRoot)

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
      "startup" hosts open when the app launches
                                        (skipped when restored windows exist)

    Split tiles the open windows using their current screens and positions.
    Align Right, Left, Top, or Bottom stacks windows on that edge of the display.
    Align grid (Settings: 5×4 or 4×3) is how many cells fit in a row or column.
    Align keeps each window’s current relative position.
    Changing Align grid in Settings re-applies Align immediately.
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
      An unfocused session that needs input badges the Dock and shows a banner
      with the host name and “Action required”.
      Click the banner or focus the window to clear it.
      Dock badge: System Settings → Notifications → ShuttleTerm → Badge App Icon.

    Each host opens in its own window (File menu or the status item).
    Split lists only counts that match the number of open windows.
    Align is in the Window menu and the status menu, just after Split.
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
