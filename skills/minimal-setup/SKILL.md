---
name: minimal-setup
description: Use when the user wants to install Minimal, set up a project with min init, create/activate/attach/rename/destroy sandboxed min sessions, develop a repo in a Minimal sandbox, or script sessions in CI. Do not use for working inside a session or task sandbox (minimal-sandbox), minimal.toml authoring (minimal-config), personalizing sessions with loadouts (minimal-loadouts), session networking or preview URLs (minimal-networking), diagnostics bundles (minimal-diag), or non-Minimal sandboxes like venv, Docker, or direnv.
---

# Minimal setup and sessions

Minimal gives every project a declarative, sandboxed dev environment called a
session. `min` is the session CLI; `mip` is the package/build CLI, and there
is no native macOS `mip`, so never send a macOS user to it:
https://minimal.dev/docs/reference/cli
Read the session model at https://minimal.dev/docs/concepts/sessions and the
full command reference at https://minimal.dev/docs/reference/cli-min instead
of guessing flags.

## Install

Install with the shell installer (Linux x86_64/aarch64, macOS Apple Silicon):

```shell
curl --proto "=https" --tlsv1.2 -fsSL https://go.minimal.dev/stable | sh
```

For the nightly channel, replace `stable` with `nightly` in the
`go.minimal.dev` URL; pass `--version <version>` to the installer for a
specific release. Verify with `min --version`. Upgrade by re-running the same
command. If the user runs the legacy `minimal` CLI (pre v0.5.0), have them
re-install with the command above; the installer migrates the old CLI.

The installer never asks for root. The one step that needs it is
`min finalize-install`, which runs every privileged item the machine still
lacks in one `sudo` call; until it runs, Minimal works and session names
resolve only through the proxy (minimal-networking). `--show` lists what is
missing and runs nothing, `--show --script` prints the script, `--undo`
removes it all. Details on the cli-min reference above.

## Onboard a project

1. Run `min init` in the repository root. It detects the stack and scaffolds
   `minimal.toml`; pass `-y` to skip the confirmation prompt.
2. Add the team's tools to the existing `packages` list under `[session]` and
   commit `minimal.toml`. For anything deeper (stacks, tasks, upstream pins),
   hand off to the minimal-config skill; schema reference:
   https://minimal.dev/docs/reference/minimal-dot-toml
3. Run `min session activate --attach` from the repo root to create the
   session and enter its shell.

Activation uploads the project directory into the session's workspace. Run it
from a VCS root (`.git`, `.hg`, ...). For a directory that is not a VCS root,
pass `--sync tarball` explicitly; otherwise the upload is gated, and headless
runs skip it with a warning.

A missing `minimal.toml` no longer blocks activation: `min` reports it, gives
the session a default environment, points at `min init`, and continues
without writing a file. `--loadout` is validated first, so an unknown loadout
errors by name even there.

## Providers on Linux

On Linux, `min` can host sessions two ways, and the choice changes how a
session sees the network. `--provider` is a global flag, accepted on every
subcommand.

- `local-minimald` (the default) runs minimald natively on the host. Sessions
  share the host's network namespace under the default `--network host_ip`;
  `--network own_ip` isolates a session into its own namespace.
- `local-minvmd` runs minimald inside the minvmd microVM, the same topology
  macOS uses. A stock Linux install with KVM can use it. `--vm <name>` runs a
  named VM with its own state beside the default one (this provider only).

macOS has no choice to make: minvmd is the only backend there, so `--provider`
has no effect.

Sessions belong to the provider that created them. `min ls` lists only the
default provider's sessions, so pass the same `--provider` to `ls` and
`destroy` that you passed to `activate` — otherwise the session looks like it
vanished. For what the choice means when reaching the host or a peer session,
use minimal-networking.

## Session lifecycle

- `min ls` lists sessions (alias of `min session list`); it is scoped to one
  provider, see above.
- `min session attach [SESSION]` re-enters a session by name, id, or a unique
  id prefix (`exec`, `run`, `policy` and `destroy` accept the same); with no
  argument it resolves from the current directory. Exiting the shell detaches;
  the session keeps running, and it keeps running when the terminal or
  connection goes away. When the daemon ends an attach (destroy, another
  attach, shutdown) it prints a one-line reason and exits 254.
- Detach without exiting with the chord the attach banner prints, and
  rebind its leader under `[session-keys]` in `<config>/minimal/config.toml`:
  https://minimal.dev/docs/reference/loadouts
- The attach shell is `bash --noprofile --rcfile <daemon rc> -i` unless the
  composed `SHELL` names an installed known shell: `SHELL = "/usr/bin/fish"`
  under `[session.vars]` plus the `fish` package opens fish on attach.
- `min session hooks <SESSION>` lists the activation hooks the session
  composed, attributed to the project or loadout each came from.
- `min session rename <SESSION> <NEW_NAME>` renames a session. Names (also
  `--name` at activation) must be valid hostnames: letters, digits and hyphens,
  case-insensitive; `host`, `local`, `localhost` and `minimald` are reserved.
  Every session is reachable as `<name>.min.internal` (minimal-networking).
- `min session exec <SESSION> <COMMAND>...` runs a one-off command in an
  existing session, non-interactively, with the session's packages on PATH.
  A command that does not exist exits 127 with `command not found`.
- `min session run <SESSION> <TASK>` runs a task declared in the session
  project's `minimal.toml` inside that session. It is not the in-session
  equivalent of `min task run` — see the env-composition trap below.
- `min session destroy <SESSION>` removes one session;
  `min session destroy --all` removes every session (`-f` skips confirmation).
- `min stop` shuts down the daemon. Sessions survive it and are re-hosted by
  the next `min` command. `min stop --force` also stops a VM whose daemon no
  longer answers; unflushed data in the VM can be lost.

For the in-sandbox `min` helper commands available inside a session, link
https://minimal.dev/docs/reference/sandbox-operations

## Scripting and CI

- Always pass `--no-prompt` to `min session activate` in scripts, CI, and any
  non-interactive context. It fails with an actionable error (including a
  ready-to-paste policy snippet) instead of hanging on a prompt. It is implied
  when stdin is not a TTY, but pass it explicitly so intent is visible.
- Inherited vars need approval, so allow-list them BEFORE the first headless
  run rather than after it. Every `{ inherit = true }` name is gated by
  `<config>/minimal/user_policy.toml`
  (https://minimal.dev/docs/reference/user-policy); `--no-prompt` prints a
  ready-to-paste snippet naming what is missing, but only once it failed:

  ```toml
  [vars]
  allow = ["MY_TOKEN", "CI_*"]   # exact names or globs
  ```
- A project that declares lifecycle hooks is arbitrated by the same file's
  `[hooks]` section, keyed on the project root: undecided means a prompt, so
  `--no-prompt` fails with the stanza to paste. Hooks from the user's own
  loadouts are not arbitrated and need no entry. `--no-hooks` is recorded on
  the session, so it skips hooks at the later attach, detach, and destroy
  transitions too, not only at this activation.

  ```toml
  [hooks]
  allow = ["/abs/path/to/project"]
  ```
- Tasks for repeatable work, `exec` for ad hoc. Anything that runs more than
  once — CI steps, agent wrappers, test lanes — belongs in a declared task,
  run with `min task run <TASK>`: it is committed, reviewable, and carries
  its own packages, env, and policy. The minimal-config skill owns the schema:
  https://minimal.dev/docs/reference/tasks
- For one-off work against a session you already have, `min session exec
  <SESSION> <COMMAND>...` is the right lane. It composes the session's
  packages onto PATH, its output is complete from the first line, argv is
  passed through without re-quoting, and a backgrounded child that inherits
  its stdout does not hold the call open (all three reproduced on released
  0.5.4; `sh -c 'sleep 8 & echo started'` returns in under a second). Do not
  build a repeatable pipeline on it; do not avoid it for a single command.
- Do not fan out concurrent `min` commands from a cold state. With no daemon
  running each client races to autospawn one, and the losers fail with
  `Failed to ensure the minimald daemon is running: ... the detached
  supervisor exited during startup`, which is untrue: the VM started and the
  winner's session is healthy. Warm the daemon with one `min ls`, then
  parallelize.
- Read session state with `min session list --json` (or `--raw` for bare ids
  one per line). Never parse the human-readable table.
- `min session attach` opens an interactive shell and takes no command
  argument; use `min session exec` for a one-off command and a task for
  anything repeatable. Confirm any flag against `min session --help` before
  scripting it.
- `min session run <SESSION> <TASK>` does not compose the session's
  environment, and its help text reads as if it does. A task it runs sees
  neither `[session.vars]` nor the session's PATH additions, and an
  `env_vars.X = { inherit = true }` declaration resolves in the DAEMON's
  environment, failing with `inheriting environment variable 'X':
  environment variable not found` even when `X` is exported in the shell that
  typed the command (reproduced again on 0.7.0-rc2). `min task run` resolves
  the same declaration on the client and works. Until this is fixed, carry
  secrets with `min task run` (task sandbox) or `[session.vars]` at
  activation, never `min session run`.
- Commits made in a session's workspace come back to the host checkout with
  `git push min://<session>`, run from inside the session.

## Inside a session

Everything an agent does from inside a session or task sandbox (installing
tools with the in-sandbox `min` helper, persisting dependencies, task
limits, what survives where) belongs to the minimal-sandbox skill; hand off
there. The in-sandbox helper is a different tool from the host `min` CLI:
https://minimal.dev/docs/reference/sandbox-operations

To run a coding agent like Claude Code inside a session, add its package to
`[session] packages` and pass credentials with `[session.vars]` entries using
`inherit = true` (e.g. `ANTHROPIC_API_KEY`); the minimal-config skill owns
that schema.

## Loadouts

Personal tooling (editor, dotfiles, env vars) belongs in a loadout applied
with `min session activate --loadout NAME`, never in the committed
`minimal.toml`. Authoring loadout files, selection defaults, and composition
conflicts are the minimal-loadouts skill's job; hand off there.

## When something breaks

Tell the user `min bug` exists: it collects a diagnostic bundle to share with
the Minimal team. Do not walk through diagnostics here; the minimal-diag skill
owns that workflow.
