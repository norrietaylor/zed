---
name: minimal-networking
description: Use when previewing a dev server running inside a Minimal session, publishing or forwarding a port from a min session, reaching a session by its .min.internal name, choosing a session's --network mode, restricting what a session can reach with egress rules, reaching the host or another session from inside a session, running min finalize-install so session names resolve, or when a session name does not resolve. Do not use for general nginx, proxy, or networking questions unrelated to Minimal, production ingress, Docker, or Kubernetes networking.
---

# Minimal session networking

Every flag and command here is documented; read the reference instead of
guessing. Verified on 2026-10-14 against min 0.7.0-rc2 (macOS arm64).

| Activity | Reference |
|---|---|
| `--network`, egress and ingress flags on `min session activate`; `min session policy`; `min net forward`; `min finalize-install` | https://minimal.dev/docs/reference/cli-min |
| What network a task gets (it follows its session) | https://minimal.dev/docs/reference/tasks |
| Linux host setup when sessions cannot start or names do not resolve | https://minimal.dev/docs/reference/linux-host-setup |
| Daemon flags: pinning the proxy port, the egress deny-all opt-out | https://minimal.dev/docs/reference/cli-minimald |

## Pick the mode at activation

`--network <none|host_ip|own_ip>`. `host_ip` is the default and shares the
host's network namespace (on macOS and `--provider local-minvmd`, the VM's).
`own_ip` gives the session its own address; it is the only mode that supports
`--ingress` and enforced egress rules. `none` has no network. Write the
underscore spellings; `no-net`, `host-net` and `own-ip` still work but print
a hint. Network and rules are fixed at activation: to change them, activate a
new session. `min session policy <session>` prints what a session ended up
with, including ports published at runtime.

## See a dev server running in a session

Choose by what the user already has:

- **Any mode, server already running:** `min net forward <session>
  <local>:<port>` puts the session's port on `localhost:<local>`. It dials
  `127.0.0.1:<port>` inside the session, so a localhost-only bind works, needs
  no reactivation and nothing installed in the session, and stays in the
  foreground until Ctrl-C. Offer this first.
- **`host_ip` session:** the name route also works with no reactivation.
  `<name>.min.internal` resolves through the HTTP proxy whose address the
  activation `names:` line and `min ls` print; call it `<proxy>` below. It is
  `127.0.0.1:7654` unless that port was busy, so read it rather than assume
  it. `curl -x http://<proxy> http://<name>.min.internal:<port>/`, or a
  browser with `--proxy-server=http://<proxy>`. After `min finalize-install`
  the name resolves in every program with no proxy.
- **`own_ip` session:** publish ports. `--ingress <ext>:<int>` at activation
  puts the port on `127.0.0.1:<ext>` on the host; the server must bind all
  addresses (`0.0.0.0`, `--host` for Vite and Astro). `--dynamic-ingress allow
  --dynamic-range <lo-hi>` lets the session publish later: `min net expose
  <port>` inside it, or any listener inside the range is published on its
  own. Both worked on macOS in the 0.7.0 verification, although the cli-min
  page says a VM-backed host refuses `allow` and `ask`; trust the running
  `min` over that sentence. The proxy route reaches an `own_ip` session only on
  a published port (`<name>.min.internal:<ext>`); any other port answers
  `the box has not published this port`.

Do not tell a user to open `http://127.0.0.1:<port>` on the host unless that
port was published with `--ingress`, dynamic ingress, or `min net forward`.
Every macOS session has its own namespace, so a bare session port is not on the
host.

## Decide what a session can reach

- An `own_ip` session with no egress flags reaches no external address and
  cannot resolve public names. Activation says so in one line. Open it with
  `--allow-dns-hosts <host>` (that host and nothing else), `--allow-subnets
  <cidr>`, or `--allow-subnets 0.0.0.0/0` for everything; narrow with
  `--deny-subnets` and `--allow-protocols`. `--deny-all-egress` states the
  default explicitly and combines with none of the others.
- A `host_ip` session keeps full access. Egress flags are accepted on it but
  only `--deny-all-egress` is enforced, and only on a native Linux host after
  `min finalize-install`; elsewhere `min` refuses the session or starts it with
  a note that the rules are not enforced. Use `own_ip` when the rules matter.
- A task takes the network and rules of the session that runs it; `min task
  run` composes a `host_ip` session (tasks reference above).

## Reach the host or another session from inside

- `host.min.internal` is the host. From a `host_ip` session it reaches a
  listener on the host's loopback (`curl http://host.min.internal:8787/`).
  `127.0.0.1` inside any macOS session is the VM's or the box's loopback, not
  the host's.
- Peer sessions resolve by name inside a session: `curl
  http://<peer>.min.internal:<port>/` from a `host_ip` session reaches a
  `host_ip` peer or an `own_ip` peer's listener directly, whatever that peer's
  egress rules say. The proxy route (`-x http://<proxy>`) works too for
  `host_ip` peers and published `own_ip` ports.
- From an `own_ip` session on macOS, `host.min.internal` and the host-side
  proxy did not answer in the 0.7.0 verification, even with `--allow-subnets
  0.0.0.0/0`; the internet and other `own_ip` sessions did, subject to its
  rules. Reach a host service from a `host_ip` session, or reach into the
  `own_ip` session from the host with `min net forward` instead.

## Names and sharp edges

- Session names must be valid hostnames: letters, digits and hyphens, case
  insensitive. `host`, `local`, `localhost` and `minimald` are reserved and a
  name shaped like a session id is refused. `min session rename` fixes an
  older name and re-registers it live.
- `min finalize-install` is the one root step. `--show` lists what the machine
  is missing and runs nothing, `--show --script` prints the script, `--undo`
  removes it. Until it runs, names work only through the proxy.
- Removed in 0.7.0: `min ssh-forward` (use `min net forward`), the daemon's
  HTTPS reverse proxy and client certificates (`min login` issues none).
- No IPv6 path, single host only, everything binds loopback. For a public URL
  bring your own tunnel (cloudflared, ngrok) pointed at a published port.
  Never tunnel the proxy port itself.
