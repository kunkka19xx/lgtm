# `lgtm` - Implementation plan

**Derived from:** SPEC.md, ARCHITECTURE.md, PERFORMANCE.md, FEATURES.md, SNAPSHOTS.md, NOTIFICATIONS.md
**Status:** draft v0.1

Phases are ordered by the dependency graph (ARCHITECTURE.md §10), not the roadmap. Each phase has an exit gate; do not start the next phase until the gate passes. T0 performance items (PERFORMANCE.md) are built inside the phase that owns them, never retrofitted.

---

## Phase 0: Scaffold and instrumentation - DONE

No product code until the skeleton builds, tests, and measures.

- [x] `.zigversion` (0.16.0), `build.zig`, `build.zig.zon` with `minimum_zig_version` and libvaxis pinned to a **main-branch commit hash**, not a release tag (ARCHITECTURE.md 5c). Pinned: `c060d31`, resolving to `vaxis-0.6.0`
- [x] `zig build` produces a binary; `zig build test` runs 16 tests across every module
- [x] Baseline measured with vaxis linked (see table below)
- [x] `src/io/fs.zig` + `src/io/proc.zig`: the only files touching filesystem and process APIs. fs: whole-file read in one call. proc: run argv, capture stdout
- [x] `src/io/tty.zig`: owns the terminal handle and the buffered writer handed to `vx.render()`. Wraps `vaxis.tty.Tty` rather than reimplementing raw mode. Writer construction never happens in `ui/` (ARCHITECTURE.md 5c)
- [x] `src/io/metrics.zig` + `--profile`: comptime-gated spans, report on exit, budget violations flagged `OVER` (PERFORMANCE.md 0)
- [x] `src/text/edit.zig`: `Position`, `Range`, `TextEdit`, all byte offsets
- [x] `src/text/buffer.zig`: line-array `Buffer` over owned bytes; read-only; `apply()` returns `error.NotImplemented` (ARCHITECTURE.md 11.1)
- [x] Full `Mode` enum (six variants, three reachable) and `Event` union; one mutex+condvar `Queue` (ARCHITECTURE.md 11.4)
- [x] SPDX header on every source file
- [x] **Walking skeleton** `src/ui/smoke.zig`, run with `lgtm --smoke`: enters the alt screen, renders a sample diff plus an 80-column ruler, holds, restores the terminal. Delete when `ui/view/diff.zig` lands
- [x] SPDX header enforced automatically: `tools/check_spdx.zig`, run by `zig build spdx` and `zig build check`

### Measured baseline

ReleaseFast, macOS arm64, with vaxis, zigimg and uucode linked:

| Metric | Budget | Measured |
|---|---|---|
| Binary size | under 1 MB (reference: zide) | 653 KB |
| Peak RSS | 40 MB | 1.6 MB |
| Cold start (warm cache) | 50 ms | under 10 ms |
| Frame render, 80x24 | 8 ms | 0.29 ms (render alone 0.21 ms) |

The `zigimg` question from ARCHITECTURE.md 5c is answered: it is fetched and compiled, but dead-code elimination keeps it out of the binary. 653 KB and 1.6 MB RSS leave ample headroom. No action needed; recheck if binary size ever approaches 1 MB.

**Gate:** `zig build` and `zig build test` pass; `--profile` prints.

## Phase 1: Anchor harness (the go/no-go gate)

Standalone, no terminal. This decides whether review notes are viable (docs estimate ~300 lines).

- [x] Line interner: `Wyhash` string to `u32` id (PERFORMANCE.md §1.1)
- [x] Window hashing: k=5 lines of interned ids, never single lines (PERFORMANCE.md §2.2)
- [x] In-process line diff over interned ids with common prefix/suffix trimming (PERFORMANCE.md §1.2, §1.3). Implemented as **patience**: anchor on lines unique to both sides, take the longest increasing subsequence, recurse between anchors. Chosen over histogram because it anchors on distinctive lines, which is what places a note correctly when a line has been duplicated
- [x] Primary re-anchor path: table lookup through the line map, O(1) per note (PERFORMANCE.md §3.1)
- [x] Fallback tiers 1, 2, 3 and 6: exact window hash within ±50 lines, exact window hash anywhere via a sorted index, whitespace-normalised hash, then `stale`. Indexes are built **lazily**, only when the line map misses, so a re-diff where every note maps costs nothing extra (PERFORMANCE.md §0). No edit distance, ever (§3.3)
- [ ] Tier 5 (`hunk_hash` fallback) deferred: it needs the hunk model from phase 2. Wire it in once `core/hunk.zig` exists
- [ ] Tier 4 (token-multiset similarity) not built. Nothing in the fixture set reaches it: tiers 1-3 resolve everything that is resolvable, and the remaining case is genuinely gone. Build it when a fixture demands it, not before
- [x] Harness (`zig build anchor`, `src/harness/anchor_harness.zig`): replays fixtures, reports hit rate and timing, exits non-zero below the gate so CI can use it. Validates on load that every expected line matches the v0 anchor content ignoring leading whitespace, and rejects weak anchors
- [x] Fixture format defined and seven mechanical fixtures written (`tests/fixtures/README.md`): whole-file `vN.txt` snapshots plus a `notes.txt` of expected lines per version. Snapshots rather than stored diffs, because the primary path (PERFORMANCE.md §3.1) needs both worktree states to build the line map
- [x] One recorded real agent session: `tests/fixtures/real-session-1`, 6 versions and 3 notes, captured with `tools/record-session.sh` from Claude Code editing a copy of `src/text/buffer.zig`. More sessions from other agents and larger files are still welcome, but the gate is no longer blocked on one

**Gate: PASSED.** ReleaseFast, all eight fixtures:

| Metric | Gate | Measured |
|---|---|---|
| Hit rate | >= ~90% | **100%** (24/24) |
| Re-anchor, 50 notes | <= 5 ms | **0.117 ms**, including lazy index construction |

Resolved by: `mapped` 22, `normalised_hash` 1, `stale` 1. The harness prints
this breakdown every run, which is what keeps the unbuilt tiers honest: tier 4
stays unwritten because nothing has reached it.

Only 4 hash indexes were built across the entire run, because 22 of the 24
notes never left the primary path. The 0.117 ms figure includes that
construction; an earlier 0.003 ms measurement excluded it and was misleading.

Two caveats. The sample is small (24 expectations), so 100% means "nothing here
is broken", not "solved"; recheck as fixtures accumulate, and expect the number
to fall when harder sessions arrive. And `real-session-1` is one agent on one
Zig file, so the drift patterns are narrower than production will be.

`zig build anchor` exits non-zero below the gate, so it can gate CI. Verified by
corrupting a fixture expectation and confirming the failure.

## Phase 2: Diff domain model - PARTIAL

`core/diff.zig` + `core/hunk.zig` + `core/git.zig`, still headless.

- [x] One batched `git diff HEAD -- <paths>` subprocess, never per-file (PERFORMANCE.md §8.1); parse unified output. `--no-color --no-ext-diff` so user config cannot change what we parse
- [x] **Untracked files are synthesised as all-addition diffs, always in full.** `git diff HEAD` does not see them, and a new file is one of the most common things an agent produces, so without this they were silently absent from the review. Found by pointing `zig build diff` at this repo and noticing six new files missing. New files are never summarised at any size (SPEC.md open question 2, now answered)
- [x] `DiffLines` struct-of-arrays: `kind`, `old_no`, `new_no`, `text` (PERFORMANCE.md §7.3)
- [x] `hunk_hash` over added and removed lines only, never context: including context would churn a hunk's identity whenever unrelated neighbouring code moved
- [x] Change-id assignment and inheritance: exact hash match, then greedy maximum overlap of new-file ranges; merge keeps the lower id and records an alias so "fix #4" still resolves; split leaves the id on the larger fragment (SPEC.md §6.5, PERFORMANCE.md §4)
- [x] Files over `large_file_lines` defer their render, and `materialise()` parses the deferred section on demand from the retained byte range. **Deferring is not discarding**: an earlier version dropped the content outright, which would have made oversized files unreviewable rather than merely slower to open
- [x] Blob hashes captured from git's `index a..b` line, ready to key the cache on
- [x] **HEAD and worktree content in `Buffer`s, with the diff as an overlay (ARCHITECTURE.md §11.1).** `core/source.zig` loads HEAD blobs through a single `git cat-file --batch` and worktree files directly, then `attach()` repoints every line's text into the buffers. Rendering now reads from buffers, not from git's diff output
- [ ] `diff_cache` LRU keyed on the blob-hash pair (PERFORMANCE.md §7.2). Still deferred: the watcher now exists, but nothing yet wires watch events to re-diffs, so there is no loop to profile. Revisit in phase 5 once the main loop runs. Blob hashes are already captured

**Gate: met.** Recorded real `git diff` output (`tests/fixtures/diffs/mixed.diff`,
covering add, rename, modify, binary, delete and a git-merged multi-change hunk)
parses with `git diff --numstat` as the oracle, and change-id stability tests
cover merge, split, drift and fresh ids. 57 tests pass.

Three things fell out of the buffer model that were not the stated goal:

- **`attach()` verifies as it goes.** Every line must match the buffer it should
  have come from, so a mismatch means the file changed between git running and
  the read: the torn-read hazard of watching a tree an agent is writing to
  (SPEC.md §9). It is reported rather than rendered as a blend of two states,
  and the caller can re-diff.
- **It is a parser cross-check.** All files in this repo and the scratch repo
  attach cleanly, which means the parser's text agrees with the file contents
  byte for byte across add, delete, rename, binary and modify.
- **Expanding context is now possible at all.** Git emits three lines either
  side; the buffers hold the whole file.

`io/proc.zig` gained `runWithInput` for the batched `cat-file`, which is also
what any future batched git call will need.

`zig build diff -- [repo]` dumps the parsed diff of any repository, which is how
the untracked-file gap surfaced.

## Phase 3: File watching - DONE

`io/watch.zig`, polling only. Native backends are v0.2 behind the same interface.

- [x] Watch thread: 500 ms poll driven by one `git status --porcelain --untracked-files=all` subprocess, not a tree walk (PERFORMANCE.md §8.1)
- [x] **Plus a stat per candidate path, which the docs did not anticipate.** `git status` prints an identical line when an already-modified file is modified again, so status alone cannot see a second edit to the same file. The stat (size and mtime) is what catches it. N is small because it only covers paths git already flagged
- [x] 200 ms debounce and burst coalescing inside the watch thread; the main loop only ever sees one `files_changed` per settled burst (ARCHITECTURE.md §3)
- [x] Deletions and reverts are changes too: a path that vanishes since the last poll is reported
- [x] Torn-write guard behind `require_stable`: signature must be identical on two consecutive polls before emitting (SPEC.md §9)
- [x] `Poller` takes the clock as a parameter, so debounce and coalescing are asserted deterministically instead of slept through. `Watcher` wraps it with the thread and queue

**Gate: PASSED.** A scripted burst produces exactly one event after settling,
asserted in a unit test against a real scratch repo with an injected clock, and
confirmed live: `zig build watch` against a simulated agent writing three files
at once emitted a single 3-path batch, then a single 1-path batch for a later
edit to one of them.

```
[+2500ms] batch 1: 3 path(s)   a.txt b.txt c.txt
[+5500ms] batch 2: 1 path(s)   a.txt
```

73 tests pass. `zig build watch -- [repo] [seconds]` runs the real thread and
prints batches as they arrive, which is how the thread path is exercised without
a timing-dependent test in CI.

## Phase 4: Lexer - DONE

`syntax/`, pure function from bytes to token runs.

- [x] `LangDef` comptime struct; generic engine: line comments, block comments (nested where the language nests them), strings with escapes, raw strings with a `#` count, line-scoped strings for Zig's `\\`, keywords, type names, `fn_decl` markers
- [x] Token runs `{start: u32, len: u16, kind: u8}`, never per-character styles (PERFORMANCE.md 6.4). Two invariants the renderer leans on, asserted by most tests rather than once: runs **tile** the scanned span with no gaps or overlaps, and a run holds at most one `\n`, only as its final byte. Phase 5 therefore groups runs into rows by walking forward, with nothing to reconcile and no fallback to the raw bytes
- [x] Brace-depth scan for the enclosing function name (feeds hunk headers). Spans nest, and a sibling declaration closes the previous one, so a bodyless `fn foo(&self);` in a trait does not adopt every method after it
- [x] Checkpoints every 64 lines `{brace_depth, lex_state}`; lex any region from the nearest checkpoint. The property test is the one that matters: lexing from **every** checkpoint reproduces the tail of the whole-file run list exactly, so a stored state that was subtly wrong cannot pass
- [x] `lang/zig.zig` first, then `rust.zig`, `go.zig`, `python.zig`; everything else renders plain without crashing
- [x] `Highlighter` union `{lexer, tree_sitter, plain}` with `tree_sitter` unimplemented (ARCHITECTURE.md 5). `.plain` emits one `.text` run per line rather than nothing, so callers have no special case
- [x] Guard rails: over 500 KB or 10k lines falls to plain; LRU cache of ~32 files keyed by content hash
- [ ] Checkpoint invalidation from the first changed line: **not built, with evidence.** The whole-file pass costs 0.5 ms over a 6.4k-line corpus against a 100 ms re-diff budget, so a partial rebuild would save half a millisecond and cost a second code path that can disagree with the first. PERFORMANCE.md 6.2 makes the *data structure* T0 and that is what shipped; the incremental rebuild waits for a profile that wants it
- [ ] "Lex the visible range plus a margin": the API takes `(from, to, state)` and the benchmark measures it at 4.5 us per 50-line screen, but nothing calls it that way until the renderer exists. Phase 5 owes the caller, not phase 4

**Zig first rather than Rust.** The plan said Rust first. Every fixture, every recorded session and every file in this repository is Zig, so a Rust-first order would have meant testing the first language against no real code. Rust, Go and Python all landed in the same phase anyway, and all four are exercised against real files through `zig build lex`.

**Gate: PASSED.** Fragment tests cover unbalanced braces, truncated functions, unterminated strings and unclosed block comments; enclosing-function names are correct on Zig, Rust, Go and Python fixtures and on real files from four repositories. 34 tests in `syntax/`, 105 in total.

Two harnesses, matching the pattern of earlier phases:

- `zig build lex -- <file> [line]` prints the colourised token stream, the function spans and the timings for one file. This is how a language definition is found to be wrong about real code rather than only about its fixtures.
- `zig build bench -- [dir] [ext]` is the phase's instrument. It measures four things separately because they have different budgets: the whole-file structure pass (per changed file per re-diff), the full lex (the pathological render), one 50-line screen from the nearest checkpoint (what a frame actually draws), and a cache hit.

### Measured, and what the measurement changed

ReleaseFast, 27 Zig files under `src/`, 6453 lines, 227 KB.

| | first working version | after the optimisation pass |
|---|---|---|
| Structure pass | 148 ns/line | **77 ns/line** (0.50 ms for the corpus) |
| Full lex | 208 MB/s | **378 MB/s** (0.57 ms for the corpus) |
| One 50-line screen | 7.0 us | **4.5 us** |
| Cache hit | 5149 ns | **20 ns** |

Nothing here was optimised on a hunch; the benchmark was written first and each change was kept only because it moved a number.

- **The cache hit was the worst result and the easiest fix.** Hashing the file on every lookup made a hit cost 5.1 us, the same order as the 0.9 ms miss it existed to avoid. The key is now supplied by the caller, which is what the blob hashes captured in phase 2 were for.
- **A comptime byte table in front of the opener ladder** was the largest scanning win. Every byte used to be tested against every comment and string opener in the language; now one table lookup answers "could anything start here" and ordinary identifiers and operators skip the ladder entirely.
- **Vectorised inner scans** (PERFORMANCE.md 6.3): `indexOfScalarPos` to the end of a line comment, `indexOfAnyPos` to the next byte that could matter inside a block comment or a string literal. Comment-heavy source spends real time in exactly those loops.
- **Keyword lookup was 20% of total scan time**, measured by deleting it: 0.542 ms fell to 0.435 ms. That is the evidence PERFORMANCE.md 6.1's T1 item was waiting for. A two-mask comptime prefilter on (first byte, length) and (last byte, length) recovered about half of it. A hand-rolled perfect hash could take the rest and is still not worth the code: the remainder is 12% of half a millisecond.

**ARCHITECTURE.md open question 5 is answered: the enclosing-function scan runs over the whole file, eagerly, per changed file.** The docs deferred this until a 5k-line file had been measured. Measured: 0.5 ms for 6.4k lines, against a 100 ms re-diff budget and an 8 ms frame budget. There is no case for restricting the scan to the visible range, and doing so would cost the correct brace depth that the scan exists to produce.

One caveat. Every number above is Zig source measured on Zig-heavy input. Rust, Go and Python are correct on real files but were not the corpus, and Python in particular does more work per line, since indentation is inspected at every line start. Re-run `zig build bench -- <dir> <ext>` before trusting the figures for another language.

## Phase 5: TUI

`ui/` with libvaxis. First phase that needs a terminal. Test at 80 columns from day one.

- [ ] Main loop: drain event queue, re-diff only changed paths, inherit change ids, re-anchor (order fixed by ARCHITECTURE.md §3), render. Diff arena resets per re-diff, frame arena per render (ARCHITECTURE.md §4)
- [ ] Rendering via the libvaxis **low-level API only** (`Window.writeCell`, `child()` for sub-regions). Do not import `vxfw` (ARCHITECTURE.md §5c)
- [ ] Output through the `io/tty.zig` buffered writer passed into `vx.render()`: one flush per frame (PERFORMANCE.md §7.4)
- [ ] Per-frame regeneration must be cheap: `lex_cache` and `layout_cache` (PERFORMANCE.md §7.2) and lazy layout for visible rows plus margin (§7.5) are required, not optional. Vaxis's internal cell diff handles terminal output; app-side regeneration cost is ours
- [ ] Start by over-drawing the visible region each frame and letting the vaxis diff absorb it. Vaxis does not clear its cell buffer between frames, so row-level dirty tracking is available as a later option - do not build it until `--profile` shows the caches are insufficient (ARCHITECTURE.md §5c)
- [ ] Use `Window.gwidth()` for display width; never assume one byte or one codepoint equals one column
- [ ] Generated row text (line numbers, gutters, expanded tabs) is allocated from the frame arena, and that arena resets **after** render and flush. Vaxis cells reference the text rather than copying it, so a slice that dies early renders as plausible garbage rather than crashing (ARCHITECTURE.md §5c)
- [ ] File list on top (collapsible) + unified diff below; `Tab` toggles full-screen diff
- [ ] Hunk headers: `@@ #<id> <enclosing fn> @@`
- [ ] Every action is a named command; keymap maps key sequences to command names; zero hardcoded keys in dispatch (FEATURES.md §4.3)
- [ ] Motions: `h j k l`, `Ctrl-d/u`, `gg G`, `{ }`, `]h [h`, `]f [f`, `V`, `zz`, `e` opens `$EDITOR`, `q` and `:q`; in-diff search `/ n N` (`?` belongs to help, FEATURES.md §4.4)
- [ ] `?` context-aware help popup from the first keybinding; shows actual bindings; `F1` and `g?` alias
- [ ] `theme.zig` + bundled themes (Catppuccin, Tokyo Night, Gruvbox, Dracula, Rosé Pine, Kanagawa)
- [ ] `config.zig`: TOML; never fail to start; report file, line, key; fall back per key only (FEATURES.md §4.9). Minimal v0.1 keys only
- [ ] SIGWINCH re-layout preserves cursor and scroll (unified only in v0.1)
- [ ] Lazy init: cold start touches config, terminal setup, one git diff and nothing else (PERFORMANCE.md §8.4)

**Gate:** flawless at 80 columns in a split tmux pane; `--profile` shows keystroke-to-frame <= 8 ms, cold start <= 50 ms, re-diff <= 100 ms.

## Phase 6: Bridge

`bridge/`, tmux + OSC 52 only in v0.1.

- [ ] `bridge.zig` tagged union; invariants enforced here, not per backend: reject any payload containing `\n` (runtime assert), trailing space, no carriage return (ARCHITECTURE.md §6)
- [ ] `detect()` from env vars, infallible, falls back to `osc52`; backend failure degrades to OSC 52 with a status-line notice, never fatal
- [ ] `osc52.zig` (works over SSH): evaluate reusing libvaxis's existing OSC 52 implementation before hand-rolling escape sequences (ARCHITECTURE.md §5c). If reused, the no-`\n` assert still lives in `bridge.zig`, above it
- [ ] `tmux.zig` via `send-keys -t <pane_id>`
- [ ] Target pane: detect `$TMUX`, minimal selection (flag or simple prompt), persist to `.lgtm/`; dead pane gives a clear error. Full picker UI polish lands v0.2
- [ ] `Enter` sends a reference from the internal template table (`#{change_id} {path}:{line}`); `V` range sends `:start-end`; references always resolve against the new file; on a deleted line send the enclosing hunk reference plus a short note (SPEC.md §6.3)
- [ ] `y` copies the reference, `Y` copies reference plus line contents
- [ ] Every outgoing string goes through the template table from day one (user-configurable `[templates]` is v0.2)
- [ ] Stretch: ask presets `a ! t x` (FEATURES.md §2.1, trivial once the bridge exists)

**Gate:** cursor on line, `Enter`, text appears in the agent pane with a trailing space and is never submitted; outside tmux the same flow lands on the clipboard via OSC 52.

---

## v0.1 release gate

All phase gates green, plus the success test: the author uses `lgtm` for a week without falling back to `git diff`. Publish the `--profile` numbers.

## v0.2 outline (useful to other people)

Order within v0.2 follows the same logic: core before UI. Two documents were
added after the original outline and are folded in here - `SNAPSHOTS.md` and
`NOTIFICATIONS.md`. Neither belongs before phase 5: both are gated on code that
does not exist yet, and nothing can be dogfooded until the TUI does.

1. Review notes: `core/notes.zig` (jsonl store, owned bytes, session allocator), note lifecycle open/sent/stale (ARCHITECTURE.md §8), `c` / `Ctrl-e` / `C` / `dc` / `]c [c`, gutter markers, `core/review.zig` renders `review-N.md`, `Ctrl-s` writes the file and sends exactly one line
2. **Snapshot store** (SNAPSHOTS.md §3-4): `snapshot/gitobj.zig` + `snapshot/snapshot.zig`. Git plumbing into `refs/lgtm/**` through an isolated `GIT_INDEX_FILE`, one snapshot per agent turn, pruning by ref deletion. No UI. Ordered this early because item 8 depends on it and because it makes the anchor fast path survive a restart (SNAPSHOTS.md §5.2), which nothing else can. Two constraints the doc should carry before anyone writes code:
   - **Gate on the watcher's `require_stable` signal.** Hashing a file the agent is mid-write on stores a corrupt turn under a ref that claims to be good. The diff path catches this with `attach()` returning `ContentMismatch`; the snapshot path has no equivalent, so it must not start until the signature has been identical on two consecutive polls (phase 3)
   - **`.gitignore` is honoured by the path list, not by `update-index`.** `git update-index --add` is plumbing and will happily add `node_modules`. What makes hard boundary 5 true is that paths come from `git status --porcelain --untracked-files=all`, which is already ignore-clean. Any future caller sourcing paths differently breaks a safety property silently
   - Also: prime `.lgtm/index` with `read-tree HEAD` rather than a full `add -A`. `write-tree` against an empty index emits a tree containing only the changed paths
3. Native filesystem watching behind the same `watch.zig` interface
4. Three-scope finder: SQLite reader for the `look` index (first C dependency, `schema_version` check, degrade with a message), fzf-style scoring, incremental narrowing (T0), bitmask prefilter, parallel top-k
5. Bridges: WezTerm, kitty (with `allow_remote_control` hint); pane picker UI + `Ctrl-t`
6. **Notifications, layers 1-2** (NOTIFICATIONS.md §2-4): the bell, the tmux user option, the `lgtm notify` subcommand, and quiescence detection as a second longer timer on the watcher's existing clock. Ordered after item 5 because `notify/` reads backend detection and pane addressing from `bridge/` rather than duplicating it, and `bridge/` does not exist until phase 6. One correction the doc needs: the `lgtm notify` state file **cannot** be picked up "through the existing watcher", because that watcher polls `git status` and `.lgtm/` is now ignored. It needs its own `fs.statFile` poll of one known path
7. Config surface: keymap remapping with presets (vim/helix/emacs/plain), user `[templates]`, per-repo `.lgtm/config.toml` merged over the global file
8. Turn checkpoints (`m` / `a`, delta-since-mark view): same machinery as anchoring, and durable once item 2 exists - the mark is a ref name in `.lgtm/state.json` rather than an in-memory marker, and it is the same state the pending badge reads, not a second copy of it (SNAPSHOTS.md §5.1, NOTIFICATIONS.md §4 rule 3)
9. Weakened-test detection banner (needs the lexer)

## v0.3 outline (finished)

- Side-by-side layout with responsive fallback below `split_min_width`; re-layout preserves cursor and scroll
- Stage/unstage hunks (`s`/`u`) and revert-a-hunk, both as `TextEdit` through `Buffer.apply()`
- Risk-ordered hunks with configurable rules; session history; Zellij (degraded, OSC 52 default)
- Custom TOML themes + live reload + `--theme-preview`; more lexers, or tree-sitter if language demand justifies it
- Turn timeline (`[t` / `]t`) and restore (`R`, `lgtm restore <path> --turn N`), both on the v0.2 snapshot store (SNAPSHOTS.md §5.3-5.4). Comparing any two turns is diff-of-diff with no extra machinery. Restore is the most dangerous action in the tool and gets the most friction: snapshot first, always show a confirmation diff, never restore more than was selected
- Desktop notifications, layer 3 (NOTIFICATIONS.md §2): opt-in, and it stays opt-in because it needs tmux `allow-passthrough` and silently no-ops without it

## Pre-1.0

- Git pager mode: stdin diff parsing, agent features absent (FEATURES.md §3)
- Docs, prebuilt binaries (macOS/Linux; Windows is an open question), README with GIF and measured numbers

---

## Cross-cutting rules (every phase)

The hard rules in CLAUDE.md apply to every line written. The ones easiest to violate accidentally while implementing:

| Rule | Where it bites |
| --- | --- |
| Byte offsets everywhere | Phases 1, 2, 4; UTF-16 exists only in a future `lsp/position.zig` |
| Notes own their bytes, never arena pointers | Phase 2 onward; v0.2 notes |
| `core/` imports no `ui/`/`bridge/`/terminal | Phases 1, 2 |
| Only `io/fs.zig`/`io/proc.zig` import `std.fs`/`std.process` | Every phase |
| `std.Io.Writer` construction stays in `io/tty.zig`; `ui/` receives it | Phases 0, 5 |
| No `\n` through the bridge, no Enter, trailing space | Phase 6 |
| `Wyhash` only, never cryptographic | Phases 1, 2, 4 |
| Instrument before optimising | T1/T2 items wait for `--profile` evidence |

## Open questions mapped to phases

Raise these when the phase touches them; do not silently pick an answer.

| Question (source) | Surfaces in |
| --- | --- |
| New files: full contents or summary (SPEC OQ2) | Phase 2 |
| jj support (SPEC OQ1), multi-repo/worktrees (OQ3) | Phase 2 |
| ~~Where the enclosing-function scan runs (ARCH OQ5)~~ | **Answered in phase 4:** whole file, eagerly, per changed file. 0.5 ms for 6.4k lines |
| Reviewed-hunks persistence (SPEC OQ4), auto-`addressed` (OQ5), note categories (OQ6) | v0.2 notes |
| Windows target (ARCH OQ4) | Pre-1.0 |
