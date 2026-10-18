#!/bin/sh
# Test suite for bin/min-zed and bin/min-zed-config. Run: sh tests/run.sh
# Every case runs in a subshell with stubbed min/zed/ssh/ssh-keygen/ps/
# osascript on a private PATH, a temp state dir, a temp HOME and a temp Zed
# settings path. Nothing real is touched.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STUBS=$ROOT/tests/stubs
BIN=$ROOT/bin/min-zed
CFG=$ROOT/bin/min-zed-config
# A python3 with tomllib (3.11+), found before the tests narrow PATH; the
# loadout cases skip without one. The CLI itself runs on any python3.
PYTOML=
for py in "$(command -v python3 2>/dev/null)" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -n "$py" ] && "$py" -c 'import tomllib' 2>/dev/null; then PYTOML=$py; break; fi
done
HP=min-zed.        # HOST_PREFIX; the long-prefix pass changes it
SELF=$(cd "$ROOT/bin" && pwd -P)/min-zed   # what min-zed bakes into ssh stanzas

# ---- harness -----------------------------------------------------------------

setup() {
    T=$(mktemp -d) || exit 1
    T=$(cd "$T" && pwd -P)
    trap 'rm -rf "$T"' EXIT
    HOME=$T/home STATE=$T/state FIXTURES=$T/fixtures STUB_LOG=$T/stub.log
    P=$T/proj          # project dir for open/new
    AP=$T/alpha-proj   # project dir of the pre-existing session "alpha"
    mkdir -p "$HOME" "$STATE" "$FIXTURES" "$T/bin" "$P" "$AP"
    : > "$STUB_LOG"
    for s in min ssh ssh-keygen ps; do ln -s "$STUBS/$s" "$T/bin/$s"; done
    # Never reached by bare name in a test: a call lands in $TRIPWIRE_LOG and
    # fails the case. zed, osascript and herdr are reachable only through
    # their *_BIN stubs in $T/stub-bin, which is not on PATH; curl only where a
    # case swaps in its stub.
    for s in open osascript zed code cursor windsurf herdr curl; do ln -s "$STUBS/tripwire" "$T/bin/$s"; done
    mkdir -p "$T/stub-bin"
    for s in zed osascript herdr; do ln -s "$STUBS/$s" "$T/stub-bin/$s"; done
    TRIPWIRE_LOG=$T/tripwire
    PATH=$T/bin:/usr/bin:/bin
    MIN_BIN=$T/bin/min SSH_KEYGEN_BIN=$T/bin/ssh-keygen ZED_BIN=$T/stub-bin/zed OSASCRIPT_BIN=$T/stub-bin/osascript
    HERDR_BIN=$T/stub-bin/herdr
    MIN_ZED_STATE_DIR=$STATE MIN_ZED_NO_WATCH=1 MIN_ZED_SETTINGS=$T/zed/settings.json MIN_NO_PATH_EXTEND=1
    ZS=$MIN_ZED_SETTINGS
    CREATED=$HOME/.local/state/min-clients/ssh-config-created   # shared by every min-<client> tool
    unset MIN_ZED_PREFETCH MIN_ZED_DEBUG XDG_CONFIG_HOME XDG_STATE_HOME ZDOTDIR VISUAL EDITOR
    export HOME PATH STUB_LOG FIXTURES MIN_BIN SSH_KEYGEN_BIN ZED_BIN OSASCRIPT_BIN HERDR_BIN \
        MIN_ZED_STATE_DIR MIN_ZED_NO_WATCH MIN_ZED_SETTINGS MIN_NO_PATH_EXTEND TRIPWIRE_LOG
    default_fixtures
}

default_fixtures() {
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active","git":{"branch":"main"},"attrs":null}]}
JSON
    printf 'user=box\nhome=/home\nsshd=/usr/sbin/sshd\nhostkey=ssh-ed25519 AAAAFAKE\n' > "$FIXTURES/facts.txt"
    : > "$FIXTURES/ps.txt"
}

# sessions_after NAME DIR: activate will add session NAME for DIR (alpha stays).
sessions_after() {
    cat > "$FIXTURES/sessions.after.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active","git":{"branch":"main"},"attrs":null},
 {"id":"ID-N","name":"$1","project_path":"$2","status":"active","git":{"branch":"main"},"attrs":null}]}
JSON
}

# run ARGS...: run min-zed, capturing RC, $T/out, $T/err. `ssh-config` and
# `zed-config` installs mark the case as opted in (see the guards below).
run() {
    case "$*" in
        ssh-config|"ssh-config --remove") : > "$T/opted.ssh" ;;
        zed-config|"zed-config --remove") : > "$T/opted.zed" ;;
    esac
    sh "$BIN" "$@" > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
}

# run_stdin INPUT ARGS...
run_stdin() {
    input=$1; shift
    printf '%s' "$input" | sh "$BIN" "$@" > "$T/out" 2> "$T/err"
    RC=$?
}

# run_cfg ARGS...: bin/min-zed-config against $ZS, backups under $STATE/backups.
run_cfg() {
    : > "$T/opted.zed"
    python3 "$CFG" --settings "$ZS" --backup-dir "$STATE/backups" --record "$STATE/zed-config.json" "$@" > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
}

# install_ssh: ssh-config with alpha's facts on disk (the gate for open/new/attach).
install_ssh() { run ssh alpha -- true; assert_rc 0; run ssh-config; assert_rc 0; reset_log; }

# run_watch: run `watch` for ~3s with a 1s interval, then stop it.
run_watch() {
    MIN_ZED_INTERVAL=1 sh "$BIN" watch > "$T/out" 2> "$T/err" < /dev/null &
    wp=$!
    sleep 3
    kill "$wp" 2>/dev/null
    wait "$wp" 2>/dev/null
}

reset_log() { : > "$STUB_LOG"; }

# skip REASON: the case counts as ok but is reported as skipped.
skip() { printf '# skip: %s\n' "$*" >&2; : > "$T/skip"; }

# ssh_g HOST: the real ssh's view of HOST through the test HOME's ~/.ssh/config.
ssh_g() { /usr/bin/ssh -G -F "$HOME/.ssh/config" "$1" 2>/dev/null; }

# ---- assertions (record failure, keep going) ---------------------------------

fail() {
    printf '# %s\n' "$*" >&2
    : > "$T/fail"
}

assert_log_contains() {
    grep -qF -- "$1" "$STUB_LOG" || { fail "log lacks: $1"; sed 's/^/#   log: /' "$STUB_LOG" >&2; }
}
assert_log_not_contains() {
    ! grep -qF -- "$1" "$STUB_LOG" || fail "log unexpectedly has: $1"
}
assert_log_count() { # N PATTERN
    c=$(grep -cF -- "$2" "$STUB_LOG")
    [ "$c" = "$1" ] || fail "expected $1 log line(s) with '$2', got $c"
}
assert_log_before() { # A B: first line with A precedes first line with B
    a=$(grep -nF -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1)
    b=$(grep -nF -- "$2" "$STUB_LOG" | head -1 | cut -d: -f1)
    { [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } || fail "expected '$1' before '$2' in log"
}
assert_file() { # PATH [CONTENT]
    [ -f "$1" ] || { fail "missing file: $1"; return 0; }
    [ $# -lt 2 ] || [ "$(cat "$1")" = "$2" ] || fail "content of $1 is '$(cat "$1")', expected '$2'"
}
assert_no_file() { [ ! -e "$1" ] || fail "should not exist: $1"; }
assert_file_contains() { grep -qF -- "$2" "$1" || { fail "$1 lacks: $2"; sed 's/^/#   file: /' "$1" >&2; }; }
assert_file_not_contains() { ! grep -qF -- "$2" "$1" || fail "$1 unexpectedly has: $2"; }
assert_mode() { # PATH MODE (octal)
    m=$(stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null)
    [ "$m" = "$2" ] || fail "mode of $1 is $m, expected $2"
}
assert_line_in() { # TEXT LINE: TEXT has LINE as a whole line
    printf '%s\n' "$1" | grep -qxF -- "$2" || { fail "no line '$2' in:"; printf '%s\n' "$1" | sed 's/^/#   /' >&2; }
}
assert_rc() { [ "$RC" = "$1" ] || fail "exit status $RC, expected $1"; }
assert_rc_nonzero() { [ "$RC" != 0 ] || fail "expected non-zero exit status"; }
assert_err_contains() { grep -qF -- "$1" "$T/err" || { fail "stderr lacks: $1"; sed 's/^/#   err: /' "$T/err" >&2; }; }
assert_out_contains() { grep -qF -- "$1" "$T/out" || { fail "stdout lacks: $1"; sed 's/^/#   out: /' "$T/out" >&2; }; }
assert_out_eq() { [ "$(cat "$T/out")" = "$1" ] || fail "stdout is '$(cat "$T/out")', expected '$1'"; }
assert_out_row() { # LEVEL CHECK
    grep -Eq "^$1 +$2 " "$T/out" || { fail "no '$1 $2' row"; sed 's/^/#   out: /' "$T/out" >&2; }
}

# cfg_hosts: the min-zed hosts in $ZS, parsed by the merger's own JSONC reader.
cfg_hosts() {
    python3 - "$ZS" "$CFG" <<'PY'
import sys, json
src = open(sys.argv[2]).read().replace('if __name__ == "__main__":\n    main()', '')
m = {}
exec(compile(src, 'min-zed-config', 'exec'), m)
cfg = m['load_jsonc'](open(sys.argv[1]).read())[0]
print(" ".join(e.get("host", "") for e in cfg.get("ssh_connections", [])))
PY
}

# ==== kernel cases (ported from minx; prefix-parameterised) ======================

MARK1='# min-zed ssh-config (remove with: min-zed ssh-config --remove)'
MARK2='Include ~/.ssh/min-zed.conf'

# alpha_facts: a plain `ssh` populates sessions/alpha/* for the stanza.
alpha_facts() { run ssh alpha -- true; assert_rc 0; }

# stanza_expected NAME: the min-zed.conf block prepare's facts produce for NAME.
stanza_expected() {
    printf '# %s\nHost %s%s\n    User box\n' "$1" "$HP" "$1"
    printf '    IdentitiesOnly yes\n    AddKeysToAgent no\n    UserKnownHostsFile "%s/sessions/%s/known_hosts"\n' "$STATE" "$1"
    printf '    StrictHostKeyChecking yes\n    ForwardAgent no\n    ForwardX11 no\n    ForwardX11Trusted no\n'
    printf '    IdentityFile "%s/sessions/%s/id_ed25519"\n' "$STATE" "$1"
    printf '    ProxyCommand env MIN_BIN=%s MIN_ZED_STATE_DIR=%s %s _proxy %s\n' "$T/bin/min" "$STATE" "$SELF" "$1"
}

# conf_expected NAME...: the whole min-zed.conf for those sessions, in that order.
conf_expected() {
    printf '# managed by min-zed ssh-config; do not edit\n'
    for n in "$@"; do printf '\n'; stanza_expected "$n"; done
    printf '\nHost %s* !%s*.*\n    ProxyCommand env MIN_ZED_STATE_DIR=%s %s _proxy --missing\n' "$HP" "$HP" "$STATE" "$SELF"
}

case_sshconfig_install_creates_include_and_stanza() {
    alpha_facts
    run ssh-config
    assert_rc 0
    assert_err_contains "added \`$MARK2\` to the top of $HOME/.ssh/config"
    assert_err_contains "$HOME/.ssh/min-zed.conf: 1 stanza(s); ssh ${HP}NAME reaches a session"
    assert_file "$HOME/.ssh/config" "$MARK1
$MARK2"
    assert_file "$HOME/.ssh/min-zed.conf" "$(conf_expected alpha)"
    assert_mode "$HOME/.ssh" 700
    assert_mode "$HOME/.ssh/config" 600
    assert_mode "$HOME/.ssh/min-zed.conf" 600
}

case_sshconfig_install_is_idempotent() {
    alpha_facts
    run ssh-config
    cp "$HOME/.ssh/min-zed.conf" "$T/first.conf"
    cp "$HOME/.ssh/config" "$T/first.config"
    run ssh-config
    assert_rc 0
    ! grep -q 'added' "$T/err" || fail "second install must not add the Include again"
    [ "$(grep -cxF -- "$MARK2" "$HOME/.ssh/config")" = 1 ] || fail "Include line duplicated"
    cmp -s "$T/first.config" "$HOME/.ssh/config" || fail "config changed on a second install"
    cmp -s "$T/first.conf" "$HOME/.ssh/min-zed.conf" || fail "min-zed.conf changed on a second install"
}

# existing_config: the user's ~/.ssh/config, a comment and a Host block, no trailing newline.
existing_config() {
    mkdir -p "$HOME/.ssh"
    printf '# mine\nHost other\n    HostName example.org' > "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$T/orig.config"
}

case_sshconfig_install_prepends_to_existing_config() {
    existing_config
    alpha_facts
    run ssh-config
    assert_rc 0
    { printf '%s\n%s\n' "$MARK1" "$MARK2"; cat "$T/orig.config"; } > "$T/want.config"
    cmp -s "$T/want.config" "$HOME/.ssh/config" || { fail "config is not marker + Include + original bytes"; sed 's/^/#   config: /' "$HOME/.ssh/config" >&2; }
}

case_sshconfig_install_keeps_symlinked_config() {
    mkdir -p "$T/dotfiles" "$HOME/.ssh"
    printf 'Host other\n    HostName example.org\n' > "$T/dotfiles/ssh_config"
    ln -s "$T/dotfiles/ssh_config" "$HOME/.ssh/config"
    alpha_facts
    run ssh-config
    assert_rc 0
    [ -L "$HOME/.ssh/config" ] || fail "$HOME/.ssh/config is no longer a symlink"
    assert_file "$T/dotfiles/ssh_config" "$MARK1
$MARK2
Host other
    HostName example.org"
}

case_sshconfig_remove_restores_original() {
    existing_config
    alpha_facts
    run ssh-config
    run ssh-config --remove
    assert_rc 0
    assert_err_contains "removed the min-zed Include from $HOME/.ssh/config"
    cmp -s "$T/orig.config" "$HOME/.ssh/config" || { fail "config not restored byte for byte"; sed 's/^/#   config: /' "$HOME/.ssh/config" >&2; }
    assert_no_file "$HOME/.ssh/min-zed.conf"
    run ssh-config --remove
    assert_rc 0
    assert_err_contains "no min-zed Include found in $HOME/.ssh/config"
    cmp -s "$T/orig.config" "$HOME/.ssh/config" || fail "second --remove changed the config"
}

# Another tool's Include (same shape, other name) is not ours to drop.
case_sshconfig_remove_keeps_other_tools_include() {
    mkdir -p "$HOME/.ssh"
    printf '%s\n%s\nHost other\n' '# min-cmux ssh-config (remove with: min-cmux ssh-config --remove)' 'Include ~/.ssh/min-cmux.conf' > "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$T/orig.config"
    alpha_facts
    run ssh-config
    run ssh-config --remove
    assert_rc 0
    cmp -s "$T/orig.config" "$HOME/.ssh/config" || { fail "other tool's Include disturbed"; sed 's/^/#   config: /' "$HOME/.ssh/config" >&2; }
}

case_sshconfig_print_touches_nothing() {
    alpha_facts
    run ssh-config --print
    assert_rc 0
    assert_out_eq "$(conf_expected alpha)"
    assert_no_file "$HOME/.ssh"
    run ssh-config --bogus
    assert_rc 1
    assert_err_contains "min-zed: ssh-config: unknown option --bogus"
    assert_no_file "$HOME/.ssh"
}

case_sshconfig_destroy_drops_stanza() {
    install_ssh
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    assert_file "$HOME/.ssh/min-zed.conf" "$(conf_expected alpha proj-amber)"
    run destroy -y alpha
    assert_rc 0
    assert_file "$HOME/.ssh/min-zed.conf" "$(conf_expected proj-amber)"
}

case_sshconfig_stale_state_dir_is_skipped() {
    alpha_facts
    mkdir -p "$STATE/sessions/ghost"
    printf 'box\n' > "$STATE/sessions/ghost/user"
    run ssh-config
    assert_rc 0
    assert_err_contains "1 stanza(s)"
    assert_file_not_contains "$HOME/.ssh/min-zed.conf" "Host ${HP}ghost"
    MIN_BIN=$T/no-such-min run ssh-config --print
    assert_rc 0
    grep -qF "Host ${HP}ghost" "$T/out" || fail "--print without min must list ghost"
    ! grep -q 'MIN_BIN=' "$T/out" || fail "no MIN_BIN word expected when min is not resolvable"
}

case_sshconfig_real_ssh_resolves() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    alpha_facts
    run ssh-config
    g=$(ssh_g "${HP}alpha")
    d=$STATE/sessions/alpha
    assert_line_in "$g" "user box"
    assert_line_in "$g" "identitiesonly yes"
    assert_line_in "$g" "stricthostkeychecking true"
    assert_line_in "$g" "identityfile $d/id_ed25519"
    assert_line_in "$g" "userknownhostsfile $d/known_hosts"
    assert_line_in "$g" "proxycommand env MIN_BIN=$T/bin/min MIN_ZED_STATE_DIR=$STATE $SELF _proxy alpha"
    g=$(ssh_g "${HP}nothing")
    assert_line_in "$g" "proxycommand env MIN_ZED_STATE_DIR=$STATE $SELF _proxy --missing"
}

case_sshconfig_forwarding_off_despite_host_star() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    mkdir -p "$HOME/.ssh"
    printf 'Host *\n    ForwardAgent yes\n    ForwardX11 yes\n    ForwardX11Trusted yes\n' > "$HOME/.ssh/config"
    alpha_facts
    run ssh-config
    g=$(ssh_g "${HP}alpha")
    assert_line_in "$g" "forwardagent no"
    assert_line_in "$g" "forwardx11 no"
    assert_line_in "$g" "forwardx11trusted no"
}

case_sshconfig_paths_with_spaces_and_percent() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    STATE="$T/st ate %x" MIN_ZED_STATE_DIR="$T/st ate %x"; export MIN_ZED_STATE_DIR
    alpha_facts
    run ssh-config
    assert_rc 0
    d=$STATE/sessions/alpha
    assert_file_contains "$HOME/.ssh/min-zed.conf" "IdentityFile \"$T/st ate %%x/sessions/alpha/id_ed25519\""
    assert_file_contains "$HOME/.ssh/min-zed.conf" "ProxyCommand env MIN_BIN=$T/bin/min MIN_ZED_STATE_DIR='$T/st ate %%x' $SELF _proxy alpha"
    g=$(ssh_g "${HP}alpha")
    assert_line_in "$g" "userknownhostsfile $d/known_hosts"
    assert_line_in "$g" "proxycommand env MIN_BIN=$T/bin/min MIN_ZED_STATE_DIR='$T/st ate %%x' $SELF _proxy alpha"
}

case_sshconfig_prefers_local_bin_symlink() {
    alpha_facts
    mkdir -p "$HOME/.local/bin"
    ln -s "$BIN" "$HOME/.local/bin/min-zed"
    run ssh-config
    assert_rc 0
    assert_file_contains "$HOME/.ssh/min-zed.conf" " $HOME/.local/bin/min-zed _proxy alpha"
    assert_file_not_contains "$HOME/.ssh/min-zed.conf" "$SELF"
    rm "$HOME/.local/bin/min-zed"; printf '#!/bin/sh\n' > "$T/other"; ln -s "$T/other" "$HOME/.local/bin/min-zed"
    run ssh-config
    assert_file_contains "$HOME/.ssh/min-zed.conf" " $SELF _proxy alpha"
}

SSHD_WORDS='[/usr/sbin/sshd] [-i] [-e] [-f] [/dev/null] [-h] [/home/.ssh/minx/host_ed25519] [-o] [LogLevel=ERROR] [-o] [PidFile=none] [-o] [StrictModes=no] [-o] [PubkeyAuthentication=yes] [-o] [PasswordAuthentication=no] [-o] [KbdInteractiveAuthentication=no] [-o] [AuthorizedKeysFile /home/.ssh/min-zed/authorized_keys] [-o] [PermitUserEnvironment=yes] [-o] [AllowTcpForwarding=yes] [-o] [GatewayPorts=no] [-o] [AllowAgentForwarding=no] [-o] [X11Forwarding=no] [-o] [PrintMotd=no] [-o] [PrintLastLog=no] [-o] [UseDNS=no] [-o] [Subsystem sftp internal-sftp]'

case_proxy_prepares_then_execs_sshd() {
    run _proxy alpha
    assert_rc 0
    d=$STATE/sessions/alpha
    pub=$(cat "$d/id_ed25519.pub")
    assert_log_before "min session exec alpha sh -c <script> min-zed $pub" "min session exec alpha /usr/sbin/sshd -i"
    assert_file "$STUB_LOG.pubkey" "$pub"
    assert_file "$d/known_hosts" "${HP}alpha ssh-ed25519 AAAAFAKE"
    assert_out_eq "sshd-stub [session] [exec] [alpha] $SSHD_WORDS"
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} alpha ok$' "$STATE/proxy.log" || fail "proxy.log: $(cat "$STATE/proxy.log")"
    assert_no_file "$HOME/.ssh"
    ! grep -q '^zed ' "$STUB_LOG" || fail "_proxy ran the zed CLI"   # _proxy never touches Zed
    assert_no_file "$T/zed"
}

case_proxy_prepare_failure_is_logged() {
    : > "$FIXTURES/facts.txt"
    run _proxy alpha
    assert_rc 1
    assert_err_contains "incomplete facts"
    assert_log_not_contains "sshd"
    [ ! -s "$T/out" ] || fail "nothing may reach stdout before the exec: $(cat "$T/out")"
    grep -q ' alpha fail: prepare$' "$STATE/proxy.log" || fail "proxy.log: $(cat "$STATE/proxy.log" 2>/dev/null)"
}

case_proxy_unknown_session_fails() {
    run _proxy nope
    assert_rc 1
    assert_err_contains "min-zed: no session named nope"
    assert_log_not_contains "session exec"
    [ ! -s "$T/out" ] || fail "nothing may reach stdout: $(cat "$T/out")"
}

case_proxy_missing_takes_no_host() {
    msg="min-zed: no min-zed ssh stanza for this ${HP}* host; run: min-zed status, then min-zed attach NAME (or min-zed ssh-config)"
    run _proxy --missing
    assert_rc 1
    assert_err_contains "$msg"
    # shellcheck disable=SC2016 # literal on purpose
    run _proxy --missing 'x.$(touch pwned)'
    assert_rc 1
    grep -qF 'pwned' "$T/err" && fail "host argument echoed: $(cat "$T/err")"
    assert_log_not_contains "min "
    MIN_BIN=/nonexistent PATH=/usr/bin:/bin sh "$BIN" _proxy --missing > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
    assert_rc 1
    assert_err_contains "$msg"
    assert_no_file "$STATE/proxy.log"
}

case_prepare_writes_atomically() {
    d=$STATE/sessions/alpha
    mkdir -p "$d"
    printf 'DECOY\n' > "$T/decoy"
    ln -s "$T/decoy" "$d/known_hosts"
    alpha_facts
    [ -z "$(find "$d" -name '.tmp.*')" ] || fail "temp files left behind"
    [ ! -L "$d/known_hosts" ] || fail "known_hosts is still a symlink: written in place"
    assert_file "$T/decoy" DECOY
    assert_file "$d/known_hosts" "${HP}alpha ssh-ed25519 AAAAFAKE"
    assert_file "$d/user" box
}

snap_alpha() {
    alpha_facts
    run ssh-config; assert_rc 0
    mkdir -p "$T/snap"
    for f in "$HOME/.ssh/min-zed.conf" "$STATE/sessions/alpha/known_hosts" "$STATE/sessions/alpha/user" \
        "$STATE/sessions/alpha/home" "$STATE/sessions/alpha/sshd"; do cp "$f" "$T/snap/$(basename "$f")"; done
}
# reject_fact FIELD LINE: with LINE in place of FIELD's fact, prepare fails
# naming FIELD and nothing on disk changes.
reject_fact() {
    grep -v "^$1=" "$FIXTURES/facts.txt" > "$T/facts.tmp"; printf '%s\n' "$2" >> "$T/facts.tmp"
    cp "$T/facts.tmp" "$FIXTURES/facts.txt"
    run ssh alpha -- true
    assert_rc 1
    assert_err_contains "min-zed: session alpha reported an invalid $1 ("
    for f in known_hosts user home sshd; do
        cmp -s "$STATE/sessions/alpha/$f" "$T/snap/$f" || fail "$1 '$2': sessions/alpha/$f changed"
    done
    cmp -s "$HOME/.ssh/min-zed.conf" "$T/snap/min-zed.conf" || fail "$1 '$2': min-zed.conf changed"
    default_fixtures
}

case_sshconfig_prepare_rejects_bad_facts() {
    printf 'user=a b\nhome=/home\nsshd=/usr/sbin/sshd\nhostkey=ssh-ed25519 AAAAFAKE\n' > "$FIXTURES/facts.txt"
    run ssh alpha -- true
    assert_rc 1
    assert_err_contains "min-zed: session alpha reported an invalid user (a b)"
    for f in known_hosts user home sshd; do assert_no_file "$STATE/sessions/alpha/$f"; done
    default_fixtures
    snap_alpha
    # shellcheck disable=SC2016 # literal on purpose
    for u in 'user=${HOME}' 'user=%h' 'user=-oops' 'user=r`id`' 'user=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do reject_fact user "$u"; done
    # shellcheck disable=SC2016
    for k in 'hostkey=ssh-rsa AAAAFAKE' 'hostkey=ssh-ed25519 AAAAFAKE extra' 'hostkey=ssh-ed25519 AA$AA'; do reject_fact hostkey "$k"; done
    # shellcheck disable=SC2016
    for h in 'home=home' 'home=/ho"me' 'home=/h%h' 'home=/a b' "$(printf 'home=/a\033b')"; do reject_fact home "$h"; done
    # shellcheck disable=SC2016
    for x in 'sshd=sshd' 'sshd=/usr/sbin/sshd$X'; do reject_fact sshd "$x"; done
}

case_sshconfig_prepare_accepts_valid_facts() {
    printf 'user=First.last_1-x\nhome=/home/u-1.x@y+z\nsshd=/nix/store/abc-openssh/bin/sshd\nhostkey=ssh-ed25519 AAAAC3+/z9==\n' > "$FIXTURES/facts.txt"
    alpha_facts
    run ssh-config
    assert_rc 0
    assert_file "$STATE/sessions/alpha/known_hosts" "${HP}alpha ssh-ed25519 AAAAC3+/z9=="
    assert_file_contains "$HOME/.ssh/min-zed.conf" "    User First.last_1-x"
}

case_sshconfig_catchall_skips_dotted_hosts() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    alpha_facts
    run ssh-config
    printf 'Host %sexample.com\n    User someone\n' "$HP" >> "$HOME/.ssh/config"
    g=$(ssh_g "${HP}example.com")
    assert_line_in "$g" "user someone"
    printf '%s\n' "$g" | grep -q '^proxycommand' && fail "${HP}example.com got a ProxyCommand"
    return 0
}

case_prepare_errors_strip_control_bytes() {
    printf 'user=box\nhome=/h\033]0;x\007%%\nsshd=/usr/sbin/sshd\nhostkey=ssh-ed25519 AAAAFAKE\n' > "$FIXTURES/facts.txt"
    run ssh alpha -- true
    assert_rc 1
    assert_err_contains "invalid home (/h?]0;x?%)"
    LC_ALL=C grep -q "$(printf '\033')" "$T/err" && fail "ESC reached stderr"
    { printf 'junk\033[31m\001\n'; printf '%01000d\n' 0; } > "$FIXTURES/facts.txt"
    run ssh alpha -- true
    assert_rc 1
    assert_err_contains "incomplete facts: junk?[31m?"
    [ "$(wc -c < "$T/err")" -lt 500 ] || fail "incomplete-facts message not cut"
}

case_sshconfig_stored_user_checked_on_read() {
    alpha_facts
    run ssh-config
    # shellcheck disable=SC2016 # literal on purpose
    printf '${HOME}\n' > "$STATE/sessions/alpha/user"
    run ssh-config --print
    assert_rc 0
    grep -q "^Host ${HP}alpha\$" "$T/out" && fail "stanza with a bad stored user printed"
    assert_err_contains "skipping alpha: invalid user in $STATE/sessions/alpha/user"
    printf 'a b\n' > "$STATE/sessions/alpha/user"
    sed '/^# ---- main/,$d' "$BIN" > "$T/lib"
    sh -c '. "$1"; MIN=$2; ssh_opts alpha' sh "$T/lib" "$T/bin/min" > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
    assert_rc 1
    assert_err_contains "min-zed: session alpha: invalid user in $STATE/sessions/alpha/user; not using it"
}

case_sshconfig_remove_loops_and_deletes_empty() {
    alpha_facts
    mkdir -p "$HOME/.ssh"
    printf '%s\n%s\n# mine\n%s\n%s\nHost other\n' "$MARK1" "$MARK2" "$MARK1" "$MARK2" > "$HOME/.ssh/config"
    run ssh-config --remove
    assert_rc 0
    assert_file "$HOME/.ssh/config" "# mine
Host other"
    rm -rf "$HOME/.ssh"
    run ssh-config
    run ssh-config --remove
    assert_rc 0
    assert_err_contains "removed the now empty $HOME/.ssh/config"
    assert_no_file "$HOME/.ssh"
    rm -rf "$HOME/.ssh"; mkdir -p "$HOME/.ssh" "$T/dotfiles"
    : > "$T/dotfiles/ssh_config"; ln -s "$T/dotfiles/ssh_config" "$HOME/.ssh/config"
    run ssh-config
    run ssh-config --remove
    [ -L "$HOME/.ssh/config" ] || fail "symlinked config was deleted"
}

case_sshconfig_write_failure_does_not_block_ssh() {
    alpha_facts
    run ssh-config
    printf '# sentinel\n' >> "$HOME/.ssh/min-zed.conf"
    cp "$HOME/.ssh/min-zed.conf" "$T/before.conf"
    chmod 500 "$HOME/.ssh"
    run ssh alpha -- true
    chmod 700 "$HOME/.ssh"
    assert_rc 0
    assert_err_contains "[min-zed] could not write $HOME/.ssh/min-zed.conf; leaving it as it was"
    assert_log_contains " ${HP}alpha true"
    cmp -s "$T/before.conf" "$HOME/.ssh/min-zed.conf" || fail "min-zed.conf changed although the dir was read-only"
}

case_sshconfig_existing_dir_mode_kept() {
    mkdir -m 755 "$HOME/.ssh"
    alpha_facts
    run ssh-config
    assert_rc 0
    assert_mode "$HOME/.ssh" 755
    assert_mode "$HOME/.ssh/min-zed.conf" 600
}

# shellcheck disable=SC2012 # ls -i is the portable inode
conf_inode() { ls -i "$HOME/.ssh/min-zed.conf" | awk '{ print $1 }'; }

case_sshconfig_unchanged_conf_not_rewritten() {
    alpha_facts
    run ssh-config
    touch -t 200001010000 "$HOME/.ssh/min-zed.conf"; : > "$T/stamp"; ino=$(conf_inode)
    reset_log
    run _proxy alpha
    assert_rc 0
    run ssh alpha -- true
    assert_rc 0
    [ "$(conf_inode)" = "$ino" ] || fail "min-zed.conf was replaced (new inode)"
    [ -z "$(find "$HOME/.ssh/min-zed.conf" -newer "$T/stamp")" ] || fail "min-zed.conf was modified"
    sessions_after beta "$P"; cp "$FIXTURES/sessions.after.json" "$FIXTURES/sessions.json"
    run _proxy beta
    assert_file "$HOME/.ssh/min-zed.conf" "$(conf_expected alpha beta)"
}

case_sshconfig_proxy_keeps_session_created_meanwhile() {
    alpha_facts
    run ssh-config
    sessions_after beta "$P"; cp "$FIXTURES/sessions.after.json" "$FIXTURES/sessions.json"
    run ssh beta -- true
    cp "$FIXTURES/sessions.json" "$T/with-beta.json"
    jq '.sessions |= map(select(.name != "beta"))' "$T/with-beta.json" > "$FIXTURES/sessions.json"
    run _proxy alpha
    assert_file "$HOME/.ssh/min-zed.conf" "$(conf_expected alpha)"
    printf 'cp "%s" "%s"\n' "$T/with-beta.json" "$FIXTURES/sessions.json" > "$FIXTURES/exec.hook"
    run _proxy alpha
    assert_rc 0
    assert_file "$HOME/.ssh/min-zed.conf" "$(conf_expected alpha beta)"
}

case_sshconfig_remove_deletes_what_it_created() {
    rm -rf "$STATE"
    run ssh-config
    assert_rc 0
    assert_file "$CREATED" "dir
config"
    run ssh-config --remove
    assert_rc 0
    assert_no_file "$HOME/.ssh"
    assert_no_file "$CREATED"
    mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    run ssh-config
    run ssh-config --remove
    assert_file "$HOME/.ssh/config" ""
    ! grep -q 'now empty' "$T/err" || fail "must not remove a config min-zed did not create"
}

case_sshconfig_backs_up_before_writing() {
    existing_config
    alpha_facts
    run ssh-config
    assert_rc 0
    b1=$(find "$STATE/backups" -name 'ssh_config.*' | head -1)
    cmp -s "$T/orig.config" "$b1" || fail "backup is not the config before install"
    assert_mode "$b1" 600
    run ssh-config
    [ "$(find "$STATE/backups" -name 'ssh_config.*' | wc -l | tr -d ' ')" = 1 ] || fail "a no-op install made a backup"
}

case_sshconfig_refuses_double_quote_in_state_dir() {
    STATE=$(printf '%s/st"q' "$T") MIN_ZED_STATE_DIR=$STATE; export MIN_ZED_STATE_DIR
    run ssh-config
    assert_rc 1
    assert_err_contains 'min-zed: state dir path contains a double quote; not writing'
    assert_no_file "$HOME/.ssh"
}

case_sshconfig_skips_invalid_dir_names() {
    alpha_facts
    mkdir -p "$STATE/sessions/my sess"
    printf 'box\n' > "$STATE/sessions/my sess/user"
    run ssh-config --print
    assert_rc 0
    ! grep -qF "Host ${HP}my sess" "$T/out" || fail "--print listed an invalid name"
    assert_err_contains "[min-zed] skipping my sess: not a valid stanza name"
}

case_ssh_passthrough() {
    run ssh alpha -- -v true
    assert_rc 0
    key=$STATE/sessions/alpha/id_ed25519
    assert_log_contains "ssh -i $key "
    assert_log_contains "-o ProxyCommand=$T/bin/min session exec alpha /usr/sbin/sshd"
    assert_log_contains "-o User=box"
    assert_log_contains " ${HP}alpha -v true"
    for o in ForwardAgent=no ForwardX11=no ForwardX11Trusted=no AddKeysToAgent=no; do assert_log_contains "-o $o "; done
    assert_log_contains " -o AllowAgentForwarding=no -o X11Forwarding=no "
}

case_ssh_opts_quote_and_double_percent() {
    STATE="$T/st ate %x" MIN_ZED_STATE_DIR="$T/st ate %x"; export MIN_ZED_STATE_DIR
    run ssh alpha -- true
    assert_rc 0
    assert_log_contains "-o UserKnownHostsFile=\"$T/st ate %%x/sessions/alpha/known_hosts\" "
}

# ---- PREP for real (the min stub only serves facts.txt) ----

prep_script() { sed -n "/^PREP='/,/'\$/p" "$BIN" | sed -e "1s/^PREP='//" -e "\$s/'\$//"; }
run_prep() {
    HOME=$T/box sh -c "$(prep_script)" min-zed "ssh-ed25519 AAAAUSER user" > "$1" 2> "$1.err" < /dev/null
}
BOXD=.ssh/minx   # the shared host key dir, under $T/box

assert_facts_only() {
    [ -s "$1" ] || fail "no facts in $1"
    ! grep -Ev '^[a-z]+=' "$1" >/dev/null || fail "non-fact stdout in $1: $(grep -Ev '^[a-z]+=' "$1")"
}

case_prep_extracts_and_prints_facts() {
    prep_script | grep -q '^echo "hostkey=' || fail "prep_script did not cut PREP out of bin/min-zed"
    run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    assert_facts_only "$T/p1"
    assert_line_in "$(cat "$T/p1")" "hostkey=ssh-ed25519 AAAAPUB"
    # authorized_keys is per tool; the host key is shared
    assert_file "$T/box/.ssh/min-zed/authorized_keys" "ssh-ed25519 AAAAUSER user"
    assert_no_file "$T/box/$BOXD/authorized_keys"
    assert_mode "$T/box/$BOXD/host_ed25519" 600
    run_prep "$T/p2" || fail "second PREP failed"
    assert_log_count 1 "ssh-keygen"
}

# Another tool's authorized_keys (minx's, min-cmux's) is never rewritten.
case_prep_leaves_other_tools_keys() {
    mkdir -p "$T/box/$BOXD" "$T/box/.ssh/min-cmux"
    printf 'ssh-ed25519 MINX\n' > "$T/box/$BOXD/authorized_keys"
    printf 'ssh-ed25519 CMUX\n' > "$T/box/.ssh/min-cmux/authorized_keys"
    run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    assert_file "$T/box/$BOXD/authorized_keys" "ssh-ed25519 MINX"
    assert_file "$T/box/.ssh/min-cmux/authorized_keys" "ssh-ed25519 CMUX"
}

# One /workbench line per rc file, whichever tool (or minx) wrote it.
case_prep_workbench_line_once() {
    run_prep "$T/p1" || fail "PREP failed"
    run_prep "$T/p2" || fail "PREP failed"
    for rc in .bashrc .zshrc; do
        [ "$(grep -c 'min:workbench' "$T/box/$rc")" = 1 ] || fail "$rc: $(grep -c 'min:workbench' "$T/box/$rc") workbench lines"
    done
    rm -rf "$T/box"; mkdir -p "$T/box"
    printf '# minx:workbench (managed by minx)\ncd-line\n' > "$T/box/.bashrc"
    run_prep "$T/p3" || fail "PREP failed"
    assert_file "$T/box/.bashrc" "# minx:workbench (managed by minx)
cd-line"
}

case_prep_waiter_keeps_lock_it_does_not_own() {
    mkdir -p "$T/box/$BOXD/.keygen"
    export MIN_KEYGEN_WAIT=2; run_prep "$T/p1"
    [ $? = 3 ] || fail "PREP should give up with exit 3"
    [ -d "$T/box/$BOXD/.keygen" ] || fail "waiter removed a lock it does not own"
    assert_log_count 0 "ssh-keygen"
    [ ! -s "$T/p1" ] || fail "stdout on failure: $(cat "$T/p1")"
}

case_prep_breaks_stale_lock() {
    mkdir -p "$T/box/$BOXD/.keygen"
    touch -t 200001010000 "$T/box/$BOXD/.keygen"
    export MIN_KEYGEN_WAIT=2; run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    assert_facts_only "$T/p1"
    assert_no_file "$T/box/$BOXD/.keygen"
}

prep_parallel() {
    n=1; while [ "$n" -le "$1" ]; do run_prep "$T/p$n" & n=$((n + 1)); done
    wait
}
assert_one_key() {
    k=$(cut -d' ' -f1-2 "$T/box/$BOXD/host_ed25519.pub")
    n=1; while [ "$n" -le "$1" ]; do
        assert_facts_only "$T/p$n"
        assert_line_in "$(cat "$T/p$n")" "hostkey=$k"
        n=$((n + 1))
    done
    [ "$(cat "$T/box/$BOXD/host_ed25519")" = "PRIVATE ${k#ssh-ed25519 AAAAPUB}" ] \
        || fail "key pair mismatch: $(cat "$T/box/$BOXD/host_ed25519") / $k"
    assert_log_count 1 "ssh-keygen"
    assert_no_file "$T/box/$BOXD/.keygen"
    [ -z "$(find "$T/box/$BOXD" -name '.new.*')" ] || fail "temp key left behind"
}

case_prep_concurrent_runs_agree_on_host_key() {
    export STUB_KEYGEN_DELAY=1.5 MIN_KEYGEN_WAIT=10
    prep_parallel 4
    assert_one_key 4
}

case_prep_regenerates_half_pair() {
    ln -s "$STUBS/mv" "$T/bin/mv"
    export STUB_KEYGEN_DELAY=0.2 STUB_MV_DELAY=1.5 MIN_KEYGEN_WAIT=10
    mkdir -p "$T/box/$BOXD"
    printf 'ssh-ed25519 AAAAOLD old\n' > "$T/box/$BOXD/host_ed25519.pub"
    prep_parallel 4
    assert_one_key 4
}

case_prep_keygen_failure_releases_lock() {
    export STUB_KEYGEN_FAIL=1
    run_prep "$T/p1" && fail "PREP succeeded with a failing ssh-keygen"
    assert_no_file "$T/box/$BOXD/.keygen"
    assert_no_file "$T/box/$BOXD/host_ed25519"
    [ ! -s "$T/p1" ] || fail "stdout on failure: $(cat "$T/p1")"
}

case_prep_stale_lock_stress() {
    ln -s "$STUBS/find" "$T/bin/find"
    export STUB_KEYGEN_DELAY=jitter
    r=0; while [ "$r" -lt 4 ]; do
        rm -rf "$T/box/.ssh"; reset_log
        mkdir -p "$T/box/$BOXD/.keygen"
        touch -t 200001010000 "$T/box/$BOXD/.keygen"
        prep_parallel 8
        assert_one_key 8
        [ ! -e "$T/fail" ] || { fail "round $r"; break; }
        r=$((r + 1))
    done
}

case_proxy_log_mode_600_and_capped() {
    run _proxy alpha
    assert_mode "$STATE/proxy.log" 600
    i=0; while [ $i -lt 1000 ]; do echo "old $i"; i=$((i + 1)); done > "$STATE/proxy.log"
    run _proxy alpha
    [ "$(($(wc -l < "$STATE/proxy.log")))" = 500 ] || fail "proxy.log kept $(wc -l < "$STATE/proxy.log") lines, expected 500"
}

case_proxy_log_failure_does_not_block() {
    mkdir "$STATE/proxy.log"
    run _proxy alpha
    assert_rc 0
    [ ! -s "$T/err" ] || fail "stderr: $(cat "$T/err")"
    head -1 "$T/out" | grep -q '^sshd-stub ' || fail "stdout is not the sshd stream"
}

# ---- naming ----

names_sessions() {
    { printf '{"sessions":[{"id":"ID-A","name":"alpha","project_path":"%s","status":"active","attrs":null}' "$AP"
      for n in "$@"; do printf ',{"id":"ID-%s","name":"%s","project_path":"%s","status":"active","attrs":null}' "$n" "$n" "$T/elsewhere"; done
      printf ']}\n'; } > "$FIXTURES/sessions.json"
}

case_names_first_free_word() {
    install_ssh
    names_sessions proj-amber
    sessions_after proj-basil "$P"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout zed -n proj-basil $P"
    names_sessions proj-basil
    sessions_after proj-amber "$P"
    run new "$P"
    assert_log_contains "min session activate --no-prompt --loadout zed -n proj-amber $P"
}

case_names_odd_characters_slugged() {
    install_ssh
    P="$T/My Repo!"; mkdir -p "$P"
    sessions_after my-repo-amber "$P"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout zed -n my-repo-amber $P"
}

case_open_rejects_bad_name() {
    install_ssh
    for n in 'a b' 'x*' 'Upper' '-dash' 'q?' 'p%'; do
        run open "$P" -n "$n"
        assert_rc 1
        assert_err_contains "min-zed: session name must be lowercase letters, digits and dashes: $n"
    done
    assert_log_not_contains "session activate"
    run open /nonexistent
    assert_rc 1
    assert_err_contains "not a directory"
}

# ==== Zed layer cases =============================================================

case_open_activates_with_loadout_and_launches_zed() {
    install_ssh
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    d=$STATE/sessions/proj-amber
    pub=$(cat "$d/id_ed25519.pub")
    assert_log_contains "min session activate --no-prompt --loadout zed -n proj-amber $P"
    assert_log_contains "min session exec proj-amber sh -c <script> min-zed $pub"
    assert_log_contains "zed ssh://${HP}proj-amber/workbench"
    assert_log_before "min session exec proj-amber sh -c" "zed ssh://"
    assert_file_contains "$HOME/.ssh/min-zed.conf" "Host ${HP}proj-amber"
    assert_out_eq "${HP}proj-amber"
    assert_no_file "$T/zed"      # settings sync is opt-in
}

case_open_needs_ssh_config() {
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 1
    assert_err_contains "Zed connects with ssh ${HP}NAME: run min-zed ssh-config first"
    assert_log_not_contains "session activate"
    assert_no_file "$HOME/.ssh"
}

case_open_reuses_live_session_for_path() {
    install_ssh
    sessions_after proj-amber "$P"; cp "$FIXTURES/sessions.after.json" "$FIXTURES/sessions.json"
    run ssh proj-amber -- true    # min-zed has prepared it: ours
    reset_log
    run open "$P"
    assert_rc 0
    assert_log_not_contains "session activate"
    assert_log_contains "zed ssh://${HP}proj-amber/workbench"
}

# A live session for PATH that another tool made is not reused.
case_open_ignores_other_tools_session() {
    install_ssh
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-C","name":"proj-amber","project_path":"$P","status":"active"}]}
JSON
    jq --arg p "$P" '.sessions += [{id:"ID-N", name:"proj-basil", project_path:$p, status:"active"}]' \
        "$FIXTURES/sessions.json" > "$FIXTURES/sessions.after.json"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout zed -n proj-basil $P"
}

case_open_name_for_other_dir_fails() {
    install_ssh
    run open "$P" -n alpha
    assert_rc 1
    assert_err_contains "session alpha is for $AP, not $P"
}

case_open_without_zed_cli_says_where() {
    install_ssh
    # an absolute path that does not exist: a bare `zed` would find a real one via the PATH fallback
    ZED_BIN=$T/no-such-zed; export ZED_BIN
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 1
    assert_err_contains "zed CLI not found (Zed: Install CLI, or set ZED_BIN); session proj-amber is ready: ssh://${HP}proj-amber/workbench"
}

case_new_always_fresh_and_rejects_taken_name() {
    install_ssh
    run ssh alpha -- true; reset_log
    sessions_after alpha-proj-amber "$AP"
    run new "$AP"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout zed -n alpha-proj-amber $AP"
    run new "$P" -n alpha
    assert_rc 1
    assert_err_contains "session alpha already exists (min-zed attach alpha)"
}

case_attach_launches_zed_and_fails_unknown() {
    install_ssh
    run attach alpha
    assert_rc 0
    assert_log_contains "min session exec alpha sh -c <script> min-zed "
    assert_log_contains "zed ssh://${HP}alpha/workbench"
    assert_log_not_contains "session activate"
    run attach nope
    assert_rc 1
    assert_err_contains "no session named nope"
}

case_destroy_yes_removes_session_and_state() {
    mkdir -p "$STATE/sessions/alpha"
    run destroy -y alpha
    assert_rc 0
    assert_log_contains "min session destroy alpha"
    assert_no_file "$STATE/sessions/alpha"
}

case_destroy_prompt() {
    run_stdin 'n
' destroy alpha
    assert_rc 0
    assert_err_contains 'Destroy Minimal session alpha ('"$AP"')? [y/N]'
    assert_log_not_contains 'min session destroy'
    assert_file "$STATE/kept/alpha"
    run destroy alpha            # stdin is /dev/null: no answer means No
    assert_log_not_contains 'min session destroy'
    run_stdin 'y
' destroy alpha
    assert_log_contains 'min session destroy alpha'
}

case_destroy_defaults_to_this_directory() {
    cd "$AP" || exit 1
    run destroy -y
    assert_rc 0
    assert_log_contains "min session destroy alpha"
    cd "$P" || exit 1
    run destroy -y
    assert_rc 1
    assert_err_contains "no session for $P; pass NAME"
}

# ---- Zed settings ----

zed_settings_fixture() {
    mkdir -p "$T/zed"
    cat > "$ZS" <<'EOF'
// Zed settings
{
  "theme": "One Dark", // mine
  "ssh_connections": [
    {"host": "box.example", "projects": []},
    {"host": "min-zed.gone", "nickname": "gone"}
  ],
  "vim_mode": true,
}
EOF
    cp "$ZS" "$T/orig.settings"
}

case_zedcfg_merge_keeps_comments_and_foreign_entries() {
    zed_settings_fixture
    run_cfg alpha beta
    assert_rc 0
    [ "$(cfg_hosts)" = "box.example min-zed.alpha min-zed.beta" ] || fail "hosts: $(cfg_hosts)"
    assert_file_contains "$ZS" '// Zed settings'
    assert_file_contains "$ZS" '"theme": "One Dark", // mine'
    assert_file_contains "$ZS" '"vim_mode": true,'
    assert_file_contains "$ZS" '{"host": "min-zed.alpha", "nickname": "alpha", "projects": [{"paths": ["/workbench"]}]}'
    b=$(find "$STATE/backups" -name 'zed-settings.json.*')
    cmp -s "$b" "$T/orig.settings" || fail "backup is not the file before the write"
    assert_mode "$b" 600
}

case_zedcfg_noop_when_unchanged() {
    zed_settings_fixture
    run_cfg alpha
    touch -t 200001010000 "$ZS"; : > "$T/stamp"
    # shellcheck disable=SC2012
    ino=$(ls -i "$ZS" | awk '{ print $1 }')
    run_cfg alpha
    assert_rc 0
    [ -z "$(find "$ZS" -newer "$T/stamp")" ] || fail "settings rewritten although unchanged"
    # shellcheck disable=SC2012
    [ "$(ls -i "$ZS" | awk '{ print $1 }')" = "$ino" ] || fail "settings replaced"
    [ "$(find "$STATE/backups" -name 'zed-settings.json.*' | wc -l | tr -d ' ')" = 1 ] || fail "a no-op made a backup"
}

case_zedcfg_remove_restores_original() {
    mkdir -p "$T/zed"
    printf '// mine\n{\n  "theme": "x", /* keep */\n  "vim_mode": true\n}\n' > "$ZS"
    cp "$ZS" "$T/orig.settings"
    run_cfg alpha beta
    run_cfg --remove
    assert_rc 0
    cmp -s "$ZS" "$T/orig.settings" || { fail "--remove is not byte-identical"; sed 's/^/#   zs: /' "$ZS" >&2; }
    printf '{\n}\n' > "$ZS"; cp "$ZS" "$T/orig.settings"
    run_cfg alpha
    run_cfg --remove
    cmp -s "$ZS" "$T/orig.settings" || fail "--remove on an empty object is not byte-identical"
}

# An entry of ours a user tuned (say upload_binary_over_ssh) is kept as written.
case_zedcfg_keeps_hand_tuned_entry() {
    mkdir -p "$T/zed"
    printf '{\n  "ssh_connections": [\n    {"host": "min-zed.alpha", "upload_binary_over_ssh": true}\n  ]\n}\n' > "$ZS"
    run_cfg alpha beta
    assert_rc 0
    assert_file_contains "$ZS" '{"host": "min-zed.alpha", "upload_binary_over_ssh": true}'
    [ "$(cfg_hosts)" = "min-zed.alpha min-zed.beta" ] || fail "hosts: $(cfg_hosts)"
}

case_zedcfg_symlink_kept_and_missing_file_created() {
    mkdir -p "$T/zed" "$T/dot"
    printf '{}\n' > "$T/dot/settings.json"
    ln -s "$T/dot/settings.json" "$ZS"
    run_cfg alpha
    [ -L "$ZS" ] || fail "symlinked settings replaced"
    assert_file_contains "$T/dot/settings.json" '"min-zed.alpha"'
    rm "$ZS"
    run_cfg
    assert_no_file "$ZS"           # nothing to add: no file made
    run_cfg alpha
    [ "$(cfg_hosts)" = "min-zed.alpha" ] || fail "hosts: $(cfg_hosts)"
}

case_zedcfg_refuses_bad_input() {
    mkdir -p "$T/zed"
    printf '{"ssh_connections": {"host": "x"}}\n' > "$ZS"; cp "$ZS" "$T/orig.settings"
    run_cfg alpha
    assert_rc 1
    assert_err_contains "ssh_connections is not a list"
    cmp -s "$ZS" "$T/orig.settings" || fail "file changed"
    run_cfg 'a b'
    assert_rc 1
    assert_err_contains "not a session name"
    printf '{ "a": \n' > "$ZS"
    run_cfg alpha
    assert_rc 1
    assert_err_contains "cannot edit"
}

# open/destroy keep Zed's list in step, but only after `zed-config` opted in.
case_zedcfg_sync_follows_sessions_after_opt_in() {
    install_ssh
    sessions_after proj-amber "$P"
    run open "$P"
    assert_no_file "$T/zed"
    run zed-config
    assert_rc 0
    [ "$(cfg_hosts)" = "min-zed.alpha min-zed.proj-amber" ] || fail "hosts after zed-config: $(cfg_hosts)"
    run destroy -y alpha
    [ "$(cfg_hosts)" = "min-zed.proj-amber" ] || fail "hosts after destroy: $(cfg_hosts)"
    run zed-config --remove
    assert_rc 0
    [ -z "$(cfg_hosts)" ] || fail "hosts after --remove: $(cfg_hosts)"
    assert_no_file "$STATE/zed-config-installed"
    run attach proj-amber
    [ -z "$(cfg_hosts)" ] || fail "sync after opt-out: $(cfg_hosts)"
}

# ---- server pre-fetch (UNVERIFIED, spike Z1) ----

case_prefetch_off_by_default() {
    install_ssh
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    assert_log_not_contains "zed --version"
    assert_log_count 1 "min session exec proj-amber sh -c"    # prepare only
}

case_prefetch_on_open_and_new_only() {
    install_ssh
    MIN_ZED_PREFETCH=1; export MIN_ZED_PREFETCH
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session exec proj-amber sh -c <script> min-zed <script> 1.22.0"
    assert_log_before "min session exec proj-amber sh -c <script> min-zed <script>" "zed ssh://"
    reset_log
    run attach proj-amber
    assert_log_not_contains "<script> 1.22.0"
    run open "$P"                  # reused, not fresh
    assert_log_not_contains "<script> 1.22.0"
    run _proxy proj-amber
    assert_log_not_contains "<script> 1.22.0"
    assert_log_not_contains "zed --version"
    sessions_after proj-basil "$P"
    run new "$P"
    assert_log_contains "min session exec proj-basil sh -c <script> min-zed <script> 1.22.0"
}

case_prefetch_skips_preview_and_odd_versions() {
    install_ssh
    MIN_ZED_PREFETCH=1; export MIN_ZED_PREFETCH
    for v in 'Zed Preview 1.23.0 – /Applications/Zed Preview.app' 'Zed 1.22.0;rm' 'garbage'; do
        STUB_ZED_VERSION_LINE=$v; export STUB_ZED_VERSION_LINE
        reset_log
        nm=v$(printf '%s' "$v" | cksum | cut -c1-6)
        sessions_after "$nm" "$P"
        run new "$P" -n "$nm"
        assert_rc 0
        assert_log_not_contains "min-zed <script>"
    done
}

fetch_script() { sed -n "/^FETCH='/,/'\$/p" "$BIN" | sed -e "1s/^FETCH='//" -e "\$s/'\$//"; }
launch_script() { sed -n "/^LAUNCH='/,/'\$/p" "$BIN" | sed -e "1s/^LAUNCH='//" -e "\$s/'\$//"; }

case_fetch_script_installs_atomically() {
    rm "$T/bin/curl"; ln -s "$STUBS/curl" "$T/bin/curl"
    mkdir -p "$T/box"
    fetch_script | grep -q 'zed-remote-server-stable-' || fail "fetch_script did not cut FETCH out"
    HOME=$T/box sh -c "$(fetch_script)" f 1.22.0 < /dev/null || fail "FETCH failed"
    f=$T/box/.zed_server/zed-remote-server-stable-1.22.0
    assert_file "$f"
    grep -q '^SERVER https://github.com/zed-industries/zed/releases/download/v1.22.0/zed-remote-server-linux-' "$f" || fail "server: $(cat "$f")"
    [ -x "$f" ] || fail "server not executable"
    [ -z "$(find "$T/box/.zed_server" -name '.min-zed-fetch.*')" ] || fail "temp left behind"
    # present: no download; a failing download leaves nothing
    reset_log
    HOME=$T/box sh -c "$(fetch_script)" f 1.22.0 < /dev/null
    assert_log_not_contains "curl"
    STUB_CURL_FAIL=1 HOME=$T/box sh -c "$(fetch_script)" f 1.23.0 < /dev/null
    assert_no_file "$T/box/.zed_server/zed-remote-server-stable-1.23.0"
    [ -z "$(find "$T/box/.zed_server" -name '.min-zed-fetch.*')" ] || fail "temp left after a failed download"
}

# LAUNCH returns at once and holds no stream open: a reader of its stdout sees EOF.
case_launch_script_detaches() {
    start=$(date +%s)
    out=$(sh -c "$(launch_script)" min-zed "sleep 5; echo late >> '$T/late'" 1.22.0 2>&1 < /dev/null)
    [ $(($(date +%s) - start)) -le 2 ] || fail "LAUNCH did not return at once"
    [ -z "$out" ] || fail "LAUNCH printed: $out"
    pkill -f "sleep 5; echo late" 2>/dev/null || true
}

# ---- use detection, gc, status ----

# own_sessions: alpha, beta, gamma active; min-zed prepared beta and gamma, not
# "cmuxbox" (another tool's).
own_sessions() {
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-B","name":"beta","project_path":"$T/beta-proj","status":"active"},
 {"id":"ID-G","name":"gamma","project_path":"$T/gamma-proj","status":"active"},
 {"id":"ID-C","name":"cmuxbox","project_path":"$T/c","status":"active"}]}
JSON
    mkdir -p "$STATE/sessions/alpha" "$STATE/sessions/beta" "$STATE/sessions/gamma"
}
age() { mkdir -p "$STATE/orphan"; printf '%s' "$(($(date +%s) - $2))" > "$STATE/orphan/$1"; }

case_inuse_any_tools_sshd_counts() {
    own_sessions
    # alpha: min-cmux's _proxy (exec'd into min); beta: a shell that mentions it;
    # gamma: a prepare exec (no sshd), not a connection.
    cat > "$FIXTURES/ps.txt" <<EOF
  100     1 ssh -o ControlMaster=yes min-cmux.alpha
  101   100 /opt/homebrew/bin/min session exec alpha /usr/sbin/sshd -i -e -f /dev/null
  200     1 /bin/zsh -c ssh min-zed.beta
  201     1 /usr/bin/ssh -o ConnectTimeout=5 build.example tail -f min-zed.beta
  300     1 /opt/homebrew/bin/min session exec gamma sh -c PREP min-zed key
EOF
    run gc --dry-run
    assert_rc 0
    ! grep -q '^alpha ' "$T/out" || fail "alpha is in use (another tool's sshd)"
    grep -q '^beta ' "$T/out" || fail "a shell or ssh that only mentions beta is not use"
    grep -q '^gamma ' "$T/out" || fail "gamma is not in use"
    ! grep -q cmuxbox "$T/out" || fail "gc lists another tool's session"
    assert_log_not_contains "session exec"     # deciding use never contacts a box
}

case_inuse_herdr_bridge_needs_agents() {
    own_sessions
    br="printf ready; exec /usr/bin/herdr remote-client-bridge --idle-timeout-v1"
    cat > "$FIXTURES/ps.txt" <<EOF
  100     1 ssh -C -F /tmp/herdr-ssh/config -o ControlMaster=auto -T min-herdr.beta $br
  101   100 /opt/homebrew/bin/min session exec beta /usr/sbin/sshd -i -e
  200     1 ssh -C -F /tmp/herdr-ssh/config -o ControlMaster=auto -T box@min-herdr.gamma $br
  201   200 /opt/homebrew/bin/min session exec gamma /usr/sbin/sshd -i -e
EOF
    printf '{"result":{"agents":[{"agent":"claude"}],"type":"agent_list"}}\n' > "$FIXTURES/herdr.agents.beta.json"
    run gc --dry-run
    ! grep -q '^beta ' "$T/out" || fail "beta has an agent: in use"
    grep -q '^gamma ' "$T/out" || fail "a bridge without agents is not use"
    run gc --dry-run
    assert_log_count 1 "herdr --machine min-herdr.beta agent list"   # cached for a minute
    assert_log_count 1 "herdr --machine min-herdr.gamma agent list"
}

case_gc_lists_oldest_first_and_filters_age() {
    own_sessions
    age beta 7200
    age gamma 200000
    run gc --dry-run
    assert_rc 0
    [ "$(sed -n 1p "$T/out" | tr -s ' ')" = "NAME PROJECT UNUSED" ] || fail "header: $(sed -n 1p "$T/out")"
    [ "$(sed -n 2p "$T/out" | tr -s ' ')" = "gamma $T/gamma-proj 2d" ] || fail "oldest first: $(sed -n 2p "$T/out")"
    [ "$(sed -n 3p "$T/out" | tr -s ' ')" = "beta $T/beta-proj 2h" ] || fail "row: $(sed -n 3p "$T/out")"
    assert_file "$STATE/orphan/alpha"          # dated now
    assert_log_not_contains "session destroy"
    run gc --dry-run --older-than 86400
    ! grep -q beta "$T/out" || fail "--older-than should drop beta"
    ! grep -q alpha "$T/out" || fail "--older-than should drop alpha (just dated)"
}

case_gc_answers() {
    own_sessions
    age alpha 400
    age beta 300
    age gamma 200
    run_stdin 'y
n
q
' gc
    assert_rc 0
    assert_log_contains "min session destroy alpha"
    assert_log_not_contains "min session destroy beta"
    assert_log_not_contains "min session destroy gamma"
    assert_no_file "$STATE/sessions/alpha"
    assert_file "$STATE/kept/beta"
    assert_err_contains "Destroy Minimal session beta ($T/beta-proj)? [y/N/q]"
    reset_log
    run gc                        # no answer means No, for every session
    assert_log_not_contains "session destroy"
}

case_gc_in_use_session_loses_its_age() {
    own_sessions
    age beta 200000
    printf '  1 0 ssh min-zed.beta\n  2 1 /x/min session exec beta /usr/sbin/sshd -i\n' > "$FIXTURES/ps.txt"
    run gc --dry-run
    ! grep -q '^beta ' "$T/out" || fail "beta is in use"
    [ $(($(date +%s) - $(cat "$STATE/orphan/beta"))) -lt 60 ] || fail "beta's age should restart while in use"
    : > "$FIXTURES/ps.txt"
    run gc --dry-run
    grep -q '^beta .* 0m$' "$T/out" || fail "beta's age should count from its last use: $(grep beta "$T/out")"
}

case_status_table() {
    own_sessions
    printf '  1 0 ssh min-zed.beta\n  2 1 /x/min session exec beta /usr/sbin/sshd -i\n' > "$FIXTURES/ps.txt"
    mkdir -p "$STATE/cache"; printf 'needs-input 1700000000' > "$STATE/cache/beta.agent"
    age gamma 7200
    run status
    assert_rc 0
    [ "$(sed -n 1p "$T/out" | tr -s ' ')" = "SESSION STATUS PROJECT MIN-ZED IN-USE AGENT UNUSED" ] || fail "header: $(sed -n 1p "$T/out")"
    grep -q "^beta  *active  *$T/beta-proj  *yes  *yes  *needs-input  *-\$" "$T/out" || fail "beta row: $(grep beta "$T/out")"
    grep -q "^gamma .* yes  *no  *-  *2h\$" "$T/out" || fail "gamma row: $(grep gamma "$T/out")"
    grep -q "^cmuxbox .* no  *no  *-  *-\$" "$T/out" || fail "cmuxbox row: $(grep cmuxbox "$T/out")"
}

# ---- watch: agent state ----

# connected NAME...: ps shows a live sshd exec for each.
connected() {
    : > "$FIXTURES/ps.txt"
    i=10; for n in "$@"; do
        printf '  %s 1 ssh min-zed.%s\n  %s %s /x/min session exec %s /usr/sbin/sshd -i\n' "$i" "$n" "$((i + 1))" "$i" "$n" >> "$FIXTURES/ps.txt"
        i=$((i + 10))
    done
}

case_watch_polls_only_connected_boxes() {
    own_sessions
    connected beta
    run_watch
    assert_log_contains "min session exec beta head -c 512 /home/.min-zed/agent-state"
    assert_log_not_contains "session exec gamma"
    assert_log_not_contains "session exec alpha"
    assert_log_not_contains "session exec cmuxbox"
}

case_watch_notifies_on_change_only() {
    own_sessions
    connected beta gamma
    now=$(date +%s)
    printf 'needs-input %s Permission: Bash\n' "$now" > "$FIXTURES/agent-state.beta"
    printf 'working %s\n' "$now" > "$FIXTURES/agent-state.gamma"
    run_watch
    assert_log_count 1 "osascript | min-zed | beta: needs input | Permission: Bash"
    assert_log_not_contains "gamma:"
    printf 'finished %s Done: all \033[31mgreen\n' "$((now + 1))" > "$FIXTURES/agent-state.gamma"
    reset_log
    run_watch
    assert_log_count 1 "osascript | min-zed | gamma: finished | Claude finished: Done: all [31mgreen"
    assert_log_not_contains "beta:"     # unchanged: cached
    LC_ALL=C grep -q "$(printf '\033')" "$STUB_LOG" && fail "ESC from the box reached osascript"
    return 0
}

case_watch_first_sight_of_stale_state_is_quiet() {
    own_sessions
    connected beta
    printf 'finished %s old news\n' "$(($(date +%s) - 3600))" > "$FIXTURES/agent-state.beta"
    run_watch
    assert_log_not_contains "osascript"
    assert_file "$STATE/cache/beta.agent"
}

case_watch_rejects_odd_state_lines() {
    own_sessions
    connected beta
    printf 'pwned %s x\n' "$(date +%s)" > "$FIXTURES/agent-state.beta"
    run_watch
    assert_log_not_contains "osascript"
    printf 'needs-input notanumber x\n' > "$FIXTURES/agent-state.beta"
    run_watch
    assert_log_not_contains "osascript"
    for w in 'needs' 'NEEDS-INPUT' 'finished2' 'Finished'; do
        printf '%s %s x\n' "$w" "$(date +%s)" > "$FIXTURES/agent-state.beta"
        run_watch
        assert_log_not_contains "osascript"
    done
    # the allowlist is exactly these six words, as the loadout's hook writes them
    # shellcheck disable=SC2016  # a literal $st in the pattern
    words=$(sed -n 's/^    case \$st in \([a-z|-]*\)) ;; \*) dbg .*/\1/p' "$BIN")
    [ "$words" = "started|working|needs-input|finished|idle|clear" ] || fail "state allowlist changed: '$words'"
    for w in started working needs-input finished idle clear; do
        grep -q "record $w" "$ROOT/loadouts/zed.toml" || fail "loadout hook never writes $w"
    done
}

case_watch_pid_file_and_stop() {
    MIN_ZED_INTERVAL=1 sh "$BIN" watch > "$T/out" 2> "$T/err" < /dev/null &
    i=0; while [ ! -f "$STATE/watch.pid" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    assert_file "$STATE/watch.pid"
    pid=$(cat "$STATE/watch.pid")
    run watch
    assert_rc 1
    assert_err_contains "watch already running (pid $pid)"
    run watch --stop
    assert_out_contains "stopped min-zed watch (pid $pid)"
    sleep 1
    kill -0 "$pid" 2>/dev/null && { fail "watch still running"; kill "$pid"; }
    assert_no_file "$STATE/watch.pid"
    # a pid file naming some other process is not ours to kill
    sleep 30 & other=$!
    printf '%s' "$other" > "$STATE/watch.pid"
    run watch --stop
    assert_out_contains "min-zed watch is not running"
    kill -0 "$other" 2>/dev/null || fail "--stop killed a process that is not a min-zed watch"
    kill "$other" 2>/dev/null
}

# ---- loadout ----

# loadout_hook N: the Nth lifecycle hook script of loadouts/zed.toml.
loadout_hook() {
    "$PYTOML" -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["lifecycle_hooks"][int(sys.argv[2])]["on_activate"]["value"])' \
        "$ROOT/loadouts/zed.toml" "$1"
}

case_loadout_parses_with_packages() {
    [ -n "$PYTOML" ] || { skip "no python3 with tomllib"; return 0; }
    p=$("$PYTOML" -c 'import tomllib; print(" ".join(tomllib.load(open("'"$ROOT"'/loadouts/zed.toml", "rb"))["packages"]))') \
        || { fail "loadouts/zed.toml does not parse"; return 0; }
    [ "$p" = "openssh curl jq rsync xxhash" ] || fail "packages: $p"
}

case_loadout_env_and_workbench_line() {
    [ -n "$PYTOML" ] || { skip "no python3 with tomllib"; return 0; }
    mkdir -p "$T/box"
    printf '# minx:workbench (managed by minx)\n' > "$T/box/.zshrc"
    loadout_hook 0 | env -i PATH="$PATH" HOME="$T/box" sh || fail "hook 0 failed"
    loadout_hook 0 | env -i PATH="$PATH" HOME="$T/box" FOO=bar PROMPT_COMMAND=x sh || fail "hook 0 failed"
    assert_file_contains "$T/box/.ssh/environment" "FOO=bar"
    assert_file_not_contains "$T/box/.ssh/environment" "PROMPT_COMMAND"
    [ "$(grep -c 'min:workbench' "$T/box/.bashrc")" = 1 ] || fail ".bashrc workbench lines: $(grep -c 'min:workbench' "$T/box/.bashrc")"
    [ "$(grep -c 'workbench' "$T/box/.zshrc")" = 1 ] || fail "legacy minx line got a second copy"
}

case_loadout_claude_hook_records_state() {
    [ -n "$PYTOML" ] || { skip "no python3 with tomllib"; return 0; }
    mkdir -p "$T/box/.claude"
    printf '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh /home/.claude/minx-hook.sh"}]}]}}\n' > "$T/box/.claude/settings.json"
    loadout_hook 1 | HOME=$T/box sh || fail "hook 1 failed"
    loadout_hook 1 | HOME=$T/box sh
    s=$T/box/.claude/settings.json
    [ "$(jq -r '.model' "$s")" = x ] || fail "other settings lost"
    [ "$(jq '[.hooks.Stop[].hooks[].command | select(test("min-zed-hook"))] | length' "$s")" = 1 ] || fail "min-zed hook duplicated or missing"
    [ "$(jq '[.hooks.Stop[].hooks[].command | select(test("minx-hook"))] | length' "$s")" = 1 ] || fail "minx's hook removed"
    [ "$(jq -r '.hooks.PreToolUse[-1].matcher' "$s")" = '*' ] || fail "PreToolUse matcher"
    h=$T/box/.claude/min-zed-hook.sh
    sf=$T/box/.min-zed/agent-state
    printf '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' | HOME=$T/box sh "$h" > "$T/hook.out"
    [ ! -s "$T/hook.out" ] || fail "hook printed: $(cat "$T/hook.out")"
    grep -Eq '^needs-input [0-9]+ Permission: Bash$' "$sf" || fail "state: $(cat "$sf")"
    printf '{"hook_event_name":"Stop","last_assistant_message":"All\\ngreen"}' | HOME=$T/box sh "$h"
    grep -Eq '^finished [0-9]+ All green$' "$sf" || fail "state: $(cat "$sf")"
    printf '{"hook_event_name":"PreToolUse"}' | HOME=$T/box sh "$h"
    grep -Eq '^working [0-9]+ $' "$sf" || fail "state: $(cat "$sf")"
    printf 'not json' | HOME=$T/box sh "$h" || fail "hook failed on bad input"
    [ -z "$(find "$T/box/.min-zed" -name '.agent-state.*')" ] || fail "temp state left behind"
}

# ---- doctor, completions, kernel pin ----

doctor_env() {
    XDG_CONFIG_HOME=$T/xdg; export XDG_CONFIG_HOME
    mkdir -p "$T/xdg/minimal/loadouts"
    : > "$T/xdg/minimal/loadouts/zed.toml"
    printf '  NAME  DESCRIPTION\n  zed   sshd for min-zed\n' > "$FIXTURES/loadouts.txt"
}

case_doctor_rows() {
    doctor_env
    run doctor
    assert_rc 1
    assert_out_row FAIL ssh-config
    for c in min zed tools loadout 'state dir' zed-config prefetch; do assert_out_row ok "$c"; done
    assert_out_row warn watch
    install_ssh
    run zed-config
    run doctor
    assert_rc 0
    assert_out_row ok ssh-config
    grep -q '^ok    zed-config   1 min-zed connection(s)' "$T/out" || fail "zed-config row: $(grep zed-config "$T/out")"
    STUB_ZED_VERSION_LINE='Zed 9.9.9 – x'; export STUB_ZED_VERSION_LINE
    rm "$T/xdg/minimal/loadouts/zed.toml"
    run doctor
    assert_out_row warn zed
    assert_out_row FAIL loadout
}

case_completions_parse() {
    run completions zsh
    assert_rc 0
    if command -v zsh > /dev/null; then zsh -n "$T/out" || fail "zsh -n rejected the zsh script"; fi
    grep -qF 'compdef _min_zed min-zed' "$T/out" || fail "zsh script lacks compdef"
    run completions bash
    assert_rc 0
    if command -v bash > /dev/null; then bash -n "$T/out" || fail "bash -n rejected the bash script"; fi
    run completions fish
    assert_rc_nonzero
    run _sessions
    assert_out_eq alpha
}

case_kernel_sha_pinned() {
    have=$(sh "$ROOT/tests/kernel-sha.sh" "$BIN") || { fail "kernel-sha.sh failed"; return 0; }
    [ "$have" = "$(cat "$ROOT/tests/kernel.sha")" ] || fail "kernel block hash $have differs from tests/kernel.sha (just kernel-sha after syncing from cmux)"
    # the kernel is client-free
    ! sed -n '/^# --- kernel begin/,/^# --- kernel end ---$/p' "$BIN" | grep -iqE '(^|[^a-z])zed([^a-z]|$)|osascript' || fail "client code inside the kernel block"
}

# Two min-<client> tools install and remove ssh-config in every order:
# ~/.ssh/config ends byte for byte as it was, or is gone (with ~/.ssh) when
# neither found one; the first removal leaves the other tool working.
make_tool_b() {
    mkdir -p "$T/tool-b"
    # shellcheck disable=SC2016  # $MIN_ZZ_STATE_DIR is for the copy
    sed -e 's/^TOOL=min-zed$/TOOL=min-zz/' -e 's/^HOST_PREFIX=.*/HOST_PREFIX=min-zz./' \
        -e 's/^ENV_PREFIX=MIN_ZED$/ENV_PREFIX=MIN_ZZ/' -e 's/^STATE=.*/STATE=$MIN_ZZ_STATE_DIR/' "$BIN" > "$T/tool-b/min-zz"
    grep -qx 'TOOL=min-zz' "$T/tool-b/min-zz" || fail "tool b not made"
}
run_b() { MIN_ZZ_STATE_DIR=$T/state-b sh "$T/tool-b/min-zz" "$@" > "$T/out" 2> "$T/err" < /dev/null; RC=$?; }

case_sshconfig_two_tools_coexist() {
    make_tool_b
    : > "$T/opted.ssh"
    for start in none existing; do
        # shellcheck disable=SC2086  # word-split on purpose
        for order in "a b a b" "a b b a" "b a a b" "b a b a"; do
            rm -rf "$HOME/.ssh" "$HOME/.local/state/min-clients"
            [ "$start" = none ] || existing_config
            set -- $order
            for t in "$1" "$2"; do
                if [ "$t" = a ]; then run ssh-config; else run_b ssh-config; fi
                assert_rc 0
            done
            assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/min-zed.conf"
            assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/min-zz.conf"
            first=$3
            for t in "$3" "$4"; do
                if [ "$t" = a ]; then run ssh-config --remove; else run_b ssh-config --remove; fi
                assert_rc 0
                [ "$t" = "$first" ] || continue
                if [ "$t" = a ]; then o=min-zz; else o=min-zed; fi
                assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/$o.conf"
                [ -f "$HOME/.ssh/$o.conf" ] || fail "$start/$order: $o.conf removed by the other tool"
            done
            if [ "$start" = none ]; then
                assert_no_file "$HOME/.ssh"
            else
                cmp -s "$T/orig.config" "$HOME/.ssh/config" || fail "$start/$order: config not restored byte for byte"
            fi
            assert_no_file "$CREATED"
        done
    done
}

# Another tool's PREP on the same box: one host key, its own authorized_keys.
case_prep_two_tools_share_host_key() {
    run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    HOME=$T/box sh -c "$(prep_script)" min-zz "ssh-ed25519 AAAAZZ zz" > "$T/p2" 2> "$T/p2.err" < /dev/null \
        || fail "PREP as min-zz failed: $(cat "$T/p2.err")"
    assert_log_count 1 "ssh-keygen"
    [ "$(grep '^hostkey=' "$T/p1")" = "$(grep '^hostkey=' "$T/p2")" ] || fail "tools got different host keys"
    assert_file "$T/box/.ssh/min-zed/authorized_keys" "ssh-ed25519 AAAAUSER user"
    assert_file "$T/box/.ssh/min-zz/authorized_keys" "ssh-ed25519 AAAAZZ zz"
    HOME=$T/box sh -c "$(prep_script)" '../x' "k" > "$T/p3" 2> "$T/p3.err" < /dev/null && fail "PREP took a tool name with a slash"
    return 0
}

# activate_session passes the user's default_loadouts on (min drops them once
# --loadout is named), then zed last and once.
case_activate_keeps_default_loadouts() {
    install_ssh
    mkdir -p "$HOME/.config/minimal"
    printf '[loadouts]\ndefault_loadouts = ["mine", "zed"]  # x\n' > "$HOME/.config/minimal/config.toml"
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout mine --loadout zed -n proj-amber $P"
}

# Safety: no test may let the CLI reach a real zed/osascript/herdr/min/ssh-keygen.
# Every override is a stub under $T or a nonexistent absolute path; bare
# names would resolve through the kernel's /opt/homebrew/bin PATH fallback.
case_tests_use_absolute_tool_paths() {
    bad=$(grep -nE '(^|[[:space:];])(ZED|OSASCRIPT|HERDR|MIN|SSH_KEYGEN)_BIN=[^$/%]' "$ROOT/tests/run.sh" | grep -v 'grep -nE') || :
    [ -z "$bad" ] || fail "tool override not absolute: $bad"
    for v in "$ZED_BIN" "$OSASCRIPT_BIN" "$HERDR_BIN" "$MIN_BIN" "$SSH_KEYGEN_BIN"; do
        case $v in "$T"/bin/min|"$T"/bin/ssh-keygen|"$T"/stub-bin/*) ;; *) fail "setup leaves a tool outside the stubs: $v" ;; esac
    done
}

# ---- review fixes (zed layer) ----

# Z1: an epoch with a leading zero or too many digits is refused, and the
# watch goes on to the next box (no $((0999)) arithmetic error).
case_watch_odd_epochs_do_not_stop_it() {
    own_sessions
    connected beta gamma
    printf 'needs-input 0999 x\n' > "$FIXTURES/agent-state.beta"
    printf 'needs-input 1234567890123 x\n' > "$FIXTURES/agent-state.alpha"
    printf 'needs-input %s go\n' "$(date +%s)" > "$FIXTURES/agent-state.gamma"
    run_watch
    assert_log_count 1 "osascript | min-zed | gamma: needs input | go"
    assert_log_not_contains "beta:"
    ! grep -qi 'arithmetic\|syntax error' "$T/err" || fail "watch hit an arithmetic error: $(cat "$T/err")"
}

# Z2: comments between other entries survive a sync and a --remove.
case_zedcfg_keeps_comments_between_entries() {
    mkdir -p "$T/zed"
    cat > "$ZS" <<'EOF'
{
  "ssh_connections": [
    // work box
    {"host": "box.example"}, // a, b
    // ours
    {"host": "min-zed.gone"},
    /* keep me */
    {"host": "other.example"}, // trailing note
  ],
}
EOF
    run_cfg alpha
    assert_rc 0
    for t in '// work box' '{"host": "box.example"}, // a, b' '/* keep me */' '{"host": "other.example"}, // trailing note'; do
        assert_file_contains "$ZS" "$t"
    done
    [ "$(cfg_hosts)" = "box.example other.example min-zed.alpha" ] || fail "hosts: $(cfg_hosts)"
    run_cfg --remove
    assert_file_contains "$ZS" '{"host": "other.example"}, // trailing note'
    [ "$(cfg_hosts)" = "box.example other.example" ] || fail "hosts: $(cfg_hosts)"
}

# Z3: a CRLF file stays CRLF, and --remove gives it back byte for byte.
case_zedcfg_crlf_kept() {
    mkdir -p "$T/zed"
    printf '{\r\n  "theme": "x"\r\n}\r\n' > "$ZS"; cp "$ZS" "$T/orig.settings"
    run_cfg alpha beta
    assert_rc 0
    python3 -c 'import sys; t = open(sys.argv[1], "rb").read(); sys.exit(t.count(b"\n") != t.count(b"\r\n"))' "$ZS" \
        || fail "a line lost its CR: $(od -c "$ZS" | head)"
    [ "$(cfg_hosts)" = "min-zed.alpha min-zed.beta" ] || fail "hosts: $(cfg_hosts)"
    run_cfg --remove
    cmp -s "$ZS" "$T/orig.settings" || fail "CRLF file not restored byte for byte"
}

# Z6: written by one rename beside the real file; its mode kept, no temp left.
case_zedcfg_atomic_write_keeps_mode() {
    mkdir -p "$T/zed" "$T/dot"
    printf '{}\n' > "$T/dot/settings.json"; chmod 640 "$T/dot/settings.json"
    ln -s "$T/dot/settings.json" "$ZS"
    run_cfg alpha
    assert_rc 0
    [ -L "$ZS" ] || fail "symlink replaced"
    assert_mode "$T/dot/settings.json" 640
    [ -z "$(find "$T/dot" "$T/zed" -name '.settings.json.*')" ] || fail "temp file left"
}

# Z7: a settings file we created goes again on --remove; a user's own empty
# ssh_connections list stays.
case_zedcfg_remove_undoes_only_what_we_made() {
    run_cfg alpha
    assert_file "$ZS"
    run_cfg --remove
    assert_rc 0
    assert_no_file "$ZS"
    mkdir -p "$T/zed"
    printf '{\n  "ssh_connections": [],\n  "theme": "x"\n}\n' > "$ZS"; cp "$ZS" "$T/orig.settings"
    run_cfg alpha
    run_cfg --remove
    cmp -s "$ZS" "$T/orig.settings" || { fail "user's empty list not kept as it was"; sed 's/^/#   zs: /' "$ZS" >&2; }
    # created by us, then the user added a setting: kept
    rm -f "$ZS" "$STATE/zed-config.json"
    run_cfg alpha
    printf '{\n  "theme": "y",\n  "ssh_connections": [{"host": "min-zed.alpha"}]\n}\n' > "$ZS"
    run_cfg --remove
    assert_file_contains "$ZS" '"theme": "y"'
}

# Z8: `zed-config --print` fails when the merger cannot edit the file.
case_zedcfg_print_propagates_failure() {
    install_ssh
    mkdir -p "$T/zed"; : > "$T/opted.zed"
    printf '{"ssh_connections": {"host": "x"}}\n' > "$ZS"
    run zed-config --print
    assert_rc 1
    assert_err_contains "ssh_connections is not a list"
}

# Z9: at most one notification per box per minute; bidi controls and line
# separators stripped; the message cut at 200 characters, not bytes. The box
# read is bounded (512 bytes).
case_watch_notifications_rate_limited_and_clean() {
    own_sessions
    connected beta
    now=$(date +%s)
    msg=$(printf 'ok\342\200\256evil\342\201\246x\342\200\250y')
    printf 'needs-input %s %s\n' "$now" "$msg" > "$FIXTURES/agent-state.beta"
    MIN_ZED_INTERVAL=1 sh "$BIN" watch > "$T/out" 2> "$T/err" < /dev/null &
    wp=$!
    sleep 1.5
    printf 'finished %s done\n' "$((now + 1))" > "$FIXTURES/agent-state.beta"
    sleep 2
    kill "$wp"; wait "$wp" 2>/dev/null
    assert_log_count 1 "osascript |"
    assert_log_contains "osascript | min-zed | beta: needs input | okevilxy"
    assert_log_contains "min session exec beta head -c 512 /home/.min-zed/agent-state"
    # characters, not bytes: 300 two-byte characters come out as 200
    rm -f "$STATE/cache/beta.notified"
    long=$(python3 -c 'print("é" * 300, end="")')
    printf 'finished %s %s\n' "$((now + 2))" "$long" > "$FIXTURES/agent-state.beta"
    reset_log
    run_watch
    body=$(sed -n 's/^osascript | min-zed | beta: finished | Claude finished: //p' "$STUB_LOG")
    [ "$(printf '%s' "$body" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode()))')" = 200 ] \
        || fail "body not cut at 200 characters: $(printf '%s' "$body" | wc -c) bytes"
}

# A box that never answers costs one exec timeout, not the watch: the next
# box in the same tick is still read.
case_watch_hanging_box_times_out() {
    own_sessions
    connected beta gamma
    : > "$FIXTURES/exec.hang.beta"
    printf 'needs-input %s go\n' "$(date +%s)" > "$FIXTURES/agent-state.gamma"
    MIN_ZED_EXEC_TIMEOUT=1; export MIN_ZED_EXEC_TIMEOUT
    run_watch
    assert_log_count 1 "osascript | min-zed | gamma: needs input | go"
    pkill -f "sleep 30" 2>/dev/null || :
}

# A box that ignores the in-box `head -c` and streams forever is cut at 512
# bytes on the host, well before the exec timeout.
case_watch_streaming_box_capped_on_host() {
    own_sessions
    connected beta
    printf 'needs-input %s msg' "$(date +%s)" > "$FIXTURES/agent-state.beta"
    : > "$FIXTURES/exec.stream.beta"
    MIN_ZED_EXEC_TIMEOUT=30; export MIN_ZED_EXEC_TIMEOUT
    run_watch
    body=$(sed -n 's/^osascript | min-zed | beta: needs input | //p' "$STUB_LOG")
    case $body in msgAAAA*) ;; *) fail "no capped notification: $(cat "$STUB_LOG")" ;; esac
    [ "${#body}" -le 200 ] || fail "body ${#body} long"
}

# A stale watch.lock and a pid file naming some other live process (a reused
# pid) do not keep the watch from starting; --ensure reports a real start only.
case_watch_stale_lock_and_reused_pid() {
    mkdir -p "$STATE/watch.lock"
    sleep 30 & other=$!
    printf '%s' "$other" > "$STATE/watch.pid"
    MIN_ZED_INTERVAL=1 sh "$BIN" watch > "$T/out" 2> "$T/err" < /dev/null & wp=$!
    sleep 1.5
    kill -0 "$wp" 2>/dev/null || fail "watch did not start: $(cat "$T/err")"
    assert_file "$STATE/watch.pid" "$wp"
    kill "$wp" "$other" 2>/dev/null; wait 2>/dev/null
    # --ensure with the watch unable to start: no success claimed
    MIN_ZED_NO_WATCH=; export MIN_ZED_NO_WATCH
    rm -f "$STATE/watch.pid"; rmdir "$STATE/watch.lock" 2>/dev/null
    mkdir "$STATE/watch.log"      # the background start cannot open its log
    run watch --ensure
    assert_rc 1
    assert_err_contains "watch did not start; see $STATE/watch.log"
    ! grep -q 'watch started' "$T/out" || fail "--ensure claimed a start"
}

# A BOM stays in front, and --remove restores the file byte for byte.
case_zedcfg_bom_kept() {
    mkdir -p "$T/zed"
    printf '\357\273\277{\n  "a": 1\n}\n' > "$ZS"; cp "$ZS" "$T/orig.settings"
    run_cfg x
    assert_rc 0
    head -c 3 "$ZS" | od -c | grep -q '357 273 277' || fail "BOM lost"
    run_cfg --remove
    cmp -s "$ZS" "$T/orig.settings" || fail "BOM file not restored byte for byte"
}

# Z5: two watches started at once: one survives and owns the pid file.
case_watch_double_start_leaves_one() {
    MIN_ZED_INTERVAL=1 sh "$BIN" watch > "$T/w1" 2>&1 < /dev/null & w1=$!
    MIN_ZED_INTERVAL=1 sh "$BIN" watch > "$T/w2" 2>&1 < /dev/null & w2=$!
    sleep 2.5
    alive=0
    for p in $w1 $w2; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
    [ "$alive" = 1 ] || fail "$alive watches running"
    for p in $w1 $w2; do kill -0 "$p" 2>/dev/null && { [ "$(cat "$STATE/watch.pid")" = "$p" ] || fail "pid file names the other watch"; }; done
    kill "$w1" "$w2" 2>/dev/null; wait 2>/dev/null
    assert_no_file "$STATE/watch.pid"
    assert_no_file "$STATE/watch.lock"
}

# Z10: watch.log is trimmed like proxy.log.
case_watch_log_trimmed() {
    i=0; while [ $i -lt 1500 ]; do echo "old $i"; i=$((i + 1)); done > "$STATE/watch.log"
    run_watch
    n=$(($(wc -l < "$STATE/watch.log")))
    [ "$n" -le 1000 ] || fail "watch.log not trimmed: $n lines"
    grep -qx 'old 1499' "$STATE/watch.log" || fail "newest lines lost"
}

# ---- kernel v2 (ported from cmux) ----

case_gc_herdr_agent_list_failure_counts() {
    own_sessions
    age beta 200000
    br='printf ready\012exec /usr/bin/herdr remote-client-bridge --idle-timeout-v1'
    printf '300 1 ssh -T min-herdr.beta %s\n301 300 /opt/homebrew/bin/min session exec beta /usr/sbin/sshd -i\n' "$br" > "$FIXTURES/ps.txt"
    : > "$FIXTURES/herdr.agents.beta.fail"
    run gc --dry-run
    ! grep -q '^beta ' "$T/out" || fail "a box Herdr could not ask about was offered"
    run gc --dry-run
    assert_log_count 2 "herdr --machine min-herdr.beta agent list"
    assert_no_file "$STATE/herdr.agents/beta"
    rm "$FIXTURES/herdr.agents.beta.fail"
    run gc --dry-run
    grep -q '^beta ' "$T/out" || fail "beta has no agents once Herdr answers"
}

case_open_default_loadouts_toml_forms() {
    install_ssh
    mkdir -p "$HOME/.config/minimal"
    sessions_after proj-amber "$P"
    printf "loadouts.default_loadouts = ['dots', \"minx\"]\n[loadouts]\nx = 1\n" > "$HOME/.config/minimal/config.toml"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout dots --loadout zed -n proj-amber $P"
    assert_err_contains "not passing default loadout minx"
    printf "[ loadouts ]\ndefault_loadouts = [ 'a.b', 'x y' ]\n" > "$HOME/.config/minimal/config.toml"
    printf '{"sessions":[]}\n' > "$FIXTURES/sessions.json"; reset_log
    run open "$P"
    assert_log_contains "min session activate --no-prompt --loadout a.b --loadout zed -n proj-amber $P"
    assert_err_contains "ignoring default loadout 'x y'"
    printf '[loadouts]\ndefault_loadouts = [dots]\n' > "$HOME/.config/minimal/config.toml"
    printf '{"sessions":[]}\n' > "$FIXTURES/sessions.json"; reset_log
    run open "$P"
    assert_log_contains "min session activate --no-prompt --loadout zed -n proj-amber $P"
    assert_err_contains "could not read default_loadouts in $HOME/.config/minimal/config.toml"
}

case_sshconfig_lock_held_waits_then_fails() {
    L=$HOME/.local/state/min-clients/ssh-config.lock
    mkdir -p "$L"
    MIN_LOCK_WAIT=1 run ssh-config
    assert_rc 1
    assert_err_contains "$L is held by another ssh-config run"
    assert_no_file "$HOME/.ssh/config"
    [ -d "$L" ] || fail "a waiter removed a lock it does not hold"
    touch -t 200001010000 "$L"
    MIN_LOCK_WAIT=1 run ssh-config
    assert_rc 0
    assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/min-zed.conf"
    assert_no_file "$L"
    MIN_LOCK_WAIT=1 run ssh-config --remove
    assert_rc 0
    assert_no_file "$HOME/.ssh"
    assert_no_file "$HOME/.local/state/min-clients"
}

case_sshconfig_two_tools_install_at_once() {
    make_tool_b
    : > "$T/opted.ssh"
    r=0; while [ "$r" -lt 4 ]; do
        rm -rf "$HOME/.ssh" "$HOME/.local/state/min-clients"
        sh "$BIN" ssh-config > "$T/a.out" 2>&1 < /dev/null & a=$!
        MIN_ZZ_STATE_DIR=$T/state-b sh "$T/tool-b/min-zz" ssh-config > "$T/b.out" 2>&1 < /dev/null & b=$!
        wait "$a" || fail "round $r: a failed: $(cat "$T/a.out")"
        wait "$b" || fail "round $r: b failed: $(cat "$T/b.out")"
        for t in min-zed min-zz; do
            [ "$(grep -cxF "Include ~/.ssh/$t.conf" "$HOME/.ssh/config")" = 1 ] || fail "round $r: $t Include lost: $(cat "$HOME/.ssh/config")"
        done
        r=$((r + 1))
    done
}

# K7: gc looks again right before each question.
case_gc_rechecks_before_each_question() {
    own_sessions
    age alpha 400
    age beta 300
    age gamma 200
    printf '100 1 ssh min-zed.gamma\n101 100 /opt/homebrew/bin/min session exec gamma /usr/sbin/sshd -i\n' > "$FIXTURES/ps.later.txt"
    run_stdin 'y
y
y
' gc
    assert_rc 0
    grep -q '^gamma ' "$T/out" || fail "gamma was idle when gc listed: $(cat "$T/out")"
    assert_log_contains "min session destroy beta"
    assert_log_not_contains "min session destroy gamma"
    assert_err_contains "gamma is in use now; not asking"
    ! grep -qF "Destroy Minimal session gamma" "$T/err" || fail "asked about gamma"
}

case_bad_session_name_refused() {
    install_ssh
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-X","name":"x; touch PWN #","project_path":"$AP","status":"active"}]}
JSON
    run attach 'x; touch PWN #'
    assert_rc 1
    assert_err_contains "session name is not lowercase letters, digits and dashes; not using it"
    assert_log_not_contains "session exec"
    assert_log_not_contains "zed ssh://"
    run ssh 'x; touch PWN #' -- true
    assert_rc 1
    assert_log_not_contains "ssh -i"
}

# ==== runner ======================================================================

# A fresh install (no session has a key dir yet): gc finds nothing to offer
# and exits 0. own_filter's loop must not fail when its glob matches nothing.
case_gc_no_own_sessions_yet() {
    own_sessions
    rm -rf "$STATE/sessions"
    run gc --dry-run
    assert_rc 0
    ! grep -q "min ls failed" "$T/err" || fail "gc died: $(cat "$T/err")"
}

CASES="
gc_no_own_sessions_yet sshconfig_install_creates_include_and_stanza sshconfig_install_is_idempotent
sshconfig_install_prepends_to_existing_config sshconfig_install_keeps_symlinked_config
sshconfig_remove_restores_original sshconfig_remove_keeps_other_tools_include sshconfig_print_touches_nothing
sshconfig_destroy_drops_stanza sshconfig_stale_state_dir_is_skipped sshconfig_real_ssh_resolves
sshconfig_forwarding_off_despite_host_star sshconfig_paths_with_spaces_and_percent sshconfig_prefers_local_bin_symlink
proxy_prepares_then_execs_sshd proxy_prepare_failure_is_logged proxy_unknown_session_fails proxy_missing_takes_no_host
prepare_writes_atomically sshconfig_prepare_rejects_bad_facts sshconfig_prepare_accepts_valid_facts
sshconfig_catchall_skips_dotted_hosts prepare_errors_strip_control_bytes sshconfig_stored_user_checked_on_read
sshconfig_remove_loops_and_deletes_empty sshconfig_write_failure_does_not_block_ssh sshconfig_existing_dir_mode_kept
sshconfig_unchanged_conf_not_rewritten sshconfig_proxy_keeps_session_created_meanwhile
sshconfig_remove_deletes_what_it_created sshconfig_backs_up_before_writing sshconfig_refuses_double_quote_in_state_dir
sshconfig_skips_invalid_dir_names ssh_passthrough ssh_opts_quote_and_double_percent
prep_extracts_and_prints_facts prep_leaves_other_tools_keys prep_workbench_line_once
prep_waiter_keeps_lock_it_does_not_own prep_breaks_stale_lock prep_concurrent_runs_agree_on_host_key
prep_regenerates_half_pair prep_keygen_failure_releases_lock prep_stale_lock_stress
proxy_log_mode_600_and_capped proxy_log_failure_does_not_block
names_first_free_word names_odd_characters_slugged open_rejects_bad_name
open_activates_with_loadout_and_launches_zed open_needs_ssh_config open_reuses_live_session_for_path
open_ignores_other_tools_session open_name_for_other_dir_fails open_without_zed_cli_says_where
new_always_fresh_and_rejects_taken_name attach_launches_zed_and_fails_unknown
destroy_yes_removes_session_and_state destroy_prompt destroy_defaults_to_this_directory
zedcfg_merge_keeps_comments_and_foreign_entries zedcfg_noop_when_unchanged zedcfg_remove_restores_original
zedcfg_keeps_hand_tuned_entry zedcfg_symlink_kept_and_missing_file_created zedcfg_refuses_bad_input
zedcfg_sync_follows_sessions_after_opt_in
prefetch_off_by_default prefetch_on_open_and_new_only prefetch_skips_preview_and_odd_versions
fetch_script_installs_atomically launch_script_detaches
inuse_any_tools_sshd_counts inuse_herdr_bridge_needs_agents gc_lists_oldest_first_and_filters_age gc_answers
gc_in_use_session_loses_its_age status_table
watch_polls_only_connected_boxes watch_notifies_on_change_only watch_first_sight_of_stale_state_is_quiet
watch_rejects_odd_state_lines watch_pid_file_and_stop
loadout_parses_with_packages loadout_env_and_workbench_line loadout_claude_hook_records_state
doctor_rows completions_parse kernel_sha_pinned
sshconfig_two_tools_coexist prep_two_tools_share_host_key activate_keeps_default_loadouts tests_use_absolute_tool_paths
watch_odd_epochs_do_not_stop_it zedcfg_keeps_comments_between_entries zedcfg_crlf_kept zedcfg_atomic_write_keeps_mode
zedcfg_remove_undoes_only_what_we_made zedcfg_print_propagates_failure watch_notifications_rate_limited_and_clean
watch_double_start_leaves_one watch_log_trimmed watch_hanging_box_times_out zedcfg_bom_kept watch_streaming_box_capped_on_host watch_stale_lock_and_reused_pid
gc_herdr_agent_list_failure_counts open_default_loadouts_toml_forms sshconfig_lock_held_waits_then_fails
sshconfig_two_tools_install_at_once gc_rechecks_before_each_question bad_session_name_refused
"

# The second pass reruns these with a long HOST_PREFIX (a sed copy of the CLI).
PREFIX_CASES="
sshconfig_install_creates_include_and_stanza sshconfig_real_ssh_resolves sshconfig_catchall_skips_dotted_hosts
sshconfig_destroy_drops_stanza sshconfig_unchanged_conf_not_rewritten proxy_prepares_then_execs_sshd
proxy_missing_takes_no_host prepare_writes_atomically ssh_passthrough open_activates_with_loadout_and_launches_zed
attach_launches_zed_and_fails_unknown
"

# Guards: nothing under ~/.ssh unless the case installed ssh-config, and no
# Zed settings unless it opted in to them.
guards() {
    [ -e "$T/opted.ssh" ] || [ ! -e "$HOME/.ssh" ] || fail "HOME/.ssh touched without ssh-config: $(find "$HOME/.ssh" | tr '\n' ' ')"
    [ -e "$T/opted.zed" ] || [ ! -e "$T/zed" ] || fail "Zed settings touched without zed-config"
    [ ! -e "$T/tripwire" ] || fail "tripwire: $(cat "$T/tripwire")"
}

pass=0 failed=0 skipped=0
run_cases() { # LABEL CASES
    for c in $2; do
        ( setup; command -v "case_$c" > /dev/null || fail "no function case_$c"; "case_$c"; guards; [ ! -e "$T/fail" ] || exit 1; [ ! -e "$T/skip" ] || exit 2 )
        case $? in
            0) echo "ok - $1$c"; pass=$((pass + 1)) ;;
            2) echo "ok - $1$c # skip"; skipped=$((skipped + 1)) ;;
            *) echo "not ok - $1$c"; failed=$((failed + 1)) ;;
        esac
    done
}

run_cases "" "$CASES"

LP=$(mktemp -d) && LP=$(cd "$LP" && pwd -P)
mkdir -p "$LP/bin"
HP=zz-a-much-longer-host-prefix.
sed "s/^HOST_PREFIX=min-zed\\.\$/HOST_PREFIX=$HP/" "$ROOT/bin/min-zed" > "$LP/bin/min-zed"
cp "$ROOT/bin/min-zed-config" "$LP/bin/min-zed-config"
grep -q "^HOST_PREFIX=$HP\$" "$LP/bin/min-zed" || { echo "not ok - long-prefix copy"; failed=$((failed + 1)); }
BIN=$LP/bin/min-zed SELF=$LP/bin/min-zed
run_cases "long-prefix " "$PREFIX_CASES"
rm -rf "$LP"

echo "# $pass passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
