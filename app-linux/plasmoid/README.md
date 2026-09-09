# W Dashboard Pomodoro Clock (KDE Plasma widget)

A panel widget that shows **Beijing time** plus the pomodoro phase as plain
wide text — like the macOS menu-bar item (`app-macos/Sources/WDashboardApp/AppDelegate.swift`).

## Why this exists, not just the tray icon

The Linux pomodoro tray icon (`app-linux/src/tray.rs`) uses the
StatusNotifierItem protocol (`ksni`). KDE Plasma's system tray gives every
SNI icon a fixed *square* cell — there's no way to make it wide enough for
`13:45` next to a phase indicator, unlike macOS's `NSStatusItem`, which can
be arbitrarily wide. A native Plasma widget doesn't have that limit, so this
package adds one. The SNI tray icon keeps working exactly as before — this
is purely additive.

## How it talks to the app

`w_dashboard_linux` runs a tiny session-bus service (see the `dbus_service`
module in `tray.rs`):

- Bus name: `dev.wdashboard.Pomodoro`
- Object path: `/dev/wdashboard/Pomodoro`
- Interface: `dev.wdashboard.Pomodoro1`
- `GetState() -> (phase: s, nudging: b)`
- `StartFocus()`, `StartBreak()`, `Stop()` (exposed for other tooling; the
  widget itself is display-only and never calls these — see below)

The widget's QML polls `GetState` once a second via `busctl`, using Plasma's
`executable` data engine — no C++ plugin needed. If it fails (process not
running, or hasn't started the D-Bus service yet), the widget fades to 40%
opacity and shows "w_dashboard: not running" in the tooltip, rather than
silently freezing on stale phase/color forever; it recovers automatically
once a poll succeeds again.

The clock needs no IPC at all: it's computed locally from the system clock
(`Asia/Shanghai` is a fixed UTC+8, no DST — see the note at the top of
`main.qml` for why this is plain JS math rather than Plasma's `time` data
engine), so it stays correct and ticking even while disconnected.

## Install

```sh
cd app-linux/plasmoid
kpackagetool6 -t Plasma/Applet -i dev.wdashboard.pomodoroclock
```

To pick up edits after the first install, use `-u`/`--upgrade` instead of
`-i`:

```sh
kpackagetool6 -t Plasma/Applet -u dev.wdashboard.pomodoroclock
```

## Add it to a panel

Right-click the panel → **Add or Manage Widgets…** → search "W Dashboard" →
drag **W Dashboard Pomodoro Clock** onto the panel.

Display-only — a colored dot + `HH:mm`, no click interaction. Use the SNI
tray icon's menu or the main window to start/stop a session.

## Turning off the old square tray icon

Since this widget covers the same ground, you probably don't want both.
Two ways to do it:

- **Quick, per-session**: right-click the system tray's chevron (˄) →
  **Configure Status and Notification Icons…** → set "W Dashboard"'s
  pomodoro icon to **Hidden**.
- **Permanent, in config**: add `tray_icon = false` under `[pomodoro]` in
  `~/.config/w_dashboard/config.toml`, then restart the app. This skips
  registering the StatusNotifierItem entirely — the D-Bus service (and so
  this widget) keeps working either way.

## Preview without adding it to a panel

```sh
plasmawindowed dev.wdashboard.pomodoroclock
```
