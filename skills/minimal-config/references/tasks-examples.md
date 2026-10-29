# Annotated task recipes

Worked examples of how task keys compose. The schema is authoritative for
every key, type, and default: https://minimal.dev/docs/reference/tasks

## Arguments: types, enums, defaults, interpolation

```toml
[tasks.greeter]
args.name = "string"                     # No default: mandatory flag --name.
args.greeting = { type = "string", help = "salutation", default = "Hello" }
exec = "echo %{greeting} %{name}"        # Nickel interpolation, not $VAR.

[tasks.deploy]
args.env = ["staging", "prod"]           # Enum: only these values accepted.
exec = "railway up --environment %{env}"
```

Running the task with `--name world` fills `%{name}`. The schema lists the
accepted arg types.

## exec vs bash vs echo

```toml
[tasks.build]
exec = ["cargo", "build", "--release"]   # One command; argv-list form.

[tasks.reset-db]
bash = "dropdb dev || true && createdb dev && psql dev < schema.sql"

[tasks.docs]
echo = "Docs live at https://minimal.dev/docs/reference/minimal-dot-toml"
# echo composes no sandbox at all; use it for pointers and reminders.
```

## Environment, host files, persistent state

```toml
[tasks.integration]
packages = ["postgresql-client"]         # Only this task gets psql.
env_vars.RAILS_ENV = "test"              # Fixed value.
env_vars.TEST_SHARD = { inherit = true }  # From the shell that runs
                                         # `min task run`, and gated:
                                         # allow-list the name under [vars]
                                         # in user_policy.toml first. See the
                                         # user-policy page. `min session run`
                                         # resolves the same declaration in
                                         # the DAEMON's environment instead,
                                         # so it cannot carry a client-shell
                                         # value; see minimal-setup.
patches.dir."~/.cache/test-fixtures" = "read-only"   # Host dir, read-only.
patches.file."~/.config/myapp/test.toml" = "read-only"  # Single host file.
state_key = "integration"                # Cache state across runs.
inherit_cwd = true                       # Start where invoked, not repo root.
```

User policy: https://minimal.dev/docs/reference/user-policy

Map host paths read-only unless the task genuinely writes them. `read-only`
stops the task writing the path, not reading it, so never map a credential
store such as `~/.aws`, `~/.ssh`, or `~/.netrc` into a task: every command
the task runs can read it. An inherited env var is readable the same way, so
inherit sparingly, and when a task genuinely needs a token, pass a scoped,
short-lived one rather than inheriting a long-lived credential.

## Interactive shells and TUIs

```toml
[tasks.shell]
interactive = true                       # TTY and stdin attached.
packages = ["base", "git", "nano"]
exec = "bash -l"
```

After adding or editing any task, validate the file and fix everything the
check reports.
