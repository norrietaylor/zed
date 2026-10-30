#!/bin/sh
# Test suite for bin/min-zed and bin/min-zed-config. Run: sh tests/run.sh
# Every case runs in a subshell with stubbed min/zed/ssh/ssh-keygen/ps
# on a private PATH, a fresh temp state dir and a temp HOME.
# Nothing real is touched.
#
# LONG_PREFIX=1 runs the whole suite against a copy of bin/ whose HOST_PREFIX
# is long, so no `min-zed.` offset can hide in the code.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STUBS=$ROOT/tests/stubs
TOOL=min-zed
HP=min-zed.
BINDIR=$ROOT/bin
if [ "${LONG_PREFIX:-}" = 1 ]; then
    HP=min-zed-a-much-longer-prefix-for-tests.
    LR=$(mktemp -d) && LR=$(cd "$LR" && pwd -P)
    trap 'rm -rf "$LR"' EXIT
    LP=$LR/bin
    mkdir "$LP" && cp -R "$ROOT/loadouts" "$ROOT/skills" "$LR/"   # setup takes these from beside bin/
    sed "s/^HOST_PREFIX=min-zed\\.\$/HOST_PREFIX=$HP/" "$ROOT/bin/min-zed" > "$LP/min-zed"
    sed "s/^HOST_PREFIX = \"min-zed\\.\"\$/HOST_PREFIX = \"$HP\"/" "$ROOT/bin/min-zed-config" > "$LP/min-zed-config"
    grep -q "^HOST_PREFIX=$HP\$" "$LP/min-zed" || { echo "LONG_PREFIX: could not rewrite HOST_PREFIX"; exit 1; }
    grep -q "^HOST_PREFIX = \"$HP\"\$" "$LP/min-zed-config" || { echo "LONG_PREFIX: could not rewrite the merger"; exit 1; }
    chmod +x "$LP/min-zed" "$LP/min-zed-config"   # ssh stanzas exec the CLI itself
    BINDIR=$LP
fi
BIN=$BINDIR/min-zed
CFG=$BINDIR/min-zed-config
SELF=$(cd "$BINDIR" && pwd -P)/min-zed   # what the CLI bakes into ssh stanzas

# ---- harness -----------------------------------------------------------------

setup() {
    T=$(mktemp -d) || exit 1
    T=$(cd "$T" && pwd -P)
    trap 'rm -rf "$T"' EXIT
    HOME=$T/home STATE=$T/state FIXTURES=$T/fixtures STUB_LOG=$T/stub.log
    P=$T/proj          # project dir for open/new
    AP=$T/alpha-proj   # project dir of the pre-existing session "alpha"
    SETTINGS=$T/zed/settings.json TASKS=$T/zed/tasks.json KEYMAP=$T/zed/keymap.json
    mkdir -p "$HOME" "$STATE" "$FIXTURES" "$T/bin" "$P" "$AP"
    : > "$STUB_LOG"
    for s in min ssh ssh-keygen ps; do ln -s "$STUBS/$s" "$T/bin/$s"; done
    # Safety: Zed is reached only as the absolute stub path below; a bare
    # open/osascript/zed/code/cursor/windsurf lands on the tripwire (logged
    # to $TRIPWIRE_LOG), which fails the case.
    for s in open osascript zed code cursor windsurf; do ln -s "$STUBS/tripwire" "$T/bin/$s"; done
    mkdir -p "$T/stub-bin"
    ln -s "$STUBS/zed" "$T/stub-bin/zed"
    TRIPWIRE_LOG=$T/tripwire
    PATH=$T/bin:/usr/bin:/bin
    MIN_BIN=$T/bin/min SSH_KEYGEN_BIN=$T/bin/ssh-keygen
    MIN_ZED_STATE_DIR=$STATE MIN_ZED_EDITOR_BIN=$T/stub-bin/zed
    MIN_ZED_SETTINGS=$SETTINGS MIN_ZED_TASKS=$TASKS MIN_ZED_KEYMAP=$KEYMAP
    MIN_NO_PATH_EXTEND=1
    unset XDG_CONFIG_HOME XDG_STATE_HOME ZDOTDIR VISUAL EDITOR
    export HOME PATH STUB_LOG FIXTURES MIN_BIN SSH_KEYGEN_BIN TRIPWIRE_LOG MIN_NO_PATH_EXTEND \
        MIN_ZED_STATE_DIR MIN_ZED_EDITOR_BIN MIN_ZED_SETTINGS MIN_ZED_TASKS MIN_ZED_KEYMAP
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

# run ARGS...: run the CLI, capturing RC, $T/out, $T/err.
run() {
    sh "$BIN" "$@" > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
}
# run_stdin INPUT ARGS...
run_stdin() {
    input=$1; shift
    printf '%s' "$input" | sh "$BIN" "$@" > "$T/out" 2> "$T/err"
    RC=$?
}
# run_cfg ARGS...: the merger against $SETTINGS, $TASKS, $KEYMAP with the test state dir.
run_cfg() {
    python3 "$CFG" --settings "$SETTINGS" --tasks "$TASKS" --keymap "$KEYMAP" --state "$STATE" "$@" \
        > "$T/out" 2> "$T/err" < /dev/null
    RC=$?
}
# jsonc_get FILE JQ: FILE parsed with the merger's own JSONC reader.
jsonc_get() {
    python3 - "$1" "$CFG" <<'PY' | jq -c "$2"
import sys, json
src = open(sys.argv[2]).read().replace('if __name__ == "__main__":\n    main()', '')
m = {}
exec(compile(src, 'min-zed-config', 'exec'), m)
print(json.dumps(m['load_jsonc'](open(sys.argv[1], encoding='utf-8-sig').read())))
PY
}
settings_get() { jsonc_get "$SETTINGS" "$1"; }
# cfg_hosts: the hosts of the ssh_connections entries, in file order.
cfg_hosts() { settings_get '[(.ssh_connections // [])[] | .host] | join(" ")' | tr -d '"'; }

reset_log() { : > "$STUB_LOG"; }
skip() { printf '# skip: %s\n' "$*" >&2; : > "$T/skip"; }
ssh_g() { /usr/bin/ssh -G -F "$HOME/.ssh/config" "$1" 2>/dev/null; }

# ---- assertions (record failure, keep going) ---------------------------------

fail() { printf '# %s\n' "$*" >&2; : > "$T/fail"; }
assert_log_contains() {
    grep -qF -- "$1" "$STUB_LOG" || { fail "log lacks: $1"; sed 's/^/#   log: /' "$STUB_LOG" >&2; }
}
assert_log_not_contains() { ! grep -qF -- "$1" "$STUB_LOG" || fail "log unexpectedly has: $1"; }
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
    # GNU first: GNU `stat -f` is file-system status and succeeds with the wrong output
    m=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)
    [ "$m" = "$2" ] || fail "mode of $1 is $m, expected $2"
}
assert_line_in() { # TEXT LINE
    printf '%s\n' "$1" | grep -qxF -- "$2" || { fail "no line '$2' in:"; printf '%s\n' "$1" | sed 's/^/#   /' >&2; }
}
assert_rc() { [ "$RC" = "$1" ] || fail "exit status $RC, expected $1"; }
assert_rc_nonzero() { [ "$RC" != 0 ] || fail "expected non-zero exit status"; }
assert_err_contains() { grep -qF -- "$1" "$T/err" || { fail "stderr lacks: $1"; sed 's/^/#   err: /' "$T/err" >&2; }; }
assert_out_contains() { grep -qF -- "$1" "$T/out" || { fail "stdout lacks: $1"; sed 's/^/#   out: /' "$T/out" >&2; }; }
assert_out_eq() { [ "$(cat "$T/out")" = "$1" ] || fail "stdout is '$(cat "$T/out")', expected '$1'"; }

# ---- ssh-config helpers --------------------------------------------------------

MARK1="# $TOOL ssh-config (remove with: $TOOL ssh-config --remove)"
MARK2="Include ~/.ssh/$TOOL.conf"
CONF=.ssh/$TOOL.conf     # under $HOME
# The shared record of what the first min-<client> ssh-config created.
CREATED_REL=.local/state/min-clients/ssh-config-created

# alpha_facts: a plain `ssh` populates sessions/alpha/* for the stanza.
alpha_facts() { run ssh alpha -- true; assert_rc 0; }
# installed: ssh-config in place, with alpha's facts.
installed() { alpha_facts; run ssh-config; assert_rc 0; }

stanza_expected() {
    printf '# %s\nHost %s%s\n    User box\n' "$1" "$HP" "$1"
    printf '    IdentitiesOnly yes\n    AddKeysToAgent no\n    UserKnownHostsFile "%s/sessions/%s/known_hosts"\n' "$STATE" "$1"
    printf '    StrictHostKeyChecking yes\n    ForwardAgent no\n    ForwardX11 no\n    ForwardX11Trusted no\n'
    printf '    IdentityFile "%s/sessions/%s/id_ed25519"\n' "$STATE" "$1"
    printf '    ProxyCommand env MIN_BIN=%s MIN_ZED_STATE_DIR=%s %s _proxy %s\n' "$T/bin/min" "$STATE" "$SELF" "$1"
}
conf_expected() {
    printf '# managed by %s ssh-config; do not edit\n' "$TOOL"
    for n in "$@"; do printf '\n'; stanza_expected "$n"; done
    printf '\nHost %s* !%s*.*\n    ProxyCommand env MIN_ZED_STATE_DIR=%s %s _proxy --missing\n' "$HP" "$HP" "$STATE" "$SELF"
}

SSHD_ARGV="/usr/sbin/sshd -i -e -f /dev/null -h /home/.ssh/$TOOL/host_ed25519 -o LogLevel=ERROR -o PidFile=none -o StrictModes=no -o PubkeyAuthentication=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o AuthorizedKeysFile /home/.ssh/$TOOL/authorized_keys -o PermitUserEnvironment=yes -o AllowTcpForwarding=yes -o GatewayPorts=no -o AllowAgentForwarding=no -o X11Forwarding=no -o PrintMotd=no -o PrintLastLog=no -o UseDNS=no -o Subsystem sftp internal-sftp"
MISSING_MSG="$TOOL: no $TOOL ssh stanza for this ${HP}* host; run: $TOOL status, then $TOOL attach NAME (or $TOOL ssh-config)"

# ---- open / new / attach -------------------------------------------------------

case_open_activates_and_launches_editor() {
    installed
    sessions_after proj-amber "$P"
    reset_log
    run open "$P"
    assert_rc 0
    assert_out_eq "${HP}proj-amber"
    d=$STATE/sessions/proj-amber
    assert_log_contains "min session activate --no-prompt --loadout zed $P"
    pub=$(cat "$d/id_ed25519.pub")
    assert_log_contains "min session exec proj-amber sh -c <script> $TOOL $pub"
    assert_log_contains "zed ssh://${HP}proj-amber/workbench"
    assert_log_before "min session exec proj-amber sh -c" "zed ssh://"
    assert_file "$d/known_hosts" "${HP}proj-amber ssh-ed25519 AAAAFAKE"
    assert_file "$HOME/$CONF" "$(conf_expected alpha proj-amber)"
    assert_file "$STATE/created/proj-amber"
    [ "$(find "$d" -maxdepth 0 -perm 700)" = "$d" ] || fail "key dir mode is not 700"
}

case_open_reuses_live_session_for_path() {
    installed
    reset_log
    run open "$AP"
    assert_rc 0
    assert_out_eq "${HP}alpha"
    assert_log_not_contains "session activate"
    assert_log_contains "zed ssh://${HP}alpha/workbench"
}

# A live box another tool (or min alone) made for PATH is not reused: open
# activates its own.
case_open_skips_foreign_session_for_path() {
    installed
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-F","name":"foreign","project_path":"$P","status":"active"}]}
JSON
    cat > "$FIXTURES/sessions.after.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-F","name":"foreign","project_path":"$P","status":"active"},
 {"id":"ID-N","name":"proj-amber","project_path":"$P","status":"active"}]}
JSON
    reset_log
    run open "$P"
    assert_rc 0
    assert_out_eq "${HP}proj-amber"
    assert_log_contains "min session activate --no-prompt --loadout zed $P"
    assert_log_not_contains "min session exec foreign"
    assert_no_file "$STATE/sessions/foreign"
}

case_open_needs_ssh_config() {
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 1
    assert_err_contains "run $TOOL ssh-config first"
    assert_log_not_contains "session activate"
    assert_log_not_contains "zed "
}

case_open_rejects_non_directory_and_bad_name() {
    installed
    run open /nonexistent
    assert_rc_nonzero
    assert_err_contains "not a directory"
    for n in 'a b' 'x*' 'Upper' '-dash' 'q?' 'h#' 'p%' 'a.b'; do
        run open "$P" -n "$n"
        assert_rc 1
        assert_err_contains "$TOOL: session name must be lowercase letters, digits and dashes: $n"
    done
    assert_log_not_contains "session activate"
}

case_open_name_for_other_dir() {
    installed
    run open "$P" -n alpha
    assert_rc 1
    assert_err_contains "session alpha is for $AP, not $P"
}

case_new_always_activates() {
    installed
    sessions_after alpha-proj-amber "$AP"
    reset_log
    run new "$AP"
    assert_rc 0
    assert_out_eq "${HP}alpha-proj-amber"
    assert_log_contains "min session activate --no-prompt --loadout zed $AP"
    run new "$AP" -n alpha
    assert_rc 1
    assert_err_contains "session alpha already exists"
}

case_attach_launches_existing() {
    installed
    reset_log
    run attach alpha
    assert_rc 0
    assert_log_contains "min session exec alpha sh -c <script>"
    assert_log_contains "zed ssh://${HP}alpha/workbench"
    assert_log_not_contains "session activate"
    run attach nope
    assert_rc 1
    assert_err_contains "no session named nope"
}

case_attach_picker_rejects_zero() {
    installed
    run attach
    assert_rc 1
    assert_err_contains "attach: NAME required when stdin is not a terminal"
}

case_open_without_editor_fails_after_prepare() {
    installed
    MIN_ZED_EDITOR_BIN=$T/no-zed run attach alpha
    assert_rc 1
    assert_err_contains "$T/no-zed not found"
}

# No zed on PATH and no MIN_ZED_EDITOR_BIN: the CLI inside the app.
case_open_editor_falls_back_to_app() {
    installed
    rm "$T/bin/zed"
    mkdir -p "$T/App.app/Contents/MacOS"
    ln -s "$STUBS/zed" "$T/App.app/Contents/MacOS/cli"
    unset MIN_ZED_EDITOR_BIN
    MIN_ZED_EDITOR_APP=$T/App.app run attach alpha
    assert_rc 0
    assert_log_contains "zed ssh://${HP}alpha/workbench"
    MIN_ZED_EDITOR_APP=$T/no-app run attach alpha
    assert_rc 1
    assert_err_contains "zed not found"
}

# ---- names ---------------------------------------------------------------------

# min names a new session; we take the one new session for the path.
case_names_from_min() {
    installed
    sessions_after proj-1a2b "$P"
    reset_log
    run new "$P"
    assert_rc 0
    assert_out_eq "${HP}proj-1a2b"
    assert_log_contains "min session activate --no-prompt --loadout zed $P"
    assert_log_not_contains " -n proj"
    assert_file "$STATE/created/proj-1a2b"
    # -n still names it
    sessions_after mine "$P"
    reset_log
    run new "$P" -n mine
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout zed -n mine $P"
    # no new session for the path, or a name that is no hostname: refused
    cp "$FIXTURES/sessions.json" "$FIXTURES/sessions.after.json"
    jq '.sessions |= map(select(.name != "mine" and .name != "proj-1a2b"))' "$FIXTURES/sessions.after.json" > "$T/s.json" \
        && cp "$T/s.json" "$FIXTURES/sessions.after.json" && cp "$T/s.json" "$FIXTURES/sessions.json"
    run new "$P"
    assert_rc 1
    assert_err_contains "activate made no session for $P"
    sessions_after 'Bad_Name' "$P"
    run new "$P"
    assert_rc 1
    assert_err_contains "not a hostname; pass -n NAME"
    assert_log_not_contains "zed ssh://${HP}Bad"
}

# ---- destroy / gc --------------------------------------------------------------

case_destroy_asks_and_cleans_up() {
    installed
    run_stdin 'n
' destroy alpha
    assert_rc 0
    assert_err_contains "Destroy Minimal session alpha ($AP)? [y/N]"
    assert_log_not_contains "session destroy"
    assert_file "$STATE/kept/alpha"
    run destroy alpha              # no answer means No
    assert_log_not_contains "session destroy"
    run_stdin 'y
' destroy alpha
    assert_rc 0
    assert_log_contains "min session destroy alpha"
    assert_no_file "$STATE/sessions/alpha"
    assert_no_file "$STATE/kept/alpha"
    assert_file "$HOME/$CONF" "$(conf_expected)"
}

case_destroy_by_cwd() {
    alpha_facts
    (cd "$AP" && sh "$BIN" destroy -y > "$T/out" 2> "$T/err" < /dev/null); RC=$?
    assert_rc 0
    assert_log_contains "min session destroy alpha"
    (cd "$P" && sh "$BIN" destroy -y > "$T/out" 2> "$T/err" < /dev/null); RC=$?
    assert_rc 1
    assert_err_contains "no session for $P; pass NAME"
}

# A failed min ls after the answer is no proof the box is gone: its keys
# and ssh stanza stay, with a warning. `n`: exit 0; `y` (min destroyed it,
# then ls failed): exit 1, not success. min ls calls: sess_exists,
# ask_destroy, then destroy_one's look, the third.
case_destroy_ls_fails_keeps_keys() {
    installed
    rm -f "$FIXTURES/ls.calls"
    printf 3 > "$FIXTURES/ls.fail-from"
    run_stdin 'n
' destroy alpha
    assert_rc 0
    assert_err_contains "kept alpha"
    assert_err_contains "min ls failed, so whether alpha is gone is unknown; kept its keys"
    assert_log_not_contains "min session destroy"
    [ -d "$STATE/sessions/alpha" ] || fail "alpha's keys removed after n"
    assert_file "$STATE/kept/alpha"
    assert_file "$HOME/$CONF" "$(conf_expected alpha)"
    rm -f "$FIXTURES/ls.calls"
    run_stdin 'y
' destroy alpha
    assert_rc 1
    assert_log_contains "min session destroy alpha"
    assert_err_contains "min ls failed, so whether alpha is gone is unknown"
    [ -d "$STATE/sessions/alpha" ] || fail "alpha's keys removed after a failed ls"
    assert_file "$HOME/$CONF" "$(conf_expected alpha)"
    # while min ls fails, destroy NAME says so and keeps them
    run destroy alpha
    assert_rc 1
    assert_err_contains "min ls failed; kept the keys of alpha"
    [ -d "$STATE/sessions/alpha" ] || fail "alpha's keys removed while min ls fails"
    # once min ls works again, destroy NAME drops what was kept
    rm -f "$FIXTURES/ls.fail-from"
    run destroy alpha
    assert_rc 0
    assert_err_contains "alpha is gone; removed its keys"
    assert_no_file "$STATE/sessions/alpha"
    assert_file "$HOME/$CONF" "$(conf_expected)"
    run destroy alpha
    assert_rc 1
    assert_err_contains "no session named alpha"
}

# Only destroy_one's look fails (ls.fail-at 2: sess_exists, then the look):
# ssh-config is not rewritten either, though its own min ls would work.
case_destroy_ls_fails_once_keeps_stanza() {
    installed
    rm -f "$FIXTURES/ls.calls"
    printf 2 > "$FIXTURES/ls.fail-at"
    run destroy -y alpha
    assert_rc 1
    assert_log_contains "min session destroy alpha"
    assert_err_contains "min ls failed, so whether alpha is gone is unknown"
    [ -d "$STATE/sessions/alpha" ] || fail "alpha's keys removed after a failed ls"
    assert_file "$HOME/$CONF" "$(conf_expected alpha)"
}

# own NAME...: sessions this tool has prepared (a key dir), the only ones gc offers.
own() { for o in "$@"; do mkdir -p "$STATE/sessions/$o"; done; }

# destroy without NAME looks only at own sessions for the cwd: another tool's
# box for the same directory is neither picked nor counted.
case_destroy_by_cwd_only_own() {
    own beta
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-B","name":"beta","project_path":"$AP","status":"active"}]}
JSON
    (cd "$AP" && sh "$BIN" destroy -y > "$T/out" 2> "$T/err" < /dev/null); RC=$?
    assert_rc 0
    assert_log_contains "min session destroy beta"
    assert_log_not_contains "min session destroy alpha"
    (cd "$AP" && sh "$BIN" destroy -y > "$T/out" 2> "$T/err" < /dev/null); RC=$?
    assert_rc 1
    assert_err_contains "no session for $AP; pass NAME"
    assert_log_not_contains "min session destroy alpha"
}

# run_tty DIR INPUT ARGS...: the CLI in DIR on a pseudo-terminal (script(1),
# BSD or util-linux), INPUT typed into it; stdout and stderr together in
# $T/out, CRs dropped. Status 1 when there is no script(1) to use.
run_tty() {
    dir=$1 input=$2; shift 2
    if script -q /dev/null true < /dev/null > /dev/null 2>&1; then
        set -- script -q /dev/null sh "$BIN" "$@"
    elif script -qec true /dev/null < /dev/null > /dev/null 2>&1; then
        c="sh '$BIN'"; for w in "$@"; do c="$c '$w'"; done
        set -- script -qec "$c" /dev/null
    else
        return 1
    fi
    # stdin stays open a while after INPUT: at its end script(1) types ^D
    # shellcheck disable=SC2059  # INPUT is a printf format on purpose
    (cd "$dir" && { printf "$input"; sleep 2; } | "$@" > "$T/raw" 2>&1); RC=$?
    tr -d '\r' < "$T/raw" > "$T/out"
}

# On a terminal (a Zed task), destroy without NAME and without exactly one
# own session for the cwd shows the picker of own sessions, then asks y/N.
case_destroy_picker_on_a_terminal() {
    orphan_sessions
    jq --arg p "$P" '.sessions += [{"id":"ID-F","name":"foreign","project_path":$p,"status":"active"}]' \
        "$FIXTURES/sessions.json" > "$T/s.json" && cp "$T/s.json" "$FIXTURES/sessions.json"
    run_tty "$P" '2\ny\n' destroy || { skip "no script(1)"; return 0; }
    assert_rc 0
    assert_out_contains " 1) alpha"
    assert_out_contains " 4) stopped"
    ! grep -q foreign "$T/out" || fail "another tool's box in the picker: $(cat "$T/out")"
    assert_out_contains "Destroy Minimal session beta ($T/beta-proj)? [y/N]"
    assert_log_contains "min session destroy beta"
    assert_log_not_contains "min session destroy foreign"
    # several own sessions for the cwd: the picker too
    jq --arg p "$AP" '(.sessions[] | select(.name == "gamma") | .project_path) = $p' \
        "$FIXTURES/sessions.json" > "$T/s.json" && cp "$T/s.json" "$FIXTURES/sessions.json"
    reset_log
    run_tty "$AP" '1\nn\n' destroy
    assert_rc 0
    assert_out_contains "several sessions for $AP: alpha gamma"
    assert_out_contains "Destroy Minimal session alpha ($AP)? [y/N]"
    assert_log_not_contains "session destroy"
    # without a terminal it stays an error
    (cd "$AP" && sh "$BIN" destroy > "$T/out" 2> "$T/err" < /dev/null); RC=$?
    assert_rc 1
    assert_err_contains "several sessions for $AP: alpha gamma; pass NAME"
    # no own session at all: no picker, the old message
    rm -rf "$STATE/sessions"
    run_tty "$P" '1\ny\n' destroy
    assert_rc 1
    assert_out_contains "no session for $P; pass NAME"
    assert_log_not_contains "session destroy"
}

orphan_sessions() {
    own alpha beta gamma stopped
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-B","name":"beta","project_path":"$T/beta-proj","status":"active"},
 {"id":"ID-G","name":"gamma","project_path":"$T/gamma-proj","status":"active"},
 {"id":"ID-S","name":"stopped","project_path":"$T/s","status":"stopped"}]}
JSON
}
age() { mkdir -p "$STATE/orphan"; printf '%s' "$(($(date +%s) - $2))" > "$STATE/orphan/$1"; }

# ps_line PID PPID ARGS
ps_line() { printf '%s %s %s\n' "$@" >> "$FIXTURES/ps.txt"; }
# exec_line PID PPID NAME: the process a connection to NAME runs on the host.
exec_line() { ps_line "$1" "$2" "/opt/homebrew/bin/min session exec $3 /usr/sbin/sshd -i -e -f /dev/null -h /home/.ssh/$TOOL/host_ed25519"; }

# In use: a `min session exec NAME .../sshd` on the host, whatever ssh client
# or Host alias started it; mentions of the name elsewhere do not count.
case_in_use_reads_ps() {
    orphan_sessions
    ps_line 100 1 "ssh -T other-alias.alpha"
    exec_line 101 100 alpha
    ps_line 300 1 "/bin/zsh -c min session exec gamma true"
    ps_line 301 1 "/usr/bin/tail -f /tmp/min session exec gamma sshd.log"
    ps_line 302 1 "/opt/homebrew/bin/min session exec gamma claude"
    ps_line 303 1 "/opt/homebrew/bin/min session exec gamma sh -c set -eu umask 077 $TOOL ssh-ed25519 AAAA"
    ps_line 304 1 "/opt/homebrew/bin/min session exec gamma-x /usr/sbin/sshd -i -e"
    ps_line 305 1 "/usr/bin/ssh -o ConnectTimeout=5 build.example tail -f ${HP}gamma"
    run gc --dry-run
    assert_rc 0
    ! grep -q '^alpha ' "$T/out" || fail "alpha is in use through another alias's connection"
    grep -q '^beta ' "$T/out" || fail "beta is not in use"
    grep -q '^gamma ' "$T/out" || fail "gamma is not in use"
    ! grep -q '^stopped ' "$T/out" || fail "only active sessions are offered"
}

case_gc_lists_oldest_first_and_asks() {
    orphan_sessions
    age beta 7200
    age gamma 200000
    run gc --dry-run
    assert_rc 0
    [ "$(sed -n 1p "$T/out" | tr -s ' ')" = "NAME PROJECT IDLE" ] || fail "header: $(sed -n 1p "$T/out")"
    [ "$(sed -n 2p "$T/out" | tr -s ' ')" = "gamma $T/gamma-proj 2d" ] || fail "oldest first: $(sed -n 2p "$T/out")"
    [ "$(sed -n 3p "$T/out" | tr -s ' ')" = "beta $T/beta-proj 2h" ] || fail "row: $(sed -n 3p "$T/out")"
    run gc --dry-run --older-than 86400
    ! grep -q beta "$T/out" || fail "--older-than should drop beta"
    ! grep -q alpha "$T/out" || fail "undated alpha has unknown age: left out with a threshold"
    assert_log_not_contains "session destroy"
    run_stdin 'y
n
q
' gc
    assert_rc 0
    assert_log_contains "min session destroy gamma"
    assert_log_not_contains "min session destroy beta"
    assert_log_not_contains "min session destroy alpha"
    assert_file "$STATE/kept/beta"
    assert_err_contains "[y/N/q]"
    run gc --older-than x
    assert_rc 1
}

# gc goes through the same look: own_ls, ask_destroy, then destroy_one's.
case_gc_ls_fails_keeps_keys() {
    orphan_sessions
    age gamma 9000
    printf 3 > "$FIXTURES/ls.fail-from"
    run_stdin 'y
q
' gc
    assert_rc 1
    assert_log_contains "min session destroy gamma"
    assert_err_contains "min ls failed, so whether gamma is gone is unknown"
    [ -d "$STATE/sessions/gamma" ] || fail "gamma's keys removed after a failed ls"
    assert_file "$STATE/orphan/gamma"
}

# Another tool's box (no key dir here) is never listed or asked about.
case_gc_offers_only_own_sessions() {
    orphan_sessions
    rm -rf "$STATE/sessions/gamma"
    age beta 300
    age gamma 200000
    run gc --dry-run
    assert_rc 0
    grep -q '^beta ' "$T/out" || fail "own idle beta is offered: $(cat "$T/out")"
    ! grep -q '^gamma ' "$T/out" || fail "gamma is another tool's: $(cat "$T/out")"
    run_stdin 'y
y
y
' gc
    assert_rc 0
    assert_log_contains "min session destroy beta"
    assert_log_not_contains "min session destroy gamma"
    ! grep -q gamma "$T/out" "$T/err" || fail "gamma mentioned by gc"
}

# gc and status date idle sessions (there is no background watch).
case_status_tracks_orphans() {
    orphan_sessions
    age gamma 500
    g=$(cat "$STATE/orphan/gamma")
    exec_line 101 1 alpha
    run status
    assert_rc 0
    assert_file "$STATE/orphan/beta"
    assert_file "$STATE/orphan/gamma" "$g"
    [ $(($(date +%s) - $(cat "$STATE/orphan/alpha"))) -lt 60 ] || fail "alpha in use: age restarts"
    assert_no_file "$STATE/orphan/stopped"
    jq '.sessions |= map(select(.name != "beta"))' "$FIXTURES/sessions.json" > "$T/s.json" && cp "$T/s.json" "$FIXTURES/sessions.json"
    run gc --dry-run
    assert_no_file "$STATE/orphan/beta"
}

case_status_table() {
    orphan_sessions
    exec_line 101 1 alpha
    age beta 7200
    run status
    assert_rc 0
    [ "$(sed -n 1p "$T/out" | tr -s ' ')" = "SESSION STATUS PROJECT IN USE IDLE" ] || fail "header: $(sed -n 1p "$T/out")"
    [ "$(grep '^alpha' "$T/out" | tr -s ' ')" = "alpha active $AP yes -" ] || fail "alpha: $(grep '^alpha' "$T/out")"
    [ "$(grep '^beta' "$T/out" | tr -s ' ')" = "beta active $T/beta-proj no 2h" ] || fail "beta: $(grep '^beta' "$T/out")"
}

# ---- Zed wiring: settings (ssh_connections), tasks, keymap ----------------------

zed_files_absent() { for f in "$SETTINGS" "$TASKS" "$KEYMAP"; do assert_no_file "$f"; done; }

case_settings_untouched_before_opt_in() {
    installed
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    zed_files_absent
    run destroy -y alpha
    zed_files_absent
}

# open/destroy keep Zed's list in step once `config` opted in; --remove gives
# the user's settings back byte for byte.
case_settings_follow_sessions() {
    installed
    mkdir -p "$T/zed"
    printf '// mine\n{\n  "theme": "One Dark", // keep\n  "ssh_connections": [\n    {"host": "box.example", "projects": []}\n  ]\n}\n' > "$SETTINGS"
    cp "$SETTINGS" "$T/orig.json"
    run config
    assert_rc 0
    assert_file "$STATE/settings-installed"
    [ "$(cfg_hosts)" = "box.example ${HP}alpha" ] || fail "hosts: $(cfg_hosts)"
    assert_file_contains "$SETTINGS" "{\"host\": \"${HP}alpha\", \"nickname\": \"alpha\", \"projects\": [{\"paths\": [\"/workbench\"]}]}"
    assert_file_contains "$SETTINGS" '"theme": "One Dark", // keep'
    sessions_after proj-amber "$P"
    run open "$P"
    [ "$(cfg_hosts)" = "box.example ${HP}alpha ${HP}proj-amber" ] || fail "after open: $(cfg_hosts)"
    run destroy -y alpha
    [ "$(cfg_hosts)" = "box.example ${HP}proj-amber" ] || fail "after destroy: $(cfg_hosts)"
    run config --remove
    assert_rc 0
    cmp -s "$T/orig.json" "$SETTINGS" || { fail "settings not restored byte for byte"; sed 's/^/#   /' "$SETTINGS" >&2; }
    assert_no_file "$STATE/settings-installed"
    assert_no_file "$TASKS"; assert_no_file "$KEYMAP"
    [ -n "$(find "$STATE/backups" -name 'settings.json.*')" ] || fail "no settings backup under the state dir"
    run attach proj-amber
    [ "$(cfg_hosts)" = "box.example" ] || fail "sync after opt-out: $(cfg_hosts)"
}

# 0.1.0's opt-in (STATE/zed-config-installed) and record (zed-config.json)
# are taken over once: sync goes on, and --remove still drops the key and the
# file 0.1.0 made.
case_settings_take_over_old_opt_in() {
    mkdir -p "$T/zed"
    printf '{\n  "theme": "x",\n  "ssh_connections": [{"host": "%sgone"}]\n}\n' "$HP" > "$SETTINGS"
    : > "$STATE/zed-config-installed"; printf '{"created_file": false, "added_key": true}\n' > "$STATE/zed-config.json"
    run ssh alpha -- true
    assert_rc 0
    [ "$(cfg_hosts)" = "${HP}alpha" ] || fail "not synced: $(cat "$SETTINGS")"
    assert_file "$STATE/settings-installed"; assert_file "$STATE/settings-key-added"
    assert_no_file "$STATE/settings-created"
    assert_no_file "$STATE/zed-config-installed"; assert_no_file "$STATE/zed-config.json"
    run_cfg --sync
    [ "$(settings_get 'has("ssh_connections")')" = false ] || fail "the key 0.1.0 added stayed: $(cat "$SETTINGS")"
    assert_file_contains "$SETTINGS" '"theme": "x"'
    # a file 0.1.0 created goes on --remove
    rm -f "$STATE"/settings-*
    printf '{\n  "ssh_connections": [{"host": "%salpha"}]\n}\n' "$HP" > "$SETTINGS"
    : > "$STATE/zed-config-installed"; printf '{"created_file": true, "added_key": true}\n' > "$STATE/zed-config.json"
    run config --remove
    assert_rc 0
    zed_files_absent
    assert_no_file "$STATE/settings-installed"; assert_no_file "$STATE/zed-config-installed"
}

# `zed-config` is `config` by its old name.
case_config_zed_config_alias() {
    installed
    run zed-config
    assert_rc 0
    [ "$(cfg_hosts)" = "${HP}alpha" ] || fail "hosts: $(cfg_hosts)"
    run zed-config --remove
    assert_rc 0
    zed_files_absent
}

case_settings_sync_skipped_when_min_ls_fails() {
    installed
    run config
    cp "$SETTINGS" "$T/before.json"
    # `ssh` lists sessions three times: sess_exists, the stanza refresh, the
    # settings refresh. Only the last fails: a partial list must not prune.
    cat > "$T/bin/min-flaky" <<EOF
#!/bin/sh
if [ "\$1 \$2" = "ls --json" ]; then
    n=\$(cat "$T/ls.count" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$T/ls.count"
    [ "\$n" -lt 3 ] || exit 1
fi
exec "$T/bin/min" "\$@"
EOF
    chmod +x "$T/bin/min-flaky"
    MIN_BIN=$T/bin/min-flaky run ssh alpha -- true
    assert_rc 0
    [ "$(cat "$T/ls.count")" = 3 ] || fail "expected three min ls calls, got $(cat "$T/ls.count")"
    assert_err_contains "min ls failed; Zed settings not refreshed"
    cmp -s "$T/before.json" "$SETTINGS" || fail "settings changed although min ls failed"
}

# min ls failing: config keeps our entries (no pruning on a partial list),
# and doctor says it could not check them.
case_config_and_doctor_keep_entries_when_min_ls_fails() {
    installed
    run config
    assert_rc 0
    # shellcheck disable=SC2016  # the $1/$2/$@ are the wrapper's
    printf '#!/bin/sh\n[ "$1 $2" != "ls --json" ] || exit 1\nexec "%s" "$@"\n' "$T/bin/min" > "$T/bin/min-nols"
    chmod +x "$T/bin/min-nols"
    MIN_BIN=$T/bin/min-nols run config
    assert_rc 0
    assert_err_contains "min ls failed; existing ${HP}* entries left as they are"
    [ "$(cfg_hosts)" = "${HP}alpha" ] || fail "entries pruned: $(cat "$SETTINGS")"
    MIN_BIN=$T/bin/min-nols run config --print
    assert_out_contains "\"host\": \"${HP}alpha\""
    MIN_BIN=$T/bin/min-nols run doctor
    grep -Eq "^warn +settings +min ls failed; ${HP}\\* entries not checked" "$T/out" || fail "doctor row: $(grep settings "$T/out")"
    grep -Eq '^ok +tasks +7 Minimal tasks' "$T/out" || fail "tasks row still checked: $(cat "$T/out")"
}

case_config_print_and_bad_option() {
    installed
    run config --print
    assert_rc 0
    assert_out_contains "\"host\": \"${HP}alpha\""
    assert_out_contains "// $TASKS"
    assert_out_contains '"label": "Minimal: Open Box…"'
    assert_out_contains "// $KEYMAP"
    zed_files_absent
    assert_no_file "$STATE/settings-installed"
    run config --bogus
    assert_rc 1
    assert_err_contains "config: unknown option --bogus"
}

# ---- the ssh_connections merger ----

zed_settings_fixture() {
    mkdir -p "$T/zed"
    cat > "$SETTINGS" <<EOF
// Zed settings
{
  "theme": "One Dark", // mine
  "ssh_connections": [
    {"host": "box.example", "projects": []},
    {"host": "${HP}gone", "nickname": "gone"}
  ],
  "vim_mode": true,
}
EOF
    cp "$SETTINGS" "$T/orig.settings"
}

case_merger_keeps_comments_and_foreign_entries() {
    zed_settings_fixture
    run_cfg --install --sync alpha beta
    assert_rc 0
    [ "$(cfg_hosts)" = "box.example ${HP}alpha ${HP}beta" ] || fail "hosts: $(cfg_hosts)"
    assert_file_contains "$SETTINGS" '// Zed settings'
    assert_file_contains "$SETTINGS" '"theme": "One Dark", // mine'
    assert_file_contains "$SETTINGS" '"vim_mode": true,'
    b=$(find "$STATE/backups" -name 'settings.json.*')
    cmp -s "$b" "$T/orig.settings" || fail "backup is not the file before the write"
    assert_mode "$b" 600
}

case_merger_fresh_file_and_noop() {
    run_cfg --install --sync a b
    assert_rc 0
    [ "$(cfg_hosts)" = "${HP}a ${HP}b" ] || fail "fresh: $(cat "$SETTINGS")"
    assert_mode "$SETTINGS" 600
    cp "$SETTINGS" "$T/one.json"
    touch -t 200001010000 "$SETTINGS"; : > "$T/stamp"
    # shellcheck disable=SC2012
    ino=$(ls -i "$SETTINGS" | awk '{ print $1 }')
    run_cfg --sync b a
    assert_rc 0
    assert_out_contains "nothing to do"
    [ -z "$(find "$SETTINGS" -newer "$T/stamp")" ] || fail "unchanged settings were rewritten"
    # shellcheck disable=SC2012
    [ "$(ls -i "$SETTINGS" | awk '{ print $1 }')" = "$ino" ] || fail "settings replaced"
    run_cfg --sync 'Bad Name' a b
    cmp -s "$T/one.json" "$SETTINGS" || fail "an invalid name reached the settings"
    run_cfg --remove
    zed_files_absent
    assert_out_contains "created and is empty again"
}

# --remove gives back the bytes it found, whatever the framing, CRLF and BOM.
case_merger_remove_restores_framing() {
    mkdir -p "$T/zed"
    for probe in '{}' '{"a": 1}' '{ "a": 1,\n "b": 2 }' '{\n  "a": 1\n}\n' '{\r\n  "a": 1, // c\r\n}\r\n' \
            '\357\273\277{"a": 1}\n' '// mine\n{\n  "theme": "x", /* keep */\n  "vim_mode": true\n}\n'; do
        rm -f "$SETTINGS" "$STATE"/settings-*
        # shellcheck disable=SC2059  # the probe is a printf format on purpose
        printf "$probe" > "$SETTINGS"; cp "$SETTINGS" "$T/orig.json"
        run_cfg --install --sync a b
        assert_rc 0
        [ "$(cfg_hosts)" = "${HP}a ${HP}b" ] || fail "$probe: not installed: $(cat "$SETTINGS")"
        case $probe in *'\r\n'*) ! LC_ALL=C grep -q "$(printf '[^\r]$')" "$SETTINGS" || fail "a bare LF went into a CRLF file" ;; esac
        case $probe in '\357'*) [ "$(head -c 3 "$SETTINGS" | od -An -tx1 | tr -d ' ')" = efbbbf ] || fail "BOM lost" ;; esac
        run_cfg --sync a
        run_cfg --remove
        assert_rc 0
        cmp -s "$T/orig.json" "$SETTINGS" || { fail "$probe: not restored byte for byte"; od -c "$SETTINGS" | head -4 | sed 's/^/#   /' >&2; }
    done
}

# An entry of ours a user tuned (say upload_binary_over_ssh) is kept as written.
case_merger_keeps_hand_tuned_entry() {
    mkdir -p "$T/zed"
    printf '{\n  "ssh_connections": [\n    {"host": "%salpha", "upload_binary_over_ssh": true}\n  ]\n}\n' "$HP" > "$SETTINGS"
    run_cfg --install --sync alpha beta
    assert_rc 0
    assert_file_contains "$SETTINGS" "{\"host\": \"${HP}alpha\", \"upload_binary_over_ssh\": true}"
    [ "$(cfg_hosts)" = "${HP}alpha ${HP}beta" ] || fail "hosts: $(cfg_hosts)"
}

# Comments between other entries survive a sync and a --remove.
case_merger_keeps_comments_between_entries() {
    mkdir -p "$T/zed"
    cat > "$SETTINGS" <<EOF
{
  "ssh_connections": [
    // work box
    {"host": "box.example"}, // a, b
    // ours
    {"host": "${HP}gone"},
    /* keep me */
    {"host": "other.example"}, // trailing note
  ],
}
EOF
    run_cfg --install --sync alpha
    assert_rc 0
    for t in '// work box' '{"host": "box.example"}, // a, b' '/* keep me */' '{"host": "other.example"}, // trailing note'; do
        assert_file_contains "$SETTINGS" "$t"
    done
    [ "$(cfg_hosts)" = "box.example other.example ${HP}alpha" ] || fail "hosts: $(cfg_hosts)"
    run_cfg --remove
    assert_file_contains "$SETTINGS" '{"host": "other.example"}, // trailing note'
    [ "$(cfg_hosts)" = "box.example other.example" ] || fail "hosts: $(cfg_hosts)"
}

# Several of ours after the user's last entry go in and out byte for byte,
# whatever the user's framing; a comment after the user's entry stays on its
# line (ours go after it, not between it and its entry).
case_merger_trailing_entries_round_trip() {
    mkdir -p "$T/zed"
    for probe in '{\n  "ssh_connections": [\n    {"host": "a"}\n  ]\n}\n' '{\n  "ssh_connections": [{"host": "a"}]\n}\n' \
            '{\n  "ssh_connections": [{"host": "a"},]\n}\n' '{\n  "ssh_connections": [\n    {"host": "a"} // c\n  ]\n}\n' \
            '{\r\n  "ssh_connections": [\r\n    {"host": "a"} // c\r\n  ]\r\n}\r\n'; do
        rm -f "$SETTINGS" "$STATE"/settings-*
        # shellcheck disable=SC2059  # the probe is a printf format on purpose
        printf "$probe" > "$SETTINGS"; cp "$SETTINGS" "$T/orig.json"
        run_cfg --install --sync x y z
        assert_rc 0
        [ "$(cfg_hosts)" = "a ${HP}x ${HP}y ${HP}z" ] || fail "$probe: hosts: $(cfg_hosts)"
        case $probe in *'// c'*) assert_file_contains "$SETTINGS" '{"host": "a"}, // c' ;; esac
        run_cfg --sync y
        [ "$(cfg_hosts)" = "a ${HP}y" ] || fail "$probe: after sync: $(cfg_hosts)"
        run_cfg --remove
        assert_rc 0
        cmp -s "$T/orig.json" "$SETTINGS" || { fail "$probe: not restored byte for byte"; od -c "$SETTINGS" | sed 's/^/#   /' >&2; }
    done
}

# A list holding only a comment keeps it while ours are in it, and gets it
# back as it was.
case_merger_comment_only_list_kept() {
    mkdir -p "$T/zed"
    printf '{\n  "ssh_connections": [\n    // only comment\n  ]\n}\n' > "$SETTINGS"; cp "$SETTINGS" "$T/orig.json"
    run_cfg --install --sync x y
    assert_rc 0
    [ "$(cfg_hosts)" = "${HP}x ${HP}y" ] || fail "hosts: $(cfg_hosts)"
    assert_file_contains "$SETTINGS" '// only comment'
    run_cfg --remove
    cmp -s "$T/orig.json" "$SETTINGS" || { fail "not restored byte for byte"; sed 's/^/#   /' "$SETTINGS" >&2; }
}

# Written by one rename beside the real file: a dotfiles symlink stays one,
# its mode is kept, no temp file is left.
case_merger_symlink_written_through() {
    mkdir -p "$T/zed" "$T/dot"
    printf '{}\n' > "$T/dot/settings.json"; chmod 640 "$T/dot/settings.json"
    ln -s "$T/dot/settings.json" "$SETTINGS"
    run_cfg --install --sync x
    assert_rc 0
    [ -L "$SETTINGS" ] || fail "settings.json is no longer a symlink"
    assert_file_contains "$T/dot/settings.json" "\"${HP}x\""
    assert_mode "$T/dot/settings.json" 640
    [ -z "$(find "$T/dot" "$T/zed" -name '.settings.json.*')" ] || fail "temp file left"
}

# A settings file we created goes again on --remove; a user's own empty
# ssh_connections list stays; a key we added goes when its last entry does.
case_merger_remove_undoes_only_what_we_made() {
    mkdir -p "$T/zed"
    printf '{\n  "ssh_connections": [],\n  "theme": "x"\n}\n' > "$SETTINGS"; cp "$SETTINGS" "$T/orig.settings"
    run_cfg --install --sync alpha
    run_cfg --sync
    run_cfg --remove
    cmp -s "$SETTINGS" "$T/orig.settings" || { fail "user's empty list not kept as it was"; sed 's/^/#   zs: /' "$SETTINGS" >&2; }
    printf '{\n  "theme": "x"\n}\n' > "$SETTINGS"; cp "$SETTINGS" "$T/orig.settings"
    run_cfg --install --sync alpha
    run_cfg --sync
    cmp -s "$SETTINGS" "$T/orig.settings" || { fail "the key we added stayed"; sed 's/^/#   zs: /' "$SETTINGS" >&2; }
    run_cfg --remove
    # created by us, then the user added a setting: kept
    rm -f "$SETTINGS" "$STATE"/settings-*
    run_cfg --install --sync alpha
    printf '{\n  "theme": "y",\n  "ssh_connections": [{"host": "%salpha"}]\n}\n' "$HP" > "$SETTINGS"
    run_cfg --remove
    assert_file_contains "$SETTINGS" '"theme": "y"'
}

# A file that cannot be edited is refused, and then no file is written.
case_merger_bad_input_refused() {
    mkdir -p "$T/zed"
    printf '{"ssh_connections": {"host": "x"}}\n' > "$SETTINGS"; cp "$SETTINGS" "$T/orig.settings"
    run_cfg --install --sync alpha
    assert_rc 1
    assert_err_contains "ssh_connections is not a list"
    cmp -s "$SETTINGS" "$T/orig.settings" || fail "file changed"
    assert_no_file "$TASKS"; assert_no_file "$KEYMAP"
    printf '{ "a": ' > "$SETTINGS"
    run_cfg --install --sync alpha
    assert_rc 1
    assert_err_contains "cannot parse or edit as JSONC"
    assert_file "$SETTINGS" '{ "a": '
    printf '[1]\n' > "$SETTINGS"
    run_cfg --install --sync alpha
    assert_rc 1
    assert_err_contains "top level is not an object"
    assert_no_file "$STATE/settings-installed"
}

# A file that is not UTF-8 is refused like one that does not parse.
case_merger_non_utf8_refused() {
    mkdir -p "$T/zed"
    printf '{"theme": "\377"}\n' > "$SETTINGS"; cp "$SETTINGS" "$T/orig.settings"
    run_cfg --install --sync alpha
    assert_rc 1
    assert_err_contains "$SETTINGS: cannot parse or edit as JSONC"
    ! grep -q Traceback "$T/err" || fail "traceback: $(cat "$T/err")"
    cmp -s "$SETTINGS" "$T/orig.settings" || fail "file changed"
    assert_no_file "$TASKS"; assert_no_file "$KEYMAP"
    assert_no_file "$STATE/settings-installed"
}

# ---- the tasks and keymap blocks ----

# Every shape a tasks.json or keymap.json may start in: the block goes in,
# a second install changes nothing, the user's entries stay, and --remove
# gives back the bytes (or deletes a file we created).
case_blocks_install_idempotent_remove_exact() {
    mkdir -p "$T/zed"
    for f in "$TASKS" "$KEYMAP"; do
        for probe in MISSING '' '\n' '// mine' '// mine\n' '[]' '[]\n' '[ // mine\n]\n' \
                '[\n  {"label": "x", "command": "echo x"}\n]\n' '[{"label": "x", "command": "echo x"}]' \
                '// tasks\n[\n  {"label": "x", "command": "echo x"}, // c\n  /* d */\n]\n' \
                '[\r\n  {"label": "x", "command": "echo x"}, // c\r\n]\r\n' '\357\273\277[\n  {"label": "x", "command": "echo x"}\n]\n'; do
            rm -f "$SETTINGS" "$TASKS" "$KEYMAP" "$STATE"/settings-* "$STATE"/tasks-* "$STATE"/keymap-*
            # shellcheck disable=SC2059  # the probe is a printf format on purpose
            [ "$probe" = MISSING ] || printf "$probe" > "$f"
            [ ! -f "$f" ] || cp "$f" "$T/orig"
            run_cfg --install --sync
            assert_rc 0
            n=$(jsonc_get "$f" 'length'); u=0
            case $probe in *'"x"'*) u=1 ;; esac
            want=7; [ "$f" = "$TASKS" ] || want=1
            [ "$n" = $((want + u)) ] || fail "$probe: $n entries in $(basename "$f"): $(cat "$f")"
            [ "$u" = 0 ] || [ "$(jsonc_get "$f" '.[-1].label')" = '"x"' ] || fail "$probe: the user's entry is not last: $(cat "$f")"
            case $probe in *'\r\n'*) ! LC_ALL=C grep -q "$(printf '[^\r]$')" "$f" || fail "$probe: a bare LF went into a CRLF file" ;; esac
            case $probe in '\357'*) [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' ')" = efbbbf ] || fail "$probe: BOM lost" ;; esac
            cp "$f" "$T/installed"
            run_cfg --install --sync
            cmp -s "$T/installed" "$f" || fail "$probe: a second install changed $(basename "$f")"
            grep -q "$(basename "$f"): already up to date" "$T/out" || fail "$probe: second install: $(cat "$T/out")"
            run_cfg --remove
            assert_rc 0
            if [ "$probe" = MISSING ]; then
                assert_no_file "$f"
            else
                cmp -s "$T/orig" "$f" || { fail "$probe: $(basename "$f") not restored byte for byte"; od -c "$f" | head -6 | sed 's/^/#   /' >&2; }
            fi
        done
    done
}

# What the blocks hold: the Minimal tasks run the CLI through sh, and the
# key opens a terminal on the Mac.
case_blocks_content() {
    run_cfg --install --sync
    assert_rc 0
    [ "$(jsonc_get "$TASKS" 'map(.label) | join("|")')" = '"Minimal: New Box from Folder…|Minimal: New Empty Box|Minimal: Open Box…|Minimal: Destroy Box…|Minimal: Clean Up Idle Boxes…|Minimal: Status|Minimal: Doctor"' ] \
        || fail "labels: $(jsonc_get "$TASKS" 'map(.label)')"
    [ "$(jsonc_get "$TASKS" 'map(.shell.program) | unique')" = '["sh"]' ] || fail "shell"
    # the window's folder through env (a value), with a default so Zed offers
    # the task in a window without one
    # shellcheck disable=SC2016  # Zed's variable, literal
    [ "$(jsonc_get "$TASKS" '.[0].env')" = '{"MIN_ZED_TASK_FOLDER":"${ZED_WORKTREE_ROOT:none}"}' ] || fail "env: $(jsonc_get "$TASKS" '.[0].env')"
    [ "$(jsonc_get "$TASKS" 'map(has("cwd")) | any')" = false ] || fail "a task sets cwd"
    [ "$(jsonc_get "$TASKS" 'map(.hide) | join(" ")')" = '"on_success on_success on_success never never never never"' ] || fail "hide"
    # no $ZED_ variable in a command: Zed would paste it in unquoted
    [ "$(jsonc_get "$TASKS" 'map(.command | test("[$][{]?ZED_")) | any')" = false ] || fail "a command names a ZED_ variable"
    [ "$(jsonc_get "$KEYMAP" '.[0]')" = '{"context":"Workspace","bindings":{"ctrl-alt-`":["workspace::NewTerminal",{"local":true}],"ctrl-alt-n":["task::Spawn",{"task_name":"Minimal: New Box from Folder…"}],"ctrl-alt-o":["task::Spawn",{"task_name":"Minimal: Open Box…"}]}}' ] \
        || fail "keymap: $(jsonc_get "$KEYMAP" '.')"
    # each task key names a task of the block
    [ "$(jq -n --argjson t "$(jsonc_get "$TASKS" 'map(.label)')" --argjson k "$(jsonc_get "$KEYMAP" '.[0].bindings')" \
        '[$k[] | select(.[0] == "task::Spawn") | .[1].task_name | IN($t[])] | (length == 2 and all)')" = true ] \
        || fail "a task key names no task"
    assert_file "$STATE/tasks-created"
    assert_file "$STATE/keymap-created"
}

# task_cmd N: the command of the Nth (from 0) task in $TASKS.
task_cmd() { jsonc_get "$TASKS" ".[$1].command" | jq -r .; }

# osa_stub: an osascript for New Box from Folder… in $T/osa (put it first on
# PATH for that call only): logs its last argument (the picker's start
# folder) and prints $OSA_PICK, or fails printing $OSA_ERR.
osa_stub() {
    mkdir -p "$T/osa"
    # shellcheck disable=SC2016  # expands in the stub
    printf '#!/bin/sh\nfor a; do :; done; echo "osascript from $a" >> "%s"\n[ -z "${OSA_ERR:-}" ] || { echo "$OSA_ERR" >&2; exit 1; }\necho "$OSA_PICK"\n' \
        "$STUB_LOG" > "$T/osa/osascript"
    chmod +x "$T/osa/osascript"
}

# A task runs the CLI from ~/.local/bin with its arguments; where that is
# missing (a box window: global tasks run in the box) it prints one line
# saying where to run it, and fails.
case_blocks_task_runs_cli_or_says_where() {
    run_cfg --install --sync
    B=$T/boxhome; mkdir -p "$B"
    HOME=$B sh -c "$(task_cmd 2)" > "$T/out" 2>&1 < /dev/null; RC=$?
    assert_rc 1
    [ "$(wc -l < "$T/out" | tr -d ' ')" = 1 ] || fail "not one line: $(cat "$T/out")"
    assert_out_contains "$TOOL: $B/.local/bin/$TOOL not found. In a box window, run Minimal tasks from a local window or a Mac terminal (⌃⌥\`); on the Mac, run $TOOL setup."
    mkdir -p "$B/.local/bin"
    printf '#!/bin/sh\necho "cli $*" >> "%s"\n' "$STUB_LOG" > "$B/.local/bin/$TOOL"; chmod +x "$B/.local/bin/$TOOL"
    i=0
    for want in "new $P" "new --empty" attach destroy gc status doctor; do
        HOME=$B MIN_ZED_TASK_FOLDER=$P sh -c "$(task_cmd $i)" < /dev/null; RC=$?
        assert_rc 0
        assert_log_contains "cli $want"
        i=$((i + 1))
    done
}

# zed_task N [ROOT]: task N of $TASKS run as Zed 1.26.2 resolves it in a
# window whose worktree root is ROOT (none: no folder open): $ZED_* and
# ${ZED_*:default} pasted into the command and env values (an unset one
# without a default hides the task: exit 98), the task variables exported
# too, the command through its shell in cwd (PATH: $TASK_PATH when set).
zed_task() {
    python3 - "$TASKS" "$CFG" "$@" <<'PY' > "$T/out" 2>&1
import os, re, subprocess, sys
src = open(sys.argv[2]).read().replace('if __name__ == "__main__":\n    main()', '')
m = {}
exec(compile(src, 'min-zed-config', 'exec'), m)
t = m['load_jsonc'](open(sys.argv[1]).read())[int(sys.argv[3])]
v = {"ZED_WORKTREE_ROOT": sys.argv[4]} if len(sys.argv) > 4 else {}
def var(x):
    if x.group(1) in v:
        return v[x.group(1)]
    if x.group(2) is None:
        sys.exit(98)
    return x.group(2)
sub = lambda s: re.sub(r"\$\{(ZED_[A-Z_]+)(?::([^}]*))?\}|\$(ZED_[A-Z_]+)",
                       lambda x: var(x) if x.group(1) else v.get(x.group(3)) or sys.exit(98), s)
env = dict(os.environ, **v, **{k: sub(x) for k, x in t.get("env", {}).items()})
if "TASK_PATH" in os.environ:
    env["PATH"] = os.environ["TASK_PATH"]
try:
    r = subprocess.run([t["shell"]["program"], "-c", sub(t["command"])], cwd=sub(t["cwd"]) if "cwd" in t else None,
                       env=env, stdin=subprocess.DEVNULL)
except OSError as e:
    sys.exit(f"spawn failed: {e}")
sys.exit(r.returncode)
PY
    RC=$?
}

# New Box from Folder… makes the box from the window's folder whatever its
# name holds, without asking; with no folder open (or a single-file window)
# it asks in macOS's picker, starting at $HOME, and makes the box from the
# folder picked. Cancelling ends it quietly, any other picker failure is
# printed, and without osascript (Linux) it says to open a folder first.
case_blocks_folder_task_window_folder_else_picker() {
    run_cfg --install --sync
    B=$T/boxhome; mkdir -p "$B/.local/bin"
    printf '#!/bin/sh\necho "cli $*" >> "%s"\n' "$STUB_LOG" > "$B/.local/bin/$TOOL"; chmod +x "$B/.local/bin/$TOOL"
    osa_stub
    d="$T/my \"odd\" dir's \$HOME; x"; mkdir -p "$d"
    PATH=$T/osa:$PATH HOME=$B zed_task 0 "$d"
    assert_rc 0
    assert_log_contains "cli new $d"
    assert_log_count 0 "osascript"
    : > "$STUB_LOG"
    PATH=$T/osa:$PATH HOME=$B OSA_PICK=/picked/ zed_task 0
    assert_rc 0
    assert_log_contains "osascript from $B"
    assert_log_contains "cli new /picked/"
    : > "$d/notes.txt"; : > "$STUB_LOG"
    PATH=$T/osa:$PATH HOME=$B OSA_PICK=/picked/ zed_task 0 "$d/notes.txt"
    assert_rc 0
    assert_log_contains "osascript from $B"
    : > "$STUB_LOG"
    PATH=$T/osa:$PATH HOME=$B OSA_ERR="execution error: User canceled. (-128)" zed_task 0
    assert_rc 0
    PATH=$T/osa:$PATH HOME=$B OSA_ERR="execution error: boom (-1700)" zed_task 0
    assert_rc 1
    assert_out_contains "execution error: boom (-1700)"
    # no osascript anywhere on PATH (only sh): never the real one
    mkdir -p "$T/noosa"; ln -s /bin/sh "$T/noosa/sh"
    TASK_PATH=$T/noosa HOME=$B zed_task 0
    assert_rc 1
    [ "$(wc -l < "$T/out" | tr -d ' ')" = 1 ] || fail "not one line: $(cat "$T/out")"
    assert_out_contains "$TOOL: open a folder in Zed (File > Open), then run this task again."
    assert_log_count 0 "cli new"
}

# Only --install writes the blocks: a sync (open, destroy) leaves tasks and
# keymap alone even when the user took the block out.
case_blocks_only_from_install() {
    installed
    run config
    printf '[]\n' > "$TASKS"; : > "$KEYMAP"
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    assert_file "$TASKS" "[]"
    assert_file "$KEYMAP" ""
    [ "$(cfg_hosts)" = "${HP}alpha ${HP}proj-amber" ] || fail "hosts: $(cfg_hosts)"
    run doctor
    grep -Eq "^warn +tasks +no $TOOL block in $TASKS" "$T/out" || fail "tasks row: $(grep tasks "$T/out")"
    run config
    [ "$(jsonc_get "$TASKS" 'length')" = 7 ] || fail "config did not put the block back"
}

# The block is ours: an edit inside it is replaced on the next config, and
# doctor calls it out of date meanwhile.
case_blocks_refreshed_when_edited() {
    installed
    run config
    sed 's/"reveal": "always"/"reveal": "never"/' "$TASKS" > "$T/t" && cat "$T/t" > "$TASKS"
    run doctor
    grep -Eq "^warn +tasks +the $TOOL block in $TASKS is out of date" "$T/out" || fail "tasks row: $(grep tasks "$T/out")"
    run config
    assert_rc 0
    assert_file_not_contains "$TASKS" '"reveal": "never"'
    run doctor
    grep -Eq "^ok +tasks +7 Minimal tasks in $TASKS" "$T/out" || fail "tasks row: $(grep tasks "$T/out")"
    grep -Eq "^ok +keymap +⌃⌥\` opens a Mac terminal" "$T/out" || fail "keymap row: $(grep keymap "$T/out")"
}

# An array we added that the user then put an entry in (after our block, as
# Zed's keymap editor appends) stays on --remove, without our marks.
case_blocks_users_entry_in_our_array_kept() {
    run_cfg --install --sync
    python3 - "$KEYMAP" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
i = s.rindex("]")
s = s[:i] + '  {"bindings": {"cmd-k x": "zed::Quit"}}\n' + s[i:]
open(p, "w").write(s)
PY
    run_cfg --remove
    assert_rc 0
    assert_file "$KEYMAP" '[
  {"bindings": {"cmd-k x": "zed::Quit"}}
]'
    assert_no_file "$STATE/keymap-created"
}

# Our marks count only as our own comment lines, the begin mark right after
# the array's `[`: the same text in a user's string or comment is theirs.
case_blocks_marks_only_as_our_comments() {
    mkdir -p "$T/zed"
    printf '[\n  {"label": "// %s:begin"},\n  {"label": "// %s:end"}\n]\n' "$TOOL" "$TOOL" > "$KEYMAP"
    printf '// x // %s:begin\n[{"label": "// %s:array"}, {"label": "// %s:end"}]\n' "$TOOL" "$TOOL" "$TOOL" > "$TASKS"
    cp "$KEYMAP" "$T/orig.keymap"; cp "$TASKS" "$T/orig.tasks"
    run_cfg --install --sync
    assert_rc 0
    [ "$(jsonc_get "$KEYMAP" 'length')" = 3 ] || fail "keymap: $(cat "$KEYMAP")"
    [ "$(jsonc_get "$TASKS" 'length')" = 9 ] || fail "tasks: $(cat "$TASKS")"
    cp "$KEYMAP" "$T/installed"
    run_cfg --install --sync
    cmp -s "$T/installed" "$KEYMAP" || fail "a second install changed the keymap: $(cat "$KEYMAP")"
    run_cfg --remove
    assert_rc 0
    cmp -s "$T/orig.keymap" "$KEYMAP" || { fail "keymap not restored"; sed 's/^/#   /' "$KEYMAP" >&2; }
    cmp -s "$T/orig.tasks" "$TASKS" || { fail "tasks not restored"; sed 's/^/#   /' "$TASKS" >&2; }
}

# A tasks or keymap file that does not parse, or is no array, is refused
# loudly, and then none of the three is written.
case_blocks_refuse_bad_files() {
    mkdir -p "$T/zed"
    for bad in '[ {' '{"label": "x"}' '[1,'; do
        printf '%s' "$bad" > "$TASKS"
        run_cfg --install --sync a
        assert_rc 1
        assert_err_contains "$TASKS: cannot parse or edit as JSONC"
        assert_file "$TASKS" "$bad"
        assert_no_file "$SETTINGS"; assert_no_file "$KEYMAP"
    done
    : > "$STATE/settings-installed"
    run_cfg --doctor a
    grep -q "^tasks	FAIL	$TASKS is not valid JSONC" "$T/out" || fail "doctor: $(cat "$T/out")"
}

# min 0.7.0 is the oldest supported; newer and dev builds pass.
case_doctor_min_version() {
    for v in 0.7.0 0.7.3 0.8.0-dev.241.g7097b969 1.0.0; do
        STUB_MIN_VERSION=$v sh "$BIN" doctor > "$T/out" 2>&1 < /dev/null
        grep -Eq "^ok +min +.* $v\$" "$T/out" || fail "$v: $(grep -E '^[a-zA-Z]+ +min ' "$T/out")"
    done
    for v in 0.6.0 0.6.9 garbage; do
        STUB_MIN_VERSION=$v sh "$BIN" doctor > "$T/out" 2>&1 < /dev/null
        grep -Eq "^FAIL +min +.*needs min 0\.7\.0 or newer" "$T/out" || fail "$v: $(grep -E '^[a-zA-Z]+ +min ' "$T/out")"
    done
}

case_doctor_rows() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    mkdir -p "$HOME/.config/minimal/loadouts"; : > "$HOME/.config/minimal/loadouts/zed.toml"
    printf 'zed\n' > "$FIXTURES/loadouts.txt"
    run doctor
    assert_rc 1
    grep -Eq '^FAIL +ssh-config +not installed' "$T/out" || fail "ssh-config row: $(grep ssh-config "$T/out")"
    grep -Eq "^warn +settings +not installed; no boxes in Zed's Remote Projects" "$T/out" || fail "settings row: $(grep settings "$T/out")"
    installed
    run config
    run doctor
    assert_rc 0
    grep -Eq "^ok +editor +Zed 1\.26\.2 \($T/stub-bin/zed\)\$" "$T/out" || fail "editor row: $(cat "$T/out")"
    ! grep -q 'remote-ssh' "$T/out" || fail "a Remote-SSH row in Zed's doctor"
    grep -Eq "^ok +settings +ssh_connections: 1 ${HP}\\* host" "$T/out" || fail "settings row: $(grep settings "$T/out")"
    grep -Eq "^ok +tasks +7 Minimal tasks in $TASKS" "$T/out" || fail "tasks row: $(grep tasks "$T/out")"
    grep -Eq '^ok +keymap +⌃⌥` opens a Mac terminal, ⌃⌥N Minimal: New Box from Folder…, ⌃⌥O Minimal: Open Box…' "$T/out" || fail "keymap row: $(grep keymap "$T/out")"
    grep -Eq '^warn +skills +missing:' "$T/out" || fail "skills row: $(grep skills "$T/out")"
    grep -Eq '^ok +ssh-config +1 stanza' "$T/out" || fail "ssh-config row"
    grep -Eq '^warn +sessions +not activated by' "$T/out" || fail "alpha was not activated by us: $(cat "$T/out")"
    STUB_ZED_VERSION_LINE='Zed 1.27.0 – /Applications/Zed.app' run doctor
    grep -Eq '^ok +editor +Zed 1\.27\.0 .*; min-zed was tested with 1\.26\.2' "$T/out" || fail "editor row: $(grep editor "$T/out")"
    MIN_ZED_EDITOR_BIN=$T/no-zed run doctor
    assert_rc 1
    grep -Eq "^FAIL +editor +$T/no-zed not found" "$T/out" || fail "editor row: $(grep editor "$T/out")"
    assert_out_contains "Zed > Install CLI"
}

# ---- client surface (the Zed tasks' calls) ----------------------------------

case_new_empty_no_window() {
    installed
    sessions_after box-amber "$STATE/box"
    reset_log
    run new --empty --no-window
    assert_rc 0
    assert_out_eq "${HP}box-amber"
    assert_log_contains "min session activate --no-prompt --sync none --loadout zed $STATE/box"
    assert_log_contains "min session exec box-amber sh -c <script>"
    assert_log_not_contains "zed ssh://"
    run new --empty "$P"
    assert_rc 1
    assert_err_contains "new: --empty takes no PATH"
    run open --empty
    assert_rc 1
    assert_err_contains "open: unknown option --empty"
}

case_attach_no_window() {
    installed
    reset_log
    run attach alpha --no-window
    assert_rc 0
    assert_out_eq "${HP}alpha"
    assert_log_contains "min session exec alpha sh -c <script>"
    assert_log_not_contains "zed ssh://"
    run attach --no-window alpha
    assert_rc 0
    assert_log_not_contains "zed ssh://"
    run attach alpha
    assert_log_contains "zed ssh://${HP}alpha/workbench"
}

case_destroy_if_idle() {
    orphan_sessions
    exec_line 101 1 alpha
    run destroy -y --if-idle alpha
    assert_rc 3
    assert_err_contains "alpha is in use now; not destroying"
    assert_log_not_contains "session destroy"
    run destroy --if-idle -y beta
    assert_rc 0
    assert_log_contains "min session destroy beta"
    run destroy -z beta
    assert_rc 1
}

# min refuses a session with unsaved changes when nobody can confirm: exit 4,
# and only -y --force discards them.
case_destroy_unsaved_needs_force() {
    alpha_facts
    : > "$FIXTURES/destroy.needs-force"
    run destroy -y alpha
    assert_rc 4
    assert_err_contains "refusing to destroy the session without confirmation"
    assert_err_contains "alpha has changes min has not saved; destroy -y --force alpha discards them"
    assert_file "$STATE/sessions/alpha/user"
    run destroy --force alpha
    assert_rc 1
    assert_err_contains "destroy: --force needs -y"
    reset_log
    run destroy -y --force alpha
    assert_rc 0
    assert_log_contains "min session destroy alpha --force"
    assert_no_file "$STATE/sessions/alpha"
}

case_status_json() {
    orphan_sessions
    rm -rf "$STATE/sessions/gamma"
    jq --arg sb "$STATE/box" '.sessions += [{"id":"ID-Y","name":"box-amber","project_path":$sb,"status":"active"},
        {"id":"ID-X","name":"Bad Name","project_path":"/x","status":"active"}]' "$FIXTURES/sessions.json" > "$T/s.json" \
        && cp "$T/s.json" "$FIXTURES/sessions.json"
    own box-amber
    exec_line 101 1 alpha
    age beta 7200
    run status --json
    assert_rc 0
    j=$(cat "$T/out")
    [ "$(printf '%s' "$j" | jq -r 'map(.name) | join(" ")')" = "alpha beta gamma stopped box-amber" ] || fail "names: $j"
    [ "$(printf '%s' "$j" | jq -c '.[0]')" = "{\"name\":\"alpha\",\"status\":\"active\",\"project\":\"$AP\",\"own\":true,\"empty\":false,\"in_use\":true,\"idle\":null}" ] \
        || fail "alpha: $(printf '%s' "$j" | jq -c '.[0]')"
    b=$(printf '%s' "$j" | jq '.[1].idle')
    [ "$b" -ge 7200 ] && [ "$b" -lt 7260 ] || fail "beta idle: $b"
    [ "$(printf '%s' "$j" | jq '.[2].own')" = false ] || fail "gamma is not own"
    [ "$(printf '%s' "$j" | jq '.[4].empty')" = true ] || fail "empty flag"
    run status --bogus
    assert_rc 1
}

case_setup_installs_follows_and_removes() {
    mkdir -p "$HOME/.ssh"; printf 'Host *\n    ServerAliveInterval 30\n' > "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$T/ssh_config.orig"
    cl=$HOME/.local/bin/$TOOL
    ld=$HOME/.config/minimal/loadouts/zed.toml
    lo=$(cd "$BINDIR/.." && pwd -P)/loadouts/zed.toml
    run setup
    assert_rc 0
    [ "$(readlink "$cl")" = "$SELF" ] || fail "CLI link: $(readlink "$cl")"
    [ "$(readlink "$ld")" = "$lo" ] || fail "loadout link: $(readlink "$ld")"
    # $LOADOUT_ROOT: a real directory, a marked copy, the skill inside
    ldd=${ld%.toml}
    [ -d "$ldd" ] && [ ! -L "$ldd" ] || fail "$ldd is not a real directory"
    cmp -s "$ldd/skills/minimal-sandbox/SKILL.md" "${lo%.toml}/skills/minimal-sandbox/SKILL.md" || fail "skill not copied"
    assert_file "$ldd/.$TOOL-copy"
    # Minimal's host skills for the agents on the Mac; not the in-box one
    for sk in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
        for n in minimal-setup minimal-config minimal-loadouts minimal-networking minimal-diag; do
            assert_file "$sk/$n/SKILL.md"
        done
        assert_file "$sk/minimal-config/references/tasks-examples.md"
        assert_no_file "$sk/minimal-sandbox"
    done
    sk=$HOME/.claude/skills
    assert_file_contains "$HOME/.ssh/config" "$MARK2"
    assert_file "$HOME/$CONF"
    assert_file "$STATE/settings-installed"
    # Zed's side of the UI: the Minimal tasks and the local-terminal key
    [ "$(jsonc_get "$TASKS" 'length')" = 7 ] || fail "tasks: $(cat "$TASKS")"
    [ "$(jsonc_get "$KEYMAP" 'length')" = 1 ] || fail "keymap: $(cat "$KEYMAP")"
    sh "$BIN" doctor > "$T/doctor" 2>&1 < /dev/null
    grep -Eq '^ok +skills +5 in ~/.agents/skills and ~/.claude/skills' "$T/doctor" || fail "skills row: $(grep skills "$T/doctor")"
    # an older copy (a checkout since moved) is followed
    ln -sfn "$T/old-ext/cli/bin/$TOOL" "$cl"
    ln -sfn "$T/old-ext/cli/loadouts/zed.toml" "$ld"
    run setup
    assert_rc 0
    [ "$(readlink "$cl")" = "$SELF" ] || fail "CLI link not followed: $(readlink "$cl")"
    [ "$(readlink "$ld")" = "$lo" ] || fail "loadout link not followed: $(readlink "$ld")"
    # something that is not ours stays, and setup says so
    mkdir -p "$T/elsewhere"; : > "$T/elsewhere/other"
    ln -sfn "$T/elsewhere/other" "$cl"
    rm -f "$ld"; echo mine > "$ld"
    rm -rf "$ldd"; mkdir -p "$ldd"; echo mine > "$ldd/x"
    rm -rf "$sk/minimal-setup"; mkdir -p "$sk/minimal-setup" "$sk/theirs"; echo mine > "$sk/minimal-setup/SKILL.md"
    run setup
    assert_rc 1
    assert_err_contains "leaving $ldd: not made by $TOOL"
    assert_file "$ldd/x" mine
    assert_err_contains "leaving $sk/minimal-setup: not made by $TOOL"
    assert_file "$sk/minimal-setup/SKILL.md" mine
    assert_err_contains "leaving $cl: it points to $T/elsewhere/other"
    assert_err_contains "leaving $ld: not a symlink"
    [ "$(readlink "$cl")" = "$T/elsewhere/other" ] || fail "foreign link replaced"
    assert_file "$ld" mine
    rm -rf "$cl" "$ld" "$ldd" "$sk/minimal-setup"
    run setup
    run setup --remove
    assert_rc 0
    assert_no_file "$cl"
    assert_no_file "$ld"
    assert_no_file "$ldd"
    assert_no_file "$HOME/.agents/skills/minimal-config"
    assert_no_file "$sk/minimal-config"
    [ -d "$sk/theirs" ] || fail "a skill dir that is not ours was removed"
    assert_no_file "$HOME/$CONF"
    cmp -s "$HOME/.ssh/config" "$T/ssh_config.orig" || fail "$HOME/.ssh/config not restored"
    zed_files_absent
    run setup --bogus
    assert_rc 1
}

# Run through its ~/.local/bin link (how users run it), setup finds the
# checkout behind the link: doctor sees the skills, --remove takes both
# links out.
case_setup_through_link() {
    cl=$HOME/.local/bin/$TOOL
    ld=$HOME/.config/minimal/loadouts/zed.toml
    run setup
    assert_rc 0
    sh "$cl" doctor > "$T/doctor" 2>&1 < /dev/null
    grep -Eq '^ok +skills ' "$T/doctor" || fail "skills row: $(grep skills "$T/doctor")"
    sh "$cl" setup > "$T/out" 2> "$T/err" < /dev/null; RC=$?
    assert_rc 0
    [ "$(readlink "$cl")" = "$SELF" ] || fail "CLI link: $(readlink "$cl")"
    sh "$cl" setup --remove > "$T/out" 2> "$T/err" < /dev/null; RC=$?
    assert_rc 0
    assert_no_file "$cl"
    assert_no_file "$ld"
}

# A skill another min-<client> installed too (its own .min-*-copy mark) is
# shared: setup takes it over keeping that mark, --remove takes only ours out
# and leaves the skill to the other tool; the skills directory setup made
# goes once it is empty.
case_setup_shares_skills_with_other_tools() {
    sk=$HOME/.claude/skills
    mkdir -p "$sk/minimal-config"; echo old > "$sk/minimal-config/SKILL.md"; echo /x > "$sk/minimal-config/.min-vscode-copy"
    run setup
    assert_rc 0
    assert_file "$sk/minimal-config/.min-vscode-copy" /x
    assert_file "$sk/minimal-config/.$TOOL-copy"
    cmp -s "$sk/minimal-config/SKILL.md" "$ROOT/skills/minimal-config/SKILL.md" || fail "shared skill not updated"
    run setup
    assert_rc 0
    assert_file "$sk/minimal-config/.min-vscode-copy" /x
    run setup --remove
    assert_rc 0
    assert_err_contains "left $sk/minimal-config: also installed by min-vscode"
    assert_file "$sk/minimal-config/.min-vscode-copy" /x
    assert_no_file "$sk/minimal-config/.$TOOL-copy"
    assert_no_file "$sk/minimal-setup"
    assert_no_file "$HOME/.agents/skills"
}

# loadout_hook N: the Nth (from 0) inline on_activate script of the loadout,
# between the lines `on_activate.value = '''` and `'''`.
# setup --remove with a Zed file the merger refuses removes nothing else and
# fails: the tasks there still run the CLI, the entries need the stanzas.
case_setup_remove_stops_when_config_refuses() {
    cl=$HOME/.local/bin/$TOOL
    ld=$HOME/.config/minimal/loadouts/zed.toml
    run setup
    assert_rc 0
    printf '{ broken' > "$SETTINGS"
    run setup --remove
    assert_rc 1
    assert_err_contains "fix the file, then run $TOOL setup --remove again"
    [ -L "$cl" ] || fail "CLI link removed"
    [ -L "$ld" ] || fail "loadout link removed"
    assert_file "$HOME/.claude/skills/minimal-config/SKILL.md"
    assert_file "$HOME/$CONF"
    assert_file_contains "$HOME/.ssh/config" "$MARK2"
    assert_file "$STATE/settings-installed"
    [ "$(jsonc_get "$TASKS" 'length')" = 7 ] || fail "tasks: $(cat "$TASKS")"
    printf '{}\n' > "$SETTINGS"
    run setup --remove
    assert_rc 0
    assert_no_file "$cl"
    assert_no_file "$HOME/$CONF"
    assert_no_file "$TASKS"
}

loadout_hook() {
    awk -v want="$1" -v q="'''" '$0 == "on_activate.value = " q { on = (n++ == want); next }
        $0 == q { on = 0; next } on' "$ROOT/loadouts/zed.toml"
}

case_loadout_rc_line_once() {
    B=$T/box; mkdir -p "$B"
    HOME=$B sh -c "$(loadout_hook 0)" < /dev/null
    HOME=$B sh -c "$(loadout_hook 0)" < /dev/null
    [ "$(grep -c 'min:workbench' "$B/.bashrc")" = 1 ] || fail ".bashrc: $(cat "$B/.bashrc")"
    [ "$(grep -c 'min:workbench' "$B/.zshrc")" = 1 ] || fail ".zshrc: $(cat "$B/.zshrc")"
    assert_file "$B/.bash_profile"
}

# The loadout copies minimal-sandbox for Claude Code in the box (Zed's agent
# runs on the Mac), from the loadout's own skills/ ($LOADOUT_ROOT).
case_loadout_skill_only_for_claude() {
    l=$ROOT/loadouts/zed.toml
    # shellcheck disable=SC2016  # min's variable, literal
    grep -q 'dest = ".claude/skills/minimal-sandbox/", source = "$LOADOUT_ROOT/skills/minimal-sandbox"' "$l" || fail "no Claude patch: $(grep dest "$l")"
    [ "$(grep -c 'dest = ' "$l")" = 1 ] || fail "patches: $(grep dest "$l")"
    [ -f "$ROOT/loadouts/zed/skills/minimal-sandbox/SKILL.md" ] || fail "minimal-sandbox not vendored"
    ! grep -q '"jq"' "$l" || fail "jq is back in the loadout"
}

# ---- ssh-config ----------------------------------------------------------------

case_sshconfig_install_creates_include_and_stanza() {
    installed
    assert_err_contains "added \`$MARK2\` to the top of $HOME/.ssh/config"
    assert_err_contains "$HOME/$CONF: 1 stanza(s); ssh ${HP}NAME reaches a session"
    assert_file "$HOME/.ssh/config" "$MARK1
$MARK2"
    assert_file "$HOME/$CONF" "$(conf_expected alpha)"
    assert_mode "$HOME/.ssh" 700
    assert_mode "$HOME/.ssh/config" 600
    assert_mode "$HOME/$CONF" 600
    cp "$HOME/$CONF" "$T/first.conf"; cp "$HOME/.ssh/config" "$T/first.config"
    run ssh-config
    assert_rc 0
    ! grep -q 'added' "$T/err" || fail "second install must not add the Include again"
    cmp -s "$T/first.config" "$HOME/.ssh/config" || fail "config changed on a second install"
    cmp -s "$T/first.conf" "$HOME/$CONF" || fail "conf changed on a second install"
}

existing_config() {
    mkdir -p "$HOME/.ssh"
    printf '# mine\nHost other\n    HostName example.org' > "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$T/orig.config"
}

case_sshconfig_remove_restores_original() {
    existing_config
    installed
    { printf '%s\n%s\n' "$MARK1" "$MARK2"; cat "$T/orig.config"; } > "$T/want.config"
    cmp -s "$T/want.config" "$HOME/.ssh/config" || fail "config is not marker + Include + original bytes"
    run ssh-config --remove
    assert_rc 0
    assert_err_contains "removed the $TOOL Include from $HOME/.ssh/config"
    cmp -s "$T/orig.config" "$HOME/.ssh/config" || fail "config not restored byte for byte"
    assert_no_file "$HOME/$CONF"
    run ssh-config --remove
    assert_err_contains "no $TOOL Include found in $HOME/.ssh/config"
    cmp -s "$T/orig.config" "$HOME/.ssh/config" || fail "second --remove changed the config"
}

case_sshconfig_coexists_with_another_tool() {
    existing_config
    other='# min-other ssh-config (remove with: min-other ssh-config --remove)
Include ~/.ssh/min-other.conf'
    { printf '%s\n' "$other"; cat "$T/orig.config"; } > "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$T/with-other.config"
    installed
    run ssh-config --remove
    cmp -s "$T/with-other.config" "$HOME/.ssh/config" || fail "another tool's Include was touched"
}

case_sshconfig_keeps_symlinked_config() {
    mkdir -p "$T/dotfiles" "$HOME/.ssh"
    printf 'Host other\n' > "$T/dotfiles/ssh_config"
    ln -s "$T/dotfiles/ssh_config" "$HOME/.ssh/config"
    installed
    [ -L "$HOME/.ssh/config" ] || fail "$HOME/.ssh/config is no longer a symlink"
    assert_file "$T/dotfiles/ssh_config" "$MARK1
$MARK2
Host other"
}

case_sshconfig_print_touches_nothing() {
    alpha_facts
    run ssh-config --print
    assert_rc 0
    assert_out_eq "$(conf_expected alpha)"
    run ssh-config --bogus
    assert_rc 1
    assert_err_contains "$TOOL: ssh-config: unknown option --bogus"
    assert_no_file "$HOME/.ssh"
}

case_sshconfig_destroy_drops_stanza() {
    installed
    sessions_after beta "$P"; cp "$FIXTURES/sessions.after.json" "$FIXTURES/sessions.json"
    run ssh beta -- true
    assert_file "$HOME/$CONF" "$(conf_expected alpha beta)"
    run destroy -y alpha
    assert_rc 0
    assert_file "$HOME/$CONF" "$(conf_expected beta)"
}

case_sshconfig_stale_and_invalid_dirs_skipped() {
    alpha_facts
    mkdir -p "$STATE/sessions/ghost" "$STATE/sessions/my sess"
    printf 'box\n' > "$STATE/sessions/ghost/user"; printf 'box\n' > "$STATE/sessions/my sess/user"
    run ssh-config
    assert_rc 0
    assert_err_contains "1 stanza(s)"
    assert_file_not_contains "$HOME/$CONF" "Host ${HP}ghost"
    assert_err_contains "[$TOOL] skipping my sess: not a valid stanza name"
    MIN_BIN=$T/no-such-min run ssh-config --print
    grep -qF "Host ${HP}ghost" "$T/out" || fail "--print without min must list ghost"
    ! grep -q 'MIN_BIN=' "$T/out" || fail "no MIN_BIN word expected when min is not resolvable"
}

case_sshconfig_real_ssh_resolves() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    installed
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
    printf 'Host %sexample.com\n    User someone\n' "$HP" >> "$HOME/.ssh/config"
    g=$(ssh_g "${HP}example.com")
    assert_line_in "$g" "user someone"
    ! printf '%s\n' "$g" | grep -q '^proxycommand' || fail "a dotted host got a ProxyCommand"
}

case_sshconfig_forwarding_off_despite_host_star() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    mkdir -p "$HOME/.ssh"
    printf 'Host *\n    ForwardAgent yes\n    ForwardX11 yes\n    ForwardX11Trusted yes\n' > "$HOME/.ssh/config"
    installed
    g=$(ssh_g "${HP}alpha")
    assert_line_in "$g" "forwardagent no"
    assert_line_in "$g" "forwardx11 no"
    assert_line_in "$g" "forwardx11trusted no"
}

case_forwarding_off_on_ssh_path() {
    run ssh alpha -- true
    assert_rc 0
    assert_log_contains "-o ForwardAgent=no"
    assert_log_contains "-o ForwardX11=no"
    assert_log_contains "-o StrictHostKeyChecking=yes"
    assert_log_contains "-o AddKeysToAgent=no"
    assert_log_contains " ${HP}alpha true"
}

case_sshconfig_paths_with_spaces_and_percent() {
    [ -x /usr/bin/ssh ] || { skip "no /usr/bin/ssh"; return 0; }
    STATE="$T/st ate %x" MIN_ZED_STATE_DIR="$T/st ate %x"; export MIN_ZED_STATE_DIR
    installed
    assert_file_contains "$HOME/$CONF" "IdentityFile \"$T/st ate %%x/sessions/alpha/id_ed25519\""
    g=$(ssh_g "${HP}alpha")
    assert_line_in "$g" "proxycommand env MIN_BIN=$T/bin/min MIN_ZED_STATE_DIR='$T/st ate %%x' $SELF _proxy alpha"
}

case_sshconfig_prefers_local_bin_symlink() {
    alpha_facts
    mkdir -p "$HOME/.local/bin"
    ln -s "$BIN" "$HOME/.local/bin/$TOOL"
    run ssh-config
    assert_file_contains "$HOME/$CONF" " $HOME/.local/bin/$TOOL _proxy alpha"
    assert_file_not_contains "$HOME/$CONF" "$SELF"
    rm "$HOME/.local/bin/$TOOL"; printf '#!/bin/sh\n' > "$T/other"; ln -s "$T/other" "$HOME/.local/bin/$TOOL"
    run ssh-config
    assert_file_contains "$HOME/$CONF" " $SELF _proxy alpha"
}

case_sshconfig_refuses_double_quote_in_state_dir() {
    alpha_facts
    STATE=$(printf '%s/st"q' "$T") MIN_ZED_STATE_DIR=$STATE; export MIN_ZED_STATE_DIR
    run ssh-config
    assert_rc 1
    assert_err_contains "$TOOL: state dir path contains a double quote; not writing"
    assert_no_file "$HOME/.ssh"
}

case_sshconfig_write_failure_does_not_block_ssh() {
    installed
    printf '# sentinel\n' >> "$HOME/$CONF"
    cp "$HOME/$CONF" "$T/before.conf"
    chmod 500 "$HOME/.ssh"
    run ssh alpha -- true
    chmod 700 "$HOME/.ssh"
    assert_rc 0
    assert_err_contains "[$TOOL] could not write $HOME/$CONF; leaving it as it was"
    cmp -s "$T/before.conf" "$HOME/$CONF" || fail "conf changed although the dir was read-only"
}

case_sshconfig_min_ls_failure_keeps_stanzas() {
    installed
    MIN_BIN=/usr/bin/false run ssh-config
    assert_rc 0
    assert_err_contains "1 stanza(s)"
    assert_file_contains "$HOME/$CONF" "MIN_BIN=/usr/bin/false "
}

case_sshconfig_unchanged_conf_not_rewritten() {
    installed
    touch -t 200001010000 "$HOME/$CONF"; : > "$T/stamp"
    run _proxy alpha
    assert_rc 0
    [ -z "$(find "$HOME/$CONF" -newer "$T/stamp")" ] || fail "conf rewritten although unchanged"
    sessions_after beta "$P"; cp "$FIXTURES/sessions.after.json" "$FIXTURES/sessions.json"
    run _proxy beta
    assert_file "$HOME/$CONF" "$(conf_expected alpha beta)"
}

case_sshconfig_remove_deletes_what_it_created() {
    rm -rf "$STATE"
    run ssh-config
    assert_file "$HOME/$CREATED_REL" "dir
config"
    run ssh-config --remove
    assert_rc 0
    assert_no_file "$HOME/.ssh"
    mkdir -p "$HOME/.ssh"; : > "$HOME/.ssh/config"
    run ssh-config
    run ssh-config --remove
    assert_file "$HOME/.ssh/config" ""
    ! grep -q 'now empty' "$T/err" || fail "must not remove a config it did not create"
}

case_sshconfig_backs_up_before_writing() {
    existing_config
    installed
    b=$(find "$STATE/backups" -name 'ssh_config.*' | head -1)
    cmp -s "$T/orig.config" "$b" || fail "backup is not the config before install"
    assert_mode "$b" 600
    assert_mode "$STATE/backups" 700
}

# ---- _proxy and prepare ---------------------------------------------------------

case_proxy_prepares_then_execs_sshd() {
    run _proxy alpha
    assert_rc 0
    d=$STATE/sessions/alpha
    pub=$(cat "$d/id_ed25519.pub")
    assert_log_before "min session exec alpha sh -c <script> $TOOL $pub" "min session exec alpha $SSHD_ARGV"
    assert_file "$d/known_hosts" "${HP}alpha ssh-ed25519 AAAAFAKE"
    assert_out_eq "sshd-stub [session] [exec] [alpha] [/usr/sbin/sshd] [-i] [-e] [-f] [/dev/null] [-h] [/home/.ssh/$TOOL/host_ed25519] [-o] [LogLevel=ERROR] [-o] [PidFile=none] [-o] [StrictModes=no] [-o] [PubkeyAuthentication=yes] [-o] [PasswordAuthentication=no] [-o] [KbdInteractiveAuthentication=no] [-o] [AuthorizedKeysFile /home/.ssh/$TOOL/authorized_keys] [-o] [PermitUserEnvironment=yes] [-o] [AllowTcpForwarding=yes] [-o] [GatewayPorts=no] [-o] [AllowAgentForwarding=no] [-o] [X11Forwarding=no] [-o] [PrintMotd=no] [-o] [PrintLastLog=no] [-o] [UseDNS=no] [-o] [Subsystem sftp internal-sftp]"
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8} alpha ok$' "$STATE/proxy.log" || fail "proxy.log: $(cat "$STATE/proxy.log")"
    assert_no_file "$HOME/.ssh"
}

case_proxy_never_touches_settings_or_editor() {
    installed
    run config
    cp "$SETTINGS" "$T/before.json"
    sessions_after beta "$P"; cp "$FIXTURES/sessions.after.json" "$FIXTURES/sessions.json"
    reset_log
    run _proxy beta
    assert_rc 0
    cmp -s "$T/before.json" "$SETTINGS" || fail "_proxy changed the settings"
    ! grep -q '^code ' "$STUB_LOG" || fail "_proxy ran the editor"
}

case_proxy_failures() {
    : > "$FIXTURES/facts.txt"
    run _proxy alpha
    assert_rc 1
    assert_err_contains "incomplete facts"
    [ ! -s "$T/out" ] || fail "nothing may reach stdout before the exec: $(cat "$T/out")"
    grep -q ' alpha fail: prepare$' "$STATE/proxy.log" || fail "proxy.log: $(cat "$STATE/proxy.log")"
    run _proxy nope
    assert_rc 1
    assert_err_contains "$TOOL: no session named nope"
    [ ! -s "$T/out" ] || fail "nothing may reach stdout"
}

case_proxy_missing_takes_no_host() {
    reset_log
    run _proxy --missing
    assert_rc 1
    assert_err_contains "$MISSING_MSG"
    # shellcheck disable=SC2016 # literal on purpose
    run _proxy --missing 'x.$(touch pwned)'
    assert_err_contains "$MISSING_MSG"
    ! grep -qF 'pwned' "$T/err" || fail "host argument echoed"
    assert_log_not_contains "min "
    MIN_BIN=/nonexistent PATH=/usr/bin:/bin sh "$BIN" _proxy --missing > "$T/out" 2> "$T/err" < /dev/null; RC=$?
    assert_rc 1
    assert_err_contains "$MISSING_MSG"
}

case_proxy_log_capped_and_private() {
    i=0; while [ $i -lt 1000 ]; do echo "old $i"; i=$((i + 1)); done > "$STATE/proxy.log"
    chmod 644 "$STATE/proxy.log"
    run _proxy alpha
    assert_mode "$STATE/proxy.log" 600
    [ "$(($(wc -l < "$STATE/proxy.log")))" = 500 ] || fail "proxy.log not capped to 500"
    rm "$STATE/proxy.log"; mkdir "$STATE/proxy.log"
    run _proxy alpha
    assert_rc 0
    [ ! -s "$T/err" ] || fail "stderr: $(cat "$T/err")"
}

# _proxy runs prepare under `||` (set -e off): a fact that cannot be written
# still fails the connect, and is logged.
case_proxy_prepare_write_failure() {
    alpha_facts
    # put's mktemp fails for the session dir (as on a full disk)
    printf '#!/bin/sh\ncase "$*" in *sessions/alpha/*) exit 1 ;; esac\nexec /usr/bin/mktemp "$@"\n' > "$T/bin/mktemp"
    chmod +x "$T/bin/mktemp"
    run _proxy alpha
    assert_rc 1
    assert_err_contains "could not write the facts for alpha"
    grep -q ' alpha fail: prepare$' "$STATE/proxy.log" || fail "proxy.log: $(cat "$STATE/proxy.log" 2>/dev/null)"
    ! grep -q ' alpha ok$' "$STATE/proxy.log" || fail "logged ok after a failed write"
}

case_prepare_writes_atomically() {
    d=$STATE/sessions/alpha
    mkdir -p "$d"
    printf 'DECOY\n' > "$T/decoy"
    ln -s "$T/decoy" "$d/known_hosts"
    alpha_facts
    [ ! -L "$d/known_hosts" ] || fail "known_hosts is still a symlink: written in place"
    assert_file "$T/decoy" DECOY
    assert_file "$d/user" box
}

# reject_fact FIELD LINE: prepare fails naming FIELD and nothing on disk changes.
reject_fact() {
    grep -v "^$1=" "$FIXTURES/facts.txt" > "$T/facts.tmp"; printf '%s\n' "$2" >> "$T/facts.tmp"
    cp "$T/facts.tmp" "$FIXTURES/facts.txt"
    run ssh alpha -- true
    assert_rc 1
    assert_err_contains "$TOOL: session alpha reported an invalid $1 ("
    for f in known_hosts user home sshd; do
        cmp -s "$STATE/sessions/alpha/$f" "$T/snap/$f" || fail "$1 '$2': sessions/alpha/$f changed"
    done
    cmp -s "$HOME/$CONF" "$T/snap/conf" || fail "$1 '$2': conf changed"
    default_fixtures
}

case_prepare_rejects_bad_facts() {
    installed
    mkdir -p "$T/snap"
    for f in known_hosts user home sshd; do cp "$STATE/sessions/alpha/$f" "$T/snap/$f"; done
    cp "$HOME/$CONF" "$T/snap/conf"
    # shellcheck disable=SC2016 # literal on purpose
    for u in 'user=${HOME}' 'user=a b' 'user=%h' 'user=-oops' 'user=r`id`' 'user=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do reject_fact user "$u"; done
    # shellcheck disable=SC2016
    for k in 'hostkey=ssh-rsa AAAAFAKE' 'hostkey=ssh-ed25519 AAAAFAKE extra' 'hostkey=ssh-ed25519 AA$AA'; do reject_fact hostkey "$k"; done
    # shellcheck disable=SC2016
    for h in 'home=home' 'home=/ho"me' 'home=/h%h' 'home=/h$X' 'home=/a b' "$(printf 'home=/a\033b')"; do reject_fact home "$h"; done
    for x in 'sshd=sshd' 'sshd=/a%d'; do reject_fact sshd "$x"; done
}

case_prepare_accepts_valid_facts() {
    printf 'user=First.last_1-x\nhome=/home/u-1.x@y+z\nsshd=/nix/store/abc-openssh/bin/sshd\nhostkey=ssh-ed25519 AAAAC3+/z9==\n' > "$FIXTURES/facts.txt"
    installed
    assert_file "$STATE/sessions/alpha/known_hosts" "${HP}alpha ssh-ed25519 AAAAC3+/z9=="
    assert_file_contains "$HOME/$CONF" "    User First.last_1-x"
}

case_prepare_errors_strip_control_bytes() {
    printf 'user=box\nhome=/h\033]0;x\007%%\nsshd=/usr/sbin/sshd\nhostkey=ssh-ed25519 AAAAFAKE\n' > "$FIXTURES/facts.txt"
    run ssh alpha -- true
    assert_rc 1
    assert_err_contains "invalid home (/h?]0;x?%)"
    ! LC_ALL=C grep -q "$(printf '\033')" "$T/err" || fail "ESC reached stderr"
}

case_stored_user_checked_on_read() {
    installed
    # shellcheck disable=SC2016 # literal on purpose
    printf '${HOME}\n' > "$STATE/sessions/alpha/user"
    run ssh-config --print
    ! grep -q "^Host ${HP}alpha\$" "$T/out" || fail "stanza with a bad stored user printed"
    assert_err_contains "skipping alpha: invalid user in $STATE/sessions/alpha/user"
}

# _proxy re-reads home/sshd after prepare; a no-op prepare leaves a bad
# stored path in place so the client-layer fact_ok can fire (TOCTOU window).
# Sourcing clears MIN (client layer); re-set it after `.`.
case_proxy_rechecks_stored_paths() {
    alpha_facts
    sed '/^# ---- main/,$d' "$BIN" > "$T/lib"
    # shellcheck disable=SC2016 # literal on purpose
    printf '/h$(x)\n' > "$STATE/sessions/alpha/home"
    sh -c '. "$1"; MIN=$2; prepare() { :; }; cmd_proxy alpha' sh "$T/lib" "$MIN_BIN" >"$T/out" 2>"$T/err"
    RC=$?
    assert_rc 1
    assert_err_contains "session alpha: invalid home in $STATE/sessions/alpha/home; not using it"
    [ ! -s "$T/out" ] || fail "nothing may reach stdout before the exec: $(cat "$T/out")"
    grep -q " alpha fail: invalid home in $STATE/sessions/alpha/home\$" "$STATE/proxy.log" || fail "proxy.log: $(cat "$STATE/proxy.log")"
    # `ssh` builds its ProxyCommand from the same stored paths
    sh -c '. "$1"; MIN=$2; ssh_opts alpha' sh "$T/lib" "$MIN_BIN" >"$T/out" 2>"$T/err"
    RC=$?
    assert_rc 1
    assert_err_contains "session alpha: invalid home in $STATE/sessions/alpha/home; not using it"
    ! grep -q ProxyCommand "$T/out" || fail "ssh_opts printed a ProxyCommand: $(cat "$T/out")"
    printf '/home\n' > "$STATE/sessions/alpha/home"
    printf 'sshd\n' > "$STATE/sessions/alpha/sshd"
    sh -c '. "$1"; MIN=$2; prepare() { :; }; cmd_proxy alpha' sh "$T/lib" "$MIN_BIN" >"$T/out" 2>"$T/err"
    RC=$?
    assert_rc 1
    assert_err_contains "session alpha: invalid sshd in $STATE/sessions/alpha/sshd; not using it"
    [ ! -s "$T/out" ] || fail "nothing may reach stdout before the exec: $(cat "$T/out")"
    sh -c '. "$1"; MIN=$2; ssh_opts alpha' sh "$T/lib" "$MIN_BIN" >"$T/out" 2>"$T/err"
    RC=$?
    assert_rc 1
    assert_err_contains "session alpha: invalid sshd in $STATE/sessions/alpha/sshd; not using it"
}

# ---- PREP for real (the min stub only serves facts.txt) ----

prep_script() { sed -n "/^PREP='/,/'\$/p" "$BIN" | sed -e "1s/^PREP='//" -e "\$s/'\$//"; }
run_prep() {
    HOME=$T/box sh -c "$(prep_script)" "$TOOL" "ssh-ed25519 AAAAUSER user" > "$1" 2> "$1.err" < /dev/null
}
BOXD=.ssh/$TOOL   # host key and authorized_keys dir under $T/box

assert_facts_only() {
    [ -s "$1" ] || fail "no facts in $1"
    ! grep -Ev '^[a-z]+=' "$1" >/dev/null || fail "non-fact stdout in $1: $(grep -Ev '^[a-z]+=' "$1")"
}

case_prep_extracts_and_prints_facts() {
    prep_script | grep -q '^echo "hostkey=' || fail "prep_script did not cut PREP out of the CLI"
    run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    assert_facts_only "$T/p1"
    assert_line_in "$(cat "$T/p1")" "hostkey=ssh-ed25519 AAAAPUB"
    assert_file "$T/box/.ssh/$TOOL/authorized_keys" "ssh-ed25519 AAAAUSER user"
    assert_mode "$T/box/$BOXD/host_ed25519" 600
    run_prep "$T/p2" || fail "second PREP failed"
    assert_log_count 1 "ssh-keygen"
    [ "$(grep -c 'min:workbench' "$T/box/.zshrc")" = 1 ] || fail "rc line repeated"
}

# A box with Minimal's claude (/usr/bin/claude) gets CLAUDE_CODE_EXECUTABLE
# in the sshd environment, once; without it, none; a value of the box's own
# is kept as it is.
case_prep_claude_executable_only_with_claude() {
    run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    ! grep -q CLAUDE_CODE_EXECUTABLE "$T/box/.ssh/environment" || fail "set without claude"
    printf '#!/bin/sh\n' > "$T/claude"; chmod +x "$T/claude"
    MIN_BOX_CLAUDE=$T/claude run_prep "$T/p2" || fail "PREP failed: $(cat "$T/p2.err")"
    MIN_BOX_CLAUDE=$T/claude run_prep "$T/p2" || fail "PREP failed: $(cat "$T/p2.err")"
    [ "$(grep -c '^CLAUDE_CODE_EXECUTABLE=' "$T/box/.ssh/environment")" = 1 ] || fail "env: $(cat "$T/box/.ssh/environment")"
    assert_file_contains "$T/box/.ssh/environment" "CLAUDE_CODE_EXECUTABLE=$T/claude"
    CLAUDE_CODE_EXECUTABLE=/opt/mine MIN_BOX_CLAUDE=$T/claude run_prep "$T/p3" || fail "PREP failed: $(cat "$T/p3.err")"
    [ "$(grep '^CLAUDE_CODE_EXECUTABLE=' "$T/box/.ssh/environment")" = CLAUDE_CODE_EXECUTABLE=/opt/mine ] || fail "env: $(cat "$T/box/.ssh/environment")"
}

case_prep_waiter_keeps_lock_it_does_not_own() {
    mkdir -p "$T/box/$BOXD/.keygen"
    MIN_KEYGEN_WAIT=2 run_prep "$T/p1"
    grep -q "did not finish" "$T/p1.err" || fail "stderr: $(cat "$T/p1.err")"
    [ -d "$T/box/$BOXD/.keygen" ] || fail "waiter removed a lock it does not own"
    assert_log_count 0 "ssh-keygen"
}

case_prep_breaks_stale_lock() {
    mkdir -p "$T/box/$BOXD/.keygen"
    touch -t 200001010000 "$T/box/$BOXD/.keygen"
    MIN_KEYGEN_WAIT=2 run_prep "$T/p1" || fail "PREP failed: $(cat "$T/p1.err")"
    assert_log_count 1 "ssh-keygen"
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
    [ "$(cat "$T/box/$BOXD/host_ed25519")" = "PRIVATE ${k#ssh-ed25519 AAAAPUB}" ] || fail "key pair mismatch"
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
    [ ! -s "$T/p1" ] || fail "stdout on failure"
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

# ---- misc ----------------------------------------------------------------------

case_completions_parse() {
    run completions zsh
    assert_rc 0
    assert_out_contains "compdef _min_zed $TOOL"
    if command -v zsh >/dev/null 2>&1; then zsh -n "$T/out" || fail "zsh completion does not parse"; fi
    run completions bash
    assert_rc 0
    if command -v bash >/dev/null 2>&1; then bash -n "$T/out" || fail "bash completion does not parse"; fi
    run completions fish
    assert_rc 1
}

# Completions offer only own sessions, not another tool's beta.
case_sessions_lists_names() {
    own alpha
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-A","name":"alpha","project_path":"$AP","status":"active"},
 {"id":"ID-B","name":"beta","project_path":"$T/beta-proj","status":"active"}]}
JSON
    run _sessions
    assert_out_eq alpha
}

case_usage() {
    run --help
    assert_rc 0
    assert_out_contains "usage: $TOOL <command>"
    run bogus
    assert_rc 2
}

# make_tool_b: a second min-<client> tool at $T/tool-b/min-zz: this script,
# other names (TOOL min-zz, Host prefix min-zz., state $MIN_ZZ_STATE_DIR).
make_tool_b() {
    mkdir -p "$T/tool-b"
    # shellcheck disable=SC2016  # $MIN_ZZ_STATE_DIR is for the copy
    sed -e 's/^TOOL=min-zed$/TOOL=min-zz/' -e 's/^HOST_PREFIX=.*/HOST_PREFIX=min-zz./' \
        -e 's/^ENV_PREFIX=MIN_ZED$/ENV_PREFIX=MIN_ZZ/' -e 's/^STATE=.*/STATE=$MIN_ZZ_STATE_DIR/' "$BIN" > "$T/tool-b/min-zz"
    grep -qx 'TOOL=min-zz' "$T/tool-b/min-zz" || fail "tool b not made"
}
run_b() { MIN_ZZ_STATE_DIR=$T/state-b sh "$T/tool-b/min-zz" "$@" > "$T/out" 2> "$T/err" < /dev/null; RC=$?; }

# Two tools install and remove in every order: ~/.ssh/config ends byte for
# byte as it was, or is gone (with ~/.ssh) when neither found one.
case_sshconfig_two_tools_coexist() {
    make_tool_b
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
            assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/$TOOL.conf"
            assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/min-zz.conf"
            first=$3
            for t in "$3" "$4"; do
                if [ "$t" = a ]; then run ssh-config --remove; else run_b ssh-config --remove; fi
                assert_rc 0
                [ "$t" = "$first" ] || continue
                # the first removal leaves the other tool working
                if [ "$t" = a ]; then o=min-zz; else o=$TOOL; fi
                assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/$o.conf"
                [ -f "$HOME/.ssh/$o.conf" ] || fail "$start/$order: $o.conf removed by the other tool"
            done
            if [ "$start" = none ]; then
                assert_no_file "$HOME/.ssh"
            else
                cmp -s "$T/orig.config" "$HOME/.ssh/config" || fail "$start/$order: config not restored byte for byte"
            fi
            assert_no_file "$HOME/$CREATED_REL"
        done
    done
}

# min skips default_loadouts once any --loadout is named: open passes them on.
case_open_keeps_default_loadouts() {
    installed
    mkdir -p "$HOME/.config/minimal"
    printf '[other]\ndefault_loadouts = ["no"]\n[loadouts] # mine\ndefault_loadouts = [\n  "dots", # comment\n  "zed", "bad name",\n  "broker"]\n[after]\nx = ["nope"]\n' \
        > "$HOME/.config/minimal/config.toml"
    sessions_after proj-amber "$P"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout dots --loadout broker --loadout zed $P"
}

# default_loadouts in the other TOML spellings.
case_open_default_loadouts_toml_forms() {
    installed
    mkdir -p "$HOME/.config/minimal"
    sessions_after proj-amber "$P"
    printf "loadouts.default_loadouts = ['dots']\n[loadouts]\nx = 1\n" > "$HOME/.config/minimal/config.toml"
    run open "$P"
    assert_rc 0
    assert_log_contains "min session activate --no-prompt --loadout dots --loadout zed $P"
    printf "[ loadouts ]\ndefault_loadouts = [ 'a.b', 'x y' ]\n" > "$HOME/.config/minimal/config.toml"
    printf '{"sessions":[]}\n' > "$FIXTURES/sessions.json"; reset_log
    run open "$P"
    assert_log_contains "min session activate --no-prompt --loadout a.b --loadout zed $P"
    assert_err_contains "ignoring default loadout 'x y'"
    printf '[loadouts]\ndefault_loadouts = [dots]\n' > "$HOME/.config/minimal/config.toml"
    printf '{"sessions":[]}\n' > "$FIXTURES/sessions.json"; reset_log
    run open "$P"
    assert_log_contains "min session activate --no-prompt --loadout zed $P"
    assert_err_contains "could not read default_loadouts in $HOME/.config/minimal/config.toml"
    printf '[loadouts]\ndefault_loadouts = []\n' > "$HOME/.config/minimal/config.toml"
    printf '{"sessions":[]}\n' > "$FIXTURES/sessions.json"
    run open "$P"
    ! grep -q 'default_loadouts' "$T/err" || fail "an empty list is not unreadable: $(cat "$T/err")"
}

# ~/.ssh/config is rewritten under one lock every tool shares.
case_sshconfig_lock_held_waits_then_fails() {
    L=$HOME/.local/state/min-clients/ssh-config.lock
    mkdir -p "$L"
    MIN_LOCK_WAIT=1 run ssh-config
    assert_rc 1
    assert_err_contains "$L is held by another ssh-config run"
    assert_no_file "$HOME/.ssh/config"
    [ -d "$L" ] || fail "a waiter removed a lock it does not hold"
    touch -t 200001010000 "$L"     # its holder died long ago
    MIN_LOCK_WAIT=1 run ssh-config
    assert_rc 0
    assert_file_contains "$HOME/.ssh/config" "Include ~/.ssh/$TOOL.conf"
    assert_no_file "$L"
    MIN_LOCK_WAIT=1 run ssh-config --remove
    assert_rc 0
    assert_no_file "$HOME/.ssh"
    assert_no_file "$HOME/.local/state/min-clients"
}

case_sshconfig_two_tools_install_at_once() {
    make_tool_b
    r=0; while [ "$r" -lt 4 ]; do
        rm -rf "$HOME/.ssh" "$HOME/.local/state/min-clients"
        sh "$BIN" ssh-config > "$T/a.out" 2>&1 < /dev/null & a=$!
        MIN_ZZ_STATE_DIR=$T/state-b sh "$T/tool-b/min-zz" ssh-config > "$T/b.out" 2>&1 < /dev/null & b=$!
        wait "$a" || fail "round $r: a failed: $(cat "$T/a.out")"
        wait "$b" || fail "round $r: b failed: $(cat "$T/b.out")"
        for t in "$TOOL" min-zz; do
            [ "$(grep -cxF "Include ~/.ssh/$t.conf" "$HOME/.ssh/config")" = 1 ] || fail "round $r: $t Include lost: $(cat "$HOME/.ssh/config")"
        done
        r=$((r + 1))
    done
}

# A session that comes into use while gc's questions are open is not asked about.
case_gc_rechecks_before_each_question() {
    orphan_sessions
    age beta 300
    age gamma 200
    printf '100 1 ssh min-zed.gamma\n101 100 /opt/homebrew/bin/min session exec gamma /usr/sbin/sshd -i\n' > "$FIXTURES/ps.later.txt"
    run_stdin 'y
y
y
' gc
    assert_rc 0
    grep -q gamma "$T/out" || fail "gamma was idle when gc listed: $(cat "$T/out")"
    assert_log_contains "min session destroy beta"
    assert_log_not_contains "min session destroy gamma"
    assert_err_contains "gamma is in use now; not asking"
    ! grep -qF "Destroy Minimal session gamma" "$T/err" || fail "asked about gamma"
}

# A name from min that is no hostname never reaches ssh, the editor or a prompt answer.
case_bad_session_name_refused() {
    installed
    cat > "$FIXTURES/sessions.json" <<JSON
{"sessions":[{"id":"ID-X","name":"x; touch PWN #","project_path":"$AP","status":"active"}]}
JSON
    reset_log
    run attach 'x; touch PWN #'
    assert_rc 1
    assert_err_contains "session name is not lowercase letters, digits and dashes; not using it"
    assert_log_not_contains "session exec"
    assert_log_not_contains "zed ssh://"
    run ssh 'x; touch PWN #' -- true
    assert_rc 1
    assert_log_not_contains "ssh -i"
}

# Safety: the CLI reaches Zed only through $EDITOR_BIN, and the harness
# points it at an absolute stub path.
case_safety_gui_commands_absolute() {
    case $MIN_ZED_EDITOR_BIN in "$T"/*) ;; *) fail "MIN_ZED_EDITOR_BIN is not an absolute stub path" ;; esac
    bare=$(grep -nE '(^|[;&|(]|then|else|do|nohup|exec)[[:space:]]*(zed|code|cursor|windsurf|osascript|open)([[:space:]]|$)' "$BIN" \
        | grep -vE '^[0-9]+:[[:space:]]*#|^[0-9]+:  (open|new|attach) |cmds=\(')
    [ -z "$bare" ] || fail "bare GUI command in the CLI: $bare"
    installed
    sessions_after proj-amber "$P"
    run open "$P"
    assert_log_contains "zed ssh://"
    # the tripwire works: a bare call is logged (and would fail the case)
    sh -c 'open x' 2>/dev/null
    assert_log_contains "tripwire open x"
    grep -v '^tripwire open x$' "$STUB_LOG" > "$T/log.tmp"; cat "$T/log.tmp" > "$STUB_LOG"
    assert_file "$T/tripwire" "open x"
    rm -f "$T/tripwire"
}

# A fresh install (no session has a key dir yet): gc finds nothing to offer
# and exits 0. own_filter's loop must not fail when its glob matches nothing.
case_gc_no_own_sessions_yet() {
    orphan_sessions
    rm -rf "$STATE/sessions"
    run gc --dry-run
    assert_rc 0
    ! grep -q "min ls failed" "$T/err" || fail "gc died: $(cat "$T/err")"
}

CASES="
gc_no_own_sessions_yet open_activates_and_launches_editor open_reuses_live_session_for_path open_skips_foreign_session_for_path
open_needs_ssh_config
open_rejects_non_directory_and_bad_name open_name_for_other_dir new_always_activates
attach_launches_existing attach_picker_rejects_zero open_without_editor_fails_after_prepare open_editor_falls_back_to_app
names_from_min
destroy_asks_and_cleans_up destroy_ls_fails_keeps_keys destroy_ls_fails_once_keeps_stanza destroy_by_cwd destroy_by_cwd_only_own destroy_picker_on_a_terminal in_use_reads_ps gc_lists_oldest_first_and_asks
gc_ls_fails_keeps_keys
gc_offers_only_own_sessions status_tracks_orphans status_table
settings_untouched_before_opt_in settings_follow_sessions settings_take_over_old_opt_in config_zed_config_alias settings_sync_skipped_when_min_ls_fails
config_print_and_bad_option config_and_doctor_keep_entries_when_min_ls_fails
merger_keeps_comments_and_foreign_entries merger_fresh_file_and_noop merger_remove_restores_framing
merger_keeps_hand_tuned_entry merger_keeps_comments_between_entries merger_symlink_written_through
merger_remove_undoes_only_what_we_made merger_bad_input_refused
merger_trailing_entries_round_trip merger_comment_only_list_kept merger_non_utf8_refused
blocks_install_idempotent_remove_exact blocks_content blocks_task_runs_cli_or_says_where blocks_only_from_install
blocks_folder_task_window_folder_else_picker
blocks_refreshed_when_edited blocks_users_entry_in_our_array_kept blocks_refuse_bad_files blocks_marks_only_as_our_comments
doctor_rows doctor_min_version
new_empty_no_window attach_no_window destroy_if_idle destroy_unsaved_needs_force status_json setup_installs_follows_and_removes
setup_remove_stops_when_config_refuses
loadout_rc_line_once loadout_skill_only_for_claude setup_shares_skills_with_other_tools setup_through_link
sshconfig_install_creates_include_and_stanza sshconfig_remove_restores_original
sshconfig_coexists_with_another_tool sshconfig_keeps_symlinked_config sshconfig_print_touches_nothing
sshconfig_destroy_drops_stanza sshconfig_stale_and_invalid_dirs_skipped sshconfig_real_ssh_resolves
sshconfig_forwarding_off_despite_host_star forwarding_off_on_ssh_path sshconfig_paths_with_spaces_and_percent
sshconfig_prefers_local_bin_symlink sshconfig_refuses_double_quote_in_state_dir
sshconfig_write_failure_does_not_block_ssh sshconfig_min_ls_failure_keeps_stanzas
sshconfig_unchanged_conf_not_rewritten sshconfig_remove_deletes_what_it_created sshconfig_backs_up_before_writing
proxy_prepares_then_execs_sshd proxy_never_touches_settings_or_editor proxy_failures
proxy_missing_takes_no_host proxy_log_capped_and_private
proxy_prepare_write_failure prepare_writes_atomically prepare_rejects_bad_facts prepare_accepts_valid_facts
prepare_errors_strip_control_bytes stored_user_checked_on_read proxy_rechecks_stored_paths
prep_extracts_and_prints_facts prep_claude_executable_only_with_claude
prep_waiter_keeps_lock_it_does_not_own prep_breaks_stale_lock prep_concurrent_runs_agree_on_host_key
prep_regenerates_half_pair prep_keygen_failure_releases_lock prep_stale_lock_stress
open_default_loadouts_toml_forms sshconfig_lock_held_waits_then_fails
sshconfig_two_tools_install_at_once gc_rechecks_before_each_question bad_session_name_refused
completions_parse sessions_lists_names usage sshconfig_two_tools_coexist open_keeps_default_loadouts safety_gui_commands_absolute"

# Nothing under ~/.ssh unless the case opted in to ssh-config.
ssh_untouched() {
    case $1 in sshconfig_*|open_*|new_*|attach_*|names_*|destroy_asks*|destroy_ls_fails*|settings_*|config_*|doctor_*|setup_*|blocks_only*|blocks_refreshed*|proxy_never*|prepare_rejects*|prepare_accepts*|stored_user*|safety_*|bad_session*) return 0 ;; esac
    [ ! -e "$T/home/.ssh" ] || fail "HOME/.ssh touched: $(find "$T/home/.ssh" | tr '\n' ' ')"
}

pass=0 failed=0 skipped=0
for c in ${ONLY:-$CASES}; do
    ( setup; CASE=$c; command -v "case_$c" >/dev/null || fail "no function case_$c"; "case_$c"; ssh_untouched "$CASE"
      [ ! -e "$T/tripwire" ] || fail "tripwire: $(cat "$T/tripwire")"
      ! grep -q '^tripwire ' "$STUB_LOG" || fail "bare GUI command: $(grep '^tripwire ' "$STUB_LOG")"; [ ! -e "$T/fail" ] || exit 1; [ ! -e "$T/skip" ] || exit 2 )
    case $? in
        0) echo "ok - $c"; pass=$((pass + 1)) ;;
        2) echo "ok - $c # skip"; skipped=$((skipped + 1)) ;;
        *) echo "not ok - $c"; failed=$((failed + 1)) ;;
    esac
done
echo "# ${LONG_PREFIX:+long prefix: }$pass passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
