# Configuration

Environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_ZED_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/min-zed` | state directory (keys, facts, backups, logs) |
| `MIN_ZED_SETTINGS` | `~/.config/zed/settings.json` | the settings file `config` edits (`ssh_connections`) |
| `MIN_ZED_TASKS` | `~/.config/zed/tasks.json` | the global tasks file `config` edits (the Minimal tasks) |
| `MIN_ZED_KEYMAP` | `~/.config/zed/keymap.json` | the keymap `config` edits (`` ctrl-alt-` ``) |
| `MIN_ZED_EDITOR_BIN` | `zed`, else the app's own | the Zed CLI (stable Zed; Preview is untested) |
| `MIN_ZED_EDITOR_APP` | `/Applications/Zed.app` | where the CLI looks for Zed's own `cli` when `zed` is not on PATH |
| `MIN_LOCK_WAIT` | 10 | seconds `ssh-config` waits for the `~/.ssh/config` lock |
| `MIN_ZED_DEBUG` | unset | log the editor command and other detail |
| `MIN_BIN` | `min` on PATH | `min` binary; resolved to an absolute path for the ProxyCommand |
| `SSH_KEYGEN_BIN` | `ssh-keygen` | key generator |

`MIN_BIN` and `MIN_ZED_STATE_DIR` are baked into each
`~/.ssh/min-zed.conf` stanza as it is written, because Zed starts `ssh` with
the launchd PATH and no shell rc; after changing either, re-run
`min-zed ssh-config` (or any `open`/`attach`).

The Minimal tasks run `~/.local/bin/min-zed` (the link `setup` makes), so
they follow the checkout wherever it moves once `setup` runs again.

Needs min 0.7.0 or newer; `doctor` fails on an older one. Tested with Zed
1.26.2; `doctor` notes any other version.

**Loadout.** `loadouts/zed.toml` adds `openssh`, `curl`, `rsync`, `xxhash`
and `git`, copies Minimal's `minimal-sandbox` skill into `~/.claude/skills`
in the box (Claude Agent and Claude Code there; vendored in `loadouts/zed/`
from gominimal/minimal-skills; `just skills` refreshes it), prepares the
in-box sshd environment, and adds the `min:workbench` rc line. Zed brings its
own server and, for Claude Agent, its own Node, so the loadout has neither.
`min-zed setup` symlinks it to `~/.config/minimal/loadouts/zed.toml` and
copies `loadouts/zed/` beside it. It is never added to `default_loadouts`:
min-zed activates with your `default_loadouts` plus `--loadout zed` (min
would drop the defaults once any `--loadout` is named, so min-zed passes them
on), and boxes made by other tools carry only their own loadouts (min-zed can
still attach to them).

**Zed's files.** See [zed.md](zed.md#zeds-files-min-zed-config).

## Rolling back

    just uninstall

takes the `min-zed.*` `ssh_connections` entries and the tasks and keymap
blocks out (`min-zed config --remove`, with backups), removes the Include
from `~/.ssh/config` (byte-identical to before; `~/.ssh/min-zed.conf` is
deleted), removes the loadout and CLI symlinks if they point into this
checkout, and the loadout copy and skill copies marked as min-zed's. It
leaves the state directory, which holds the session keys and every backup.
