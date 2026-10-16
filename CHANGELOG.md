# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/).

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
