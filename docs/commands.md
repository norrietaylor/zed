# Commands

Run `min-zed` on the host: any Mac terminal, a Minimal task in a local Zed
window, or a terminal opened with `` ⌃⌥` ``. Shells inside a box run
in the box, where `min-zed` is not installed.

| Command | Does |
|---|---|
| `min-zed open [PATH] [-n NAME] [--no-window]` | the session for `PATH` (default `.`): a live one of min-zed's is reused, else one is activated with `--loadout zed`; then Zed opens `/workbench` in it. Prints `min-zed.NAME` |
| `min-zed new [PATH \| --empty] [-n NAME] [--no-window]` | always a new session for `PATH`, then Zed; `--empty`: an empty `/workbench` (`--sync none`), named by min (`box-<hex>`) |
| `min-zed attach [NAME] [--no-window]` | an existing session in Zed (no NAME: pick one of min-zed's) |
| `min-zed destroy [-y] [--if-idle] [--force] [NAME]` | ask `[y/N]`, then destroy. No NAME: min-zed's one session for the current directory; otherwise, on a terminal, pick one. `--if-idle` refuses with exit 3 while something is connected. Without a terminal, min refuses a session with unsaved changes: exit 4; `-y --force` discards them. When the `min ls` that follows fails, the session's keys and stanza stay, with a warning, and after a y the exit is 1 |
| `min-zed gc [--older-than SECONDS] [--dry-run]` | list active sessions no ssh client is using (oldest first), then ask `[y/N/q]` for each |
| `min-zed status [--json]` | table: session, status, project, in use, idle age; `--json`: `[{name, status, project, own, empty, in_use, idle}]` (idle in seconds or null) |
| `min-zed doctor` | health report; exits 1 on any FAIL |
| `min-zed setup [--remove]` | the whole install from this checkout: links `~/.local/bin/min-zed` and the `zed` loadout here, copies Minimal's skills, then `ssh-config` and `config`; `--remove` undoes only ours |
| `min-zed config [--remove\|--print]` | opt in to (or out of) the Zed wiring: `ssh_connections` in `settings.json`, the Minimal tasks in `tasks.json`, the local-terminal key in `keymap.json`; `--print` only prints. Also `min-zed zed-config` |
| `min-zed ssh NAME [-- ARGS]` | plain `ssh` over the same transport (debugging: `-- -v`) |
| `min-zed ssh-config [--remove\|--print]` | opt in: one `Host min-zed.NAME` stanza per session in `~/.ssh/min-zed.conf`, included from the top of `~/.ssh/config` |
| `min-zed completions <zsh\|bash>` | print a completion script (`eval "$(min-zed completions zsh)"`) |

`--no-window` does everything but open the window.

Names: without `-n`, min names a new session (`<dir>-<hex>`, e.g.
`myproject-3f9c`), and min-zed takes the one new session for the path.
Every name, min's or a `-n NAME`, must match `^[a-z0-9][a-z0-9-]*$`: names
become hostnames and ssh `Host` patterns; one that does not is refused.

"In use" means some process on the host is connected to the box: any
`min session exec NAME ... sshd`, which covers Zed, a terminal `ssh`, `scp`
and any other ssh client, including other min-<client> tools. `gc` leaves
sessions in use out; their idle age (`status`, `gc`) restarts while they are
in use, and counts from the first `gc` or `status` that saw the session
unused (each run dates them).

Own sessions: min-zed chooses only among sessions it has connected to (it
has keys for them under `STATE/sessions/NAME`): `gc`, `open`'s reuse,
`destroy`'s current-directory lookup and picker, the `attach` picker and
completions. Boxes other tools or `min` alone made are not its to tidy; only
an explicit NAME (`attach NAME`, `destroy NAME`, `open -n NAME`) reaches
them.

just recipes: `check`, `install`, `ssh-config`, `zed-config`, `skills`,
`uninstall`.
