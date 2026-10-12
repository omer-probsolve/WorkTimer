# Work Timer

A menu bar app for logging work time on macOS 14+.

## Features

- **Menu bar timer** — the clock icon turns into a running `1:23:45` while you're tracking.
  Left-click opens the window; right-click gives a quick Start/Stop / Auto Clock-In / Quit menu.
- **Start / stop** from the window, the right-click menu, or a global shortcut.
- **Auto clock-out** — if the timer is running and the Mac has no keyboard/mouse
  activity for *X* minutes (default 10), the session ends at your last activity, so
  idle time isn't counted. The notification has an *"I was working — count idle time"*
  button for meetings away from the desk.
- **Auto clock-in** — after the Mac has been idle (or asleep, or just started), 30 seconds of
  sustained activity clocks you in, back-dated to when you started. The notification has
  *"Not work — discard"* and *"Discard & turn off auto clock-in"* buttons.
  Pressing **Stop** yourself pauses auto clock-in until the next idle period.
- **Auto clock-in on/off switch** for personal time (the menu bar icon becomes a moon while off).
- Today / this week totals, per-day history, delete sessions, CSV export.
- Opens at login (switchable in Settings).

## Shortcuts (changeable in Settings)

| Shortcut | Action |
|---|---|
| ⌃⌥T | Show / hide the window |
| ⌃⌥S | Start / stop the timer |

## Build & install

```bash
./install.sh     # builds, copies to /Applications, launches
./build.sh       # just builds dist/Work Timer.app
```

No special permissions are needed: idle time comes from the system's input-idle counter,
and the shortcuts use the Carbon hotkey API. macOS asks once to allow notifications.

Data lives in `~/Library/Application Support/WorkTimer/sessions.json`.
