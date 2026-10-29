---
name: minimal-diag
description: Use when Minimal itself is broken or misbehaving and the user wants to report a bug, collect diagnostics, or send an existing bundle for diagnosis, e.g. Minimal is broken, a min session won't start, the minimald daemon is unreachable, a VM boot hangs, or the user has a minimal-diag bundle to send or upload, and the user mentions Minimal. Do not use for session names that do not resolve or ports that are not published (minimal-networking), for a daemon that fails to start only when several commands run at once (minimal-setup), for general debugging of the user's own application, or for bug reports about non-Minimal software.
---

# minimal-diag

This skill covers Minimal's diagnostic bundles: `min bug` collects one, and
`min diag upload` sends it somewhere that will diagnose it.

## When to run it

Run `min bug` for any hard-to-explain Minimal failure, before filing a report:
sessions that won't start, VM boots that hang, an unreachable daemon, or any
broken state you cannot explain. Collect the bundle first, then report.

## Invocation

Run `min bug` in the project directory. It is a host command and does not
exist inside a sandbox; from a session, have the user run it on the host
(minimal-sandbox skill). It writes
`minimal-diag-<timestamp>.tar.zst` to the current directory. Flags:

- `--output <path>` (or `-o`): write the bundle to a specific path instead.
- `--no-guest`: skip contacting daemons and collect host-side state only.
  Always pass this when the VM or daemon is wedged, so collection cannot
  hang on it.
- `--guest-timeout-secs <N>`: bound each provider's daemon-bundle download
  (default 60).
- `--log-tail-bytes <N>`: capture more of each log file, counted from the
  end. Raise it when the incident is older than the default tail covers.
- `--upload`: also send the bundle for a diagnosis (see below). The bundle is
  written to disk first either way, so a failed upload never costs the
  collection.

## Always safe to run

`min bug` works even when no daemon is running and never starts one, and it
mutates no state. Run it on any broken install; a failed collector becomes an
entry in the bundle's `manifest.json`, not a failed run.

## What is in the bundle, and privacy

The bundle contains host system facts, log tails, redacted config, state
listings, and a `manifest.json` of any collector that failed. Reassure users
before they share it: secret-shaped values (env vars, tokens) are redacted,
and session/project file contents are never included, only name/size
listings.

## Uploading it for a diagnosis

A bundle on disk helps nobody until someone reads it. `min bug --upload` does
both steps at once:

```
min bug --upload --context "min up hangs at 'booting' and never returns"
```

The bundle is written to disk first, so a failed upload never costs the
collection. On success it prints (verified on 0.7.0-rc2):

```
Report:  https://agents.minimal.farm/diag/<id>
The bundle is stored for the minimal team for 7 days. It is not diagnosed until someone signs in at the report URL and starts the diagnosis.
Expires: <date>
Delete:  min diag delete <id> <token>
```

Paste the report URL into the issue you file. The diagnosis is not automatic:
a member of the Minimal team signs in at the report URL and starts it, so do
not poll for a verdict. The bundle expires after 7 days; the `Delete:` line
removes it sooner, and it is the only place the delete token appears, so keep
it if the user may want the bundle gone.

To send a bundle collected earlier, or one somebody handed you:

```
min diag upload minimal-diag-20260913T175713Z.tar.zst --context "..."
```

`min diag collect` is the same command as `min bug`, under the `<noun> <verb>`
name; either spelling works. Full command reference:
https://minimal.dev/docs/reference/cli-min

### Always write `--context`

The agent that reads the bundle is told what is in it and nothing about what
you were trying to do. One sentence saying the command you ran, what you
expected, and what happened instead is the difference between a verdict and a
description of your log files.

### No account, no token

The upload needs no authentication: no account, no token, no login, and
nothing to set up first. That is about authentication only: the bundle still
carries host facts, log tails
and state listings, and the `--context` text is whatever the user wrote, so
either can identify a person or project. If the CLI cannot reach the portal,
the page at https://agents.minimal.farm/diag accepts the file.

### Before you upload

Uploading sends the bundle off the machine, which collecting it does not.
The archive is the same either way, with secret-shaped values redacted and
file contents never included, but confirm with the user before uploading a
bundle from a machine you were not asked to diagnose. Anyone with the report
URL can read the report.

## Reporting

A report URL is the useful thing to attach to an issue. When you cannot
upload, tell users to attach the bundle itself when reporting the issue to the
Minimal dev team.

## Out of scope

Do not root-cause the failure yourself from this skill. Collect the bundle
and, if the user wants a verdict, upload it. The portal's agent reads the
bundle against Minimal's own source, which you cannot do from here. For
deeper setup and session troubleshooting, use the minimal-setup skill.
A session name that does not resolve, or a port that is not published, is
networking configuration, not a bug to bundle: use the minimal-networking
skill.
