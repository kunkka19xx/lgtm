#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Capture successive states of a file while an agent edits it, as anchor
# fixture snapshots. See tests/fixtures/README.md for the format.
#
#   tools/record-session.sh <file-to-watch> <output-dir>
#
# Run it in a spare pane, then let the agent work. Ctrl-C to stop.

set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <file-to-watch> <output-dir>" >&2
    exit 2
fi

WATCH=$1
OUTDIR=$2
POLL=0.5

if [ ! -f "$WATCH" ]; then
    echo "record-session: $WATCH does not exist yet; create it first" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
if [ -n "$(ls -A "$OUTDIR" 2>/dev/null)" ]; then
    echo "record-session: $OUTDIR is not empty, refusing to mix recordings" >&2
    exit 1
fi

hash_of() { shasum -a 256 <"$1" | cut -d' ' -f1; }

n=0
cp "$WATCH" "$OUTDIR/v0.txt"
last=$(hash_of "$WATCH")
echo "record-session: v0.txt captured, watching $WATCH (Ctrl-C to stop)"

# Debounce: a state must be identical on two consecutive polls before it is
# recorded. Agents write in bursts and leave files half-written for a few
# milliseconds; without this the recording fills up with torn states.
pending=""
while true; do
    sleep "$POLL"
    [ -f "$WATCH" ] || continue
    cur=$(hash_of "$WATCH")

    [ "$cur" = "$last" ] && { pending=""; continue; }

    if [ "$cur" != "$pending" ]; then
        pending=$cur
        continue
    fi

    n=$((n + 1))
    cp "$WATCH" "$OUTDIR/v$n.txt"
    last=$cur
    pending=""
    echo "record-session: v$n.txt  ($(wc -l <"$OUTDIR/v$n.txt" | tr -d ' ') lines)"
done
