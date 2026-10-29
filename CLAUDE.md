# CLAUDE.md

`min-zed` opens Minimal boxes (`min` sessions, libkrun microVMs) in Zed as ssh
remote projects (`zed ssh://min-zed.NAME/workbench`), with sshd running inside
the box behind a `min session exec` ProxyCommand. One POSIX shell script plus
a python3 merger, no build step. It is the Zed twin of min-vscode
([norrietaylor/vscode](https://github.com/norrietaylor/vscode)): same plumbing
and commands; only the editor-specific constants, the merger and the loadout
differ. There is no Zed extension (Zed's WASM API has no UI): the UI is Zed's
own surfaces, which `setup` wires: the Remote Projects list
(`ssh_connections`), global tasks, and one key.

## Layout

| File | Role |
|---|---|
| `bin/min-zed` | tool constants, then the transport/ssh/session plumbing, then the client layer, whose first block holds every editor-specific constant |
| plumbing | transport, PREP/prepare, `stored_path`, ssh options and stanzas, `ssh-config`, `_proxy`, `ssh`, naming, `pick_session`, `activate_session`, `destroy_one`, `in_use_names`/`box_in_use`, `track_orphans`, `default_loadouts`, the ssh-config record, report helpers; editor-neutral, reaching the client layer only through its hooks |
| client layer | `open`/`new`/`attach` (session, stanza, settings, `zed ssh://…` unless `--no-window`; `new --empty`), `destroy` (`--if-idle`; no NAME: the cwd's own box, else on a terminal the picker), `gc`, `status` (`--json`), `doctor`, `completions`, `config` (alias `zed-config`), `setup`, hidden `_sessions`; hooks `client_on_connect` and `client_on_destroy` (settings sync) |
| `bin/min-zed-config` | python3 merger for three JSONC files in `~/.config/zed`: `settings.json` (`ssh_connections` entries for live sessions, edited in place), `tasks.json` and `keymap.json` (a marked block at the top of the array: the Minimal tasks, the local-terminal key); `--install`, `--sync NAME...`, `--remove`, `--doctor`, `--dry-run` |
| `loadouts/zed.toml`, `loadouts/zed/` | `openssh curl rsync xxhash git`; sshd env prep; `min:workbench` rc line; a patch copying `zed/skills/minimal-sandbox` to `~/.claude/skills` in the box. `setup` copies `zed/` beside the linked toml: `$LOADOUT_ROOT` must be a real directory |
| `skills/`, `loadouts/zed/skills/` | Minimal's skills, vendored from gominimal/minimal-skills (MIT) at a pinned commit by `just skills`: the host ones (`setup` copies them into the Mac's `~/.agents/skills` (Zed's agent) and `~/.claude/skills`, marked `.min-zed-copy`, never over a dir with no `.min-*-copy` mark; one another min tool marked is shared, keeping its mark, and `--remove` deletes it only once no other mark is left) and `minimal-sandbox` (box only: the host ones teach commands a box lacks) |
| `minimal.toml` | developing this repo in a box: session packages for `just check`; task `check` (`min task run check`) |
| `justfile` | `check`, `install`/`uninstall` (= `setup`), `ssh-config`, `zed-config`, `skills` |
| `tests/run.sh`, `tests/stubs/` | plain-sh tests over stub `min`, `zed`, `ssh`, `ssh-keygen`, `ps` (+ `find`/`mv` for PREP races) and a `tripwire` for bare GUI commands; `LONG_PREFIX=1` reruns them with a long host prefix; the destroy picker runs on a pty through `script(1)` (skipped without it) |
| `docs/` | user docs (being rewritten for 0.2.0), `public/` marks and badge |

## The Zed UI (what `config` writes)

- One `ssh_connections` entry per live own session,
  `{"host": "min-zed.NAME", "nickname": "NAME", "projects": [{"paths": ["/workbench"]}]}`:
  the Remote Projects modal (`ctrl-cmd-o`), reloaded live.
- `tasks.json` block, seven tasks: `Minimal: New Box from Folder…`
  (`new FOLDER`: the window's folder, given as `env`
  `MIN_ZED_TASK_FOLDER: ${ZED_WORKTREE_ROOT:none}` so the task is offered
  with no folder open too; with none, or a single-file window, it asks in
  macOS's folder picker (`osascript` `choose folder`, from `$HOME`; cancel
  exits 0); without `osascript` it prints one line saying to open a folder),
  `Minimal: New Empty Box` (`new --empty`), `Minimal: Open Box…` (`attach`:
  picker), `Minimal: Destroy Box…` (`destroy`: the cwd's box, else picker),
  `Minimal: Clean Up Idle Boxes…` (`gc`), `Minimal: Status`,
  `Minimal: Doctor`. Each runs through `"shell": {"program": "sh"}` (any
  login shell) and calls `$HOME/.local/bin/min-zed` by absolute path; where
  that is missing (a box window: global tasks run in the box) it prints one
  line pointing at a local window or the local-terminal key, and exits 1.
  The CLI's own y/N questions and numbered pickers are the UI.
  `reveal: always`, `use_new_terminal: false`, `allow_concurrent_runs:
  false`, `show_command: false`; `hide: on_success` for the three that open
  a window, `never` for the rest. No `$ZED_*` variable in a command or
  `cwd`: Zed pastes them into a command unquoted, and a root may be a file.
- `keymap.json` block, context `Workspace`: `` ctrl-alt-` `` →
  `["workspace::NewTerminal", {"local": true}]` (a Mac terminal from a box
  window); `ctrl-alt-n`/`ctrl-alt-o` → `["task::Spawn", {"task_name": …}]`
  for New Box from Folder…/Open Box… (Zed's welcome page is hard-coded, so
  keys are how the tasks reach it; both free in the default macOS and vim
  keymaps). Free in Zed
  1.26.2's default macOS keymap, beside `` ctrl-` `` (terminal panel) and
  `ctrl-~` (new terminal). No task bindings: `cmd-shift-r`, then "Minimal".

## Invariants

- Session names match `^[a-z0-9][a-z0-9-]*$`, `-n` included: they are
  hostnames and ssh `Host` patterns. Without `-n`, min names the session;
  `activate_session` takes the one new session for the path and refuses a
  name that is no hostname.
- Host alias is `min-zed.NAME` (`HOST_PREFIX`); nothing hard-codes the
  prefix length (the long-prefix test run guards it).
- `prepare` re-pins the host key and re-pushes the public key on every
  `open`/`attach`/`ssh`/`_proxy`, so a recreated session self-heals.
  `_proxy` always runs `prepare` and writes nothing to stdout before `exec`
  (stdout is the SSH byte stream). `_proxy` and `prepare` never call client
  hooks, never touch Zed's files.
- `ssh-config` is an opt-in gate: nothing under `~/.ssh` is touched until it
  has run. `ssh-config --remove` leaves `~/.ssh/config` byte-identical to
  before install; `--print` writes nothing. Other tools' Include lines are
  never touched.
- `config` is the same kind of gate for Zed's files: `--sync` is a no-op
  until `config` has run (`STATE/settings-installed`), and `--sync` (from
  open/attach/ssh/destroy/gc) touches only `ssh_connections`; only `config`
  (`--install`, also run by `setup`) writes the tasks and keymap blocks.
  Settings: only entries whose host starts with the prefix are added or
  removed; an existing entry of ours is kept verbatim; every other byte
  (comments between entries, CRLF, BOM) stays; the key is removed only if we
  added it (`STATE/settings-key-added`); adding ours and taking them out
  again gives back the bytes (a comment after the user's last entry stays
  on its line). 0.1.0's `STATE/zed-config-installed` and `zed-config.json`
  are taken over once (opt-in, key added, file created). Tasks/keymap: the
  block between `// min-zed:begin` and `// min-zed:end` (the marks only as
  comment lines of their own, the first right after the top-level `[`) is
  ours and rewritten whole (Zed's keymap editor appends after it); a file
  with no array gets one marked `// min-zed:array`, taken out with the block
  while nothing else went into it. For all three: dated backup in
  `STATE/backups/` before a write; written through a symlink, replaced
  atomically; never written when unchanged; `--remove` restores the bytes it
  found and deletes a file it created (`STATE/<file>-created`) once empty; a
  file that does not parse (or is not UTF-8, or has the wrong top level) is
  refused, and then none of the three is written. Settings sync is skipped when `min ls` fails.
- The host key is pinned (`StrictHostKeyChecking=yes`); never `accept-new`.
- Agent and X11 forwarding stay off on every client path: one option list
  (`ssh_common`) feeds both the stanza and `ssh_opts`.
- Facts the box reports (user, hostkey, home, sshd) are untrusted: `prepare`
  validates them before writing anything, and dies if a write fails; stored
  `home`/`sshd` are re-checked on read (`stored_path`) by `_proxy` and by the
  ProxyCommand `ssh` builds.
- `gc` and `destroy` never destroy without an explicit y; `-y` is the only
  way past `destroy`'s question.
- `gc` offers only own sessions (`own_ls`: a key dir `STATE/sessions/NAME`),
  and `gc`/`status` date only those in `orphan/` (`track_orphans`, each run);
  boxes made by `min` alone are never listed. The same holds wherever a
  session is chosen for the user: `open`'s reuse of a live session for PATH,
  `destroy`'s cwd lookup and its picker, the `attach` picker and `_sessions`
  (completions). Only an explicit NAME (`attach NAME`, `destroy NAME`,
  `open -n NAME`) may reach another tool's box.
- `destroy` without NAME: exactly one own session for the cwd is it;
  otherwise, on a terminal (a Zed task), the own-session picker; without a
  terminal, or with no own session at all, the errors ("no session for DIR;
  pass NAME", "several sessions for DIR: …; pass NAME").
- In use = some host process runs `min session exec NAME ... sshd` (any ssh
  client's connection). Never contact a box without such a live process: a
  connect starts a stopped box.
- `gc` re-checks `gc_still_idle` before each question; `destroy --if-idle`
  re-checks it too (exit 3 when in use); without a terminal, unsaved changes
  exit 4 and only `destroy -y --force` discards them.
- Activation passes the user's `default_loadouts` on before `--loadout zed`.
- What `ssh-config` created under `~/.ssh` is recorded in
  `~/.local/state/min-clients/ssh-config-created`; removing the last
  `Include ~/.ssh/min-*.conf` deletes only that, so `~/.ssh/config` ends
  byte-identical.
- Install never edits `default_loadouts`; `setup --remove` (`just uninstall`)
  removes only our own links, marked skill copies, Zed entries and blocks,
  and Include; when the merger refuses a Zed file it removes nothing else
  and fails. `setup` replaces a link only when missing, dangling, or
  pointing to another copy of the same file (a moved checkout); stanzas bake
  the `~/.local/bin` link, so it follows the checkout.

## External facts that bite

- `min` is a zsh function on the host; `MIN_BIN` is resolved to an absolute
  path and baked into each stanza (Zed spawns ssh with the launchd PATH).
- Without `zed` on PATH, `bin/min-zed` uses the app's own CLI
  (`$MIN_ZED_EDITOR_APP/Contents/MacOS/cli`, default `/Applications/Zed.app`);
  `MIN_ZED_EDITOR_BIN` overrides both. `zed --version` prints
  `Zed 1.26.2 – /Applications/Zed.app`; doctor notes a version other than
  the tested 1.26.2.
- `bin/min-zed` appends `/opt/homebrew/bin`, `/usr/local/bin` and
  `~/.local/bin` to PATH (unless `MIN_NO_PATH_EXTEND=1`, which tests set,
  with `ZDOTDIR VISUAL EDITOR` unset), where the real `zed` lives: tests must
  point `MIN_ZED_EDITOR_BIN` (and every other `*_BIN`) at an absolute stub
  path, never a bare name. Bare `open`, `osascript`, `zed`, `code`, `cursor`
  and `windsurf` on the test PATH are `tests/stubs/tripwire` (stubs live in
  `$T/stub-bin`), and any tripwire line fails the case. A mutation check
  never removes or bypasses a stub or the tripwire; skip any that could
  launch a real app.
- ssh runs the ProxyCommand via `$SHELL -c "exec ..."` and expands `%`
  tokens: every word goes through `shq` and the whole string through `pct`.
- Zed 1.26.2, seen live 2026-10-29: `ssh_connections` entries appear in
  Remote Projects and reload live; global `~/.config/zed/tasks.json` tasks
  run on the Mac in a local window and in the box (bash, cwd `/workbench`)
  in a box window; `["workspace::NewTerminal", {"local": true}]` opens a Mac
  terminal from a box window; a new box host opens in Restricted Mode until
  trusted once; agent notifications fire for box threads.
- Zed task commands go through `shellexpand` (Zed source, v1.26.2): `$ZED_*`
  variables are pasted into the command text unquoted, a task whose
  `$ZED_*` variable is unset is not offered unless it is written
  `${ZED_VAR:default}`, other `$VARS` are left to the
  shell. `env` values get the same substitution but are no shell text, and
  the task variables are exported too. `ZED_WORKTREE_ROOT` is set without a
  directory check: in a single-file window it is the file. Tasks run in an interactive terminal (`sh -i -c`), so `[ -t 0 ]`
  holds.
- Zed downloads its remote server into the box itself:
  `~/.zed_server/zed-remote-server-stable-<ver>+stable.<build>.<sha>`.
  Claude Agent (ACP) runs in the box with the Node Zed downloads
  (`~/.local/share/zed/node`; the loadout needs none) and reads
  `~/.claude/skills` there; Zed's own agent runs on the Mac and reads
  `~/.agents/skills/<skill>/SKILL.md`.
- Claude Agent's adapter (agentclientprotocol/claude-agent-acp) runs
  `$CLAUDE_CODE_EXECUTABLE` instead of the SDK's own claude and loads user
  settings. Minimal's `claude` package (`min add claude`) is a
  `/usr/bin/claude` wrapper adding `--plugin-dir=/usr/share/claude/plugins/minimal`
  (skill, SessionStart primer, denial-triage hook). PREP and the loadout hook
  set the variable in `~/.ssh/environment` only when `/usr/bin/claude`
  exists; never Zed's global `agent_servers` env, which local windows share.
  Unverified: that the variable reaches the agent process, and that the SDK
  runs the wrapper.
- The box is uid 1000 with `$HOME=/home`, aarch64, glibc 2.44, has bash, tar,
  curl, python3, zsh; `sshd` at `/usr/sbin/sshd`.
- sshd scrubs the environment: PREP writes `~/.ssh/environment` (filtering
  `PROMPT_COMMAND`/`MINIMAL_MOTD`) and sshd runs with `PermitUserEnvironment=yes`.
- In the box, the host key and `authorized_keys` live in `~/.ssh/min-zed/`.
- Without a terminal, `min session destroy` refuses a box with unsaved
  changes ("refusing to destroy the session without confirmation; pass
  --force").

## Working here

- Verify: `just check`.
- Tests never touch the real min, Zed, `~/.ssh` or `~/.config`: stubs first
  on a private PATH, `HOME`, `MIN_ZED_STATE_DIR`, `MIN_ZED_SETTINGS`,
  `MIN_ZED_TASKS` and `MIN_ZED_KEYMAP` in a tempdir.
- Don't create, attach or destroy min sessions, or `min session exec` into
  one, without asking. Don't run `ssh-config`, `config`, `_proxy`,
  `just install`/`uninstall` against the real HOME; use `HOME=<scratch>`
  `XDG_CONFIG_HOME=<scratch>` and a stub `MIN_BIN`.

## Unverified (needs a live session)

- New Box from Folder… with no folder open: the osascript folder picker
  (may open behind Zed's window).
- Destroying the box a window is on: what that window does.

Seen end to end (Zed 1.26.2, 2026-10-29): the tasks through `sh`, the
folder through `env`, `hide: on_success`, pickers and y/N in a task
terminal, the box-window guard line, all three keys (US keyboard), Remote
Projects, `setup --remove` restoring `~/.ssh/config` byte-identical.
