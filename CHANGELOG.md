# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

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
