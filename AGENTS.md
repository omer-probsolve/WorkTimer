# Work Timer — notes for AI agents

A macOS menu bar app (Swift 5.9, SwiftUI + AppKit, macOS 14+) that logs your work time and
the time Claude Code and Codex agents spend working. See `README.md` for features.

## Rule: one source of truth

Define every piece of logic, UI component, style, string and constant **once**, and reuse it
everywhere it's needed.

- Before writing something, search for an existing definition (`grep` the type, the format,
  the color, the wording). If one exists, use it. If it almost fits, extend it with a
  parameter instead of copying it.
- When the same thing is about to appear in a second place, move it to the shared home
  listed below first, then use it from both places.
- Never re-derive a number in the UI. Totals, multipliers and "who is working now" come from
  `WorkLog`; the views only display them.
- When you add a new shared piece, add it to the table below in the same change.

| What | Single source |
|---|---|
| Time spans, unions, sums, merging | `Models/Timeline.swift` (`Span`, `[Span]` helpers) |
| Day / week / hour ranges | `DateInterval.of(_:containing:)` in `Models/Timeline.swift` |
| Your sessions and your time | `SessionStore` (`spans(now:)`, `total(in:now:)`) |
| Agent transcript parsing, turn rules, the 5-minute silence rule | `Agents/AgentLog.swift` (`AgentLogState`) |
| Finding and watching transcripts, the parse cache | `Agents/AgentMonitor.swift` |
| Project name for a folder | `Agents/ProjectResolver.swift` |
| All totals: per worker, agent-hours, session, multipliers, concurrency, who's live, table rows | `Store/WorkLog.swift` |
| Data folder location | `Store/AppPaths.swift` |
| Preferences | `Store/AppSettings.swift` |
| Every user-visible number / time / date format, and every `DateFormatter` | `Models/Format.swift` |
| Worker names and colors | `Worker` (`Agents/AgentLog.swift`) and `Worker.color` (`UI/LaneChart.swift`) |
| Timeline axis, lanes, lane styles, track, concurrency chart, multiplier badge | `UI/LaneChart.swift` |
| Totals cards, card fill colors, `cardBackground()`, tooltip copy (`Explain`), agent card text | `UI/StatCard.swift` |
| Live markers (breathing dot, dot slot, live edge) | `UI/LiveIndicators.swift` |
| Session editor, CSV export box, settings form | `UI/SharedViews.swift` |

## Layout

- `Sources/WorkTimer/Models`, `Store`, `Agents`: data and logic. Keep these free of SwiftUI
  and AppKit so they can be shared with other platforms later (see below).
- `Sources/WorkTimer/System`: macOS integration (idle detection, hotkeys and `KeyCombo`, login item,
  notifications, auto clock-in/out in `TimeTracker`).
- `Sources/WorkTimer/UI`: the menu bar item (`StatusItemController`), the popover
  (`GlanceView`), the dashboard window (`DashboardView`, `DashboardWindowController`) and
  the shared components listed above.

## Build and run

```bash
swift build                 # debug build
./build.sh                  # release app bundle in dist/
./install.sh                # build, install to /Applications, relaunch
```

To try a debug build next to the installed app without touching real data:

```bash
WORKTIMER_DATA_DIR=/path/to/scratch .build/debug/WorkTimer
```

Debug builds also render their own windows to PNGs in the data folder when they receive the
`com.omershaashua.worktimer.debugSnapshot` distributed notification (`userInfo` keys:
`window=glance`, `grouping`, `period`, `step`, `filter`, `appearance`). Use it to check
layout without Screen Recording permission.

## Conventions

- Match the surrounding code: short doc comments on types and non-obvious functions,
  explaining *why*; no comments that restate the code.
- UI copy is sentence case. Durations show as `Format.clock(_, seconds: false)` ("1:05").
- Don't block the main thread with file I/O; `AgentMonitor` parses on its own queue.

## Other platforms

The macOS app uses SwiftUI, AppKit, Carbon (hotkeys), CoreServices (file watching) and
Combine (`ObservableObject`), none of which exist on Windows or Linux. The parsing and the
time math (`Timeline`, `AgentLog`, `ProjectResolver`) are plain Foundation. `WorkLog` and
`SessionStore` hold that logic too, but are `ObservableObject`s. Porting means first moving the
platform-free parts into a separate `WorkTimerCore` library target, then building each
platform's UI on top of it. Don't fork the logic per platform.
