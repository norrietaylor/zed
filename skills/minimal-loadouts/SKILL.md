---
name: minimal-loadouts
description: Use when personalizing Minimal sessions with loadouts, e.g. bringing an editor, dotfiles, shell config, env vars, or personal tooling into min sessions without touching the project's committed minimal.toml, authoring or fixing a loadout TOML file, selecting loadouts at activation, or resolving loadout conflicts. Do not use for the project-wide minimal.toml (minimal-config), session lifecycle (minimal-setup), or dotfiles outside Minimal: your own machine's .zshrc, stow, or devcontainers.
---

# Minimal loadouts

A loadout is a per-developer bundle of packages, env vars, and file patches
layered onto the sessions you activate. The project's `minimal.toml` declares
what every contributor needs; a loadout carries what YOU want on top. Direct
personal tooling (editors, multiplexers, dotfiles) into a loadout, never into
the committed `minimal.toml`. Full schema and composition rules:
https://minimal.dev/docs/reference/loadouts

## Files and selection

- One TOML file per loadout, at `<config>/minimal/loadouts/<name>.toml` or
  `<config>/minimal/loadouts/<name>/loadout.toml`
  (`~/.config/minimal/loadouts/` on both Linux and macOS). The second layout
  keeps the loadout, its hook scripts, and its files in one directory you
  can clone from git. The directory is not created automatically.
- The filename IS the loadout's name (for `<name>/loadout.toml`, the
  directory name is). A `name` field inside the file is deprecated: matching
  the filename warns that the field can be deleted, and differing from it
  warns and is ignored; the filename (or directory name) wins either way.
  There is no longer a `NameMismatch` failure. Do not write `name` into a new
  loadout, and delete it from an existing one.
- Defining one name in BOTH layouts is an error, not a precedence rule:
  `min loadout list` and any activation selecting it fail with `is defined
  twice`, naming both paths. Delete one of the two files.
- Apply with `min session activate --loadout NAME` (repeatable). Set
  `[loadouts] default_loadouts = ["NAME"]` in `<config>/minimal/config.toml`
  to apply automatically; any explicit `--loadout` overrides the defaults,
  and `--no-loadouts` skips them all.
- `min loadout list` shows every loadout in both layouts with its
  description. A loadout that fails to load (malformed TOML, or a name in
  both layouts) is reported on stderr and the command exits non-zero, with
  the valid loadouts still listed.

## Authoring

```toml
# file: ~/.config/minimal/loadouts/dev.toml (or dev/loadout.toml); the path names the loadout
description = "helix + zellij with my dotfiles"
packages    = ["helix", "zellij"]

patches = [
    { dest = ".config/helix/config.toml", source = "~/dotfiles/helix/config.toml" },
    { dest = ".config/helix/themes/",     source = "~/dotfiles/helix/themes/**/*.toml" },
]

[vars]
EDITOR = "hx"
PAGER  = { inherit = true, default = "less" }
```

Directives that prevent the common failures:

- `[vars]` values take three forms: a literal, `{ inherit = true }` (from
  the host env; dropped with a warning when unset), or
  `{ inherit = true, default = "..." }`. `inherit = false` is rejected;
  omit the variable instead. Non-POSIX-shaped names need `[[vars_lenient]]`.
- When the host variable named by `{ inherit = true }` is unset, a loadout
  and a project's `[session.vars]` diverge, despite carrying the same
  syntax. (`inherit` itself is always `true` here; it is the host variable
  it points at that is missing.) A loadout drops it and activates (`WARN ... loadout inherits X but it isn't set in the host env;
  dropping`); `[session.vars]` fails activation outright (`error: Composition
  gating failed: could not resolve pending var X`). Do not carry an
  expectation from one to the other.
- `patches` sources anchor to the host: `~` expands to the host home, the
  expanded path must be absolute, globs need a literal directory prefix
  (`~/dotfiles/**/*.lua` works, bare `**/*.lua` is rejected), and `..` is
  rejected everywhere. `dest` is relative to the session home; for glob
  sources it is a directory. A plain directory source (`source =
  "~/dotfiles/nvim"`) copies the directory's contents, recursively, into
  `dest` (before 0.6.0 it silently copied nothing). A missing source is
  dropped with a warning, so opportunistic dotfile patches are safe.
- `packages` names are not checked at activation; an unknown package fails
  later at session spawn with `no such package`.
- `[[lifecycle_hooks]]` DO execute. Each script is a table
  (`{ type = "inline", value = "..." }` or `{ type = "external", value =
  "./hooks/on-activate.sh" }`), never a bare string; an external path
  resolves under `$LOADOUT_ROOT`, which is `<config>/minimal/loadouts/<name>/`
  in both layouts (beside `<name>.toml`, or the directory holding
  `loadout.toml`). That directory must be real, not a symlink: a symlinked
  one fails activation with `no such directory`. A project declares the same
  block one level down, as `[[session.lifecycle_hooks]]`, so a top-level copy
  pasted into a `minimal.toml` is reported as an unknown field rather than
  run.
- YOUR loadout's hooks are your own files and run without a policy decision.
  The `[hooks]` section of `<config>/minimal/user_policy.toml` arbitrates
  the PROJECT that declares hooks, not your loadout
  (https://minimal.dev/docs/reference/user-policy): an undecided project
  prompts, and under `--no-prompt` fails the activation with the stanza to
  paste. Do not tell a user to allow-list their loadout; there is nothing to
  allow-list. `--no-hooks` skips every hook from both origins and is recorded on
  the session, so it holds for the later attach, detach, and destroy
  transitions too.

  ```toml
  [hooks]
  allow = ["/abs/path/to/project"]   # the project, never the loadout
  ```
- A hook's stdout AND stderr surface in the activation output, attributed to
  the loadout or project it came from, and capture is bounded by size as
  well as by the per-hook timeout that `min session hooks <session>` shows.
- The command runs inside the session, not on the host, so `$HOME` and every
  path in it resolve in the sandbox. Hooks run after `patches` are in place,
  so a hook may read a file the loadout patched in.

## Shell personalization: rc files and vars

By default the attach shell is
`bash --noprofile --rcfile <daemon rc> -i`, an interactive non-login bash.
The daemon's rc sources `~/.bashrc` from the session home, so a patched-in
`.bashrc` applies. The login chain (`.bash_profile`, `.bash_login`,
`.profile`) is never read; if your bash setup lives in `.bash_profile`, patch
it in with `dest = ".bashrc"`. A `.bashrc` that sets its own `DEBUG` trap
has a caveat; see the reference above. Setting `SHELL` in `[vars]` to
an installed known shell (with its package in the loadout) changes which
shell attach opens: `SHELL = "/usr/bin/fish"` plus `packages = ["fish"]`
lands you in fish, which reads its own patched `config.fish`. Env-only
settings can also go in `[vars]`: `PS1` in `[vars]` replaces the stock
prompt, and a once-only banner ships as a `PROMPT_COMMAND` payload that
unsets itself.

## Composition rules

Contributions from the project and every applied loadout compose into one
session; when they clash:

- Same package twice: deduplicated.
- Same var name, same value: deduplicated. Same name, DIFFERENT values: a
  hard conflict that fails activation; there is no override precedence. Fix
  the clash or add the name to the `ignore` list in your user policy.
- Same patch dest with different sources: likewise a conflict.
- Two loadouts with the same name cannot be applied together.

Loadout items also pass through the user policy
(`<config>/minimal/user_policy.toml`): a `deny` pattern fails the
composition client-side before the daemon is involved. A missing policy
file is an empty policy and activates fine.
