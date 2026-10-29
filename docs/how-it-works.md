# How min-zed works

## The shape of it

```
Zed ──ssh min-zed.NAME──▶ /usr/bin/ssh ──ProxyCommand──▶ min-zed _proxy NAME
                                                            │ prepare (re-pin, push key)
                                                            ▼
                                          exec min session exec NAME sshd -i ...
                                                            │ (min's exec channel)
                                                            ▼
                                                sshd in the box ◀── Zed's remote server
```

`bin/min-zed` has three parts: tool constants (`TOOL`, `HOST_PREFIX`, ...),
the **plumbing** (transport, ssh, sessions), and the **client layer**
(everything Zed). The plumbing never mentions an editor: it calls
`client_on_connect` and `client_on_destroy` (and `client_linked`, which
min-zed does not define) when the client layer defines them.
`bin/min-zed-config` is the python3 merger for Zed's three files.

## Transport

`min session exec NAME argv...` is a byte-transparent, non-PTY exec channel
into the box. The ProxyCommand runs `sshd -i` over it, so ssh speaks to a
real OpenSSH server on stdin/stdout. No port listens anywhere.

sshd runs with a fixed flag set: `-f /dev/null` (no config file), the box's
host key `~/.ssh/min-zed/host_ed25519`, `AuthorizedKeysFile
~/.ssh/min-zed/authorized_keys`, public-key auth only,
`PermitUserEnvironment=yes` (sshd scrubs the environment; `~/.ssh/environment`
restores the session's variables), TCP forwarding on, agent and X11
forwarding off, `internal-sftp`.

### prepare and PREP

Before every connection (`open`, `attach`, `ssh`, and `_proxy` behind every
stanza) `prepare` runs one `min session exec NAME sh -c PREP min-zed
PUBKEY`. PREP, in the box:

- generates the box's host key once, under a lock (`.keygen` dir; stale
  locks broken by one waiter at a time; the pair renamed into place whole),
  so concurrent connects agree on one key;
- writes `authorized_keys`;
- rewrites `~/.ssh/environment` from `env`;
- appends the `min:workbench` rc line (unless one is there) and a
  `~/.bash_profile` that sources `~/.bashrc`;
- prints `user=`, `home=`, `sshd=`, `hostkey=`.

The host validates every fact (they come from an untrusted box), then writes
`known_hosts` (`min-zed.NAME <key>`), `user`, `home`, `sshd` under
`~/.local/state/min-zed/sessions/NAME/`, each by rename, and refreshes the
stanza file; if a write fails, `prepare` stops there. `_proxy` and the
ProxyCommand `min-zed ssh` builds re-check the stored `home` and `sshd`
before using them. A session recreated under the same name therefore heals
on the next connect.

### Stanzas and `_proxy`

`min-zed ssh-config` adds two marked lines at the top of `~/.ssh/config`:

    # min-zed ssh-config (remove with: min-zed ssh-config --remove)
    Include ~/.ssh/min-zed.conf

`~/.ssh/min-zed.conf` (mode 600) has one stanza per prepared session that
min still lists:

    # myproject-3f9c
    Host min-zed.myproject-3f9c
        User <box user>
        IdentitiesOnly yes
        AddKeysToAgent no
        UserKnownHostsFile "~/.local/state/min-zed/sessions/myproject-3f9c/known_hosts"
        StrictHostKeyChecking yes
        ForwardAgent no
        ForwardX11 no
        ForwardX11Trusted no
        IdentityFile "~/.local/state/min-zed/sessions/myproject-3f9c/id_ed25519"
        ProxyCommand env MIN_BIN=/path/to/min MIN_ZED_STATE_DIR=... ~/.local/bin/min-zed _proxy myproject-3f9c

then a catch-all `Host min-zed.* !min-zed.*.*` whose ProxyCommand explains
that no stanza exists (it passes no hostname to the shell). The file is
rewritten only when its content changes. `_proxy` writes nothing to stdout
before it `exec`s `min session exec NAME sshd ...`, and logs one line per
attempt to `proxy.log` (mode 600, capped): `ok`, or `fail:` and why.

Any other `Include ~/.ssh/min-*.conf` line in `~/.ssh/config` is left
alone. What the install created (`~/.ssh`, `~/.ssh/config`) is recorded in
`~/.local/state/min-clients/ssh-config-created`, and removing the last such
Include deletes those, so `~/.ssh/config` ends byte for byte as it was.

### In use

`in_use_names` reads the host process table (`ps -xo pid=,ppid=,args=`)
for processes whose argv has `session exec NAME <path ending /sshd>`:
`_proxy` after its exec, ControlPersist masters, any ssh client. Nothing
contacts a box to find out.

## Client layer

### open / new / attach

1. Pick or activate the session (`min session activate --no-prompt
   [--loadout D]... --loadout zed [-n NAME] PATH`, D being your
   `[loadouts] default_loadouts`, which min skips once any `--loadout` is
   named; without `-n`, min names it and min-zed takes the one new session
   for PATH).
2. `prepare` (above).
3. `client_on_connect`: `ssh_connections` refresh (below).
4. `zed ssh://min-zed.NAME/workbench` (skipped with `--no-window`).

Zed then runs its own ssh to `min-zed.NAME`, downloads its remote server
into `~/.zed_server` in the box (once per Zed version) and opens
`/workbench`.

### The merger (`bin/min-zed-config`)

`settings.json`, `tasks.json` and `keymap.json` are JSONC and Zed edits
them too, so none is ever rewritten from a parsed object. The merger blanks
comments (keeping byte offsets) to parse a file, then makes textual edits:

- **settings.json.** In `ssh_connections`, entries whose host starts with
  `min-zed.` and are not live are deleted, and live sessions without one get
  `{"host": "min-zed.NAME", "nickname": "NAME", "projects": [{"paths":
  ["/workbench"]}]}` appended; every other entry and the comments between
  entries stay. A comment after your last entry stays on its line; taking
  min-zed's entries out again gives back the bytes. Without the key, it is
  spliced in after the opening brace and recorded
  (`STATE/settings-key-added`), so `--remove` takes it out only then.
- **tasks.json, keymap.json.** A block between `// min-zed:begin` and
  `// min-zed:end` right after the array's `[`, holding the seven tasks or
  the one binding, rewritten whole. The marks count only as comment lines
  of their own, the first right after the top-level `[`: the same text in
  your string or comment is yours. A file without an array gets one marked
  `// min-zed:array`.

`--sync NAME...` (from `open`, `attach`, `ssh`, `destroy`, `gc`) is the
full set of live prepared sessions and touches only `settings.json`;
`--install` (from `config` and `setup`) also writes the two blocks. The
opt-in record is `STATE/settings-installed`: `--sync` does nothing before
it. 0.1.0's records (`STATE/zed-config-installed`, `STATE/zed-config.json`)
are taken over on the first run, so its opt-in, the key it added and the
file it created carry over. A refresh is skipped when `min ls` fails, so a transient error never
empties the list. All three files are planned before any is written: one
that does not parse stops all three.

Each task runs, through `sh`, `$HOME/.local/bin/min-zed` with fixed
arguments, or prints where to run it when that file is missing (in a box
window, global tasks run in the box). New Box from Folder gets its folder
as `MIN_ZED_TASK_FOLDER` in the task's `env`, set from `$ZED_WORKTREE_ROOT`:
an env value is no shell text (Zed pastes `$ZED_*` into a command
unquoted), and with no folder open Zed does not offer the task. The
command `cd`s there, or, when it is no folder (a window on a single file),
says so in one line. Its terminal is the UI: the CLI's
numbered pickers and `[y/N]` questions read from it.

## State directory

`~/.local/state/min-zed/`:

| Path | What |
|---|---|
| `sessions/NAME/` | `id_ed25519` keypair, `known_hosts`, `user`, `home`, `sshd` |
| `created/NAME` | the session was activated by min-zed (has the loadout) |
| `orphan/NAME`, `kept/NAME` | first seen unused by `gc` or `status` (epoch); kept at a destroy prompt |
| `box/` | the empty folder `new --empty` activates on |
| `backups/` | `ssh_config.<time>`, `settings.json.<time>`, `tasks.json.<time>`, `keymap.json.<time>` |
| `settings-installed`, `settings-key-added`, `settings-created`, `tasks-created`, `keymap-created` | opt-in records (the ssh-config one is `~/.local/state/min-clients/ssh-config-created`) |
| `proxy.log` | one line per connection attempt |

In the box: `~/.ssh/min-zed/host_ed25519`, `~/.ssh/min-zed/authorized_keys`,
`~/.ssh/environment`, `~/.zed_server/` (Zed's server),
`~/.local/share/zed/node` (Claude Agent's Node, downloaded by Zed), the
`minimal-sandbox` skill in `~/.claude/skills/`.
