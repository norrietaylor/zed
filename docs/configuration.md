# Configuration

## Environment variables

| Variable | Default | |
|---|---|---|
| `MIN_ZED_STATE_DIR` | `$XDG_STATE_HOME/min-zed` (`~/.local/state/min-zed`) | keys, box facts, logs, caches, backups |
| `MIN_ZED_SETTINGS` | `~/.config/zed/settings.json` | the Zed settings file `zed-config` edits |
| `MIN_ZED_INTERVAL` | `5` | seconds between watch polls |
| `MIN_ZED_PREFETCH` | `0` | `1`: pre-fetch Zed's remote server on `open`/`new` (unverified, spike Z1) |
| `MIN_ZED_NO_WATCH` | unset | `1`: `open`/`attach` do not start the watch |
| `MIN_ZED_DEBUG` | unset | non-empty: extra `[min-zed]` lines on stderr |
| `MIN_BIN` | `min` on PATH | absolute path baked into every stanza |
| `ZED_BIN` | `zed` | the Zed CLI |
| `OSASCRIPT_BIN` | `osascript` | notification poster (tests stub it) |
| `HERDR_BIN` | `herdr` | asked only to decide whether a Herdr bridge counts as use |
| `SSH_KEYGEN_BIN` | `ssh-keygen` | host-side key generation |

`MIN_BIN`, the state dir and the path of `min-zed` itself are written into
each stanza's ProxyCommand: Zed spawns `ssh` with the launchd PATH and no
shell rc, so nothing may depend on your shell.

## The `zed` loadout

`loadouts/zed.toml`, installed by `just loadout` as Minimal loadout `zed`:

- packages `openssh curl jq rsync xxhash`;
- an activation hook that writes `~/.ssh/environment` for sshd
  (`PermitUserEnvironment`) and the `min:workbench` line in `~/.bashrc` and
  `~/.zshrc` (an existing `minx:workbench` or `min:workbench` line counts, so
  no rc file gets two);
- an activation hook that writes `~/.claude/min-zed-hook.sh` and merges it
  into `~/.claude/settings.json` for the Claude Code events, removing only its
  own earlier entries.

min-zed activates every session with `--loadout zed`, which makes min ignore
`default_loadouts`; install never edits `config.toml`. Add your own loadouts
by activating with `min` yourself, then `min-zed attach NAME`.

## State dir

| Path | |
|---|---|
| `sessions/NAME/` | `id_ed25519` (mode 600), `known_hosts`, `user`, `home`, `sshd` (box facts, validated) |
| `proxy.log` | one line per `_proxy` run (mode 600, capped at 1000 lines) |
| `watch.pid`, `watch.log` | the watch loop |
| `cache/NAME.agent` | last agent state seen (`state epoch`) |
| `orphan/NAME`, `kept/NAME` | when a session was first seen unused; when you kept it at a prompt |
| `backups/` | `ssh_config.*` before each `~/.ssh/config` write, `zed-settings.json.*` before each settings write |
| `ssh-config-created`, `zed-config-installed` | what install created; the settings-sync opt-in |

## Rolling back

`just uninstall`, then `min session destroy` whatever you no longer need.
`~/.ssh/config` ends byte-identical to before install; the previous contents
of both edited files are in `backups/`.
