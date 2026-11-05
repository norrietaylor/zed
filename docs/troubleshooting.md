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
  `ok`, or `fail: min ls`, `fail: no session named NAME`, `fail: no id`
  (no box id to trust: see below), `fail: prepare` (the box's facts
  could not be fetched, were invalid or could not be written) or
  `fail: invalid home|sshd in PATH` (a stored fact no longer valid; the next
  `min-zed attach NAME` rewrites it).
  ssh runs the ProxyCommand under `$SHELL -c`: nushell and xonsh users
  should give Zed a POSIX `SHELL`.
- **"several boxes are named NAME, and min-zed cannot tell which is its
  own".** min 0.8 lets boxes share a name, and NAME's key dir is from
  before min-zed recorded box ids. min-zed leaves all of them alone (no
  Remote Projects entry, no stanza, no connect) rather than let min pick
  the running one. `min ls --json` shows their ids: give the others new
  names (`min session rename ID NEW`) and min-zed takes the one left, or
  remove `~/.local/state/min-zed/sessions/NAME` to let go of it.
- **"Several boxes are named NAME, and none is min-zed's."** You named a
  box min-zed never connected to, and several have that name. Give the
  others new names with `min session rename ID NEW` (`min ls --json` lists
  their ids), then try again.
- **"…/sessions/NAME/id is not a session id".** The file was edited or
  damaged; min-zed never passes it to min. Write the box's id (from `min ls
  --json`) into it, or, if the box is gone, remove
  `~/.local/state/min-zed/sessions/NAME`. Removing only the file makes
  min-zed take whatever one box has the name now, which may not be yours.
- **"your box NAME is gone; another box now has the name".** min-zed's box
  NAME was destroyed outside min-zed and another tool (or `min`) made a box
  with the same name. min-zed never reaches that box under your record:
  `min-zed destroy NAME` drops what is left of yours; then `attach NAME`
  reaches the other box if you mean to.
- **"NAME was renamed outside min-zed, to NEW. To use it here again: min
  session rename ID NAME."** (or "min lists box NAME with no name now").
  Run the command it gives (it names your box's id). Or remove
  `~/.local/state/min-zed/sessions/NAME` to let go of it.
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
