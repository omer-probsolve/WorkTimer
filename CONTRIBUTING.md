# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

[Open an issue](https://github.com/omer-probsolve/WorkTimer/issues) with your macOS version,
what you expected, and what happened. If agent time looks wrong, say which agent (Claude Code
in the terminal, the Claude desktop app, or Codex) and roughly when.

## Making a change

1. Fork the repo and create a branch.
2. Read [`AGENTS.md`](AGENTS.md). It lists where each piece of logic, UI and formatting
   lives, and the rule that each one is defined only once. It's written for AI coding agents
   but applies to everyone.
3. Build and test:

   ```bash
   swift build
   swift test
   ```

   Add a test in `Tests/WorkTimerCoreTests` when you change parsing or the math.
4. To try your build without touching your real data:

   ```bash
   WORKTIMER_DATA_DIR=/tmp/worktimer-dev .build/debug/WorkTimer
   ```

5. Open a pull request that explains what changed and why. Include a screenshot for UI changes.

## Code style

- Platform-free logic goes in `WorkTimerCore` (Foundation only), not in the macOS app target.
- Match the code around you: short doc comments that explain *why*, sentence-case UI copy.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
