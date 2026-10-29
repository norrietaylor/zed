# Zed guide

min-zed turns a Minimal session into an ssh host named `min-zed.NAME` and
opens Zed on `/workbench` in it as a remote project. Everything Zed does
after that (installing its server in the box, language servers, terminals,
tasks, agents) is Zed's own ssh remoting.

There is no Zed extension: Zed's extension API has no UI. `min-zed setup`
(through `min-zed config`) wires three of Zed's own surfaces instead: the
Remote Projects list, the Minimal tasks and one key.

## Requirements

- macOS. min-zed is Mac-only for now (Linux is not supported: the Zed
  app path, `osascript` and the tests assume a Mac).
- Zed (tested with 1.26.2; `min-zed doctor` notes any other version). The
  `zed` command (**Zed → Install CLI**) is optional: without it min-zed uses
  `/Applications/Zed.app/Contents/MacOS/cli`.
- `min-zed ssh-config` installed (`just install` does it): Zed runs
  `/usr/bin/ssh`, which reads `~/.ssh/config`, which then includes
  `~/.ssh/min-zed.conf`.
- The box needs outbound HTTPS once per Zed version, to download Zed's
  server (below).

`min-zed doctor` checks each of these.

## Opening a session

| Command | Session | Window |
|---|---|---|
| `min-zed open [PATH]` | the live min-zed session for PATH if there is one, else a new one | yes |
| `min-zed open PATH -n NAME` | NAME if it exists (for PATH), else a new one named NAME | yes |
| `min-zed new [PATH]` | always a new one | yes |
| `min-zed new --empty` | a new one with an empty `/workbench` | yes |
| `min-zed attach [NAME]` | an existing one (no NAME: a numbered picker) | yes |

`--no-window` on any of them skips the window.

New sessions are activated with your `default_loadouts` plus
`--loadout zed`. Each command prepares the box (pins its host key, pushes the
public key, refreshes the stanza), refreshes the `ssh_connections` entries,
then runs:

    zed ssh://min-zed.NAME/workbench

The command prints `min-zed.NAME`, so `ssh "$(min-zed open)"` works too.

Remote Projects, Open Recent and `zed ssh://min-zed.NAME/workbench` from
any terminal reconnect the same way: every connection goes through
`min-zed _proxy NAME`, which prepares the box again first, so a session
recreated under the same name heals itself.

## Zed and a box

- **The server.** Zed downloads its remote server into the box itself, into
  `/home/.zed_server/zed-remote-server-stable-<version>+stable.<build>.<sha>`,
  which persists with the session (seen with Zed 1.26.2, 2026-10-29). A box
  without outbound HTTPS can take it from the Mac instead: add
  `"upload_binary_over_ssh": true` to the box's `ssh_connections` entry;
  min-zed keeps an entry of yours as you wrote it.
- **Restricted Mode.** Zed opens a host it has not seen in Restricted Mode.
  Trust a new box once; it stays trusted.
- **Tasks run where the window is.** Global tasks run on the Mac in a local
  window, and in the box (bash, in `/workbench`) in a box window. The
  Minimal tasks therefore work from local windows; in a box window they
  print where to run them instead (below).
- **A terminal on the Mac.** A box window's terminals are in the box.
  `` ⌃⌥` `` opens a terminal on your Mac from any window
  (`workspace::NewTerminal` with `"local": true`), where `min-zed` works.
  It sits beside Zed's `` ⌃` `` (terminal panel) and `⌃~` (new
  terminal).
- **Recent projects.** Zed remembers boxes you opened. min-zed cannot edit
  that list: once a box is destroyed, remove it in Zed (Open Recent, then
  remove the entry). Remote Projects, which min-zed keeps, lists only live
  boxes.
- **Agent forwarding** stays off: the stanza says `ForwardAgent no` and the
  box's sshd refuses it anyway.
- **Several editors at once.** VS Code, Cursor and Zed have been connected
  to one box at the same time (2026-10-02); each min-<client> tool keeps its
  own key and host alias.

## The Minimal tasks

`min-zed config` puts seven tasks in Zed's global `~/.config/zed/tasks.json`.
Run them with **task: spawn** (⌘⇧R) and type "Minimal". In
`keymap.json`, ⌃⌥N runs New Box from Folder… and ⌃⌥O
Open Box… directly, from any window including Zed's welcome page (which
cannot list them otherwise):

| Task | Runs | Notes |
|---|---|---|
| Minimal: New Box from Folder… | `min-zed new FOLDER` | the window's folder; with none open, asks in the macOS folder picker |
| Minimal: New Empty Box | `min-zed new --empty` | |
| Minimal: Open Box… | `min-zed attach` | numbered picker |
| Minimal: Destroy Box… | `min-zed destroy` | the folder's box, else a picker; asks `[y/N]` |
| Minimal: Clean Up Idle Boxes… | `min-zed gc` | asks `[y/N/q]` per box |
| Minimal: Status | `min-zed status` | |
| Minimal: Doctor | `min-zed doctor` | |

Each opens in a task terminal, where the CLI's own pickers and `[y/N]`
questions are the UI: type the number or the answer there. The three that
open a window hide their terminal once they succeed; the others leave it to
be read. Every task runs `$HOME/.local/bin/min-zed` through `sh`, whatever
your login shell. Where that file is missing (a box window, or before
`setup`) it prints:

    min-zed: /home/.local/bin/min-zed not found. In a box window, run Minimal tasks from a local window or a Mac terminal (⌃⌥`); on the Mac, run min-zed setup.

## Zed's files (`min-zed config`)

All three files are in `~/.config/zed` (or `MIN_ZED_SETTINGS`,
`MIN_ZED_TASKS`, `MIN_ZED_KEYMAP`). They are JSONC that you and Zed edit, so
min-zed never rewrites one from a parsed object: every edit is textual.

**settings.json: Remote Projects.** One `ssh_connections` entry per live
min-zed session; Zed reloads the list live:

```jsonc
"ssh_connections": [
  { "host": "min-zed.myproject-3f9c", "nickname": "myproject-3f9c", "projects": [{ "paths": ["/workbench"] }] }
]
```

- Entries are added by `open`, `attach` and `ssh`, and dropped by
  `destroy`, `gc` and any later refresh once min no longer lists the
  session.
- Only entries whose host starts with `min-zed.` are added or removed. An
  entry of ours that already exists is kept exactly as written (so
  `"upload_binary_over_ssh": true` survives); every other entry, setting and
  comment, CRLF line endings and a BOM stay.
- If you have no `ssh_connections`, min-zed adds the key, and `--remove`
  takes it out again only then.
- When `min ls` fails, the existing `min-zed.*` entries are left as they are
  (a partial list would prune live ones), and doctor says it could not check
  them.

**tasks.json and keymap.json: marked blocks.** Each gets a block right
after the array's opening `[`:

```jsonc
[
  // min-zed:begin (managed by `min-zed config`; `min-zed config --remove` removes it; edits inside are replaced)
  { "label": "Minimal: New Box from Folder…", ... },
  // min-zed:end
  ...your tasks...
]
```

The block is min-zed's and is rewritten whole; everything outside it is
yours (Zed's keymap editor adds new bindings after it). A file with no array
gets one, marked `// min-zed:array`, and `--remove` takes that array out
again while nothing else went into it. Only `min-zed config` (and `setup`)
writes these two blocks; the refreshes from `open`, `destroy` and the rest
touch only `ssh_connections`.

For all three:

- Before each write the old file is copied to
  `~/.local/state/min-zed/backups/<file>.<time>`. A symlinked file is
  written through, and replaced in one rename.
- A file whose content would not change is not written.
- A file that does not parse (or whose top level is the wrong kind) is
  refused, and then none of the three is written.
- `min-zed config --print` shows the results without writing;
  `min-zed config --remove` takes everything out, restoring the bytes it
  found, and deletes a file min-zed created once it is empty again.

## Agents

- **Claude Agent and other ACP agents** in a box window run inside the box.
  Zed installs its own Node for them there (`~/.local/share/zed/node`; the
  loadout needs none). Sign in once per box: the login lives in the box and
  goes with it when the box is destroyed.
- **Minimal's Claude in a box.** A box with Minimal's `claude` package
  (`min add claude` in the box, or `claude` in a loadout of yours) has a
  `/usr/bin/claude` that loads Minimal's Claude plugin: the sandbox skill
  plus a session note that says the agent is in a sandbox and how to add
  tools. min-zed then points Claude Agent at it
  (`CLAUDE_CODE_EXECUTABLE=/usr/bin/claude` in the box's sshd environment,
  from the next connect), so Claude Agent starts like `claude` in a box
  terminal. Boxes without the package keep Claude Agent's own Claude. Not
  yet seen end to end.
- **Zed's own agent** runs in Zed on the Mac and works on the box's files
  through the remote project.
- **Notifications.** Zed's agent notifications cover threads in box windows
  too (seen 2026-10-29). Worth setting in your Zed settings:

  ```jsonc
  "agent": {
    "notify_when_agent_waiting": "all_screens",
    "play_sound_when_agent_done": true
  }
  ```

- **Claude Code in a Zed terminal** (in the box) can trigger the same Zed
  notification by ringing the terminal bell: set Claude's
  `preferredNotifChannel` to `"terminal_bell"` in the box (from Zed's docs;
  not tested with min-zed).

**Skills.** `min-zed setup` copies Minimal's host skills (`minimal-setup`,
`-config`, `-loadouts`, `-networking`, `-diag`) into `~/.agents/skills`
(Zed's agent) and `~/.claude/skills` (Claude Code) on the Mac, marked
`.min-zed-copy`; a skill directory of yours with the same name is left
alone, and `setup --remove` takes out only the marked copies. min-vscode
installs the same skills into `~/.claude/skills`: a copy marked by another
min tool is shared (each keeps its own mark, the last `setup` writes the
files), and `--remove` leaves it while another mark is in it. In a box, the
`zed` loadout puts Minimal's `minimal-sandbox` skill in `~/.claude/skills`,
which Claude Agent picks up (seen 2026-10-29), so an agent can add a missing
tool or package from inside the box instead of guessing.

## Troubleshooting

- **A Minimal task prints "not found".** It ran in a box window. Run it from
  a local window, or press `` ⌃⌥` `` and run `min-zed` there. On the
  Mac, run `min-zed setup`.
- **New Box from Folder… shows no picker.** The macOS dialog can open
  behind Zed's window: look with ⌘-Tab or Mission Control.
- **No boxes in Remote Projects.** `min-zed config` (once), then
  `min-zed attach NAME`. `min-zed doctor` shows missing or stale entries.
- **"Could not connect".** `min-zed doctor`, then `ssh -v min-zed.NAME true`,
  then `~/.local/state/min-zed/proxy.log` (one line per connection attempt).
  Zed's log (**zed: open log**) shows the ProxyCommand's stderr.
- **"no min-zed ssh stanza for this min-zed.\* host".** The session is gone,
  or was never prepared by min-zed: `min-zed status`, then
  `min-zed attach NAME`.
- **Host key changed after recreating a session.** Reconnect: `_proxy`
  re-pins before sshd starts.
- **The terminal starts in `/home`.** The `min:workbench` rc line moves
  interactive shells that start in `$HOME`; sessions without the loadout get
  it on the next connect.

## Not yet verified

Run end to end with Zed 1.26.2 on 2026-10-29: the tasks (through `sh`,
the window's folder reaching New Box from Folder…, the terminal hiding
after a window opens, the pickers and `[y/N]` answered in a task terminal,
the box-window line), the three keys on a US keyboard, Remote Projects, and
`setup --remove` leaving `~/.ssh/config` byte-identical. Not yet checked:

- New Box from Folder… with no folder open (the macOS folder picker).
- Destroying the box a window is on: what that window does.
- Claude Code's `terminal_bell` notification through Zed.
