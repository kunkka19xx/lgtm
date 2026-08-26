# `lgtm` - Performance

**Companion docs:** SPEC.md, ARCHITECTURE.md
**Status:** draft v0.1

---

## 0. The framing

The largest speed wins in this program are not algorithmic. They come from **not doing the work at all** - content-hash caching, incremental narrowing, damage tracking. A cache hit beats any O(n log n).

So this document is ordered by expected payoff, not by how interesting the algorithm is. Tiers:

- **T0** - build it this way from the start. Cheap now, expensive to retrofit.
- **T1** - build when the subsystem is built. Clearly worth it.
- **T2** - only after a measurement says so.
- **T3** - probably never, documented so it stops being tempting.

### Budget

Everything below exists to protect these numbers.

| Operation | Budget | Frequency |
|---|---|---|
| Cold start to first frame | 50 ms | once |
| Keystroke to rendered frame | 8 ms | constant |
| Re-diff after an agent write | 100 ms | every few seconds |
| Finder keystroke, 500k paths | 30 ms | bursty |
| Note re-anchor, 50 notes | 5 ms | every re-diff |

### Instrumentation first (T0)

```zig
// io/metrics.zig - compiled out in ReleaseFast unless -Dprofile
pub inline fn span(comptime name: []const u8) Span { ... }
```

Timed spans around: git subprocess, diff parse, re-anchor, lex, layout, terminal flush. A `--profile` flag dumps a histogram on exit. Twenty lines. Without this, every decision below is guesswork.

---

## 1. Diff computation

### 1.1 Line interning (T0)

Before any diff algorithm runs, map each distinct line to a `u32` id via a hash table. The diff then operates on `[]u32`, not `[][]const u8`.

Effects: comparisons become integer compares; the working set shrinks by ~8×; equality is exact with no memcmp. Every serious diff implementation does this first, and it is the single highest-leverage decision in the whole diff path.

Hash: `std.hash.Wyhash` (≈GB/s). Never a cryptographic hash - see §2.

### 1.2 Common prefix/suffix trimming (T0)

Strip identical leading and trailing lines before diffing. An agent editing one function in a 2,000-line file leaves a 40-line problem. This is five lines of code and routinely reduces the input by 95%+.

Do it *after* interning, so it is an integer scan.

### 1.3 Choice of algorithm (T1, only if replacing `git`)

v0.1 shells out to `git diff`. If profiling shows subprocess overhead dominating (likely - see §8), these are the candidates:

| Algorithm | Complexity | Notes |
|---|---|---|
| **Histogram** | ~O(n log n) typical | git's `--histogram`. Fast in practice and produces better hunk boundaries than Myers - fewer spurious splits, which directly improves change-id stability (§3). **Recommended.** |
| Myers O(ND) | O((N+D)·D) | The classic. Degrades badly when D is large. |
| Patience | O(n log n) + recursion | Anchors on unique lines. Nice output, slower than histogram. |
| Hunt–Szymanski | O((r + n) log n) | Good when matches are sparse. Rarely worth the complexity here. |

Histogram is the right pick specifically because hunk-boundary quality is not cosmetic for `lgtm` - it feeds change-id inheritance.

**Bounded search:** cap the edit-graph exploration (git's `MAX_COST` heuristic) and fall back to a coarse "replace this whole region" result. A pathological file must degrade, never hang.

### 1.4 Per-file parallelism (T1)

Diffing is embarrassingly parallel across files. A thread pool sized to `cpu_count - 1`, one file per task. The agent touching six files becomes one file of latency.

Guard: files under ~200 lines are not worth a task. Batch them.

---

## 2. Hashing

### 2.1 Which function (T0)

`std.hash.Wyhash` for everything internal: line interning, content hashes, cache keys, anchor hashes.

Not SHA/BLAKE - an order of magnitude slower for zero benefit. There is no adversary here. Collision risk at 64 bits over a few thousand lines is negligible; if a collision ever mattered, a re-anchor would land wrong by one line, not corrupt anything.

### 2.2 Window hashing for anchors (T0)

**Do not hash single lines.** Real source is full of duplicates - `}`, blank lines, `    return nil`. A single-line hash collides constantly and re-anchoring lands in the wrong place.

Hash a **window of k lines** (k = 5, centred on the anchor) as one unit. Duplicate windows are rare; duplicate lines are the norm. This one choice probably does more for re-anchor accuracy than any search strategy.

Store the interned ids, not the text: `hash(ids[i-2..i+3])`.

### 2.3 Rolling hash (T2)

Rabin–Karp or buzhash makes "find this window anywhere in the file" O(n) instead of O(n·k). Only relevant if the tiered lookup in §3 falls through often enough to matter. Measure first.

---

## 3. Re-anchoring - the hot algorithm

This is the one that decides whether the review-notes feature works at all. It deserves the most thought.

### 3.1 The key realisation: the diff already contains the answer (T0)

The naive design searches for each note's anchor in the new file. That is backwards. **You are re-diffing anyway, and a diff is precisely a line correspondence.**

Diff *previous working tree* against *new working tree* - not just against HEAD - and you get an exact `old_line → new_line` map. Every note migrates by table lookup, O(1) each, with no searching and no heuristics.

```
prev_worktree ──diff──> new_worktree   ⇒  line map
notes.range = map[notes.range]              O(1) per note
```

Cost: keep the previous working-tree content in memory (the buffers from §11 of ARCHITECTURE.md, which you have anyway). Search-based anchoring becomes a *fallback* for the cases where the chain breaks - first run, external edits, `git checkout`, a formatter pass, a file you were not watching.

This turns re-anchoring from a fuzzy-matching problem into a bookkeeping problem for the common case. It is the most important idea in this document.

### 3.2 Fallback: tiered lookup (T0)

When the chain is broken, degrade through progressively looser and more expensive tiers, stopping at the first hit:

| Tier | Method | Cost |
|---|---|---|
| 1 | Exact window hash, ±50 lines | O(100) |
| 2 | Exact window hash, whole file, via prebuilt index | O(1) |
| 3 | Whitespace/indent-normalised window hash | O(1) |
| 4 | Token-multiset similarity vs candidates sharing ≥1 line hash | O(candidates) |
| 5 | `hunk_hash` → anchor to the hunk | O(1) |
| 6 | `stale` | - |

**Tier 2 needs a prebuilt index:** one pass over the new file building `window_hash → line[]` (a multimap). Built once per re-diff, O(n), then every note lookup is O(1). Building it once for 50 notes beats 50 linear scans by a wide margin.

Tier 3 catches the very common case of a formatter changing indentation.

### 3.3 Never use edit distance (T3)

Levenshtein/Damerau on line content is O(n·m) per comparison and buys almost nothing over tier 4. If tiers 1–5 all miss, the code genuinely changed and the honest answer is `stale`.

---

## 4. Change-id inheritance

Matching old hunks to new hunks is a bipartite assignment problem, but a tiny one - usually under 20 hunks per file.

**Greedy by hash, then by overlap (T1).** Exact `hunk_hash` matches first. Remaining hunks match by maximum line-range overlap under the §3.1 line map, greedily, highest overlap first. Hungarian algorithm would be optimal and is unnecessary at n < 50; greedy is correct in essentially every real case.

Merge and split resolution (SPEC.md §6.5) falls out of the overlap scores directly.

---

## 5. Fuzzy finder

The one place where a genuinely large n exists: the `look` index may hold hundreds of thousands of paths.

### 5.1 Bitmask prefilter (T1) - the big one

For each candidate, precompute a 256-bit ASCII presence mask (4× `u64`, cached in the index). A query's mask is computed once per keystroke. Any candidate whose mask lacks a query bit cannot match - reject with four `AND` operations.

This typically eliminates 90–99% of candidates before any scoring runs, and it vectorises trivially with `@Vector(4, u64)`.

### 5.2 Incremental narrowing (T0)

Typing only ever *narrows* results for a prefix-extended query. Keep the previous result set; when a character is appended, re-score only those survivors. From the second keystroke onward, n collapses from 500k to a few thousand.

Invalidate on backspace or any non-append edit.

### 5.3 Scoring (T1)

fzf-style: Smith–Waterman with affine gap penalties, bonuses for word-boundary, camelCase, and path-separator starts. O(n·m) per candidate but m is tiny and n is post-prefilter.

Two-phase like fzf: a cheap greedy forward scan to reject non-matches, full DP only on survivors.

### 5.4 Parallel scoring (T1)

Chunk the candidate slice across a thread pool, merge top-k per thread with a bounded heap. Never sort the full result set - a `k`-sized max-heap (k = visible rows + margin) is O(n log k).

### 5.5 SIMD (T2)

Only after the above. The prefilter is the natural target; the DP inner loop can be vectorised across candidates but the code cost is high. Zig makes it portable:

```zig
const V = @Vector(4, u64);
const hit = @reduce(.And, (cand_mask & query_mask) == query_mask);
```

Revisit only if a `--profile` run shows finder scoring above 10 ms post-prefilter.

---

## 6. Lexer

### 6.1 Comptime perfect hashing for keywords (T1)

Zig can build a keyword lookup at compile time from the `LangDef` list. Bucket by length first, then a comptime-generated perfect hash - no runtime HashMap, no string comparison chains, no allocation.

### 6.2 Checkpointed incremental lexing (T0 for the data structure)

The enclosing-function scan needs the whole file for brace depth, which conflicts with lexing only the visible range.

Resolution: store a **checkpoint every 64 lines** - `{brace_depth, lex_state}` where `lex_state` is "outside string/comment" or the specific state. Lexing any visible region restarts from the nearest preceding checkpoint, so cost is bounded at 64 lines regardless of file size.

Checkpoints invalidate from the first changed line onward; everything above survives an edit. Store them in the per-file cache alongside token runs.

### 6.3 Delimiter skipping (T2)

Most source is uninteresting runs between quotes, slashes, and newlines. `std.mem.indexOfAny` is already vectorised in Zig's std - use it to jump between interesting bytes rather than stepping character by character. Free performance from the standard library.

### 6.4 Token run encoding (T1)

Emit `{start: u32, len: u16, kind: u8}` runs, not per-character styles. A typical line becomes 5–15 runs. Rendering iterates runs, not characters.

---

## 7. Rendering

### 7.1 Damage tracking (T0)

Never repaint the screen. Keep front and back cell buffers, diff them, and emit escape sequences only for changed cells. libvaxis does this; the job is to not defeat it by regenerating everything each frame.

### 7.2 Cache by content hash, not by path (T0)

The single most valuable cache in the program:

```
lex_cache:    LRU<content_hash, TokenRuns>     ~32 entries
layout_cache: LRU<(content_hash, width), Layout>
diff_cache:   LRU<(blob_a, blob_b), Hunks>
```

The agent writes six files; two actually changed content. The other four cost nothing. Keying on content hash rather than path also makes revert-and-rewrite free, which agents do constantly.

### 7.3 Struct-of-arrays for diff lines (T0)

```zig
const DiffLines = struct {
    kind: []LineKind,      // add/del/ctx
    old_no: []u32,
    new_no: []u32,
    text: [][]const u8,
};
```

Rendering walks `kind` and `new_no` for every visible row and touches `text` only for rows it draws. Array-of-structs drags cold fields through cache on every iteration. Cheap to do now, annoying to convert later.

### 7.4 One syscall per frame (T0)

Accumulate all output into a single arena-backed buffer, one `write()`. Many small writes to a terminal is a classic and easily avoided stall.

### 7.5 Lazy layout (T1)

Compute wrapping and column layout only for visible rows plus a small margin. Never lay out a 5,000-line file to display 40 rows of it.

---

## 8. Process and I/O

### 8.1 The likely #1 cost (T1)

`git diff` as a subprocess costs roughly 5–20 ms in fork + exec + git startup, before it does any work. That is 20–200× the cost of the diff itself on a small change. It will almost certainly top the profile.

Options, in order of preference:

1. **Batch** - one `git diff` for all changed paths, never one per file. (T0 - do this from the start.)
2. **`git status --porcelain=v2` for change detection** in the polling watcher - one subprocess instead of N `stat` calls.
3. **Read blobs directly.** `.git/index` plus loose/packed objects are a documented format. Reading them yourself removes the subprocess entirely but means implementing pack index lookup and zlib inflation. A real project, but a bounded and well-specified one.
4. libgit2 - a middle path, at the cost of the C dependency you just removed.

Option 3 is where "willing to rewrite" pays off most, and it pairs naturally with §1.3: own the object reading *and* the diff algorithm, and the whole path becomes in-process and cacheable.

### 8.2 Whole-file reads (T0)

One `read()` into an arena buffer. No `BufferedReader`, no line-by-line iteration over a file handle. Slice the buffer for lines.

### 8.3 mmap (T3)

Tempting for large files, and wrong here: the agent is actively writing these files, and a truncating write under an active mapping is a `SIGBUS`. Not worth it.

### 8.4 Lazy subsystem init (T0)

SQLite is not opened until the finder is first invoked. Themes are not parsed until first render. Grammars/lang defs load on first use of that language. Cold start should touch: config, terminal setup, one `git diff`.

### 8.5 Overlap startup (T1)

Spawn the initial `git diff` *before* terminal initialisation. Both take milliseconds; running them concurrently makes first paint meaningfully faster on a large repo.

---

## 9. Concurrency

Keep it boring. One render thread, one watcher thread, one thread pool for parallelisable work (per-file diff, per-file lex, finder scoring, hashing).

- Render is single-threaded. Always.
- The pool is a fixed `std.Thread.Pool`, not work-stealing. n is small and tasks are uniform.
- Cross-thread communication is the single `Event` union queue from ARCHITECTURE.md §11.4, mutex + condvar. Lock-free queues are unnecessary at these rates and a source of bugs.

---

## 10. Explicitly rejected

| Idea | Why not |
|---|---|
| SIMD in the lexer | ~0.1 ms of a 8 ms budget. Wrong target. |
| Levenshtein for anchoring | O(n·m) for near-zero benefit over tier 4. |
| Rope data structure | Not until editing exists and line arrays are proven too slow. |
| mmap | `SIGBUS` risk with a concurrently-writing agent. |
| Lock-free queues | Event rates are in the tens per second. |
| Hungarian algorithm for hunk matching | n < 50; greedy is correct in practice. |
| Persistent daemon / index server | Contradicts the "kill it and restart it" property. |
| Bloom filters for path search | The bitmask prefilter (§5.1) already does this job better. |

---

## 11. Suggested order

1. `metrics.zig` and the `--profile` flag. Everything else is guesswork without it.
2. T0 structural choices - line interning, window hashing, SoA diff lines, content-hash caches, damage tracking, one write per frame, incremental narrowing, checkpointed lex state.
3. Measure. Publish the numbers in the README; it is good marketing for a tool whose pitch is speed.
4. T1 items in whatever order the profile ranks them.
5. Revisit §8.1 option 3 only when the profile makes the case for it - but expect it to.
