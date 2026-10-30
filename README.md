<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/public/min-zed-mark-light.svg">
    <img src="docs/public/min-zed-mark-dark.svg" alt="min-zed" width="300">
  </picture>
</p>

<p align="center"><strong>Run your agent in a Minimal box, and work in it from Zed.</strong></p>

<p align="center">
  <a href="#getting-started">Getting started</a> ·
  <a href="docs/zed.md">Zed guide</a> ·
  <a href="docs/commands.md">Commands</a> ·
  <a href="docs/how-it-works.md">How it works</a>
</p>

<p align="center">
  <a href="https://minimal.dev"><img src="docs/public/built-with-minimal.svg" alt="Built with Minimal"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache 2.0 license"></a>
</p>

## What is min-zed?

[Minimal](https://minimal.dev) runs each box in its own microVM on your Mac.
min-zed makes those boxes Zed remote projects: it creates a box from a
folder (or an empty one), opens a Zed window inside it, and tidies up
afterwards. Zed's own ssh remoting does the rest, so Zed's server, language
servers, terminals, tasks and agents all run in the box.

There is no Zed extension (Zed's extension API has no UI). Instead
`min-zed setup` wires Zed's own surfaces: your boxes in **Remote Projects**,
the **Minimal: …** tasks, and a key for a terminal on your Mac.

- **Nothing listens on a port.** An OpenSSH `sshd` runs inside the box on
  demand, behind a `ProxyCommand` that rides Minimal's own exec channel.
- **Only a public key enters the box.** Each box gets its own key; the box's
  host key is pinned; agent and X11 forwarding are off.
- **Nothing is destroyed without your y.** Destroy and clean-up always ask.

## Getting started

### 1. Requirements

- macOS with [Minimal](https://minimal.dev/docs) (`min` 0.7.0 or newer).
- [Zed](https://zed.dev) (tested with 1.26.2). The `zed` command is optional
  (**Zed → Install CLI**); without it min-zed uses the CLI inside
  `/Applications/Zed.app`.
- `jq`, `python3` and [`just`](https://just.systems) on the host.

```sh
brew install jq just
```

### 2. Install

```sh
git clone https://github.com/norrietaylor/zed.git min-zed && cd min-zed
just install
min-zed doctor
```

`just install` is `bin/min-zed setup`. It:

- links `~/.local/bin/min-zed` to this checkout, and the `zed` loadout into
  `~/.config/minimal/loadouts` (your `default_loadouts` are left alone);
- adds one `Include` line to the top of `~/.ssh/config`;
- lists your boxes in Zed's `settings.json` (`ssh_connections`), and adds a
  marked block to `tasks.json` (the Minimal tasks) and to `keymap.json`
  (`` ⌃⌥` ``, ⌃⌥N, ⌃⌥O), all in `~/.config/zed`;
- copies Minimal's skills (`minimal-setup`, `-config`, `-loadouts`,
  `-networking`, `-diag`) into `~/.agents/skills` (Zed's agent) and
  `~/.claude/skills` (Claude Code), so agents on your Mac know how to use
  Minimal. A skill of yours with the same name is never replaced.

Every file it edits is backed up first. `just uninstall` puts everything
back.

### 3. Work with boxes

Run the Minimal tasks with **task: spawn** (⌘⇧R), then type
"Minimal". Two have keys of their own, which work on Zed's welcome page
too: ⌃⌥N New Box from Folder…, ⌃⌥O Open Box….

| To | Do |
|---|---|
| Start on a project | Open the folder in Zed, then **Minimal: New Box from Folder…**. The folder is copied to `/workbench` in a new box and a window opens on it. With no folder open, it asks for one in the macOS folder picker. |
| Start from scratch | **Minimal: New Empty Box**: an empty `/workbench`. |
| Come back to a box | **Remote Projects** (⌃⌘O, or "projects: open remote"): every box is listed by name. Or **Minimal: Open Box…**, or Open Recent. |
| See what is running | **Minimal: Status**: each box, whether something is connected, how long it has been idle. |
| Finish with a box | **Minimal: Destroy Box…**: the folder's box, else pick one; asks `[y/N]`. |
| Tidy up | **Minimal: Clean Up Idle Boxes…** asks about each box nothing is connected to, oldest first. |
| Diagnose | **Minimal: Doctor**. |

**Tasks run where the window is.** In a local window they run on your Mac;
in a box window Zed runs them in the box, where min-zed is not installed, so
they print one line saying so. Run them from a local window, or press
`` ⌃⌥` `` in a box window for a terminal on your Mac and use
`min-zed` there.

**Trust a new box once.** Zed opens each new box in Restricted Mode. Click
Trust: the language servers it then starts run in the box. The box stays
trusted. [Why each box asks](docs/zed.md#zed-and-a-box).

**A box is a copy.** Edits inside it do not change the folder on your Mac.
Get work out with git: commit and push from the box's terminal (`git` is in
every box).

**Agents run in the box.** Claude Agent (and other ACP agents) in a box
window run inside the box: sign in once per box. Minimal's
`minimal-sandbox` skill is in the box's `~/.claude/skills`, so an agent can
add a missing tool or package from inside the box rather than reach for host
commands that do not exist there. The skills come from
[gominimal/minimal-skills](https://github.com/gominimal/minimal-skills)
(MIT), pinned; `just skills` refreshes them. More, including notifications,
in [docs/zed.md](docs/zed.md#agents).

## From a terminal

The tasks run the `min-zed` CLI, which also works on its own:

```sh
min-zed open ~/code/myproject     # box for the folder + a Zed window on /workbench
min-zed status                    # boxes, in use, idle age
min-zed destroy myproject-3f9c    # asks first
```

`ssh min-zed.NAME` works from any terminal too, and so do `scp` and
`rsync`. Every command is in [docs/commands.md](docs/commands.md).

## Documentation

- [Zed guide](docs/zed.md): how Zed reaches a box, the Minimal tasks, the
  files min-zed keeps in `~/.config/zed`, agents.
- [Commands](docs/commands.md): every CLI command and the naming rules.
- [Configuration](docs/configuration.md): environment, loadout, rolling back.
- [What never leaves the host](docs/security.md): keys, pinning, prompts.
- [How it works](docs/how-it-works.md): transport, sshd flags, stanzas, `_proxy`.
- [Troubleshooting](docs/troubleshooting.md), starting with **Minimal: Doctor**.
- [CHANGELOG](CHANGELOG.md).

## Uninstall

```sh
just uninstall
```

That is `min-zed setup --remove`: it takes out only what min-zed added (the
Zed entries and blocks, the ssh Include, the marked skill copies, the
links); if one of Zed's files does not parse, it stops and removes nothing
else until you fix it. Your boxes keep running; destroy them first if you are done with
them. Boxes stay in Zed's recent projects until you remove them there (Open
Recent).

## Contributing

`just check` runs shellcheck, a python3 compile check and the test suite
(twice: once with a long host prefix). The tests never touch a real box,
Zed or `~/.ssh`. Working rules are in [CLAUDE.md](CLAUDE.md).

Zed is a trademark of Zed Industries, Inc.; min-zed is not affiliated with
or endorsed by Zed Industries.

## License

[Apache-2.0](LICENSE).
