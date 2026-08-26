#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Propose a notes.txt row by tracking one anchor line across recorded versions.
#
#   tools/propose-notes.sh <fixture-dir> <1-based line in v0>
#
# Deliberately dumb: it reports an expected line ONLY when the exact line text
# occurs exactly once in that version. Anything else prints AMBIGUOUS or
# MISSING for a human to resolve.
#
# That restraint is the point. The harness under test re-anchors with window
# hashing and a tiered fallback; if this tool used the same reasoning, the
# fixture would agree with the algorithm by construction and the hit rate would
# measure nothing. Exact-unique-match is a deliberately different, weaker rule,
# and the cases it refuses (a reindented line, a deleted region) are exactly the
# ones whose ground truth a human must decide.

set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <fixture-dir> <1-based line in v0>" >&2
    exit 2
fi

DIR=$1
LINE=$2

[ -f "$DIR/v0.txt" ] || { echo "propose-notes: no $DIR/v0.txt" >&2; exit 1; }

ANCHOR=$(sed -n "${LINE}p" "$DIR/v0.txt")
if [ -z "$(printf '%s' "$ANCHOR" | tr -d '[:space:]}')" ]; then
    echo "propose-notes: line $LINE is blank or a bare brace: '$ANCHOR'" >&2
    echo "propose-notes: pick a distinctive line. Weak anchors make a fixture" >&2
    echo "               pass or fail for reasons unrelated to what it tests." >&2
    exit 1
fi

echo "anchor: '$ANCHOR'"
printf 'n1 %s' "$LINE"
row=""
for f in $(ls "$DIR" | grep '^v[0-9]*\.txt$' | sort -t v -k2 -n | tail -n +2); do
    hits=$(grep -Fxn "$ANCHOR" "$DIR/$f" | cut -d: -f1 || true)
    count=$(printf '%s' "$hits" | grep -c . || true)
    if [ "$count" = "1" ]; then
        printf ' %s' "$hits"
    elif [ "$count" = "0" ]; then
        printf ' MISSING'
        row="$row $f=gone"
    else
        printf ' AMBIGUOUS'
        row="$row $f=[$(echo "$hits" | tr '\n' ',')]"
    fi
done
echo
[ -n "$row" ] && {
    echo
    echo "unresolved, decide these by hand:$row"
    echo "  MISSING   -> 'stale' if the region is genuinely gone, else the line it moved to"
    echo "  AMBIGUOUS -> the listed candidates all match exactly; pick the right one"
}
exit 0
