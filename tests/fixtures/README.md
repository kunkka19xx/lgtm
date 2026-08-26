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
| `real-session-1` | Recorded agent session, 6 versions, 3 notes. Includes a duplicate-line case the agent produced on its own |

`real-session-1` is worth reading before writing the harness. The agent added a
helper that copied an existing guard clause verbatim, so
`if (n >= self.lineCount()) return null;` occurs twice from v1 onward, and the
note belongs to the second one. Nothing contrived produced that: it is what
agents do, and it is the single-line-hash failure PERFORMANCE.md 2.2 predicts,
observed in the wild on the first session recorded.

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

## Recording a real agent session

The seven fixtures above are mechanical and cover known failure modes. A real
session covers the ones nobody thought of, so at least one is wanted.

**1. Start the recorder in a spare pane**, pointing at a file you expect the
agent to edit repeatedly:

```sh
tools/record-session.sh src/auth.rs tests/fixtures/real-session-1
```

It captures `v0.txt` immediately, then a new `vN.txt` every time the file
settles on new content. It debounces by requiring the content to be identical
on two consecutive polls, because agents write in bursts and leave files
half-written for a few milliseconds; without that the recording fills with torn
states. It refuses to write into a non-empty directory so recordings never mix.

**2. Let the agent work.** Aim for three to six versions covering more than one
kind of change: an insertion above, an edit inside a function, a rename, ideally
a revert. One edit is not a session. Ctrl-C when done.

**3. Choose an anchor and propose the row:**

```sh
tools/propose-notes.sh tests/fixtures/real-session-1 47
```

Pick a line you would genuinely have commented on, and a distinctive one. The
tool rejects blank lines and bare braces outright.

**4. Resolve what the tool refuses.** It reports an expected line only where the
exact text occurs exactly once, and otherwise prints `MISSING` or `AMBIGUOUS`
for you to decide: `stale` if the region is genuinely gone, otherwise the line
it moved to.

That restraint is deliberate and worth preserving. The harness re-anchors with
window hashing and a tiered fallback; if the proposal tool used the same
reasoning, the fixture would agree with the algorithm by construction and the
hit rate would measure nothing. Exact-unique-match is a deliberately different
and weaker rule, and the cases it refuses are exactly the ones whose ground
truth a human has to supply.

**5. Write `notes.txt`** with the resolved row and a comment saying what the
agent was actually asked to do. That context is what makes the fixture
interpretable a year later.
