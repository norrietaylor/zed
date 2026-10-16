# min-zed: Minimal sessions as Zed remote projects. Every recipe runs on the HOST.
# `just --list` for the menu.

config := env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") + "/.config") + "/minimal"

_default:
    @just --list

# shellcheck, py_compile, the test suite (kernel hash pin included).
check:
    #!/bin/sh
    set -eu
    shellcheck -s sh bin/min-zed tests/run.sh tests/stubs/*
    python3 -m py_compile bin/min-zed-config
    rm -rf bin/__pycache__
    sh tests/run.sh

# Link min-zed into ~/.local/bin, install the `zed` loadout, write the ssh stanzas, opt in to Zed settings sync.
install: && loadout ssh-config zed-config
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$PWD/bin/min-zed" "$HOME/.local/bin/min-zed"
    @echo "linked $HOME/.local/bin/min-zed -> $PWD/bin/min-zed"

# Link loadouts/zed.toml into the Minimal config as loadout `zed` (default_loadouts is left alone).
loadout:
    #!/bin/sh
    set -eu
    loadouts="{{ config }}/loadouts"
    mkdir -p "$loadouts"
    l="$loadouts/zed.toml"
    if [ -e "$l" ] || [ -L "$l" ]; then
        if [ "$(readlink "$l" 2>/dev/null)" != "$PWD/loadouts/zed.toml" ]; then
            echo "$l exists and is not this repo's; move it aside, then run just loadout again" >&2
            exit 1
        fi
    fi
    ln -sfn "$PWD/loadouts/zed.toml" "$l"
    echo "installed loadout 'zed' -> $l (min-zed activates with --loadout zed)"

# Write Host min-zed.NAME stanzas to ~/.ssh/min-zed.conf and Include them from the top of ~/.ssh/config.
ssh-config:
    "$HOME/.local/bin/min-zed" ssh-config

# Keep Zed's ssh_connections (min-zed.* entries only) in step with live sessions.
zed-config:
    "$HOME/.local/bin/min-zed" zed-config

# Undo `install`: drop the ssh Include and Zed entries, stop the watch, unlink only what points here.
uninstall:
    #!/bin/sh
    set -eu
    b="$HOME/.local/bin/min-zed"
    if [ -x "$b" ]; then
        "$b" ssh-config --remove || true
        "$b" zed-config --remove || true
        "$b" watch --stop || true
    fi
    for l in "{{ config }}/loadouts/zed.toml" "$b"; do
        if [ -L "$l" ]; then
            case "$(readlink "$l")" in
                "$PWD"/*) rm -f "$l"; echo "removed $l" ;;
                *) echo "$l does not point into this repo; leaving it" ;;
            esac
        fi
    done
    echo "left ${XDG_STATE_HOME:-$HOME/.local/state}/min-zed in place: it holds the keys of live sessions"

# Re-pin tests/kernel.sha to the kernel block in bin/min-zed (after copying it from the cmux repo).
kernel-sha:
    #!/bin/sh
    set -eu
    sed -n '/^# --- kernel begin/,/^# --- kernel end ---$/p' bin/min-zed | shasum -a 256 | cut -d' ' -f1 > tests/kernel.sha
    echo "tests/kernel.sha: $(cat tests/kernel.sha)"
