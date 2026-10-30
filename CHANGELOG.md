# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/).

## [0.2.0] - unreleased

Rebuilt as the Zed twin of min-vscode 0.2.0: its plumbing, commands and
loadout, with Zed's own surfaces as the UI. There is no Zed extension (Zed's
extension API has no UI); `min-zed setup` wires Remote Projects, tasks and a
key instead.

### Added

- **Zed wiring** (`min-zed config`, run by `setup`; `bin/min-zed-config`):
  - Remote Projects: one `ssh_connections` entry per live min-zed box in
    `settings.json`, kept current by `open`, `attach`, `ssh`, `destroy` and
    `gc`; Zed reloads the list live.
  - Seven **Minimal: …** tasks in the global `tasks.json` (New Box from
    Folder, New Empty Box, Open Box…, Destroy Box…, Clean Up Idle Boxes…,
    Status, Doctor), run with task: spawn (`cmd-shift-r`). In a box window,
    where tasks run in the box, they say where to run them instead.
  - `` ctrl-alt-` `` in `keymap.json`: a terminal on the Mac from any window.
  - `tasks.json` and `keymap.json` get a marked block; all three files keep
    every byte that is not min-zed's, are backed up before a write, are
    refused when they do not parse, and are restored by `config --remove`.
- `min-zed setup [--remove]`: the whole install (CLI link, loadout, skills,
  ssh Include, Zed wiring) from this checkout; `just install`/`uninstall`
  call it.
- `open`/`new`/`attach --no-window`, `new --empty` (an empty `/workbench`),
  `destroy --if-idle` (exit 3 while in use) and `destroy -y --force` (exit 4
  when min refuses unsaved changes), `status --json`.
- `destroy` without NAME on a terminal offers a picker when the current
  directory has no single min-zed box.
- The `zed` loadout adds `git` and puts Minimal's `minimal-sandbox` skill in
  the box's `~/.claude/skills` (Claude Agent and Claude Code there).
- **Skills**: Minimal's skills from gominimal/minimal-skills 0.7.0 (MIT),
  vendored: `setup` gives the agents on the Mac the host ones
  (`minimal-setup`, `-config`, `-loadouts`, `-networking`, `-diag`) in
  `~/.agents/skills` (Zed's agent) and `~/.claude/skills` (Claude Code).
- Without the `zed` command on PATH, the CLI uses the one inside
  `/Applications/Zed.app` (`MIN_ZED_EDITOR_APP`). `doctor` reports the Zed
  version (tested: 1.26.2), the tasks, keymap and skills.

### Changed

- min names new sessions (`<dir>-<hex>`; `box-<hex>` for `--empty`) unless
  `-n` is given (was min-zed's `<dir>-<word>`).
- Each tool keeps its own in-box host key, `~/.ssh/min-zed/host_ed25519`
  (was the shared `~/.ssh/minx/host_ed25519`): existing boxes re-key on the
  next connect, which re-pins it.
- `open`'s reuse, `destroy`'s current-directory lookup, the pickers and
  completions consider only sessions min-zed has connected to.
- The plumbing is no longer a vendored kernel block; it lives in
  `bin/min-zed` directly.
- `zed-config` is now `config` (`zed-config` still works). 0.1.0's opt-in
  and record (`zed-config-installed`, `zed-config.json`) are taken over on
  the first run.
- Needs min 0.7.0 or newer (`doctor` fails on older).

### Removed

- `min-zed watch` (`MIN_ZED_INTERVAL`, `MIN_ZED_NO_WATCH`), its macOS
  notifications and the Claude Code agent-state hook in the loadout. Zed's
  own agent notifications cover box threads; see
  [docs/zed.md](docs/zed.md#agents).
- The server pre-fetch (`MIN_ZED_PREFETCH`); Zed downloads its server into
  the box itself.
- Herdr support, bounded in-box reads (`MIN_ZED_EXEC_TIMEOUT`).
- `jq` from the loadout; `docs/spike.md` and `docs/manual-test-plan.md`.

### Fixed

- `destroy` and `gc`: a failed `min ls` after the answer no longer counts as
  the box being gone. Before, it removed the session's keys, refreshed
  settings and dropped its ssh stanza even after an `n`; now everything is
  kept, with a warning, and after a `y` the command exits non-zero (min's
  own status, or 1 when min destroyed the box). Once `min ls` no longer
  lists the box, `destroy NAME` removes what was kept.
- `gc` offers only sessions min-zed has connected to (has keys for);
  sessions another tool or you created with `min` are never listed or asked
  about.

## [0.1.0] - 2026-10-16

First release, split from [minx](https://github.com/noric-labs/minx).

### Added

- `min-zed open|new|attach`: activate (or reuse) a session with
  `--loadout zed`, prepare it, open `ssh://min-zed.NAME/workbench` in Zed.
- `destroy`, `gc` (only min-zed's sessions, only unused ones), `status`,
  `doctor`, `completions`.
- `ssh`, `ssh-config`, `_proxy`: the minx transport under the `min-zed.`
  prefix, with `~/.ssh/min-zed.conf` and its own Include markers.
- `zed-config` and `bin/min-zed-config`: Zed `ssh_connections` entries for
  live sessions (JSONC text edit, backup, no-op when unchanged, `--remove`).
- `watch`: macOS notifications when Claude Code in a connected box needs
  input or finishes, from the loadout's in-box state file (unverified, spike E1).
- Optional Zed remote server pre-fetch, `MIN_ZED_PREFETCH=1` (unverified,
  spike Z1; off by default).
- Loadout `zed`: openssh, curl, jq, rsync, xxhash; sshd environment;
  `min:workbench` rc line; Claude Code hook.

### Fixed (review, before release)

- Watch: epochs with a leading zero or more than 12 digits are refused
  instead of stopping the loop; reads are capped at 512 bytes and time out
  (`MIN_ZED_EXEC_TIMEOUT`); at most one notification per box per minute;
  bidi/line-separator characters stripped, messages cut by characters; one
  watch per state dir; `watch --ensure` no longer claims a start that did not
  happen; `watch.log` trimmed.
- Settings: comments between `ssh_connections` entries, CRLF and a BOM are
  kept; atomic replace; `--remove` deletes a file min-zed created and keeps a
  user's own empty list; `zed-config --print` fails when the file cannot be
  edited.
- `gc` re-checks a session right before asking about it (kernel v2).

### Changed (from minx)

- Host alias `min-zed.NAME` (was `min.NAME`); state in
  `~/.local/state/min-zed`; env prefix `MIN_ZED_`.
- In the box, `authorized_keys` is per tool (`~/.ssh/min-zed/`); the host key
  stays shared at `~/.ssh/minx/host_ed25519`.
- Use detection reads any tool's `session exec NAME … sshd` process, not
  only `ssh min.NAME` command lines.
- Install leaves `config.toml` alone; sessions get the user's
  `default_loadouts` plus `--loadout zed` last.
- What ssh-config created under `~/.ssh` is recorded once for every
  min-<client> tool (`~/.local/state/min-clients/ssh-config-created`); the
  tool removing the last Include deletes it.

[0.1.0]: https://github.com/norrietaylor/zed/releases/tag/v0.1.0
