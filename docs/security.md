# Security

What never leaves the host:

- **Private keys.** Each session has its own ed25519 key in
  `~/.local/state/min-zed/sessions/NAME/` (dir 700, key 600). Only the public
  key is pushed into the box, to `~/.ssh/min-zed/authorized_keys`.
- **Your ssh agent and X11.** Every client path turns forwarding off itself
  (`ForwardAgent no`, `ForwardX11 no`, `ForwardX11Trusted no`,
  `AddKeysToAgent no`, `IdentitiesOnly yes`), and the box's sshd runs with
  `AllowAgentForwarding=no` and `X11Forwarding=no`. A `Host *` with
  `ForwardAgent yes` later in your config does not override it: the Include
  comes first.
- **Your other ssh identities.** `IdentitiesOnly yes` offers only the
  session's key.

Trust:

- **Host keys are pinned.** `StrictHostKeyChecking yes` against a per-session
  `known_hosts` that `prepare` writes from the key the box reports over
  `min session exec` (min's own authenticated channel). Never `accept-new`.
- **The box is untrusted.** The user name, home, sshd path and host key it
  reports are checked against strict patterns before anything is written,
  and the stored ones again when read; error messages strip control bytes.
  The agent-state line is validated the same way before it reaches a
  notification, and is passed to `osascript` as data.
- **Nothing listens.** No port is opened on the host or in the box; the only
  channel is `min session exec`.
- **Opt-in edits.** Nothing under `~/.ssh` is touched until
  `min-zed ssh-config`; Zed's settings not until `min-zed zed-config`. Both
  back up before writing and leave every byte outside their own lines/entries
  as it was (`--remove` restores `~/.ssh/config` byte for byte).
- **Explicit destroy.** `destroy` and `gc` never destroy without a typed `y`
  (`destroy -y` is the only way past it).

The server pre-fetch, when enabled, downloads Zed's remote server inside the
box over HTTPS from GitHub releases with `curl -f`; it verifies nothing
beyond TLS, as Zed's own installer does. It is off by default.
