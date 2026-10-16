#!/bin/sh
# kernel-sha.sh FILE: sha256 of FILE's kernel block, the lines from
# `# --- kernel begin` to `# --- kernel end ---` inclusive. Fails unless
# FILE has exactly one of each, in that order. Every min-<client> repo pins
# this hash in tests/kernel.sha (just kernel-sha writes it; just check checks it).
set -eu
f=${1:?usage: kernel-sha.sh FILE}
b=$(grep -c '^# --- kernel begin' "$f" || :)
e=$(grep -cx '# --- kernel end ---' "$f" || :)
[ "$b" = 1 ] && [ "$e" = 1 ] || { echo "kernel-sha.sh: $f needs one kernel begin and one end marker (has $b, $e)" >&2; exit 1; }
[ "$(grep -n '^# --- kernel begin' "$f" | cut -d: -f1)" -lt "$(grep -nx '# --- kernel end ---' "$f" | cut -d: -f1)" ] \
    || { echo "kernel-sha.sh: $f has the kernel end marker before its begin" >&2; exit 1; }
sed -n '/^# --- kernel begin/,/^# --- kernel end ---$/p' "$f" | shasum -a 256 | cut -d' ' -f1
