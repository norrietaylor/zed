# Commands

| Command | What it does |
|---|---|
| `open [PATH] [-n NAME]` | Reuse PATH's live min-zed session (or NAME's), else activate one with `--loadout zed`; prepare it; open `ssh://min-zed.NAME/workbench` in Zed. Prints `min-zed.NAME`. |
| `new [PATH] [-n NAME]` | Always activate a fresh session for PATH (default `.`), then as `open`. NAME must be free. |
| `attach [NAME]` | Open an existing session in Zed; no NAME: a numbered picker (terminal only). |
| `destroy [-y] [NAME]` | `min session destroy` after `[y/N]` (`-y` skips it). No NAME: the one session whose project is this directory. Drops its stanza, keys and Zed entry. |
| `gc [--older-than SECONDS] [--dry-run]` | min-zed sessions with no live ssh client of any tool, oldest first, each with `[y/N/q]`. |
| `status` | Every min session: status, project, made by min-zed, in use, last agent state, time unused. |
| `doctor` | Health report; exits 1 on any FAIL. |
| `watch [--ensure\|--stop]` | Agent-state notification loop (foreground); `--ensure` starts it in the background if needed, `--stop` stops it by its PID file. |
| `ssh NAME [-- ARGS...]` | Plain ssh over the same transport (`-- -v true` to debug). |
| `ssh-config [--remove\|--print]` | Install/remove the `~/.ssh/min-zed.conf` Include; `--print` writes nothing. |
| `zed-config [--remove\|--print]` | Opt in to/out of Zed `ssh_connections` sync; `--print` writes nothing. |
| `completions zsh\|bash` | Completion script: `eval "$(min-zed completions zsh)"`. |
| `_proxy NAME` | Hidden: the stanzas' ProxyCommand. Never run it by hand. |

## Names

`<dir>-<word>`: the project directory's name lowercased, every run of other
characters turned into `-`, then the first of `amber basil coral … zinc`
(then `amber2 …`) no live session uses. `-n NAME` must match
`^[a-z0-9][a-z0-9-]*$`: names are ssh host names and `Host` patterns.

## `open` versus `new`

`open` reuses only a session min-zed prepared (it has keys under
`~/.local/state/min-zed/sessions/NAME`); a session for the same directory
made by another tool is left to that tool, and `open` makes its own.
`open -n NAME` for a session whose project is another directory fails rather
than opening the wrong code.

## just recipes

| Recipe | |
|---|---|
| `just check` | shellcheck, py_compile, `tests/run.sh` (includes the kernel hash pin and a long-prefix pass) |
| `just install` | link `~/.local/bin/min-zed`, then `loadout`, `ssh-config`, `zed-config` |
| `just loadout` | symlink `loadouts/zed.toml` as Minimal loadout `zed`; refuses to replace a `zed.toml` that is not this repo's |
| `just ssh-config` / `just zed-config` | the two opt-ins |
| `just uninstall` | `ssh-config --remove`, `zed-config --remove`, `watch --stop`, remove the two symlinks if they point here |
| `just kernel-sha` | re-pin `tests/kernel.sha` after syncing the kernel block |
