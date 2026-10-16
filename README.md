<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/public/min-zed-mark-light.svg">
    <img alt="min-zed" src="docs/public/min-zed-mark-dark.svg" width="300">
  </picture>
</p>

<p align="center"><b>Minimal sessions as Zed remote projects.</b></p>

<p align="center">
  <a href="https://minimal.dev"><img alt="built with Minimal" src="docs/public/built-with-minimal.svg" height="22"></a>
</p>

`min-zed` opens a [Minimal](https://minimal.dev) session (a `min` microVM) in
[Zed](https://zed.dev) as an ordinary ssh remote project:

```sh
min-zed open ~/code/myapp      # session myapp-amber, then: zed ssh://min-zed.myapp-amber/workbench
```

Zed connects with stock `ssh`. A `Host min-zed.NAME` stanza routes it through a
ProxyCommand that runs OpenSSH's `sshd` *inside* the box over
`min session exec`, so there is no port, no daemon and no network path to the
box beyond what `min` already has. Zed then installs and runs its remote
server in the box exactly as on any Linux host: editor, language servers,
terminals and tasks all run next to your code in `/workbench`.

What you get on top of a plain ssh host:

- **One command per lifecycle step.** `open` (reuse or create), `new`,
  `attach`, `destroy`, `gc`, `status`; names are `<dir>-<word>`.
- **Pinned host key, per session.** Recreate a session and the next connect
  re-pins its key; Zed never shows a changed-key prompt and never trusts on
  first use.
- **Zed's connection list kept tidy** (opt-in): `ssh_connections` entries for
  `min-zed.*` follow your live sessions; your own entries are never touched.
- **Claude Code notifications.** The loadout records Claude's state in the box;
  `min-zed watch` posts a macOS notification when Claude needs input or has
  finished in a box Zed is connected to.
- **Safe tidy-up.** `gc` offers to destroy only min-zed sessions nothing is
  connected to — including other tools' ssh clients and Herdr agents.

## Install

Needs macOS, [Minimal](https://minimal.dev) (`min` 0.6), Zed with its CLI
(Zed → Install CLI), `jq`, `python3` and [`just`](https://just.systems).

```sh
git clone <this repo> ~/code/min-clients/zed && cd ~/code/min-clients/zed
just install     # ~/.local/bin/min-zed, loadout `zed`, ~/.ssh/min-zed.conf Include, Zed settings sync
min-zed doctor
```

`just install` adds a marked `Include ~/.ssh/min-zed.conf` at the top of
`~/.ssh/config` (backed up first; other min-<client> tools' Includes live
beside it) and does **not** edit your `config.toml`: min-zed activates every
session with your `default_loadouts` plus `--loadout zed` last. `just
uninstall` takes all of it back out.

## Quick start

```sh
cd ~/code/myapp
min-zed open                 # create (or reuse) the session, open it in Zed
min-zed status               # sessions, whether anything is connected, Claude's state
min-zed destroy              # this directory's session, after a y/N
```

More: [Zed guide](docs/zed.md) · [commands](docs/commands.md) ·
[configuration](docs/configuration.md) · [how it works](docs/how-it-works.md) ·
[security](docs/security.md) · [troubleshooting](docs/troubleshooting.md).

## Status

0.1.0. The transport, stanzas and lifecycle are the minx code that was used
daily with cmux and verified with Zed 1.22 (2026-10-02). Two Zed-specific
pieces are not yet verified against a live session and are marked so: the
server pre-fetch (off by default; spike Z1) and the agent-state watch
(spike E1). See [docs/spike.md](docs/spike.md).

## Credits

Split from [minx](https://github.com/noric-labs/minx), which did all of this
for cmux first; the ssh transport, `_proxy`, `prepare` and the stanza code are
its kernel, vendored here byte for byte. Apache-2.0.
