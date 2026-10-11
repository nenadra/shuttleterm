//
//  ShuttleTerminalTheme.swift
//  Shuttle
//
//  Palettes and fonts used by popular terminals (Terminal.app, iTerm, Ghostty, etc).
//

import AppKit

struct ShuttleTerminalTheme {
    let name: String
    let foreground: NSColor
    let background: NSColor
    let caret: NSColor
    let selection: NSColor
    let font: NSFont
    let fontFamily: String

    private static let defaultSize: CGFloat = 12

    static let paletteNames: [String] = [
        "Pro", "Homebrew", "Basic", "Dracula", "Nord", "One Dark",
        "Solarized Dark", "Solarized Light", "Gruvbox Dark", "Catppuccin Mocha",
        "Tokyo Night", "Monokai", "Grass", "Ocean", "Novel", "Man Page",
        "Red Sands", "Silver Aerogel"
    ]

    static let fontNames: [String] = [
        "Menlo", "SF Mono", "Monaco", "JetBrains Mono", "Fira Code", "Hack",
        "Source Code Pro", "Inconsolata", "Cascadia Mono", "IBM Plex Mono",
        "Ubuntu Mono", "Anonymous Pro", "Courier New"
    ]

    static func named(_ raw: String?, fontName: String? = nil, fontSize: CGFloat = defaultSize) -> ShuttleTerminalTheme {
        let key = normalized(raw ?? "Pro")
        let palette = palettes[key] ?? palettes["pro"]!
        let resolved = resolveFont(named: fontName, size: fontSize)
        return ShuttleTerminalTheme(
            name: palette.name,
            foreground: palette.foreground,
            background: palette.background,
            caret: palette.caret,
            selection: palette.selection,
            font: resolved.font,
            fontFamily: resolved.family
        )
    }

    static func resolveFont(named raw: String?, size: CGFloat) -> (font: NSFont, family: String) {
        let clamped = min(max(size, 9), 72)
        let requested = (raw ?? "Menlo").trimmingCharacters(in: .whitespacesAndNewlines)
        if !requested.isEmpty, let font = fontMatching(family: requested, size: clamped) {
            return (font, requested)
        }
        if let menlo = fontMatching(family: "Menlo", size: clamped) {
            return (menlo, "Menlo")
        }
        return (NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular), "SF Mono")
    }

    static func installedFontNames() -> [String] {
        fontNames.filter { isFontInstalled($0) }
    }

    static func isFontInstalled(_ name: String) -> Bool {
        if name.caseInsensitiveCompare("SF Mono") == .orderedSame {
            return true
        }
        return fontMatching(family: name, size: 12) != nil
    }

    private static func fontMatching(family requested: String, size: CGFloat) -> NSFont? {
        if requested.caseInsensitiveCompare("SF Mono") == .orderedSame {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let families = NSFontManager.shared.availableFontFamilies
        if let family = families.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            if let font = NSFontManager.shared.font(withFamily: family, traits: .fixedPitchFontMask, weight: 5, size: size) {
                return font
            }
            if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                return font
            }
            if let members = NSFontManager.shared.availableMembers(ofFontFamily: family),
               let psName = members.first?.first as? String,
               let font = NSFont(name: psName, size: size) {
                return font
            }
        }
        let postscript = [
            requested,
            requested + "-Regular",
            requested.replacingOccurrences(of: " ", with: "")
        ]
        for name in postscript where !name.isEmpty {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return nil
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
    }

    private struct Palette {
        let name: String
        let foreground: NSColor
        let background: NSColor
        let caret: NSColor
        let selection: NSColor
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: 1)
    }

    private static let palettes: [String: Palette] = {
        let entries: [Palette] = [
            Palette(name: "Basic", foreground: rgb(0, 0, 0), background: rgb(255, 255, 255), caret: rgb(0, 0, 0), selection: rgb(179, 215, 255)),
            Palette(name: "Homebrew", foreground: rgb(0, 255, 0), background: rgb(0, 0, 0), caret: rgb(0, 255, 0), selection: rgb(0, 80, 0)),
            Palette(name: "Pro", foreground: rgb(242, 242, 242), background: rgb(16, 16, 16), caret: rgb(0, 255, 0), selection: rgb(70, 70, 70)),
            Palette(name: "Dracula", foreground: rgb(248, 248, 242), background: rgb(40, 42, 54), caret: rgb(255, 121, 198), selection: rgb(68, 71, 90)),
            Palette(name: "Nord", foreground: rgb(216, 222, 233), background: rgb(46, 52, 64), caret: rgb(136, 192, 208), selection: rgb(67, 76, 94)),
            Palette(name: "One Dark", foreground: rgb(171, 178, 191), background: rgb(40, 44, 52), caret: rgb(97, 175, 239), selection: rgb(62, 68, 81)),
            Palette(name: "Solarized Dark", foreground: rgb(131, 148, 150), background: rgb(0, 43, 54), caret: rgb(38, 139, 210), selection: rgb(7, 54, 66)),
            Palette(name: "Solarized Light", foreground: rgb(101, 123, 131), background: rgb(253, 246, 227), caret: rgb(38, 139, 210), selection: rgb(238, 232, 213)),
            Palette(name: "Gruvbox Dark", foreground: rgb(235, 219, 178), background: rgb(40, 40, 40), caret: rgb(250, 189, 47), selection: rgb(60, 56, 54)),
            Palette(name: "Catppuccin Mocha", foreground: rgb(205, 214, 244), background: rgb(30, 30, 46), caret: rgb(245, 194, 231), selection: rgb(49, 50, 68)),
            Palette(name: "Tokyo Night", foreground: rgb(169, 177, 214), background: rgb(26, 27, 38), caret: rgb(122, 162, 247), selection: rgb(41, 46, 66)),
            Palette(name: "Monokai", foreground: rgb(248, 248, 242), background: rgb(39, 40, 34), caret: rgb(249, 38, 114), selection: rgb(73, 72, 62)),
            Palette(name: "Grass", foreground: rgb(255, 240, 165), background: rgb(19, 119, 61), caret: rgb(255, 240, 165), selection: rgb(10, 80, 40)),
            Palette(name: "Ocean", foreground: rgb(255, 255, 255), background: rgb(34, 79, 121), caret: rgb(255, 255, 255), selection: rgb(20, 50, 90)),
            Palette(name: "Novel", foreground: rgb(59, 35, 34), background: rgb(223, 219, 195), caret: rgb(59, 35, 34), selection: rgb(196, 188, 150)),
            Palette(name: "Man Page", foreground: rgb(0, 0, 0), background: rgb(254, 244, 156), caret: rgb(0, 0, 0), selection: rgb(230, 210, 90)),
            Palette(name: "Red Sands", foreground: rgb(215, 201, 170), background: rgb(122, 37, 30), caret: rgb(215, 201, 170), selection: rgb(90, 20, 16)),
            Palette(name: "Silver Aerogel", foreground: rgb(0, 0, 0), background: rgb(146, 146, 146), caret: rgb(0, 0, 0), selection: rgb(180, 180, 180))
        ]
        var map: [String: Palette] = [:]
        for palette in entries {
            map[normalized(palette.name)] = palette
        }
        map["default"] = map["pro"]
        map["onedark"] = map["one dark"]
        map["one-dark"] = map["one dark"]
        map["solarized"] = map["solarized dark"]
        map["gruvbox"] = map["gruvbox dark"]
        map["catppuccin"] = map["catppuccin mocha"]
        map["tokyonight"] = map["tokyo night"]
        map["tokyo-night"] = map["tokyo night"]
        map["manpage"] = map["man page"]
        map["redsands"] = map["red sands"]
        map["silver"] = map["silver aerogel"]
        return map
    }()
}
