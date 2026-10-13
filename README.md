# Work Timer

A menu bar app for logging work time on macOS 14+.

## Features

- **Menu bar timer** — the clock icon turns into a running `1:23:45` while you're working.
  Left-click opens an at-a-glance window; right-click gives a quick Start/Stop / Auto Clock-In /
  Dashboard / Quit menu.
- **Claude and Codex count as work** — the app reads Claude Code (terminal and the Claude
  desktop app's Code tab) and Codex app transcripts, and keeps your work session going while
  an agent is working, even when you're away from the keyboard (the icon shows ✨).
  For each of You, Claude and Codex you get:
  - **wall clock** — time with at least one session working (parallel sessions count once);
  - **agent-hours** — every session counts (three sessions over one hour = 3h).

  The **session** total is time when you *or* an agent was working.
- **Multipliers** — the badge next to the clock is work logged per hour of *your* time
  (your time plus all agent-hours, divided by your time: 1h of you + 3 agent-hours = 4×).
  Each agent card shows how many of its sessions ran at once on average while it was
  working (one session = 1×, three in parallel = 3×). The dashboard's *Workers* lane charts
  how many workers were active at each moment.
- **Dashboard** — a timeline grouped by worker or by project (the git repo an agent worked in),
  day and week views, totals, and every session. Click a lane or a totals card to filter the
  session list. Whoever is working right now gets a breathing dot and a thin colored edge.
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
- Choose the hours the day timelines show (Settings → Timeline; the whole day by default).
- Edit or delete your sessions (right-click a row in the dashboard), CSV export.
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

The logic lives in the `WorkTimerCore` library (Foundation only, shareable with other
platforms); the macOS app is the `WorkTimer` target. Run its tests with `swift test`.

No special permissions are needed: idle time comes from the system's input-idle counter,
and the shortcuts use the Carbon hotkey API. macOS asks once to allow notifications.

Data lives in `~/Library/Application Support/WorkTimer/sessions.json`.

### How agent time is measured

Transcripts are read from `~/.claude/projects` and `~/.codex/sessions` (incrementally, with
a cache in `agent-cache.json`). A turn runs from your prompt to the agent's final answer;
silences longer than 5 minutes inside a turn (e.g. waiting for a permission prompt) aren't
counted. Subagents are covered by their parent session. Agent work from before the first
launch with this feature only shows on days you also logged time.

The Claude chat tab doesn't write transcripts, so only Claude Code work counts.
