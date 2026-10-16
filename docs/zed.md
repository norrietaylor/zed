# Zed guide

## Getting started

1. `just install` (once). It links `min-zed`, installs the `zed` loadout,
   writes `~/.ssh/min-zed.conf` with its Include, and opts in to Zed settings
   sync.
2. `min-zed open PATH` (default `.`): reuses a live min-zed session for PATH,
   else activates one (`min session activate --loadout zed`), prepares it,
   and runs `zed ssh://min-zed.NAME/workbench`.
3. Zed connects over ssh, installs its remote server into `/home/.zed_server`
   (first time per Zed version) and opens `/workbench`, the session's copy of
   your project.

`min-zed new PATH` always makes a fresh session (next free `<dir>-<word>`),
for a second, independent box on the same project. `min-zed attach NAME`
reopens an existing one.

## Reaching a session from Zed directly

Every live session has a stanza, so any of these work once `open` has run
for it at least once:

- Zed's **Open Remote** (`⌃⌘O`): with settings sync on, each session is
  listed by its name (the entry's `nickname`) under host `min-zed.NAME`.
- `zed ssh://min-zed.NAME/workbench` from any terminal.
- `ssh min-zed.NAME` in a terminal, for a plain shell.

Each connect goes through `min-zed _proxy NAME`, which re-pins the session's
host key and re-pushes its public key before starting sshd, so a session that
was destroyed and recreated under the same name just works.

## Settings sync (`ssh_connections`)

`min-zed zed-config` (run by `just install`) makes the `ssh_connections`
entries whose `host` starts with `min-zed.` in `~/.config/zed/settings.json`
exactly the live min-zed sessions; `open`, `attach`, `ssh`, `destroy` and `gc`
keep it that way afterwards. A new entry is

```json
{"host": "min-zed.NAME", "nickname": "NAME", "projects": [{"paths": ["/workbench"]}]}
```

and an entry you already have for a live session is kept exactly as you wrote
it, so options such as `"upload_binary_over_ssh": true` (for a box without
outbound HTTPS) survive. Every other entry and setting is left alone; your
comments are kept, except comments *inside* the `ssh_connections` array,
which are dropped when that array is rewritten. Each write is preceded by a
backup in `~/.local/state/min-zed/backups/` (the newest 20 are kept) and
skipped when nothing would change. `min-zed zed-config --print` shows the
result without writing; `--remove` takes every `min-zed.*` entry out (and the
key itself when only ours were in it).

Settings sync is optional: `zed ssh://` reads `~/.ssh/config`, so Zed reaches
a session without any entry.

## Claude Code notifications (unverified end to end: spike E1)

The `zed` loadout registers a Claude Code hook in the box
(`~/.claude/min-zed-hook.sh`) that writes Claude's state to
`/home/.min-zed/agent-state` as one line, `state epoch message`
(`started`, `working`, `needs-input`, `finished`, `idle`, `clear`).

`min-zed watch` (started in the background by `open`/`attach`/`new`) wakes
every 5 s, looks at the host's process list for sessions that have a live
sshd connection, and for those only runs
`min session exec NAME cat /home/.min-zed/agent-state`. When the state has
changed to `needs-input` or `finished` it posts a macOS notification titled
`min-zed`, subtitle `NAME: needs input` / `NAME: finished`. A box with no
connection is never asked (asking would start a stopped box).

`min-zed watch --stop` stops it; `min-zed status` shows the last state seen.

## Server pre-fetch (unverified: spike Z1, off by default)

With `MIN_ZED_PREFETCH=1`, `open` and `new` (on a fresh session only) read
the host Zed's version and start a fully detached download of the matching
remote server inside the box, into `/home/.zed_server/zed-remote-server-stable-VERSION`,
so Zed may find it already there. The file name, URL and packaging follow
Zed's installer as read, not as observed; until spike Z1 confirms them Zed's
own installer does the job (it took a few seconds in the 2026-10-02 test).

## Boxes made by other tools

A session min-zed did not create (by `min` directly, or another min-<client>
tool) has no `zed` loadout: `min-zed attach NAME` still connects (openssh is
in every min-<client> loadout), but the Claude hook is absent, so no
notifications. min-zed's `gc` never offers another tool's session.
