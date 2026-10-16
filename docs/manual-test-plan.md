# Manual test plan

End to end on a real host with Zed and min. Uses real sessions: run it
yourself, on a scratch project. Record versions and the date at the top of
each run.

## Install

- [ ] `just check` green.
- [ ] `just install`: `~/.local/bin/min-zed` links here; `min loadout list`
      shows `zed`; `~/.ssh/config` starts with the two min-zed marker lines
      (backup in `~/.local/state/min-zed/backups/`); `config.toml`
      unchanged; Zed settings untouched while no session exists.
- [ ] `min-zed doctor`: no FAIL.

## Open, attach, new

- [ ] `min-zed open ~/scratch/p`: session `p-amber` activated with
      `--loadout zed`; Zed opens `/workbench`; terminal starts in
      `/workbench`; `echo $MINIMAL_SESSION_NAME` prints `p-amber`.
- [ ] Zed settings: one `min-zed.p-amber` entry; other entries and comments intact.
- [ ] `min-zed open ~/scratch/p` again: no new session; Zed reopens it.
- [ ] `min-zed new ~/scratch/p`: `p-basil`; two entries.
- [ ] Zed "Open Remote" lists both by name and connects.
- [ ] `ssh min-zed.p-amber true` from a plain terminal; `rsync -e ssh` and `scp` to it.
- [ ] `min session destroy p-basil` then `min session activate --loadout zed -n p-basil ~/scratch/p`
      outside min-zed; `min-zed attach p-basil` connects with no host-key prompt (self-heal).

## Use, gc, status

- [ ] `min-zed status`: IN-USE yes for the box Zed is connected to, no otherwise.
- [ ] Close Zed's window; `min-zed gc --dry-run` lists the session; answer
      `n` in `min-zed gc`: kept, `kept/NAME` written.
- [ ] With the session connected from another min-<client> tool (or plain
      `ssh min-zed.NAME sleep 600`), `gc` leaves it out.

## Agent state (spike E1)

- [ ] `min-zed watch` running (`doctor`).
- [ ] Claude in a Zed terminal in the box: a permission prompt posts
      "NAME: needs input"; the end of a turn posts "NAME: finished"; working
      states post nothing; the same state does not post twice.
- [ ] Disconnect Zed: the watch stops reading that box (`proxy.log` and min's
      exec log show no reads).

## Pre-fetch (spike Z1)

- [ ] `MIN_ZED_PREFETCH=1 min-zed new ~/scratch/q`: the server file appears
      in `/home/.zed_server`; Zed's first connect does not download again.

## Destroy and uninstall

- [ ] `min-zed destroy p-amber` → `y`: session gone, stanza gone, Zed entry gone.
- [ ] `just uninstall`: `~/.ssh/config` byte-identical to before install;
      Zed settings without `min-zed.*` entries; symlinks gone; the watch stopped.
