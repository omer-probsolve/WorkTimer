# Windows collection and LAN sync

Windows reads Claude Code and Codex transcripts locally using the same Swift core as the Mac.
It keeps normalized history and an outbox even when the Mac is off or on another network.
No cloud sync service is involved. Raw prompts, answers and tool contents are never sent.

## Setup

1. On Windows, install Swift plus Microsoft's C++ tools and Windows SDK, then run
   `./install-windows.ps1` from PowerShell. It builds/tests, bundles runtime DLLs in
   `dist/windows`, and starts the **WorkTimer agent collector** task at user login.
2. Build/install the updated WorkTimer on the Mac, or rebuild Toolbelt against this package.
   In WorkTimer settings → **Windows activity**, enable LAN sync and export the pairing file.
3. Transfer that file explicitly to Windows, then run:

   ```powershell
   ./pair-windows.ps1 -PairingFile C:\path\worktimer-pairing.json
   ```

   If hostname discovery is unavailable, add `-MacHost your-mac.local` or the Mac's current
   LAN IPv4 address. This changes the endpoint, never the certificate pin.
4. Delete the transferred pairing-file copy after import: it contains the pairing credential.
   Keep WorkTimer or Toolbelt running on the Mac to receive uploads. Collection continues
   independently on Windows; uploads retry automatically when both devices share a LAN.

The Mac listens on TCP 48765 and advertises `_worktimer._tcp.local`. It may ask for local
network/firewall access. The installer does not alter either device's firewall.

## Local data and recovery

Windows data lives in `%USERPROFILE%\AppData\Local\WorkTimer`:

- `collector-history.json`: normalized session timing, stable origin ID, revisions and outbox.
- `collector-cache.json`: incremental shared-parser state, including byte offsets.
- `pairing.json`: the explicitly imported Mac identity, certificate pin and credential.

These files stay local. Deleting transcripts does not delete normalized history. Keep the
history file backed up if you need recovery from Windows disk loss. Do not copy the origin
ID to a second independently collecting machine.

The Mac stores pairing/certificate material and `imported-history.json` under its existing
WorkTimer data directory's `lan-sync` folder. Imported intervals feed the existing dashboard,
including historical dates before Mac tracking began, through the same WorkMetrics instance.
Toolbelt starts the same receiver via WorkTimerController. A file lock prevents a second
process from owning the receiver/store concurrently.

Every receiver launch has a new epoch. Windows replays its complete retained history after
a receiver restart or restore. Acknowledgements follow an atomic saved commit; lost replies
are retried safely. Session revisions replace earlier snapshots instead of adding intervals.
Canonical agent/session identities suppress mirrored local transcripts. One paired Windows
origin owns this receiver's imported history; additional Windows computers are not supported
by this initial version.

Live status has a 20-second receiver lease, refreshed only by fresh heartbeats. Leases are
never restored from disk. Durable measured intervals remain after a disconnect; the dashboard
stops extrapolating live activity once the lease expires. Clock skew over 30 seconds suppresses
live status while still allowing historical delivery. UTC epoch milliseconds are used on the
wire; the Mac calendar controls reporting.

To check collection while it is running:

```powershell
./dist/windows/WorkTimerCollector.exe --status
Get-ScheduledTask -TaskName 'WorkTimer agent collector'
```

`--data-dir`, `WORKTIMER_DATA_DIR`, `--home` and `WORKTIMER_HOME` support isolated fixtures.
`--once` performs one local collection pass. Custom `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
must be present in the login task's environment, or launch the collector explicitly with them.
The roots include Codex `sessions` and `archived_sessions`; Claude subagent transcripts and
Codex subagent/guardian records are excluded by the shared timing rules.

## Networking and platform limits

Discovery suggests an endpoint; it never establishes trust. Windows authenticates the pinned
TLS certificate before writing the body containing the credential and normalized history.
Proxies and redirects are disabled. Windows requires an RFC1918 IPv4 destination reached
directly on-link through a physical Ethernet/Wi-Fi interface. The Mac accepts local-link
connections on LAN interface types and checks the peer against the active LAN subnet.
IPv6-only LANs, routed VLANs and VPN sync are intentionally unsupported.

Windows watches files and reconciles periodically, including after missed notifications.
Network delivery runs separately so DNS/TLS delays cannot block collection. Process crashes
release the collector lock, and the login task restarts failures. Malformed local history
fails closed rather than resetting the origin or overwriting data.

Background-task output writes are positive activity evidence and use the shared sustained-work
tracker. CPU-only background work without transcript/output updates cannot yet be identified
reliably on Windows; a stale output file is never proof that its process is alive. Normal
foreground turn/tool timing still uses the shared silence and approval rules.

This version collects native Windows transcripts. It does not start or inspect stopped WSL
distributions. A future WSL collector must use the same core and send normalized results to
the native outbox; it must not introduce separate timing rules.
