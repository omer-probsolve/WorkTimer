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
  `WorkMetrics` (via `WorkLog.metrics` in the macOS app); the views only display them.
- Logic that isn't tied to a platform belongs in `WorkTimerCore`, never in an app target.
- When you add a new shared piece, add it to the table below in the same change.

| What | Single source |
|---|---|
| Time spans, unions, sums, merging | `WorkTimerCore/Timeline.swift` (`Span`, `[Span]` helpers) |
| Day / week / hour ranges | `DateInterval.of(_:containing:)` in `WorkTimerCore/Timeline.swift` |
| Time per weekday × hour, and its shading levels | `WeekHeatmap`, `[Span].weekHeatmap()` in `WorkTimerCore/Timeline.swift` |
| Your sessions: rules, edits, validation, your time, CSV, the `sessions.json` format | `WorkTimerCore/SessionLog.swift` |
| Agent transcript parsing, turn rules, the 5-minute silence rule and its tool-wait exceptions | `WorkTimerCore/AgentLog.swift` (`AgentLogState`) |
| Finding and reading transcripts, the parse cache | `WorkTimerCore/TranscriptScanner.swift` |
| AI World turns: reading its local database, the turn rules (approval waits, silences), its cache | `WorkTimerCore/AIWorldLog.swift` (`AIWorldTurn`, `AIWorldScanner`) |
| Polling AI World on macOS and publishing its segments | `WorkTimer/Agents/AIWorldMonitor.swift` |
| Project name for a folder | `WorkTimerCore/ProjectResolver.swift` |
| All totals: per worker, agent-hours, session, multipliers, concurrency, who's live, table rows, what was happening at a moment (`Moment`); tooltip copy (`Explain`); agent card text | `WorkTimerCore/WorkMetrics.swift` |
| Every user-visible number / time / date format, and every `DateFormatter` | `WorkTimerCore/Format.swift` |
| Worker names | `Worker` in `WorkTimerCore/AgentLog.swift` |
| Publishing sessions to the macOS UI and saving them | `WorkTimer/Store/SessionStore.swift` |
| Watching transcripts on macOS (FSEvents) and publishing segments | `WorkTimer/Agents/AgentMonitor.swift` |
| Background tasks: which keep an agent working, when one counts as busy (`BackgroundTask`, `TaskActivity`, `TaskActivityTracker`) | `WorkTimerCore/AgentLog.swift` |
| Whether a background task's processes worked since the last check on macOS (CPU, file writes) | `WorkTimer/Agents/TaskProbe.swift` |
| Publishing `WorkMetrics` to the macOS UI | `WorkTimer/Store/WorkLog.swift` |
| Data folder and transcripts home locations | `WorkTimer/Store/AppPaths.swift` |
| Preferences | `WorkTimer/Store/AppSettings.swift` (always through `Host.defaults`, never `UserDefaults.standard`) |
| Starting the app (stores, monitors, hotkeys, windows); the API a host such as Toolbelt uses | `WorkTimer/WorkTimerController.swift` |
| Today's numbers, formatted, for a host's glanceable views (`WorkTimerStats`) | `WorkTimer/Store/WorkTimerStats.swift` |
| Standalone vs hosted, the preferences domain, not running next to Toolbelt | `WorkTimer/Store/Host.swift` (`Host`, `HostCheck`) |
| The shared "Island" look: UI colors (window, ink, card, row, control, hairline, the one accent), corner radii, the spring and Reduce Motion, caps labels, rolling numbers, cards, rows, sections, setting rows, buttons, segmented control | `WorkTimer/UI/IslandTheme.swift` — an identical copy of the file in every MacApp (like `Host.swift`); never edit it here, copy it from the others |
| Work Timer's additions to the theme: track fill, soft chart box, always-dark ink card, icon and link buttons, the row appear transition | `WorkTimer/UI/IslandExtras.swift` |
| Worker colors (data only — chrome uses `IslandTheme.accent`) | `Worker.color` in `WorkTimer/UI/LaneChart.swift` |
| Timeline axis, lanes, lane styles, track, concurrency chart, hover line and card, week heat-map, multiplier badge | `WorkTimer/UI/LaneChart.swift` |
| Totals cards and their shape | `WorkTimer/UI/StatCard.swift` |
| Live markers (breathing dot, dot slot, live edge); use `BreathingDot`, not the theme's `IslandLiveDot`, so the periodic refresh can't restart it | `WorkTimer/UI/LiveIndicators.swift` |
| Session editor, CSV export box, settings form | `WorkTimer/UI/SharedViews.swift` |

## Layout

- `Sources/WorkTimerCore`: platform-free logic, **Foundation only** — no SwiftUI, AppKit,
  Combine or other Apple-only frameworks, so a Windows or Linux app can reuse it. Types are
  `package` access: visible to every target in this package, not a public API.
- `Sources/WorkTimer` (target `WorkTimerKit`): the macOS app as a library, so Toolbelt
  (`../Toolbelt`) can host it. `Sources/WorkTimerApp` is the standalone app's `App.swift`,
  which only starts `WorkTimerController`.
  - `Store`, `Agents`: thin `ObservableObject` wrappers that run the core, publish its results
    and save them. Keep logic out of them.
  - `System`: macOS integration (idle detection, hotkeys and `KeyCombo`, login item,
    notifications, auto clock-in/out in `TimeTracker`).
  - `UI`: the menu bar item (`StatusItemController`), the popover (`GlanceView`), the
    dashboard window (`DashboardView`, `DashboardWindowController`) and the shared
    components listed above.
- `Tests/WorkTimerCoreTests`: tests for the core. Add one when you change parsing or the
  math.

## Build and run

```bash
swift build                 # debug build
swift test                  # core tests
./build.sh                  # release app bundle in dist/
./install.sh                # build, install to /Applications, relaunch
```

To try a debug build next to the installed app without touching real data:

```bash
WORKTIMER_DATA_DIR=/path/to/scratch .build/debug/WorkTimer
```

Add `WORKTIMER_HOME=/path/to/demo` to read transcripts from `/path/to/demo/.claude` and
`/path/to/demo/.codex` instead of your own.

Debug builds also render their own windows to PNGs in the data folder when they receive the
`com.omershaashua.worktimer.debugSnapshot` distributed notification (`userInfo` keys:
`window=glance`, `grouping`, `period`, `step`, `filter`, `hover` (0–1 along the timeline),
`appearance`). Use it to check
layout without Screen Recording permission.

## Conventions

- Match the surrounding code: short doc comments on types and non-obvious functions,
  explaining *why*; no comments that restate the code.
- UI copy is sentence case. Durations show as `Format.clock(_, seconds: false)` ("1:05").
- Don't block the main thread with file I/O; `AgentMonitor` runs the scanner on its own queue.

## Other platforms

A new platform adds an app target next to `WorkTimer` that depends on `WorkTimerCore`, and
supplies only what the core leaves to the platform: UI, idle detection, file watching (call
`TranscriptScanner.scan()` on changes), checking on `pendingTasks` (pass the result to
`segments(taskActivity:)`), hotkeys, notifications and where data is stored. Don't
fork the logic per platform — if the core is missing something, add it to the core.

Known gaps for Windows: transcript locations and `ProjectResolver` assume `/`-separated paths
under the home folder, and the Claude Code / Codex transcript layout there is unverified.
