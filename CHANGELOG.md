# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Settings: App display size (Full, Left half, Right half); half mode keeps Align, Split, and dragging on that side. The layout is full-screen wide, only the half is visible, and a two-finger swipe pages through it with navigation dots at the bottom
- App Display Size in the status menu and Window menu (Full, Left half, Right half)
- Half-screen mode sizes each window to an Align grid cell and turns off minimize and resize

### Changed
- Attention banners look like system notifications, with a close button; hovering the waiting window dismisses them

### Fixed
- Attention banners and Notification Center items show as soon as a waiting terminal needs a response
- Half-screen mode hides overflow windows until a swipe brings them in; they no longer stack on the visible half
- Switching App display size from Full to Left/Right half keeps each window’s current position

## [1.0.0] - 2026-10-12

First release of ShuttleTerm: a macOS menubar launcher with a built-in terminal.

### Added
- Built-in terminal (SwiftTerm); hosts open in ShuttleTerm windows
- Hosts in File (after New Window) and in the status item
- Settings for hosts, groups, theme, font, Align grid, launch at login, restore windows, and lock after sleep
- Split 2…20 and Align Right / Left / Top / Bottom (5×4 or 4×3 grid)
- Per-window and default theme and font
- SSH/mosh/telnet reconnect, per-host `after` and `startup`, Run Command…
- Hover title bar, focus on hover, Copy/Paste and Find
- Session restore keeps window layout and resumes a coding-agent TUI only when it was still running in that window
- Attention: one banner per window that needs a response; Dock badge is that count (host name and “Action required”)
- Optional lock after sleep or screen lock (Touch ID or Mac password)
- About 1.0.0; English UI; MIT licenses for Shuttle, SwiftTerm, and LaunchAtLoginController
