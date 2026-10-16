# Troubleshooting

Run `min-zed doctor` first: every warn/FAIL row says how to fix it.

| Symptom | Look at |
|---|---|
| `Zed connects with ssh min-zed.NAME: run min-zed ssh-config first` | `just install`, or `min-zed ssh-config` |
| Zed: "Could not resolve hostname min-zed.NAME" | the Include is missing or below a `Host`/`Match` block: `min-zed doctor` (ssh-config row) |
| `no min-zed ssh stanza for this min-zed.* host` | the session was never opened by min-zed, or is gone: `min-zed status`, then `min-zed attach NAME` |
| Zed hangs connecting, or "Permission denied (publickey)" | `~/.local/state/min-zed/proxy.log` (one line per connect), then `min-zed ssh NAME -- -v true` |
| `could not prepare session NAME (is it active, with openssh installed?)` | the session has no openssh: it was not activated with `--loadout zed`; recreate it with `min-zed new` |
| `session NAME reported an invalid …` | the box returned something odd; nothing was written. `min session attach NAME` and look |
| Zed downloads its server every time | normal per Zed version; with `MIN_ZED_PREFETCH=1`, see spike Z1 in [spike.md](spike.md) |
| Box without outbound HTTPS | add `"upload_binary_over_ssh": true` to that session's entry in Zed's settings (kept by settings sync) |
| No Claude notifications | `min-zed watch --ensure`; `min-zed status` AGENT column; the box needs the `zed` loadout (`~/.claude/min-zed-hook.sh`); macOS: allow notifications for Script Editor |
| `gc` does not offer a session | it is in use (a live ssh client of any tool), or another tool made it |

Logs: `~/.local/state/min-zed/proxy.log`, `watch.log`; settings backups in
`backups/`. A bug report should include `min-zed doctor`, `zed --version` and
`min version`.
