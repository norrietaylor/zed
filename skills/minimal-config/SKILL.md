---
name: minimal-config
description: "Use when writing or editing minimal.toml, adding a package to a project's Minimal config, defining or fixing a Minimal task, pinning or updating the [upstream], resolving `mip check` errors, explaining unexpected locked_commit changes, or choosing a stack or output for the Minimal build system. Do not use for session lifecycle or host CLI usage (minimal-setup), working inside a sandbox (minimal-sandbox), generic TOML syntax, or other manifests such as Cargo.toml or package.json."
---

# Authoring and validating minimal.toml

`minimal.toml` is the declarative config for Minimal: the package/build plane
(`mip` CLI) and sandboxed dev sessions (`min` CLI).

Read the schema rather than reproducing it from memory. Keys, types, and
section names change between releases, and a config written from a
half-remembered shape fails validation in ways that are tedious to unpick.

## Where to read, by what you are doing

| Activity | Reference |
|---|---|
| The `minimal.toml` schema: every section, key, and type | https://minimal.dev/docs/reference/minimal-dot-toml |
| Declaring or fixing a task: actions, args, env, patches, state | https://minimal.dev/docs/reference/tasks |
| Choosing or changing the stack | https://minimal.dev/docs/reference/stack-specs |
| Writing a package build spec in `packages/<name>/build.ncl` | https://minimal.dev/docs/reference/build-specs |
| Per-developer loadouts, which never belong in `minimal.toml` | https://minimal.dev/docs/reference/loadouts |
| Running `mip` on a Linux host | https://minimal.dev/docs/reference/cli-mip |
| Doing any of this from inside a sandbox | https://minimal.dev/docs/reference/sandbox-operations |

## Non-negotiables

These are policy, not schema, and the reference will not tell you them:

- **Always pin `[upstream]`.** Every minimal.toml you emit must carry `repo`,
  `branch`, and a full `locked_commit` hash. An unpinned config does not
  resolve, and an unpinned supply chain is not reproducible.
- **Never run `mip update` (or its passthrough `min update`) as a side
  effect** of other work. It re-resolves `branch` to its current HEAD and
  rewrites `locked_commit` in place for the upstream and every sideload. Run
  it only when the user explicitly asks for new pins, and tell them to
  expect a diff on those fields. An unexplained `locked_commit` change in a
  diff is usually this.
- **Always validate after any change**, whether you hand-edited the file or
  a CLI wrote it, and fix everything the check reports. The full `mip` CLI
  is Linux-only and does not exist on macOS installs; from inside a sandbox
  on any platform, the in-sandbox `min` helper has the equivalent check.
- **Profiles have been removed from Minimal.** Do not add a `profile` key, a
  `profiles/` directory, or a `--profiles` flag to anything, and treat any
  such leftovers in an existing config as stale.
- **`[harness]` no longer loads (0.7.0).** The build section is `[stack]`; a
  file that still says `[harness]` fails to load and names the rename. Rename
  the table, nothing else changes.
- **A task has no network setting.** It takes the network mode and egress
  rules of the session that runs it; `min task run` composes a default
  `host_ip` session. Do not invent a `network` key:
  https://minimal.dev/docs/reference/tasks
- **Read an unknown-field warning as a nesting error first.** The
  `help: do you need to update to a newer version of minimal?` line appended
  to it is a blanket suffix; upgrading usually fixes nothing. Check the key's
  nesting against the schema instead. Lifecycle hooks are the common trap: a
  loadout declares `[[lifecycle_hooks]]` at the top level, a project
  `[[session.lifecycle_hooks]]`. The warning repeats once per decode, so one
  activation prints it several times for a single mistake.
- **Scaffold before hand-authoring.** Project init inspects the source tree,
  detects the stack, and proposes a config. Hand-author only when detection
  picks wrong or the layout is unusual, and validate either way.

## Where a package goes

Put each package exactly where it is needed and nowhere broader. Scope is a
judgement call the schema cannot make for you:

| Need | Section |
|---|---|
| Tool needed to build the project | `[stack] build_packages` |
| Library the built artifact needs at runtime | `[stack] runtime_packages` |
| Tool every contributor's dev session should have | `[session] packages` |
| Tool exactly one task needs | `[tasks.<name>] packages` |

Some of these can be written by a CLI flag instead of by hand; see the
reference for your platform. Whichever way it is written, it belongs in the
committed config, not installed ad hoc: a package that exists only in your
sandbox works for you and fails for everyone else.

## Out of scope

- Session lifecycle and host CLI usage (activate, attach, destroy) belong to
  the minimal-setup skill; working from inside a sandbox belongs to
  minimal-sandbox. Defer to them.
- This skill covers Minimal config only, not Cargo.toml, package.json, or
  other ecosystems' manifests.

## References

Worked examples, to show how the pieces compose in a real project. They are
illustrations, not a schema; the reference table above is authoritative.

- `references/minimal-toml-rust.md`: annotated Rust project config.
- `references/minimal-toml-node.md`: annotated pnpm/Node project config.
- `references/tasks-examples.md`: annotated task recipes.
