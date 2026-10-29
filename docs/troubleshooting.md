# Troubleshooting

Start with **Minimal: Doctor** (or `min-zed doctor`). It checks `min` and
its version, the Zed CLI and its version, `jq`/`python3`/`ssh`, the `zed`
loadout, the state dir, the ssh Include and that `ssh -G min-zed.NAME`
routes through `_proxy`, the `ssh_connections` entries, the tasks and keymap
blocks, and Minimal's skills on the Mac, and prints a one-line fix for each
problem. `min-zed status` lists sessions, whether something is connected,
and how long each has been idle.

- **`openssh is not installed in this session`.** The session was activated
  without a loadout carrying openssh. `min-zed open` activates with
  `--loadout zed`; for a session made by `min` directly, re-activate it with
  `--loadout zed`.
- **Connection problems.** `min-zed ssh NAME -- -v` runs plain ssh over the
  same transport and prints the negotiation;
  `~/.local/state/min-zed/proxy.log` has one line per connection attempt:
  `ok`, or `fail: no session named NAME`, `fail: prepare` (the box's facts
  could not be fetched, were invalid or could not be written) or
  `fail: invalid home|sshd in PATH` (a stored fact no longer valid; the next
  `min-zed attach NAME` rewrites it).
  ssh runs the ProxyCommand under `$SHELL -c`: nushell and xonsh users
  should give Zed a POSIX `SHELL`.
- **An earlier `Host`/`Match` block shadows the stanza.** doctor says so;
  keep the min-zed Include at the top of `~/.ssh/config`.
- **`cannot parse or edit as JSONC … fix it by hand`.** One of Zed's three
  files does not parse (Zed ignores it too); min-zed writes none of them
  until it is fixed. Then run `min-zed config` again.
- **doctor: "the min-zed block … is out of date".** Something edited inside
  the marked block, or this checkout is newer: `min-zed config` rewrites it.
- **A box is still in Open Recent after it was destroyed.** Remove it there;
  min-zed does not edit Zed's recent projects.

Zed specifics (tasks in box windows, Remote Projects, Restricted Mode):
[zed.md](zed.md#troubleshooting).
