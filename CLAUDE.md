# CLAUDE.md

`min-zed` opens Minimal sessions (`min`, libkrun microVMs) as Zed ssh remote
projects (`zed ssh://min-zed.NAME/workbench`), with sshd running inside the
box behind a `min session exec` ProxyCommand. One POSIX shell script plus a
python3 settings merger, no build step. Split from noric-labs/minx; one of
the min-<client> repos (plan of record:
`~/.claude/plans/we-are-going-to-fancy-sloth.md`, kernel contract:
`~/code/min-clients/KERNEL.md`).

## Layout

| File | Role |
|---|---|
| `bin/min-zed` | constants (`TOOL CLIENT LOADOUT HOST_PREFIX ENV_PREFIX STATE`), then the vendored kernel block, then the Zed layer: `open new attach destroy gc status doctor watch zed-config completions`; kernel commands `ssh ssh-config _proxy` |
| `bin/min-zed` kernel | between `# --- kernel begin (vendored from norrietaylor/cmux; keep in sync) ---` and `# --- kernel end ---`: transport, PREP/`prepare`, stanzas, naming, `destroy_one`, `box_in_use`, `track_orphans`, report helpers. Byte-identical across repos, pinned by `tests/kernel.sha`; client-free (no Zed code) |
| `bin/min-zed-config` | python3: keeps `ssh_connections` entries whose host starts `min-zed.` in Zed's `settings.json` equal to the live sessions (JSONC text edit, backup, no-op when unchanged, `--remove`, `--doctor`, `--dry-run`) |
| `loadouts/zed.toml` | Minimal loadout `zed`: `openssh curl jq rsync xxhash`; sshd env + `min:workbench` rc line; Claude hook `~/.claude/min-zed-hook.sh` writing `/home/.min-zed/agent-state` |
| `justfile` | `check install loadout uninstall ssh-config zed-config kernel-sha` |
| `tests/run.sh`, `tests/stubs/`, `tests/kernel.sha` | plain-sh tests over stub `min zed ssh ssh-keygen ps osascript herdr curl` (+ `find`/`mv` for PREP races); a second pass with a long `HOST_PREFIX` |
| `README.md`, `docs/` | `zed.md` (guide), `commands.md`, `configuration.md`, `how-it-works.md`, `security.md`, `troubleshooting.md`, `spike.md` (Z1, E1, K1), `manual-test-plan.md` |
| `docs/public/` | `min-zed-mark-{dark,light}.svg` (Minimal glyph + "zed", text not outlined), `built-with-minimal.svg` |
| `CHANGELOG.md`, `LICENSE`, `.github/ISSUE_TEMPLATE/` | Keep a Changelog, Apache-2.0, bug template asking for `doctor` output |

## Invariants

- Session names are `<dir>-<word>` (`next_name`: first free word, never a
  live name) unless `-n` is given, and match `^[a-z0-9][a-z0-9-]*$`, `-n`
  included: they are hostnames and ssh `Host` patterns.
- `prepare` re-pins the host key and re-pushes the public key on every
  `open`/`new`/`attach`/`ssh`/`_proxy`, so a recreated session or a rotated
  key self-heals for every client. `_proxy` always runs `prepare` and writes
  nothing to stdout before `exec` (stdout is the SSH byte stream).
- `ssh-config` is an opt-in gate: nothing under `~/.ssh` is touched until it
  has run (`open`/`new`/`attach` refuse until then). Once installed,
  `min-zed.conf` is rewritten only by `prepare` and `destroy_one`, and only
  when its content changed. `ssh-config --remove` leaves `~/.ssh/config`
  byte-identical to before install; `--print` writes nothing.
- `zed-config` is the second opt-in gate: Zed's settings are untouched until
  it has run (`$STATE/zed-config-installed`). Then `client_on_connect`
  (open/new/attach/ssh) and `client_on_destroy` resync; `_proxy` never does.
  Only entries whose host starts `min-zed.` are added or removed; an existing
  entry of ours is kept verbatim; no write when the parsed result is
  unchanged; dated backup in `$STATE/backups` before every write; written
  through (symlinks survive).
- The host key is pinned (`StrictHostKeyChecking=yes`); never `accept-new`.
- Agent and X11 forwarding stay off on every client path: one option list
  (`ssh_common`) feeds both the stanza and `ssh_opts`.
- Facts the box reports (user, hostkey, home, sshd) are untrusted: `prepare`
  validates them before writing anything, and stored ones are re-checked on
  read. The agent-state line is validated (state word, numeric epoch, control
  bytes stripped) and reaches `osascript` only as argv.
- `gc` and `destroy` never destroy without an explicit y; `-y` is the only
  way past `destroy`'s prompt. `gc` offers only sessions min-zed prepared
  (`$STATE/sessions/NAME`), never another tool's.
- A session with a host process running `session exec NAME … sshd` (any
  tool) is in use; under Herdr's `remote-client-bridge` only while Herdr lists
  an agent (cached a minute). Never contact a box without such a live
  process: a connect starts a stopped box. The watch polls only in-use boxes.
- The watch notifies only on a change to `needs-input` or `finished`
  (cache `$STATE/cache/NAME.agent`); a stale state seen first is cached
  silently. One watch per state dir (`watch.pid`), stopped by PID
  (`watch --stop` checks the PID is a `min-zed watch`).
- Server pre-fetch runs only from `open`/`new` on a fresh session, only with
  `MIN_ZED_PREFETCH=1`, fully detached in the box (`setsid nohup … &`, all
  streams `/dev/null`); never from `prepare` or `_proxy`.
- In the box: host key `~/.ssh/minx/host_ed25519` shared by every
  min-<client> tool under one lock protocol; `authorized_keys` per tool in
  `~/.ssh/min-zed/`; `~/.ssh/environment` shared; one `/workbench` rc line
  (`minx:workbench` or `min:workbench` counts); the loadout's jq merge removes
  only `min-zed-hook` entries.
- Install never edits `default_loadouts`; sessions are activated with
  `--loadout zed`. `just uninstall` removes only its own symlinks and never
  restores a `.bak`.

## Kernel

Do not edit the kernel block here. Changes go into the cmux repo's
`bin/min-cmux` first, then are copied byte for byte into every repo, then
`just kernel-sha`. The block in this repo is a **provisional port** of minx
made while the cmux kernel was being produced; replace it with the frozen
cmux block (and re-pin) before release. `tests/run.sh` checks the pin and
that the block mentions neither Zed nor osascript.

## External facts that bite

- `min` is a zsh function on the host; `MIN_BIN` is resolved to an absolute
  path and baked into each stanza. GUI apps (Zed) spawn `ssh` with the
  launchd PATH and no shell rc.
- ssh runs the ProxyCommand via `$SHELL -c "exec …"` and expands `%` tokens:
  every word goes through `shq` and the whole string through `pct`; `env
  VAR=… cmd`, not a `VAR=x cmd` prefix (tcsh, old fish).
- OpenSSH reads `UserKnownHostsFile` only after the server banner, which is
  why `_proxy` may re-pin the key before exec'ing sshd.
- The box is uid 1000 with `$HOME=/home`; its passwd name follows the SSH
  username of the connection that launched the session host, so `user` is
  read on every `prepare`.
- sshd scrubs the environment: `PermitUserEnvironment=yes` +
  `~/.ssh/environment`, with `PROMPT_COMMAND`/`MINIMAL_MOTD` filtered out.
- `min session activate --loadout X` makes min ignore `default_loadouts`.
- Zed 1.22 (2026-10-02, via minx): `zed ssh://HOST/PATH` reads
  `~/.ssh/config`; Zed runs its own ControlMaster and downloads
  `zed-remote-server-linux-<arch>` inside the box with curl into
  `/home/.zed_server`. `zed --version` prints `Zed 1.22.0 – /Applications/Zed.app`.
- The kernel appends `/opt/homebrew/bin` to PATH, so a test that unsets a
  stub by name (`ZED_BIN=zed`) reaches the real binary: use a nonexistent
  absolute path instead.

## Working here

- Verify: `just check` (shellcheck on `bin/min-zed`, `tests/run.sh` and the
  stubs; `py_compile` on `bin/min-zed-config`; the tests).
- Tests never touch the real min, Zed, `~/.ssh` or Zed settings: stubs first
  on a private PATH, `HOME`, `MIN_ZED_STATE_DIR` and `MIN_ZED_SETTINGS` in a
  tempdir; guards fail a case that writes `~/.ssh` or settings without
  opting in.
- Don't create, attach or destroy min sessions, `min session exec` into one,
  or run `zed` against a real host, without asking.
- `just install`/`just loadout` edit the real `~/.config/minimal` and
  `~/.ssh`; exercise them with `HOME` and `XDG_CONFIG_HOME` pointed at a
  scratch dir. Don't run `ssh-config`, `zed-config` or `_proxy` by hand from
  this shell; `--print` is the read-only way to look.
- A `watch` started for a smoke test must be stopped by PID.

## Unverified (needs a live session)

Recorded in `docs/spike.md`: Z1 (server pre-fetch naming/URL; gates
`MIN_ZED_PREFETCH`), E1 (agent-state hook → file → watch → notification with
Zed connected; Claude via Zed's agent panel), K1 (two tools on one box).
