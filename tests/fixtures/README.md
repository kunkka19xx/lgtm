# Anchor fixtures

Ground truth for the `core/anchor.zig` harness (docs/PLAN.md phase 1). The gate
is a re-anchor hit rate of roughly 90% or better; below that, review notes get
redesigned before more code is written.

## Layout

One directory per scenario:

```
<scenario>/
  v0.txt      state of the file when the note was written
  v1.txt      state after the first edit
  v2.txt      optional, and so on
  notes.txt   expectations
```

Versions are whole-file snapshots, not diffs. This is deliberate: the primary
re-anchor path (PERFORMANCE.md 3.1) diffs the previous worktree against the new
one to build an old-to-new line map, so the harness needs both full states. A
stored diff could not exercise that path.

## notes.txt

Blank lines and lines starting with `#` are ignored. Every other line is:

```
<note_id> <line in v0> <line in v1> ...
```

Line numbers are 1-based. There must be exactly one column per `vN.txt` file,
in order, including v0. The literal `stale` means the note must fail to
re-anchor and be surfaced as stale, never silently relocated or dropped
(hard rule 7).

The first column is where the note is placed; the rest are what re-anchoring
must produce. A run is a hit when the computed line equals the expectation, and
`stale` counts as a hit only when the tiers genuinely miss.

## Scenarios

| Directory | Exercises |
|---|---|
| `drift-insert-above` | Pure offset shift, a function inserted above the anchor |
| `in-hunk-drift` | Insertion inside the same hunk, above the anchor |
| `formatter-indent` | Whitespace-only reindent; every exact hash misses, tier 3 must catch it |
| `hunk-merge` | Two edits under 3 context lines apart collapsing into one hunk |
| `hunk-split` | An insertion partly reverted, splitting the original hunk |
| `revert-rewrite` | Change then revert; v2 is byte-identical to v0, so the anchor must return, not drift |
| `anchor-deleted` | The anchored region is rewritten away; every tier misses and the note goes stale |

## Adding fixtures

Two rules, both learned the hard way while writing these:

1. **Never anchor on a weak line.** A `}`, a blank line, or a lone `);` occurs
   many times per file and makes the fixture pass or fail for reasons unrelated
   to what it claims to test. This is the whole reason anchors hash a window of
   k=5 lines rather than one line (PERFORMANCE.md 2.2).
2. **Verify expectations mechanically.** The content at the expected line in
   every version must match the content at the anchor line in v0, ignoring
   leading whitespace. Hand-counted line numbers are wrong often enough that
   the harness should assert this on load and fail loudly rather than quietly
   scoring against a bad expectation.

A recorded real agent session is still wanted alongside these. The seven above
are mechanical and cover known failure modes; a real session covers the ones
nobody thought of.
