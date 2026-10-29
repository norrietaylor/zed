# min-zed: Minimal sessions as Zed remote projects. Every recipe runs on the HOST.
# `just --list` for the menu.


_default:
    @just --list

# shellcheck, py_compile, and the test suite (normal and long host prefix).
check:
    #!/bin/sh
    set -eu
    shellcheck -s sh bin/min-zed tests/run.sh tests/stubs/*
    python3 -m py_compile bin/min-zed-config
    sh tests/run.sh
    LONG_PREFIX=1 sh tests/run.sh

# Link min-zed into ~/.local/bin, install the `zed` loadout and Minimal's skills, write the ssh stanzas, wire Zed (ssh_connections, tasks, key).
install:
    "$PWD/bin/min-zed" setup

# Minimal's skills for the agents (Zed's, Claude), vendored from gominimal/minimal-skills (MIT) at a pinned commit
# (version 0.7.0): the host ones in skills/ (setup installs them into ~/.agents/skills and ~/.claude/skills on the Mac),
# minimal-sandbox in loadouts/zed/skills/ (the loadout copies it into every box).
skills_commit := "d3ccc13ed4286978e2581a30eb3859dcbed59076"
skills_sha256 := "bea8b245fc5e32de55ca4175dfc46c271c3a9ee8befa5d4c276336fc7a8aa993"

# Re-fetch the vendored skills (after changing skills_commit and skills_sha256).
skills:
    #!/bin/sh
    set -eu
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    curl -fsSL "https://codeload.github.com/gominimal/minimal-skills/tar.gz/{{ skills_commit }}" -o "$t/a.tgz"
    got=$(shasum -a 256 "$t/a.tgz" 2>/dev/null || sha256sum "$t/a.tgz"); got=${got%% *}
    [ "$got" = "{{ skills_sha256 }}" ] || { echo "sha256 mismatch: $got" >&2; exit 1; }
    tar -xzf "$t/a.tgz" -C "$t" --strip-components 1
    rm -rf skills loadouts/zed/skills
    mkdir -p skills loadouts/zed/skills
    for d in "$t"/skills/*/; do
        d=${d%/}; n=$(basename "$d")   # no trailing slash: BSD cp would copy the contents only
        if [ "$n" = minimal-sandbox ]; then cp -R "$d" loadouts/zed/skills/; else cp -R "$d" skills/; fi
    done
    cp "$t/LICENSE" skills/LICENSE
    cp "$t/LICENSE" loadouts/zed/skills/LICENSE
    echo "skills at {{ skills_commit }}: $(ls skills | grep -v LICENSE | tr '\n' ' ')+ minimal-sandbox (box)"

# Write Host min-zed.NAME stanzas to ~/.ssh/min-zed.conf and Include them from the top of ~/.ssh/config.
ssh-config:
    "$PWD/bin/min-zed" ssh-config

# Opt in to the Zed wiring: ssh_connections per session in settings.json, the Minimal tasks in tasks.json, the local-terminal key in keymap.json.
zed-config:
    "$PWD/bin/min-zed" config

# Undo `install`, touching only what is ours: Zed entries and blocks, ssh Include, skill copies, loadout link and copy, CLI link.
uninstall:
    "$PWD/bin/min-zed" setup --remove
