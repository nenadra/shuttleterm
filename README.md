<img src="icons/shuttleterm-icon.png" width="128" alt="ShuttleTerm">

# ShuttleTerm

A macOS menubar launcher with a built-in terminal. Open saved SSH hosts, local commands, and split grids from the status item or File.

Requires macOS 12 or later and Xcode.

## Install

```
git clone https://github.com/nenadra/shuttleterm.git
cd shuttleterm
./build.sh
cp -R build/ShuttleTerm.app /Applications/
```

On first launch, macOS may ask for permission if a command opens another app, such as your web browser. Ad-hoc signed builds may need a right-click → Open the first time.

## Config

Hosts live in `~/.shuttleterm.json` (created on first run).

```json
{
  "titlebar": "hover",
  "focus_on_hover": false,
  "reconnect": true,
  "default_theme": "Homebrew",
  "default_font": "Menlo",
  "hosts": [
    {
      "name": "prod",
      "cmd": "ssh user@example.com",
      "after": "htop",
      "startup": false,
      "theme": "Dracula",
      "font": "Menlo",
      "reconnect": true
    },
    {
      "Work": [
        {
          "name": "db",
          "cmd": "ssh user@db.example.com"
        }
      ]
    }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `titlebar` | `hover` hides the title bar until the pointer is at the top; `always` keeps it visible |
| `focus_on_hover` | Focus a window when the pointer enters it |
| `reconnect` | Wrap ssh/mosh/telnet/sftp so a drop reconnects |
| `align_grid` | `5x4` or `4x3` — cells used by Align Right/Left/Top/Bottom |
| `lock_after_sleep` | After sleep or screen lock, require Touch ID or the Mac password before showing terminals |
| per-host `theme` / `font` | Each window has its own background and font |
| per-host `after` | Command run after the session starts |
| per-host `startup` | Open this host when the app launches (checkmark in the menu) |
| host group | `{ "Work": [ {host}, … ] }` becomes a menubar submenu; set in Settings |

Settings in the menubar also write these keys. Help → ShuttleTerm Help lists them.

## Terminal

- Double-click selects a word, triple-click a paragraph
- Copy / Paste with ⌘C / ⌘V or the right-click menu
- View → Theme / Font is per window; Settings default theme/font apply to every open window
- Split 2…20 tiles terminals in a grid
- Align Right / Left / Top / Bottom stacks terminals on that edge of the display (Settings: 5×4 or 4×3 grid; keeps current window order; changing the grid re-applies the last Align)
- Hosts are in File (after New Window) and in the status item
- Window title stays the saved server name
- Unfocused sessions that need input show a Dock badge and a banner with the host name and “Action required” (Badge App Icon in System Settings → Notifications → ShuttleTerm)

This project started as an Apple Silicon fork of [Shuttle](https://github.com/fitztrev/shuttle), then added a built-in terminal using [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). Shuttle, SwiftTerm, and LaunchAtLoginController are MIT licensed; the texts ship in the app (About ShuttleTerm) and in `ShuttleTerm/Licenses/`.

## License

[MIT](LICENSE). SwiftTerm’s license is in `Vendor/SwiftTerm/LICENSE`.
