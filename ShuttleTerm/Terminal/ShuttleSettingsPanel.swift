//
//  ShuttleSettingsPanel.swift
//  ShuttleTerm
//

import AppKit

@objc(ShuttleSettingsPanel)
final class ShuttleSettingsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    @objc static let shared = ShuttleSettingsPanel()

    private var window: NSWindow?
    private let launchAtLogin = LaunchAtLoginController()
    private var launchCheckbox: NSButton!
    private var titlebarCheckbox: NSButton!
    private var focusCheckbox: NSButton!
    private var reconnectCheckbox: NSButton!
    private var restoreCheckbox: NSButton!
    private var lockCheckbox: NSButton!
    private var themePopup: NSPopUpButton!
    private var fontPopup: NSPopUpButton!
    private var alignGridPopup: NSPopUpButton!
    private var displaySizePopup: NSPopUpButton!
    private var hostTable: NSTableView!
    private var hostPlaceholder: NSTextField!
    private var minusButton: NSButton!
    private var selectedPath: [Int]?
    private var rows: [HostListRow] = []
    private var editor: HostEditorSheet?

    @objc static func migrateConfigIfNeeded() {
        _ = ShuttleHostStore.loadJSON()
    }

    /// Above ShuttleTerm windows while this app is active; `.normal` when
    /// another app is in front so Settings does not cover Chrome, Calendar, …
    private static let activeLevel: NSWindow.Level = .modalPanel

    @objc func bringToFrontIfOpen() {
        guard let window, window.isVisible else { return }
        applyWindowLevel()
        window.orderFrontRegardless()
    }

    @objc func syncDisplaySizeControl() {
        guard window != nil else { return }
        displaySizePopup.selectItem(
            withTitle: displaySizeTitle(ShuttleTerminalController.shared.displaySize)
        )
    }

    @objc func show() {
        ShuttleAppLock.shared.performWhenUnlocked { [weak self] in
            self?.showNow()
        }
    }

    @objc func hideIfOpen() {
        window?.orderOut(nil)
        editor?.hide()
    }

    private func showNow() {
        if window == nil {
            buildWindow()
        }
        loadFromJSON()
        reloadHostList()
        guard let window else { return }
        ShuttleTerminalController.shared.activateApplication()
        window.collectionBehavior = [.managed, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        applyWindowLevel()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func appActiveStateChanged(_ notification: Notification) {
        applyWindowLevel()
    }

    private func applyWindowLevel() {
        let level: NSWindow.Level = NSApp.isActive ? Self.activeLevel : .normal
        window?.level = level
        editor?.applyLevel(level)
    }

    private func buildWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 770),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.isReleasedWhenClosed = false
        panel.level = NSApp.isActive ? Self.activeLevel : .normal
        panel.collectionBehavior = [.managed, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appActiveStateChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appActiveStateChanged),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        launchCheckbox = checkbox("Launch at login", #selector(changed))
        titlebarCheckbox = checkbox("Hide title bar until hover", #selector(changed))
        focusCheckbox = checkbox("Focus window on hover", #selector(changed))
        reconnectCheckbox = checkbox("Reconnect SSH when it drops", #selector(changed))
        restoreCheckbox = checkbox("Reopen terminal windows on launch", #selector(changed))
        lockCheckbox = checkbox("Lock terminals after sleep or screen lock", #selector(lockSettingChanged))

        themePopup = popup(ShuttleTerminalTheme.paletteNames, #selector(changed))
        fontPopup = popup(ShuttleTerminalTheme.installedFontNames(), #selector(changed))
        alignGridPopup = popup(["5 × 4", "4 × 3"], #selector(changed))
        displaySizePopup = popup(["Full", "Left half", "Right half"], #selector(changed))

        stack.addArrangedSubview(launchCheckbox)
        stack.addArrangedSubview(titlebarCheckbox)
        stack.addArrangedSubview(focusCheckbox)
        stack.addArrangedSubview(reconnectCheckbox)
        stack.addArrangedSubview(restoreCheckbox)
        stack.addArrangedSubview(lockCheckbox)
        let lockHint = NSTextField(wrappingLabelWithString: "After the Mac sleeps or the screen locks, Touch ID or your Mac password is required before windows are shown again.")
        lockHint.textColor = .secondaryLabelColor
        lockHint.font = NSFont.systemFont(ofSize: 11)
        stack.addArrangedSubview(lockHint)
        stack.addArrangedSubview(labeled("Default theme", themePopup))
        stack.addArrangedSubview(labeled("Default font", fontPopup))
        stack.addArrangedSubview(labeled("Align grid", alignGridPopup))
        stack.addArrangedSubview(labeled("App display size", displaySizePopup))

        let hostsHeader = NSTextField(labelWithString: "Hosts")
        hostsHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(hostsHeader)

        let hostsHint = NSTextField(wrappingLabelWithString: "Click a host to edit it. Assign a group in the host editor to split the menubar list. The switch opens a host at startup.")
        hostsHint.textColor = .secondaryLabelColor
        hostsHint.font = NSFont.systemFont(ofSize: 11)
        stack.addArrangedSubview(hostsHint)

        let listBox = NSView()
        listBox.wantsLayer = true
        listBox.layer?.cornerRadius = 8
        listBox.layer?.borderWidth = 1
        listBox.layer?.borderColor = NSColor.separatorColor.cgColor
        listBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        listBox.translatesAutoresizingMaskIntoConstraints = false

        hostPlaceholder = NSTextField(labelWithString: "No hosts. Click + to add one.")
        hostPlaceholder.textColor = .secondaryLabelColor
        hostPlaceholder.font = NSFont.systemFont(ofSize: 12)
        hostPlaceholder.alignment = .center
        hostPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        column.resizingMask = .autoresizingMask
        hostTable = NSTableView()
        hostTable.headerView = nil
        hostTable.rowHeight = 48
        hostTable.allowsEmptySelection = true
        hostTable.allowsMultipleSelection = false
        hostTable.backgroundColor = .controlBackgroundColor
        hostTable.selectionHighlightStyle = .regular
        hostTable.addTableColumn(column)
        hostTable.delegate = self
        hostTable.dataSource = self
        hostTable.target = self
        hostTable.action = #selector(hostClicked)
        hostTable.doubleAction = #selector(hostClicked)
        hostTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = hostTable
        listBox.addSubview(scroll)
        listBox.addSubview(hostPlaceholder)

        NSLayoutConstraint.activate([
            listBox.heightAnchor.constraint(equalToConstant: 220),
            listBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            scroll.topAnchor.constraint(equalTo: listBox.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
            hostPlaceholder.centerXAnchor.constraint(equalTo: listBox.centerXAnchor),
            hostPlaceholder.centerYAnchor.constraint(equalTo: listBox.centerYAnchor)
        ])
        stack.addArrangedSubview(listBox)
        listBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true

        let plusMinus = NSStackView()
        plusMinus.orientation = .horizontal
        plusMinus.spacing = 1
        let plus = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: self, action: #selector(addHost))
        minusButton = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: self, action: #selector(removeHost))
        for button in [plus, minusButton!] {
            button.bezelStyle = .smallSquare
            button.setButtonType(.momentaryPushIn)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        minusButton.isEnabled = false
        plusMinus.addArrangedSubview(plus)
        plusMinus.addArrangedSubview(minusButton)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 8).isActive = true
        plusMinus.addArrangedSubview(spacer)
        let addGroup = NSButton(title: "Add Group", target: self, action: #selector(addGroupClicked))
        addGroup.bezelStyle = .rounded
        addGroup.font = NSFont.systemFont(ofSize: 12)
        addGroup.controlSize = .small
        plusMinus.addArrangedSubview(addGroup)
        stack.addArrangedSubview(plusMinus)

        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        panel.center()
        window = panel
    }

    private func checkbox(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = NSFont.systemFont(ofSize: 13)
        return button
    }

    private func popup(_ items: [String], _ action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = action
        popup.font = NSFont.systemFont(ofSize: 13)
        return popup
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return row
    }

    @objc private func changed(_ sender: Any?) {
        saveToJSON()
        if isPopup(themePopup, sender: sender) {
            ShuttleTerminalController.shared.applyDefaultTheme(themePopup.titleOfSelectedItem ?? "Pro")
        } else if isPopup(fontPopup, sender: sender) {
            ShuttleTerminalController.shared.applyDefaultFont(fontPopup.titleOfSelectedItem ?? "Menlo")
        } else if isPopup(alignGridPopup, sender: sender) {
            let grid = alignGridPopup.titleOfSelectedItem == "4 × 3" ? "4x3" : "5x4"
            ShuttleTerminalController.shared.applyAlignGrid(grid)
        } else if isPopup(displaySizePopup, sender: sender) {
            ShuttleTerminalController.shared.applyDisplaySize(displaySizeValue())
        }
    }

    private func isPopup(_ popup: NSPopUpButton, sender: Any?) -> Bool {
        if sender as AnyObject? === popup { return true }
        if let item = sender as? NSMenuItem, item.menu === popup.menu { return true }
        return false
    }

    @objc private func addHost() {
        let draft = ShuttleHostLeaf(
            path: [],
            name: "New Host",
            cmd: "ssh user@host",
            after: "",
            theme: "",
            font: "",
            title: "",
            startup: false,
            reconnect: nil,
            group: selectedGroupName()
        )
        openEditor(leaf: draft, isNew: true)
    }

    @objc private func addGroupClicked() {
        guard let name = promptForName(title: "New Group", info: "Hosts in this group appear as a submenu in File and the status menu.", value: "") else {
            return
        }
        if let path = ShuttleHostStore.addGroup(named: name) {
            selectedPath = path
        }
        reloadHostList()
        (NSApp.delegate as? AppDelegate)?.reloadFromJSON()
    }

    @objc private func removeHost() {
        guard let path = selectedPath else { return }
        ShuttleHostStore.remove(at: path)
        selectedPath = nil
        reloadHostList()
        (NSApp.delegate as? AppDelegate)?.reloadFromJSON()
    }

    private func openEditor(leaf: ShuttleHostLeaf, isNew: Bool) {
        editor?.close()
        let sheet = HostEditorSheet(leaf: leaf, isNew: isNew, groups: ShuttleHostStore.groupNames()) { [weak self] result in
            guard let self else { return }
            self.editor = nil
            switch result {
            case .cancel:
                return
            case .save(let updated):
                if isNew {
                    ShuttleHostStore.append(updated)
                } else {
                    ShuttleHostStore.update(updated)
                }
                self.reloadHostList()
                (NSApp.delegate as? AppDelegate)?.reloadFromJSON()
            }
        }
        editor = sheet
        guard let parent = window else { return }
        sheet.show(over: parent)
    }

    @objc private func hostClicked() {
        let row = hostTable.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .group(let name, let path, _):
            selectedPath = path
            minusButton.isEnabled = true
            if NSApp.currentEvent?.clickCount ?? 0 >= 2 {
                renameGroup(named: name, path: path)
            }
        case .host(let leaf):
            if let event = NSApp.currentEvent {
                let point = hostTable.convert(event.locationInWindow, from: nil)
                let rect = hostTable.rect(ofRow: row)
                if point.x > rect.maxX - 52 {
                    return
                }
            }
            selectedPath = leaf.path
            minusButton.isEnabled = true
            openEditor(leaf: leaf, isNew: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let name, _, let indent):
            return GroupRowView(name: name, indent: indent)
        case .host(let leaf):
            let cell = HostRowView(leaf: leaf, indent: max(0, leaf.path.count - 1))
            cell.onToggleStartup = { [weak self] on in
                ShuttleHostStore.setStartup(on, at: leaf.path)
                self?.reloadHostList()
                (NSApp.delegate as? AppDelegate)?.reloadFromJSON()
            }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return 28 }
        return 48
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = hostTable.selectedRow
        guard row >= 0, row < rows.count else {
            selectedPath = nil
            minusButton.isEnabled = false
            return
        }
        selectedPath = rows[row].path
        minusButton.isEnabled = true
    }

    private func reloadHostList() {
        let keep = selectedPath
        rows = ShuttleHostStore.rows()
        hostPlaceholder.isHidden = !rows.isEmpty
        hostTable.reloadData()
        hostTable.sizeLastColumnToFit()
        if let keep, let index = rows.firstIndex(where: { $0.path == keep }) {
            selectedPath = keep
            hostTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            minusButton.isEnabled = true
        } else {
            selectedPath = nil
            minusButton.isEnabled = false
        }
    }

    private func selectedGroupName() -> String {
        guard let path = selectedPath else { return "" }
        for row in rows {
            switch row {
            case .group(let name, let groupPath, _) where groupPath == path:
                return name
            case .host(let leaf) where leaf.path == path:
                return leaf.group
            default:
                continue
            }
        }
        return ""
    }

    private func renameGroup(named current: String, path: [Int]) {
        guard let name = promptForName(title: "Rename Group", info: "This updates the menubar submenu title.", value: current) else {
            return
        }
        ShuttleHostStore.renameGroup(at: path, to: name)
        selectedPath = path
        reloadHostList()
        (NSApp.delegate as? AppDelegate)?.reloadFromJSON()
    }

    private func promptForName(title: String, info: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if let parent = window {
            alert.window.level = parent.level
        }
        let ok = alert.runModal() == .alertFirstButtonReturn
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ok, !name.isEmpty else { return nil }
        return name
    }

    private func configURL() -> URL? {
        let delegate = NSApp.delegate as? AppDelegate
        let path = delegate?.configurationFilePath() ?? NSHomeDirectory() + "/.shuttleterm.json"
        return URL(fileURLWithPath: path)
    }

    private func loadFromJSON() {
        ShuttleHostStore.ensureFile()
        guard let url = configURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            launchCheckbox.state = launchAtLogin.launchAtLogin ? .on : .off
            titlebarCheckbox.state = .on
            reconnectCheckbox.state = .on
            restoreCheckbox.state = .on
            lockCheckbox.state = .off
            alignGridPopup.selectItem(withTitle: "5 × 4")
            displaySizePopup.selectItem(withTitle: "Full")
            return
        }
        launchCheckbox.state = bool(json["launch_at_login"], fallback: launchAtLogin.launchAtLogin) ? .on : .off
        titlebarCheckbox.state = (json["titlebar"] as? String)?.lowercased() == "always" ? .off : .on
        focusCheckbox.state = bool(json["focus_on_hover"], fallback: false) ? .on : .off
        reconnectCheckbox.state = bool(json["reconnect"], fallback: true) ? .on : .off
        restoreCheckbox.state = bool(json["restore_windows"], fallback: true) ? .on : .off
        lockCheckbox.state = bool(json["lock_after_sleep"], fallback: false) ? .on : .off

        if let theme = json["default_theme"] as? String, themePopup.itemTitles.contains(theme) {
            themePopup.selectItem(withTitle: theme)
        }
        if let font = json["default_font"] as? String, fontPopup.itemTitles.contains(font) {
            fontPopup.selectItem(withTitle: font)
        }
        let grid = (json["align_grid"] as? String)?.lowercased() ?? "5x4"
        alignGridPopup.selectItem(withTitle: grid == "4x3" ? "4 × 3" : "5 × 4")
        displaySizePopup.selectItem(withTitle: displaySizeTitle(json["display_size"] as? String))
    }

    private func saveToJSON() {
        let json = ShuttleHostStore.loadJSON()
        json["launch_at_login"] = launchCheckbox.state == .on
        json["titlebar"] = titlebarCheckbox.state == .on ? "hover" : "always"
        json["focus_on_hover"] = focusCheckbox.state == .on
        json["reconnect"] = reconnectCheckbox.state == .on
        json["restore_windows"] = restoreCheckbox.state == .on
        json["lock_after_sleep"] = lockCheckbox.state == .on
        json["default_theme"] = themePopup.titleOfSelectedItem ?? "Pro"
        json["default_font"] = fontPopup.titleOfSelectedItem ?? "Menlo"
        json["align_grid"] = alignGridPopup.titleOfSelectedItem == "4 × 3" ? "4x3" : "5x4"
        json["display_size"] = displaySizeValue()
        json.removeObject(forKey: "terminal")
        json.removeObject(forKey: "iTerm_version")
        ShuttleHostStore.saveJSON(json)
        launchAtLogin.launchAtLogin = launchCheckbox.state == .on
        ShuttleAppLock.shared.isEnabled = lockCheckbox.state == .on
        (NSApp.delegate as? AppDelegate)?.reloadFromJSON()
    }

    @objc private func lockSettingChanged(_ sender: Any?) {
        if lockCheckbox.state == .on, !ShuttleAppLock.canAuthenticate() {
            lockCheckbox.state = .off
            let alert = NSAlert()
            alert.messageText = "A Mac login password is required"
            alert.informativeText = "Set a password in System Settings → Touch ID & Password, then turn this on. Touch ID is used when it is available."
            alert.runModal()
            return
        }
        saveToJSON()
    }

    private func bool(_ value: Any?, fallback: Bool) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return fallback
    }

    private func displaySizeValue() -> String {
        switch displaySizePopup.titleOfSelectedItem {
        case "Left half": return "left"
        case "Right half": return "right"
        default: return "full"
        }
    }

    private func displaySizeTitle(_ value: String?) -> String {
        switch ShuttleWindowChrome.normalizedDisplaySize(value) {
        case "left": return "Left half"
        case "right": return "Right half"
        default: return "Full"
        }
    }
}

struct ShuttleHostLeaf {
    var path: [Int]
    var name: String
    var cmd: String
    var after: String
    var theme: String
    var font: String
    var title: String
    var startup: Bool
    var reconnect: Bool?
    var group: String
}

enum HostListRow {
    case group(name: String, path: [Int], indent: Int)
    case host(ShuttleHostLeaf)

    var path: [Int] {
        switch self {
        case .group(_, let path, _): return path
        case .host(let leaf): return leaf.path
        }
    }
}

enum ShuttleHostStore {
    static let legacyKeys = [
        "editor", "open_in", "iTerm_version", "terminal", "show_ssh_config_hosts",
        "ssh_config_ignore_hosts", "ssh_config_ignore_keywords", "_comments"
    ]
    static let legacyHostKeys = ["inTerminal"]

    static func configURL() -> URL {
        let delegate = NSApp.delegate as? AppDelegate
        let path = delegate?.configurationFilePath() ?? NSHomeDirectory() + "/.shuttleterm.json"
        return URL(fileURLWithPath: path)
    }

    static func ensureFile() {
        let url = configURL()
        if FileManager.default.fileExists(atPath: url.path) { return }
        if let bundled = Bundle.main.url(forResource: "shuttleterm.default", withExtension: "json"),
           let data = try? Data(contentsOf: bundled) {
            try? data.write(to: url, options: .atomic)
            return
        }
        let skeleton: [String: Any] = [
            "launch_at_login": false,
            "default_theme": "Homebrew",
            "default_font": "Menlo",
            "titlebar": "hover",
            "focus_on_hover": false,
            "reconnect": true,
            "restore_windows": true,
            "lock_after_sleep": false,
            "align_grid": "5x4",
            "display_size": "full",
            "hosts": []
        ]
        if let data = try? JSONSerialization.data(withJSONObject: skeleton, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func loadJSON() -> NSMutableDictionary {
        ensureFile()
        let url = configURL()
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? NSMutableDictionary {
            if normalize(json) {
                saveJSON(json)
            }
            return json
        }
        return NSMutableDictionary()
    }

    static func saveJSON(_ json: NSMutableDictionary) {
        _ = normalize(json)
        let url = configURL()
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    @discardableResult
    static func normalize(_ json: NSMutableDictionary) -> Bool {
        var changed = false
        for key in legacyKeys where json.object(forKey: key) != nil {
            json.removeObject(forKey: key)
            changed = true
        }
        if cleanHosts(hostsArray(json)) {
            changed = true
        }
        return changed
    }

    private static func cleanHosts(_ items: NSMutableArray) -> Bool {
        var changed = false
        for case let dict as NSMutableDictionary in items {
            if let nested = groupArray(of: dict) {
                if cleanHosts(nested) {
                    changed = true
                }
            } else if dict["cmd"] != nil || dict["name"] != nil {
                if cleanHost(dict) {
                    changed = true
                }
            }
        }
        return changed
    }

    static func isHost(_ dict: NSDictionary) -> Bool {
        dict["cmd"] != nil && dict["name"] != nil
    }

    static func groupArray(of dict: NSMutableDictionary) -> NSMutableArray? {
        if isHost(dict) { return nil }
        return dict.allValues.first(where: { $0 is NSMutableArray }) as? NSMutableArray
    }

    static func groupTitle(of dict: NSDictionary) -> String? {
        if isHost(dict) { return nil }
        for (key, value) in dict {
            if value is NSArray, let name = key as? String {
                return name
            }
        }
        return nil
    }

    private static func cleanHost(_ dict: NSMutableDictionary) -> Bool {
        var changed = false
        for key in legacyHostKeys where dict.object(forKey: key) != nil {
            dict.removeObject(forKey: key)
            changed = true
        }
        if let title = dict["title"] as? String, let name = dict["name"] as? String, title == name {
            dict.removeObject(forKey: "title")
            changed = true
        }
        if let theme = dict["theme"] as? String,
           let match = ShuttleTerminalTheme.paletteNames.first(where: { $0.caseInsensitiveCompare(theme) == .orderedSame }),
           match != theme {
            dict["theme"] = match
            changed = true
        }
        return changed
    }

    static func hostsArray(_ json: NSMutableDictionary) -> NSMutableArray {
        if let hosts = json["hosts"] as? NSMutableArray {
            return hosts
        }
        let hosts = NSMutableArray()
        json["hosts"] = hosts
        return hosts
    }

    static func rows() -> [HostListRow] {
        let json = loadJSON()
        var result: [HostListRow] = []
        collectRows(from: hostsArray(json), path: [], group: "", indent: 0, into: &result)
        return result
    }

    static func leaves() -> [ShuttleHostLeaf] {
        rows().compactMap {
            if case .host(let leaf) = $0 { return leaf }
            return nil
        }
    }

    static func groupNames() -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func walk(_ items: NSMutableArray) {
            for case let dict as NSMutableDictionary in items {
                guard let nested = groupArray(of: dict), let title = groupTitle(of: dict) else { continue }
                if seen.insert(title).inserted {
                    names.append(title)
                }
                walk(nested)
            }
        }
        walk(hostsArray(loadJSON()))
        return names
    }

    private static func collectRows(
        from items: NSMutableArray,
        path: [Int],
        group: String,
        indent: Int,
        into result: inout [HostListRow]
    ) {
        for (index, item) in items.enumerated() {
            guard let dict = item as? NSMutableDictionary else { continue }
            let itemPath = path + [index]
            if let nested = groupArray(of: dict), let title = groupTitle(of: dict) {
                result.append(.group(name: title, path: itemPath, indent: indent))
                collectRows(from: nested, path: itemPath, group: title, indent: indent + 1, into: &result)
            } else {
                var host = leaf(from: dict, path: itemPath)
                host.group = group
                result.append(.host(host))
            }
        }
    }

    private static func leaf(from dict: NSMutableDictionary, path: [Int]) -> ShuttleHostLeaf {
        ShuttleHostLeaf(
            path: path,
            name: dict["name"] as? String ?? "Host",
            cmd: dict["cmd"] as? String ?? "",
            after: dict["after"] as? String ?? "",
            theme: dict["theme"] as? String ?? "",
            font: dict["font"] as? String ?? "",
            title: dict["title"] as? String ?? "",
            startup: (dict["startup"] as? Bool) ?? (dict["startup"] as? NSNumber)?.boolValue ?? false,
            reconnect: {
                if let flag = dict["reconnect"] as? Bool { return flag }
                if let number = dict["reconnect"] as? NSNumber { return number.boolValue }
                return nil
            }(),
            group: ""
        )
    }

    static func dictionary(at path: [Int], in json: NSMutableDictionary) -> NSMutableDictionary? {
        var current: Any = hostsArray(json)
        var lastDict: NSMutableDictionary?
        for (step, index) in path.enumerated() {
            guard let array = current as? NSMutableArray, index >= 0, index < array.count else { return nil }
            guard let dict = array[index] as? NSMutableDictionary else { return nil }
            lastDict = dict
            if step == path.count - 1 {
                return dict
            }
            if let nested = groupArray(of: dict) {
                current = nested
            } else {
                return nil
            }
        }
        return lastDict
    }

    static func append(_ leaf: ShuttleHostLeaf) {
        let json = loadJSON()
        insert(dictionary(from: leaf), intoGroup: leaf.group, json: json)
        saveJSON(json)
    }

    static func update(_ leaf: ShuttleHostLeaf) {
        let json = loadJSON()
        guard let dict = dictionary(at: leaf.path, in: json) else { return }
        apply(leaf, to: dict)
        let current = parentGroupName(path: leaf.path, json: json)
        let wanted = leaf.group.trimmingCharacters(in: .whitespacesAndNewlines)
        if current != wanted {
            remove(at: leaf.path, in: json)
            insert(dict, intoGroup: wanted, json: json)
        }
        saveJSON(json)
    }

    static func setStartup(_ on: Bool, at path: [Int]) {
        let json = loadJSON()
        guard let dict = dictionary(at: path, in: json) else { return }
        dict["startup"] = on
        saveJSON(json)
    }

    @discardableResult
    static func addGroup(named name: String) -> [Int]? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let json = loadJSON()
        let hosts = hostsArray(json)
        if let existing = topLevelGroupIndex(named: trimmed, in: hosts) {
            return [existing]
        }
        let group = NSMutableDictionary()
        group[trimmed] = NSMutableArray()
        hosts.add(group)
        saveJSON(json)
        return [hosts.count - 1]
    }

    static func renameGroup(at path: [Int], to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !path.isEmpty else { return }
        let json = loadJSON()
        guard let dict = dictionary(at: path, in: json),
              let old = groupTitle(of: dict),
              let nested = groupArray(of: dict),
              old != trimmed else { return }
        if path.count == 1, let other = topLevelGroupIndex(named: trimmed, in: hostsArray(json)), other != path[0] {
            let hosts = hostsArray(json)
            if let otherDict = hosts[other] as? NSMutableDictionary, let otherArray = groupArray(of: otherDict) {
                for object in nested {
                    otherArray.add(object)
                }
                hosts.removeObject(at: path[0])
            }
            saveJSON(json)
            return
        }
        dict.removeObject(forKey: old)
        dict[trimmed] = nested
        saveJSON(json)
    }

    static func remove(at path: [Int]) {
        let json = loadJSON()
        remove(at: path, in: json)
        saveJSON(json)
    }

    private static func remove(at path: [Int], in json: NSMutableDictionary) {
        guard !path.isEmpty else { return }
        let hosts = hostsArray(json)
        if path.count == 1 {
            let index = path[0]
            if index >= 0, index < hosts.count {
                hosts.removeObject(at: index)
            }
            return
        }
        let parentPath = Array(path.dropLast())
        guard let parent = dictionary(at: parentPath, in: json),
              let nested = groupArray(of: parent) else {
            return
        }
        let index = path[path.count - 1]
        if index >= 0, index < nested.count {
            nested.removeObject(at: index)
        }
    }

    private static func insert(_ dict: NSMutableDictionary, intoGroup group: String, json: NSMutableDictionary) {
        let hosts = hostsArray(json)
        let name = group.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            hosts.add(dict)
            return
        }
        if let existing = firstGroupArray(named: name, in: hosts) {
            existing.add(dict)
            return
        }
        let group = NSMutableDictionary()
        group[name] = NSMutableArray(object: dict)
        hosts.add(group)
    }

    private static func parentGroupName(path: [Int], json: NSMutableDictionary) -> String {
        guard path.count >= 2 else { return "" }
        let parentPath = Array(path.dropLast())
        guard let parent = dictionary(at: parentPath, in: json) else { return "" }
        return groupTitle(of: parent) ?? ""
    }

    private static func firstGroupArray(named name: String, in items: NSMutableArray) -> NSMutableArray? {
        for case let dict as NSMutableDictionary in items {
            guard let nested = groupArray(of: dict), let title = groupTitle(of: dict) else { continue }
            if title == name { return nested }
            if let found = firstGroupArray(named: name, in: nested) { return found }
        }
        return nil
    }

    private static func topLevelGroupIndex(named name: String, in items: NSMutableArray) -> Int? {
        for (index, item) in items.enumerated() {
            guard let dict = item as? NSMutableDictionary,
                  groupArray(of: dict) != nil,
                  groupTitle(of: dict) == name else { continue }
            return index
        }
        return nil
    }

    private static func dictionary(from leaf: ShuttleHostLeaf) -> NSMutableDictionary {
        let dict = NSMutableDictionary()
        apply(leaf, to: dict)
        return dict
    }

    private static func apply(_ leaf: ShuttleHostLeaf, to dict: NSMutableDictionary) {
        dict["name"] = leaf.name
        dict["cmd"] = leaf.cmd
        if leaf.after.isEmpty {
            dict.removeObject(forKey: "after")
        } else {
            dict["after"] = leaf.after
        }
        if leaf.theme.isEmpty {
            dict.removeObject(forKey: "theme")
        } else {
            dict["theme"] = leaf.theme
        }
        if leaf.font.isEmpty {
            dict.removeObject(forKey: "font")
        } else {
            dict["font"] = leaf.font
        }
        if leaf.title.isEmpty {
            dict.removeObject(forKey: "title")
        } else {
            dict["title"] = leaf.title
        }
        dict["startup"] = leaf.startup
        if let reconnect = leaf.reconnect {
            dict["reconnect"] = reconnect
        } else {
            dict.removeObject(forKey: "reconnect")
        }
        for key in legacyHostKeys {
            dict.removeObject(forKey: key)
        }
        if let title = dict["title"] as? String, title == leaf.name {
            dict.removeObject(forKey: "title")
        }
    }
}

private final class GroupRowView: NSView {
    init(name: String, indent: Int) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: name)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.refusesFirstResponder = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let inset = CGFloat(12 + indent * 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

private final class HostRowView: NSView {
    var onToggleStartup: ((Bool) -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let startupSwitch = NSSwitch()

    init(leaf: ShuttleHostLeaf, indent: Int = 0) {
        super.init(frame: .zero)
        wantsLayer = true

        nameLabel.stringValue = leaf.name
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.isSelectable = false
        nameLabel.refusesFirstResponder = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = leaf.cmd.isEmpty ? "No command" : leaf.cmd
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isSelectable = false
        detailLabel.refusesFirstResponder = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        startupSwitch.controlSize = .small
        startupSwitch.state = leaf.startup ? .on : .off
        startupSwitch.target = self
        startupSwitch.action = #selector(toggled)
        startupSwitch.translatesAutoresizingMaskIntoConstraints = false
        startupSwitch.toolTip = "Open at startup"

        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(startupSwitch)

        let inset = CGFloat(12 + indent * 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: startupSwitch.leadingAnchor, constant: -8),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: startupSwitch.leadingAnchor, constant: -8),
            startupSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            startupSwitch.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    @objc private func toggled() {
        onToggleStartup?(startupSwitch.state == .on)
    }
}

/// Combo box whose popup list highlights the row under the pointer, like a menu.
private final class GroupComboBox: NSComboBox {
    private var hoverMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private weak var listTable: NSTableView?
    private var hoverRow = -1
    private var poppedIndex = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(listWillPopUp),
            name: NSComboBox.willPopUpNotification,
            object: self
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(listWillDismiss),
            name: NSComboBox.willDismissNotification,
            object: self
        )
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        detachHover()
    }

    @objc private func listWillPopUp() {
        poppedIndex = indexOfSelectedItem
        DispatchQueue.main.async { [weak self] in
            self?.attachHover()
            if self?.listTable == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.attachHover()
                }
            }
        }
    }

    @objc private func listWillDismiss() {
        detachHover()
    }

    private func attachHover() {
        detachHover()
        guard let table = findListTable() else { return }
        listTable = table
        let area = NSTrackingArea(
            rect: table.bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        table.addTrackingArea(area)
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            if event.type == .scrollWheel {
                DispatchQueue.main.async { self?.updateHover() }
            } else {
                self?.updateHover()
            }
            return event
        }
        updateHover()
    }

    private func detachHover() {
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
            self.hoverMonitor = nil
        }
        if let table = listTable, let area = trackingArea {
            table.removeTrackingArea(area)
        }
        trackingArea = nil
        listTable = nil
        hoverRow = -1
    }

    override func mouseMoved(with event: NSEvent) {
        if listTable != nil {
            updateHover()
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if listTable != nil {
            updateHover()
            return
        }
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if let table = listTable {
            hoverRow = -1
            restoreSelection(in: table)
            return
        }
        super.mouseExited(with: event)
    }

    private func updateHover() {
        guard let table = listTable ?? findListTable() else { return }
        listTable = table
        let row = rowUnderMouse(in: table)
        guard row != hoverRow else { return }
        hoverRow = row
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            restoreSelection(in: table)
        }
    }

    private func restoreSelection(in table: NSTableView) {
        if poppedIndex >= 0, poppedIndex < table.numberOfRows {
            table.selectRowIndexes(IndexSet(integer: poppedIndex), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    private func rowUnderMouse(in table: NSTableView) -> Int {
        guard let window = table.window else { return -1 }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = table.convert(inWindow, from: nil)
        guard table.bounds.contains(local) else { return -1 }
        return table.row(at: local)
    }

    private func findListTable() -> NSTableView? {
        if let children = window?.childWindows {
            for child in children {
                if let table = firstTable(in: child.contentView) { return table }
            }
        }
        let selfWindow = window
        for candidate in NSApp.windows where candidate.isVisible && candidate !== selfWindow {
            guard let table = firstTable(in: candidate.contentView), table.numberOfColumns == 1 else { continue }
            let name = candidate.className
            if name.localizedCaseInsensitiveContains("combo") || candidate.styleMask.contains(.borderless) {
                return table
            }
        }
        return nil
    }

    private func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let table = firstTable(in: sub) { return table }
        }
        return nil
    }
}

private final class HostEditorSheet: NSObject, NSWindowDelegate {
    private var finished = false
    enum Result {
        case cancel
        case save(ShuttleHostLeaf)
    }

    private var sheet: NSWindow!
    private var leaf: ShuttleHostLeaf
    private let isNew: Bool
    private let completion: (Result) -> Void
    private var nameField: NSTextField!
    private var groupCombo: GroupComboBox!
    private var cmdView: NSTextView!
    private var afterField: NSTextField!
    private var titleField: NSTextField!
    private var themePopup: NSPopUpButton!
    private var fontPopup: NSPopUpButton!
    private var startupCheckbox: NSButton!
    private var reconnectPopup: NSPopUpButton!
    private let groups: [String]

    init(leaf: ShuttleHostLeaf, isNew: Bool, groups: [String], completion: @escaping (Result) -> Void) {
        self.leaf = leaf
        self.isNew = isNew
        self.groups = groups
        self.completion = completion
        super.init()
        build()
    }

    func applyLevel(_ level: NSWindow.Level) {
        sheet.level = level
    }

    func hide() {
        sheet.orderOut(nil)
    }

    func show(over parent: NSWindow) {
        sheet.level = parent.level
        sheet.isReleasedWhenClosed = false
        let origin = NSPoint(
            x: parent.frame.midX - sheet.frame.width / 2,
            y: parent.frame.midY - sheet.frame.height / 2
        )
        sheet.setFrameOrigin(origin)
        sheet.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        finish(.cancel)
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancel)
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        sheet.orderOut(nil)
        completion(result)
    }

    private func build() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 556),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = isNew ? "Add Host" : "Host"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        nameField = field(leaf.name)
        groupCombo = GroupComboBox()
        groupCombo.completes = true
        groupCombo.hasVerticalScroller = true
        groupCombo.numberOfVisibleItems = 8
        groupCombo.addItems(withObjectValues: groups)
        groupCombo.stringValue = leaf.group
        groupCombo.placeholderString = "None"
        groupCombo.font = NSFont.systemFont(ofSize: 13)
        groupCombo.translatesAutoresizingMaskIntoConstraints = false
        groupCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        afterField = field(leaf.after)
        titleField = field(leaf.title)
        themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        themePopup.addItem(withTitle: "Default")
        themePopup.addItems(withTitles: ShuttleTerminalTheme.paletteNames)
        if !leaf.theme.isEmpty {
            let match = themePopup.itemTitles.first { $0.caseInsensitiveCompare(leaf.theme) == .orderedSame }
            themePopup.selectItem(withTitle: match ?? leaf.theme)
        }
        fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.addItem(withTitle: "Default")
        fontPopup.addItems(withTitles: ShuttleTerminalTheme.installedFontNames())
        if !leaf.font.isEmpty {
            let match = fontPopup.itemTitles.first { $0.caseInsensitiveCompare(leaf.font) == .orderedSame }
            fontPopup.selectItem(withTitle: match ?? leaf.font)
        }
        startupCheckbox = NSButton(checkboxWithTitle: "Open at startup", target: nil, action: nil)
        startupCheckbox.state = leaf.startup ? .on : .off
        reconnectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        reconnectPopup.addItems(withTitles: ["Use app setting", "Always", "Never"])
        if leaf.reconnect == true {
            reconnectPopup.selectItem(withTitle: "Always")
        } else if leaf.reconnect == false {
            reconnectPopup.selectItem(withTitle: "Never")
        }

        let commandBlock = commandEditor(leaf.cmd)
        stack.addArrangedSubview(labeled("Name", nameField))
        stack.addArrangedSubview(labeled("Group", groupCombo))
        stack.addArrangedSubview(commandBlock)
        stack.addArrangedSubview(labeled("After", afterField))
        stack.addArrangedSubview(labeled("Window title", titleField))
        stack.addArrangedSubview(labeled("Theme", themePopup))
        stack.addArrangedSubview(labeled("Font", fontPopup))
        stack.addArrangedSubview(labeled("Reconnect", reconnectPopup))
        stack.addArrangedSubview(startupCheckbox)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSheet))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveSheet))
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        commandBlock.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        sheet = panel
    }

    private func commandEditor(_ value: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let text = scroll.documentView as! NSTextView
        text.string = value
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        cmdView = text

        let label = NSTextField(labelWithString: "Command")
        label.font = NSFont.systemFont(ofSize: 13)
        let col = NSStackView(views: [label, scroll])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    private func field(_ value: String) -> NSTextField {
        let field = NSTextField()
        field.stringValue = value
        field.font = NSFont.systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return field
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    @objc private func cancelSheet() {
        finish(.cancel)
    }

    @objc private func saveSheet() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = cmdView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !cmd.isEmpty else { return }
        var updated = leaf
        updated.name = name
        updated.cmd = cmd
        var group = groupCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if group == "(None)" { group = "" }
        updated.group = group
        updated.after = afterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let theme = themePopup.titleOfSelectedItem ?? "Default"
        updated.theme = theme == "Default" ? "" : theme
        let font = fontPopup.titleOfSelectedItem ?? "Default"
        updated.font = font == "Default" ? "" : font
        updated.startup = startupCheckbox.state == .on
        switch reconnectPopup.titleOfSelectedItem {
        case "Always":
            updated.reconnect = true
        case "Never":
            updated.reconnect = false
        default:
            updated.reconnect = nil
        }
        finish(.save(updated))
    }
}
