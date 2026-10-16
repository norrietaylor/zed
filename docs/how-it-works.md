# How it works

## Transport

```
Zed ──ssh min-zed.NAME──▶ ProxyCommand: env MIN_BIN=… MIN_ZED_STATE_DIR=… min-zed _proxy NAME
                                         │  prepare NAME (keys, facts, stanza refresh)
                                         └▶ exec min session exec NAME sshd -i -e -f /dev/null -h … -o …
```

`min session exec NAME argv…` is a byte-transparent, non-PTY exec channel;
with sshd in inetd mode (`-i`) on the far end it *is* the ssh connection.
sshd runs as the box user with `-f /dev/null` and every option on the command
line: host key `~/.ssh/minx/host_ed25519` (shared by every min-<client>
tool), `AuthorizedKeysFile ~/.ssh/min-zed/authorized_keys` (this tool's
only), public key only, no agent or X11 forwarding, TCP forwarding on (Zed's
port forwards), `internal-sftp`, and `PermitUserEnvironment=yes` to restore
the session variables sshd scrubs.

## prepare

Run by `open`, `new`, `attach`, `ssh` and every `_proxy`:

1. a per-session ed25519 key on the host (`sessions/NAME/id_ed25519`);
2. `min session exec NAME sh -c PREP min-zed PUBKEY`, which in the box makes
   the shared host key once (under a lock all min-<client> tools share),
   writes this tool's `authorized_keys`, `~/.ssh/environment` and the
   `/workbench` rc line, and prints `user= home= sshd= hostkey=`;
3. those facts are validated (the box is untrusted) and written atomically;
   `known_hosts` pins `min-zed.NAME` to the reported host key;
4. `~/.ssh/min-zed.conf` is rewritten if (and only if) its content changed.

So a recreated session, or a rotated key, heals on the next connect from any
client. `_proxy` prints nothing before its `exec`: stdout is the ssh stream.

## Stanzas

`~/.ssh/min-zed.conf` (mode 600) holds one block per live session plus a
catch-all:

```
Host min-zed.NAME
    User box
    IdentitiesOnly yes
    AddKeysToAgent no
    UserKnownHostsFile "…/sessions/NAME/known_hosts"
    StrictHostKeyChecking yes
    ForwardAgent no
    ForwardX11 no
    ForwardX11Trusted no
    IdentityFile "…/sessions/NAME/id_ed25519"
    ProxyCommand env MIN_BIN=/opt/homebrew/bin/min MIN_ZED_STATE_DIR=… …/min-zed _proxy NAME

Host min-zed.* !min-zed.*.*
    ProxyCommand env MIN_ZED_STATE_DIR=… …/min-zed _proxy --missing
```

It is Included from two marker lines at the top of `~/.ssh/config`, so its
`ForwardAgent no` wins over a later `Host *`. The catch-all explains a
missing stanza instead of a DNS error, and passes no hostname to a shell.

## Zed

`zed ssh://min-zed.NAME/workbench` makes Zed run `ssh` with its own
ControlMaster; Zed uploads or downloads its remote server into
`/home/.zed_server` and runs it there. `min-zed-config` keeps
`ssh_connections` in Zed's settings in step (text edit of the JSONC file;
see [zed.md](zed.md)).

## Use detection

`box_in_use NAME` reads the host's process table only: a process running
`… session exec NAME … sshd` is a live connection, from any tool (min-zed's
`_proxy` after its exec, min-cmux's, an ssh2 client, a ControlPersist
master). Herdr's app keeps a `remote-client-bridge` ssh to every saved
machine, so a connection whose parent is such a bridge counts only while
`herdr --machine DEST agent list` lists an agent (asked at most once a
minute). `gc` and the watch rely on it; neither ever contacts a box without a
live connection, because a connect starts a stopped box.

## Watch

A plain loop (`watch.pid`): every `MIN_ZED_INTERVAL` seconds it lists
min-zed's sessions, dates unused ones (`orphan/NAME`), and for each session in
use reads the agent-state line with `min session exec NAME cat`. The line is
validated (known state word, numeric epoch, control bytes stripped from the
message) and compared with `cache/NAME.agent`; only a change to
`needs-input` or `finished` posts a notification, via `osascript` with the
text passed as AppleScript arguments, never spliced into the script.

## Kernel

Everything above the `# --- kernel end ---` line in `bin/min-zed` (from
`# --- kernel begin …`) is vendored byte for byte from the min-cmux repo and
pinned by `tests/kernel.sha` (`tests/kernel-sha.sh` computes it); the Zed
layer below it uses only the functions and hooks in the kernel contract. The
kernel calls client hooks through `hook NAME` only when the client defines
them: min-zed defines `client_on_connect` (refresh Zed's settings) and
`client_on_destroy` (drop the entry and the cached state), and leaves
`client_linked` undefined (Zed's connection already shows in `box_in_use`).
