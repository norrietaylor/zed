# Annotated minimal.toml: pnpm/Node project

A worked example of how the sections compose. The schema is authoritative
for every key and type: https://minimal.dev/docs/reference/minimal-dot-toml

```toml
[upstream]
repo = "https://github.com/gominimal/pkgs"
branch = "main"
locked_commit = "d39aaaa581f983d6b3ba5eaaf383485a602f37f0"  # Always present, full hash.

[stack]
use = "pnpm"                     # The stack supplies the default build command.
build_packages = ["railway"]     # Extra build-time tool on top of the stack.

[defaults]
state_key = "dev"                # Keep node_modules etc. between task runs.

[session]
packages = ["base", "git", "nano"]

[tasks.dev]
exec = "pnpm run dev"            # Bare names resolve to /bin/pnpm in the sandbox.

[tasks.preview]
env_vars.PORT = "8080"           # Fixed value in the task environment.
bash = "pnpm run build && pnpm run start"

[tasks.deploy]
packages = ["railway"]           # Only this task gets the railway CLI.
exec = "railway up"
env_vars.RAILWAY_TOKEN = { inherit = true }        # Copied from the host env.
patches.dir."~/.config/railway" = "read-only"      # Host dir mapped read-only.

[tasks.shell]
interactive = true
packages = ["base", "git", "nano"]
exec = "bash -l"
```

Notes:

- Project init detects the pnpm stack from `pnpm-lock.yaml` and proposes most
  of this automatically; prefer it over hand-writing from scratch.
- Inherit env vars sparingly and prefer short-lived tokens; an inherited
  value is readable by everything the task runs.
- Map host files `"read-only"` unless the task genuinely writes them.
- Validate after every edit and fix everything the check reports.
