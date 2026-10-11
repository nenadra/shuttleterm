//
//  ShuttleTermView.swift
//  ShuttleTerm
//

import AppKit

final class ShuttleTermView: LocalProcessTerminalView {
    var titlebarChromeCapturesMouse = true
    var interceptCtrlC: (() -> Bool)?
    var onHostOutput: ((ArraySlice<UInt8>) -> Void)?
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    private var chromeDragActive = false
    private var lastCtrlCUptime: TimeInterval = 0

    func setChromeDragActive(_ active: Bool) {
        chromeDragActive = active
        if active {
            selection.active = false
            setNeedsDisplay(bounds)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if shouldCaptureTitlebar(event) {
            chromeDragActive = true
            selection.active = false
            setNeedsDisplay(bounds)
            if event.clickCount < 2, let window {
                if let session = window.delegate as? ShuttleTerminalSession {
                    session.beginChromeDrag(with: event)
                } else {
                    ShuttleWindowChrome.snapForDrag(window)
                    window.performDrag(with: event)
                }
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        chromeDragActive = false
        let appWantsMouse = allowMouseReporting && getTerminal().mouseMode != .off
        if event.clickCount >= 3, !appWantsMouse {
            selectLine(at: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if chromeDragActive || shouldCaptureTitlebar(event) {
            selection.active = false
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if chromeDragActive || shouldCaptureTitlebar(event) {
            chromeDragActive = false
            return
        }
        super.mouseUp(with: event)
        if event.clickCount != 1 || event.modifierFlags.contains(.shift) {
            return
        }
        if allowMouseReporting, getTerminal().mouseMode != .off {
            return
        }
        let hit = calculateMouseHit(with: event).grid
        if let url = implicitURL(at: hit) {
            requestOpenLink(source: self, link: url, params: [:])
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if chromeDragActive || shouldCaptureTitlebar(event) {
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if chromeDragActive || shouldCaptureTitlebar(event) {
            return
        }
        super.mouseEntered(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hideNativeScroller()
    }

    override func layout() {
        super.layout()
        hideNativeScroller()
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: caretStyleForKeyWindow())
    }

    func syncCaretToKeyWindow() {
        cursorStyleChanged(source: getTerminal(), newStyle: caretStyleForKeyWindow())
    }

    private func caretStyleForKeyWindow() -> CursorStyle {
        (window?.isKeyWindow == true) ? .blinkUnderline : .steadyUnderline
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onHostOutput?(slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }

    override func keyDown(with event: NSEvent) {
        if isCtrlC(event) {
            if interceptCtrlC?() == true {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastCtrlCUptime < 0.85 {
                    lastCtrlCUptime = 0
                    window?.performClose(nil)
                    return
                }
                lastCtrlCUptime = now
                return
            }
        }
        let isDelete = event.keyCode == 51 || event.keyCode == 117
            || event.charactersIgnoringModifiers == "\u{7f}"
            || event.charactersIgnoringModifiers == "\u{8}"
        if isDelete, deleteActiveSelection() {
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(deleteBackward(_:)) || selector == #selector(deleteForward(_:)) {
            if deleteActiveSelection() {
                return
            }
        }
        super.doCommand(by: selector)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let cutItem = menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
        cutItem.target = self
        cutItem.isEnabled = selection.active
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = selection.active
        let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(.separator())
        let selectAllItem = menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        return menu
    }

    @objc func cut(_ sender: Any?) {
        if selection.active {
            copy(sender as Any)
            if !deleteActiveSelection() {
                selection.active = false
                setNeedsDisplay(bounds)
            }
        }
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "mailto"].contains(scheme) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
        }
    }

    override func resetCursorRects() {
        let chrome = titlebarChromeRect()
        if chrome.isNull || chrome.isEmpty {
            addCursorRect(bounds, cursor: .iBeam)
            return
        }
        addCursorRect(chrome, cursor: .arrow)
        let text = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, chrome.minY - bounds.minY)
        )
        if text.height > 0 {
            addCursorRect(text, cursor: .iBeam)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if titlebarChromeRect().contains(location) {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private let titlebarChromeHeight: CGFloat = 30

    private func isCtrlC(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
            return false
        }
        if event.keyCode == 8 { return true }
        if event.charactersIgnoringModifiers?.lowercased() == "c" { return true }
        if event.characters == "\u{3}" { return true }
        return false
    }

    private func shouldCaptureTitlebar(_ event: NSEvent) -> Bool {
        guard titlebarChromeCapturesMouse else { return false }
        if event.modifierFlags.contains(.command) { return false }
        return titlebarChromeRect().contains(convert(event.locationInWindow, from: nil))
    }

    private func titlebarChromeRect() -> NSRect {
        guard let content = window?.contentView else { return .null }
        let chromeInContent = NSRect(
            x: content.bounds.minX,
            y: content.bounds.maxY - titlebarChromeHeight,
            width: content.bounds.width,
            height: titlebarChromeHeight
        )
        return bounds.intersection(convert(chromeInContent, from: content))
    }

    @discardableResult
    func deleteActiveSelection() -> Bool {
        guard selection.active else { return false }
        let term = getTerminal()
        let (first, last) = orderedSelection()
        let cursorRow = term.buffer.yBase + term.buffer.y
        let cursorCol = term.buffer.x
        guard first.row <= cursorRow, last.row <= cursorRow, last.row >= cursorRow - 1 else {
            return false
        }

        let raw = selection.getSelectedText()
        let body = raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let count = body.count
        guard count > 0 else { return false }

        let endCol = min(last.col + 1, term.cols)
        let delta = (last.row - cursorRow) * term.cols + (endCol - cursorCol)
        if delta > 0 {
            for _ in 0..<delta { sendKeyRight() }
        } else if delta < 0 {
            for _ in 0..<(-delta) { sendKeyLeft() }
        }
        for _ in 0..<count {
            send([0x7f])
        }
        selection.active = false
        setNeedsDisplay(bounds)
        return true
    }

    private func hideNativeScroller() {
        for view in subviews where view is NSScroller {
            view.isHidden = true
            view.alphaValue = 0
        }
    }

    private func implicitURL(at position: Position) -> String? {
        if payloadString(at: position) != nil {
            return nil
        }
        let term = getTerminal()
        let line = lineString(position.row, term: term)
        guard position.col >= 0, position.col < line.count else { return nil }
        let pattern = #"https?://[^\s<>"'\\]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        for match in matches where NSLocationInRange(position.col, match.range) {
            var url = nsLine.substring(with: match.range)
            while let last = url.last, ".,);]".contains(last) {
                url.removeLast()
            }
            return url.isEmpty ? nil : url
        }
        return nil
    }

    private func selectLine(at event: NSEvent) {
        let hit = calculateMouseHit(with: event).grid
        let term = getTerminal()
        let lastRow = max(0, term.buffer.lines.count - 1)
        let row = min(max(hit.row, 0), lastRow)
        let startCol = contentStartColumn(row: row, term: term)
        let endCol = lastContentColumn(row: row, term: term)

        selection.setSelection(
            start: Position(col: startCol, row: row),
            end: Position(col: endCol, row: row)
        )
        selection.selectionMode = .character
        setNeedsDisplay(bounds)
    }

    private func orderedSelection() -> (Position, Position) {
        if Position.compare(selection.start, selection.end) == .after {
            return (selection.end, selection.start)
        }
        return (selection.start, selection.end)
    }

    private func contentStartColumn(row: Int, term: Terminal) -> Int {
        if let semantic = firstNonPromptColumn(row: row, term: term) {
            return semantic
        }
        return promptPrefixLength(lineString(row, term: term))
    }

    private func firstNonPromptColumn(row: Int, term: Terminal) -> Int? {
        let buffer = term.displayBuffer
        guard row >= 0, row < buffer.lines.count else { return nil }
        let line = buffer.lines[row]
        var sawPrompt = false
        var first: Int?
        for col in 0..<term.cols {
            switch line[col].semanticContent {
            case .prompt:
                sawPrompt = true
            default:
                if first == nil {
                    first = col
                }
                if sawPrompt {
                    return col
                }
            }
        }
        return sawPrompt ? first : nil
    }

    private func lastContentColumn(row: Int, term: Terminal) -> Int {
        var last = max(term.cols - 1, 0)
        while last > 0 {
            if let ch = term.getCharacter(col: last, row: row), !ch.isWhitespace, ch != "\0" {
                break
            }
            last -= 1
        }
        return last
    }

    private func lineString(_ row: Int, term: Terminal) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(term.cols)
        for col in 0..<term.cols {
            chars.append(term.getCharacter(col: col, row: row) ?? " ")
        }
        return String(chars)
    }

    private func promptPrefixLength(_ line: String) -> Int {
        let patterns = [
            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[^\n]{0,80}?!#[ \t]*"#,
            #"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+[^\n]{0,80}?[#$%>❯➜][#%!]?[ \t]+"#,
            #"^[%$#❯➜][ \t]+"#
        ]
        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return line.distance(from: line.startIndex, to: range.upperBound)
            }
        }
        return 0
    }
}
