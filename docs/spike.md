# Spikes (need a live session; ask before touching one)

Results go here, dated, with the versions used. Until a spike is done the
feature it gates stays as documented below.

## Carried over from minx (2026-10-02, Zed 1.22, min 0.6.0)

- `zed ssh://min.mctest/workbench` connected through the minx stanza; Zed ran
  one ControlMaster (`-o ControlMaster=yes -o ControlPath=…/zed-ssh-session…`),
  downloaded `zed-remote-server-linux-aarch64` from GitHub *inside the box*
  with curl, and ran the server from `/home/.zed_server` (`proxy` and `run`).
- `curl -sI https://zed.dev` from the box: 200.
- VS Code, Cursor and Zed connected to one box at the same time without
  trouble.

These used minx's `min.` prefix and `~/.ssh/minx/authorized_keys`; min-zed
changes only the names (`min-zed.`, `~/.ssh/min-zed/authorized_keys`).

## Z1: Zed remote server pre-fetch — OPEN

Gates `MIN_ZED_PREFETCH` (default 0).

Questions:

1. The exact file Zed looks for in `/home/.zed_server` for a stable build
   (assumed `zed-remote-server-stable-<version>`, e.g. `…-stable-1.22.0`),
   and whether it checks anything beyond presence (size, a version probe).
2. The URL Zed itself fetches for this version and arch (assumed
   `https://github.com/zed-industries/zed/releases/download/v<version>/zed-remote-server-linux-<arch>.gz`),
   and whether the asset is gzip.
3. Whether Zed's installer tolerates a file appearing mid-install (our
   rename vs. its own), or uses a lock we must honour.
4. Whether the pre-fetch saves visible time on first connect.

Procedure: `MIN_ZED_PREFETCH=1 min-zed new` on a scratch project; wait for
`ls -l /home/.zed_server` to show the file; then let Zed connect and check
it did not download again (`ps` in the box during connect; Zed's log). If any
answer differs, fix `FETCH` in `bin/min-zed` or drop the feature.

Result: _not run._

## E1: agent-state notifications — OPEN

Gates nothing (the watch is cheap and silent) but is unverified end to end.

Questions:

1. With Zed connected, `box_in_use` sees the `_proxy`'s
   `min session exec NAME … sshd` process on the host (its ps line, parent).
2. Claude Code run in a Zed terminal in the box fires the loadout's hook
   (user settings in `/home/.claude/settings.json`), and
   `/home/.min-zed/agent-state` changes per event.
3. Claude run through Zed's agent panel (ACP) in a remote project: does it
   run in the box with the same settings, so the same hook fires?
4. `min session exec NAME cat …` while Zed is connected: latency, and no
   interference with Zed's connection.
5. Notification latency (interval 5 s) and that only changes notify;
   osascript notifications appear (Script Editor's permission).

Result: _not run._

## K1: two tools on one box (shared with every min-<client> repo) — OPEN

Per-tool `authorized_keys` dirs, the shared host key under the lock,
concurrent connects from min-zed and another tool, the other tool's `gc`
seeing min-zed's connection as use.

Result: _not run._
