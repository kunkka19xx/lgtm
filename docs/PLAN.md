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

| Metric                  | Budget                       | Measured                       |
| ----------------------- | ---------------------------- | ------------------------------ |
| Binary size             | under 1 MB (reference: zide) | 653 KB                         |
| Peak RSS                | 40 MB                        | 1.6 MB                         |
| Cold start (warm cache) | 50 ms                        | under 10 ms                    |
| Frame render, 80x24     | 8 ms                         | 0.29 ms (render alone 0.21 ms) |

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

| Metric              | Gate    | Measured                                        |
| ------------------- | ------- | ----------------------------------------------- |
| Hit rate            | >= ~90% | **100%** (24/24)                                |
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

## Phase 2: Diff domain model - DONE

`core/diff.zig` + `core/hunk.zig` + `core/git.zig`, still headless.

- [x] One batched `git diff HEAD -- <paths>` subprocess, never per-file (PERFORMANCE.md §8.1); parse unified output. `--no-color --no-ext-diff` so user config cannot change what we parse
- [x] **Untracked files are synthesised as all-addition diffs, always in full.** `git diff HEAD` does not see them, and a new file is one of the most common things an agent produces, so without this they were silently absent from the review. Found by pointing `zig build diff` at this repo and noticing six new files missing. New files are never summarised at any size (SPEC.md open question 2, now answered)
- [x] `DiffLines` struct-of-arrays: `kind`, `old_no`, `new_no`, `text` (PERFORMANCE.md §7.3)
- [x] `hunk_hash` over added and removed lines only, never context: including context would churn a hunk's identity whenever unrelated neighbouring code moved
- [x] Change-id assignment and inheritance: exact hash match, then greedy maximum overlap of new-file ranges; merge keeps the lower id and records an alias so "fix #4" still resolves; split leaves the id on the larger fragment (SPEC.md §6.5, PERFORMANCE.md §4)
- [x] Files over `large_file_lines` defer their render, and `materialise()` parses the deferred section on demand from the retained byte range. **Deferring is not discarding**: an earlier version dropped the content outright, which would have made oversized files unreviewable rather than merely slower to open
- [x] Blob hashes captured from git's `index a..b` line, ready to key the cache on
- [x] **HEAD and worktree content in `Buffer`s, with the diff as an overlay (ARCHITECTURE.md §11.1).** `core/source.zig` loads HEAD blobs through a single `git cat-file --batch` and worktree files directly, then `attach()` repoints every line's text into the buffers. Rendering now reads from buffers, not from git's diff output
- [x] `diff_cache` LRU keyed on the blob-hash pair (PERFORMANCE.md §7.2): **measured and rejected**, not deferred a third time. §7.2 specifies `LRU<(blob_a, blob_b), Hunks>`, so what it saves is the production of hunks, and hunks are not where the time goes. Blob hashes stay captured: the key is free and v0.2 item 8 wants them anyway. Numbers under phase 5 below

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
- [ ] Checkpoint invalidation from the first changed line: **not built, with evidence.** The whole-file pass costs 0.5 ms over a 6.4k-line corpus against a 100 ms re-diff budget, so a partial rebuild would save half a millisecond and cost a second code path that can disagree with the first. PERFORMANCE.md 6.2 makes the _data structure_ T0 and that is what shipped; the incremental rebuild waits for a profile that wants it
- [x] "Lex the visible range plus a margin": the API takes `(from, to, state)` and the benchmark measures it at 4.5 us per 50-line screen. Phase 5 shipped without calling it that way, and **the profile says leave it**: `lex` costs 0.053 ms across a whole frame against an 8 ms budget, memoised by `lex_cache`. Ranged lexing would save microseconds and add a second path that can disagree with the whole-file one about a lexer state carried across a screen boundary. Closed rather than left looking like debt; reopen it if a file ever makes `lex` visible in `--profile`

**Zig first rather than Rust.** The plan said Rust first. Every fixture, every recorded session and every file in this repository is Zig, so a Rust-first order would have meant testing the first language against no real code. Rust, Go and Python all landed in the same phase anyway, and all four are exercised against real files through `zig build lex`.

**Gate: PASSED.** Fragment tests cover unbalanced braces, truncated functions, unterminated strings and unclosed block comments; enclosing-function names are correct on Zig, Rust, Go and Python fixtures and on real files from four repositories. 34 tests in `syntax/`, 105 in total.

Two harnesses, matching the pattern of earlier phases:

- `zig build lex -- <file> [line]` prints the colourised token stream, the function spans and the timings for one file. This is how a language definition is found to be wrong about real code rather than only about its fixtures.
- `zig build bench -- [dir] [ext]` is the phase's instrument. It measures four things separately because they have different budgets: the whole-file structure pass (per changed file per re-diff), the full lex (the pathological render), one 50-line screen from the nearest checkpoint (what a frame actually draws), and a cache hit.

### Measured, and what the measurement changed

ReleaseFast, 27 Zig files under `src/`, 6453 lines, 227 KB.

|                    | first working version | after the optimisation pass             |
| ------------------ | --------------------- | --------------------------------------- |
| Structure pass     | 148 ns/line           | **77 ns/line** (0.50 ms for the corpus) |
| Full lex           | 208 MB/s              | **378 MB/s** (0.57 ms for the corpus)   |
| One 50-line screen | 7.0 us                | **4.5 us**                              |
| Cache hit          | 5149 ns               | **20 ns**                               |

Nothing here was optimised on a hunch; the benchmark was written first and each change was kept only because it moved a number.

- **The cache hit was the worst result and the easiest fix.** Hashing the file on every lookup made a hit cost 5.1 us, the same order as the 0.9 ms miss it existed to avoid. The key is now supplied by the caller, which is what the blob hashes captured in phase 2 were for.
- **A comptime byte table in front of the opener ladder** was the largest scanning win. Every byte used to be tested against every comment and string opener in the language; now one table lookup answers "could anything start here" and ordinary identifiers and operators skip the ladder entirely.
- **Vectorised inner scans** (PERFORMANCE.md 6.3): `indexOfScalarPos` to the end of a line comment, `indexOfAnyPos` to the next byte that could matter inside a block comment or a string literal. Comment-heavy source spends real time in exactly those loops.
- **Keyword lookup was 20% of total scan time**, measured by deleting it: 0.542 ms fell to 0.435 ms. That is the evidence PERFORMANCE.md 6.1's T1 item was waiting for. A two-mask comptime prefilter on (first byte, length) and (last byte, length) recovered about half of it. A hand-rolled perfect hash could take the rest and is still not worth the code: the remainder is 12% of half a millisecond.

**ARCHITECTURE.md open question 5 is answered: the enclosing-function scan runs over the whole file, eagerly, per changed file.** The docs deferred this until a 5k-line file had been measured. Measured: 0.5 ms for 6.4k lines, against a 100 ms re-diff budget and an 8 ms frame budget. There is no case for restricting the scan to the visible range, and doing so would cost the correct brace depth that the scan exists to produce.

One caveat. Every number above is Zig source measured on Zig-heavy input. Rust, Go and Python are correct on real files but were not the corpus, and Python in particular does more work per line, since indentation is inspected at every line start. Re-run `zig build bench -- <dir> <ext>` before trusting the figures for another language.

## Phase 5: TUI - DONE

`ui/` with libvaxis. First phase that needs a terminal. Test at 80 columns from
day one.

Split into three because the checklist is the largest in the plan and all of
the integration risk sits in the first slice: **5a** the loop and a rendered
unified diff, **5b** the full motion set, **5c** chrome (file list on `F`, help,
themes, config, SIGWINCH polish).

The layout is mockup **2a** from `lgtm TUI Mockups.dc.html`: no persistent file
list, one status row, files reached with `]f`. Chosen over 1a because it gives
the body 22 of 26 rows instead of 17, and because 1c (the side-by-side view)
already uses the same chrome - so when split lands in v0.3 it swaps the body
rather than re-laying out the screen. Sign column is 1o option B, classic
`+`/`−`, which is what every other mockup in the doc already draws.

### 5a - done

- [x] Main loop: drain event queue, re-diff, inherit change ids, render. Order fixed by ARCHITECTURE.md 3
- [x] Diff arena resets per re-diff, frame arena per render - and the frame arena resets **after** render and flush, never before (ARCHITECTURE.md 5c)
- [x] Rendering via the libvaxis low-level API only; `vxfw` is not imported
- [x] Output through the `io/tty.zig` buffered writer, one flush per frame
- [x] **`vx.resize` only on an actual resize event.** Found by using it: `j`/`k` flickered. `resize` reallocates both screen buffers and discards `screen_last`, which _is_ the damage-tracking baseline - vaxis's own source says "this has the effect of redrawing every cell" - so calling it per frame repainted all 2080 cells per keystroke. Measured with `tmux pipe-pane`: **3949 bytes per keypress before, 248 after**. The winsize ioctl is gone from the frame path too; `WinsizeNotifier` already delivered resizes as events
- [x] `Window.gwidth()` for display width everywhere a field is right-aligned
- [x] Hunk headers: `@@ #<id> ▏ <enclosing fn> ▏ <range> @@`, the name coming from phase 4's brace-depth scan
- [x] Syntax highlighting per row, from whole-file runs cached on the blob hash
- [x] Every action is a named command; the keymap maps sequences to command names; zero hardcoded keys in dispatch. The status-line hint strip is generated from the bindings, so it cannot advertise a key that does nothing
- [x] Motions `j k`, `Ctrl-d/u`, `gg G`, `]h [h`, `]f [f`, `zz`, `q`
- [x] `--once` renders a single frame and exits, which is what makes the render path testable without a human at a keyboard
- [x] Walking skeleton `ui/smoke.zig` deleted, as its own header instructed
- [x] 5b: `V`, `/ n N`, `e $EDITOR`, `:q`, `Tab` - shipped, with `ui/prompt.zig`, `ui/search.zig` and `ui/editor.zig` as their own modules. Beyond the checklist: a `<Space>` leader defined once as `keymap.leader` (FEATURES.md 4.3), `]f`/`[f` wrap at either end and announce it the way a wrapped search does (SPEC.md 6.2), and `?` freed for the help popup by dropping reverse search (FEATURES.md 4.4)
- [x] 5c: file list on `F` - **an overlay, not a pane.** The same box the `?` popup draws, because a list of files and a list of keys want the same rules: a filter that narrows as you type, a selection clamped against what the filter left, `H J K L` and the arrows to move, `Esc` to close. `Enter` jumps to the selected file, which is the one thing it does that `?` does not, and the footer says so. It opens on the file the review is already showing, so it answers "where am I" before it offers to move you; the current file keeps its marker while the selection moves over it, because those are different questions. One column always - two columns of paths would give each half the width a path needs
- [x] 5c, part: three pieces of the `?` overlay turned out to be the general case, and the file list is what proved it. `popup.fit` gained a `max_cols` ceiling; the box chrome - blank, borders, the two labels, the verticals - became `chromeOf`, shared by both; and `helpFooter` became `footerOf`, which takes the keys that are not bindings (`<CR>`, `<Esc>` are `prompt.zig`'s submit and cancel) as data rather than writing them out. `fuzzy.zig` came out of `keytext.zig` for the same reason: both lists rank a run of the query above scattered letters, and neither wants its own copy of that rule
- [x] 5c, part: the popup navigation commands were named `help_down`/`help_up`/`help_left`/`help_right` and are now `list_*`, live in both overlay modes. Two sets of navigation keys for two lists would be two things to learn, and the second list is where that would have started
- [x] 5c, part: the `F` list says what happened to each file **in colour, not in a letter column**. Green arrived, red left, amber changed, blue moved, grey cannot be read; the icon beside it takes its filetype hue the way oil.nvim and neo-tree draw one. Both come from the theme's palette - `Theme.hues` is the raw-colour accessor that avoids a slot per language - so a theme moves them together. The first attempt put `A`/`D`/`R`/`B` in a column before the path and it was wrong twice over: a second alphabet to learn, and a column the path did not get
- [x] 5c, part: `ui.icons = "nerd"` ships, opt-in. The icons are private-use codepoints and draw as tofu in a font that lacks them, so nothing reaches them unless asked for by name; the table in `ui/devicon.zig` names the Nerd Font class beside each codepoint, so a wrong one is a one-line fix against a name. Two fixed cells before the path whether or not an icon lands there, because a slot that is only sometimes present steps every path beside it one column sideways
- [x] **Binary back under budget: 1077 KB → 778 KB.** ARCHITECTURE.md 5c's 1 MB gate had quietly been breached (957 KB at the phase-5a measurement, 1077 KB by the end of 5c). Measured rather than guessed: `size -A` put 336 KB in `.rodata` and 720 KB in `.text`, and `nm --size-sort` found two 50 KB stable-sort instantiations and a heap of DWARF and inflate code - the stack-trace machinery, 304 KB of it. It is now a build option: traces in Debug where a developer reads them, off in a release where a panic trace lands in an alt screen the TUI never got to leave, and `-Dtraces` to force them back for a bug report. The remaining floor is uucode's 185 KB of Unicode width tables, which `Window.gwidth` needs and ARCHITECTURE.md 5c already predicted
- [ ] Deferred, and named so it is not mistaken for missing: the three-scope fuzzy finder on `f` (SPEC.md 6.4). `F` is its changed-files scope, which needs nothing the review does not already have; project and machine scope need a SQLite reader for the `look` index, which is phase 7
- [x] 5c, part: `theme.zig` + bundled themes. A theme is a `Palette` - twelve colours - plus one shared mapping onto the twenty-six semantic slots the renderer asks for, so seven themes are seven data blocks rather than seven chances to get "the accent, recessed" subtly different, and a new slot is one edit instead of seven. `terminal` (the default) is that palette in 16-colour indexes, so the tool still opens already matching the terminal around it; Catppuccin, Tokyo Night, Gruvbox, Dracula, Rosé Pine and Kanagawa are true colour. `default` is `fromPalette(terminal)` rather than a second hand-written copy that could drift from it, which the old literal would have become the moment a slot was added
- [x] 5c, part: `[theme]` in the config - `name` picks a bundled palette, every other key overrides one slot over the top of it, in file order. Styles are written the way a human types them: a colour and attributes in any order, `#rrggbb`, a 256 index, or an ANSI name, with `on` marking the background. Errors follow 4.9 - an unknown theme lists the ones that exist, an unknown slot names itself, a colour that cannot be read says which word - and the theme the user had is the theme they keep
- [x] 5c, part: `--theme-preview` draws every bundled theme as a few rows of real diff, and `--theme <name>` tries one for a run. It writes SGR directly rather than through vaxis, because it runs before terminal setup and would otherwise have to enter and leave the alt screen once per theme; that encoder is the only hand-written escape sequence in the codebase, and it is unit-tested against the sequences a terminal palette actually applies (`;32`, not `;38;5;2`)
- [x] 5c, part: the consistency between themes is asserted, not trusted. Every bundled palette is checked for an accent distinguishable from its own greys, an add sign distinguishable from its delete sign, and text that survives being drawn on its cursor line. **Rosé Pine is why**: it has no green, and choosing one by eye is how a port ends up with an unreadable add sign, so it uses the palette's own published ANSI mapping
- [x] 5c, part: `config.zig`. A TOML subset parsed in one pass - tables, `key = value`, strings, booleans, integers, single-line string arrays - read from `~/.config/lgtm/config.toml` (or `$XDG_CONFIG_HOME`) and then `.lgtm/config.toml`, merged key by key rather than file by file (FEATURES.md 4.8). `--config <path>` reads one file instead, which is also how it is driven in a test. The surface is what exists to configure today: `[nav] hunk_crosses_files` and `scrolloff` (the last hardcoded policy constant in `app.zig`), `[ui] icons`, and `[keys]` remapping any command by the spelling the `?` popup prints. Themes, templates and risk rules add sections when they land; nothing outside `config.zig` knows the file format, so a real TOML dependency could replace the parser without touching a call site
- [x] 5c, part: **never fatal, and specific about why** (FEATURES.md 4.9). A bad line costs that one key its value and nothing else: the key keeps its default, the file, line and key are reported, and the rest of the file still applies. The first problem and a count of the others go to the status line on the first frame - `config: config.toml:2: unknown key 'nav.scroloff' (+1 more)` - and are cleared by the first keystroke like any other notice. An unknown `[section]` is reported once at its header rather than once per key inside it, so a `[templates]` block read by an older binary costs one line of complaint
- [x] 5c, part: a remap that would shadow another binding is refused rather than accepted. `feed` returns on the first exact match, so a sequence that is a prefix of a longer one fires first and makes it unreachable - `quit = "<Space>"` would leave every leader binding listed in `?` and silently dead. `keymap.shadowed` is the general form of the "never bind the leader on its own" rule, is run over the table an override _would_ produce, and reports the pair; the previous keymap stands. It catches the duplicate as well as the prefix - the same sequence bound to two commands leaves the second dead for the same reason - and names the _other_ command, not the one being edited It also asserts the shipped defaults, so the next `<Space>x` cannot regress it
- [x] 5c, part: **the hint strip carried its own text, and remapping exposed it.** Each binding held a finished string - `"]f [f file"` - so `next_file = "]w"` in a config left the status line advertising a key that no longer did anything, which is exactly what FEATURES.md 4.3 says the generated strip cannot do. `Binding.hint` is now the label alone (`"file"`), the keys are rendered from the chords, and bindings sharing a label share an entry. `keymap.parseChords` is the inverse of the popup's `bufWriteChords`, pinned to it by a round-trip test over every default binding - a key read off `?` and pasted into `[keys]` has to parse, or the two spellings drift and only a user finds out
- [x] 5c, part: SIGWINCH re-layout, preserving cursor and scroll - **and the bug this item named was not the bug**. The empty `.resize` arm looked like a re-layout that never happened; driving it proved otherwise, because the run loop owns `ws`, calls `vx.resize` on the event and clamps the scroll at the top of every iteration. Re-checked at 100x30, 70x14, 110x36, 40x6 and 20x4 ("window too small"), with the cursor at the end of the review, in visual mode, with a `/` prompt open and with the help popup up: every one re-lays out, keeps the cursor and re-windows the popup around its selection. The arm now clamps the scroll itself anyway - not because the loop misses it, but because a resize that a unit test can assert against beats one that only a terminal can
- [x] 5c, part: **what was actually wrong was the signal handler.** `WinsizeNotifier.onWinch` ran `Queue.push` - a mutex and an allocation - from inside vaxis's SIGWINCH handler. SIGWINCH is delivered to whichever thread is not blocking it, so a signal landing on a thread already holding the queue mutex, or inside the allocator, hangs the process outright: rare, unreproducible and exactly the kind of hang that ships. The handler now does one atomic store and nothing else; the reader thread's existing 50 ms wake turns the flag into an event, measures the terminal there, and coalesces a whole drag into one `resize` at the size the pane settled on. No third thread, and a resize is still on screen within 150 ms of the drag stopping. `register` gained a matching `unregister`, since the handler holds a pointer into `app.run`'s stack frame
- [x] Reload moved from `<C-l>` to `<C-r>`. vim-tmux-navigator binds `C-h`/`C-j`/`C-k`/`C-l` at the tmux **root** table and forwards them only to processes matching its vim pattern, which `lgtm` does not match, so reload was unreachable under a very common config (FEATURES.md 4.4). A second binding was the plan; moving it was better, because `<C-r>` is the reload key everywhere else and nothing takes it, so there is one key to learn rather than two
- [x] The overlay lists one row per **action**, not one per binding: `]f / <Space>nf  next file (wraps)` rather than two rows a reader has to compare to find no difference. The slash matters: separated by a space alone the row read as one four-token key. The leader forms are aliases now, and `keysFor` gathers every spelling of a command onto its row. The footer prints only the first spelling of each, because it is one line inside a box and the list above it already has the rest
- [x] 5c, part: `]h`/`[h` walk the whole review, crossing files, wrapping only at its far end; `<Space>nh`/`<Space>ph` alias them. Stepping is by hunk _index_, not by row - by row, `[h` could never move, because the cursor lands on `header + 1` and the nearest header above it is the one it just landed on. The policy sits in an `app.Nav` struct (`hunk_crosses_files`, default true) for `config.zig` to fill in (FEATURES.md 4.7b)
- [x] 5c, part: `?` help popup. A box floating over the diff, sized to content and centred, with a fuzzy filter over both descriptions and rendered keys and an `HJKL` selection moving by row and by column, arrows aliasing it. Shifted rather than `<C-j>`/`<C-k>`, which vim-tmux-navigator takes at the tmux root table before the app sees them. Its own `Mode`, in which the keymap serves navigation only and every other key is filter text, so nothing fires behind it. Rows come from the bindings, so a remapped keymap documents itself; two columns where the width allows, `+N more` rather than a silently truncated list (FEATURES.md 4.4). Grouping by category is not built
- [x] 5c, part: `app.zig` split, after it reached 1,800 lines and three jobs. `ui/loop.zig` takes the run loop and everything that owns a terminal - the vaxis screen, the input and watch threads, the `$EDITOR` handover - and has no unit tests by construction. `ui/review.zig` takes one diff generation: git, the buffers it overlays, the change ids and the lexer cache. `ui/help.zig` takes the `?` overlay's filter, selection and grid. What is left in `app.zig` is the state a reader has - which file, which row, which mode - and what a key means, which is what all the tests were about anyway. 650 lines of code where there were 1,040, and `rediff` is eight lines instead of eighty
- [x] 5c, part: three motions had each spelled the same ring arithmetic differently - `]f`, `]h`, and the search's walk across files, the last of it a seventeen-line switch. One `wrapIndex` now answers "where does this step land, and did it come round the end", with the backward case - `@mod`, not `@rem` - pinned by a test. `Rows.empty`, one `EditTarget` for "the file, no line", and the prompt's submit path as its own function are the rest of the sweep
- [x] 5c, part: **the split cost nothing, measured rather than assumed.** Comparing the commit before it against the tree after it, both driven through the same 91 frames of the same scratch repo: frame 0.138 ms → 0.132 ms, render 0.060 → 0.057, re-diff 3.264 → 3.263. Both runs show `diff_parse` twice, which is not waste: the watcher's first poll has no previous state to compare against, so it reports everything once and the app re-diffs - the resync that catches anything written between start-up's diff and that first poll
- [x] 5c, part: `render.zig` and `keymap.zig` split the same way, and for the same reason - each was two or three jobs in one file. `frame.zig` holds what a frame is drawn onto (`Frame`) and from (`View`, `HelpView`), imported by the three that draw and importing nothing back, so they stay independent of each other rather than a knot of mutual imports. `body.zig` is the diff, `popup.zig` the overlay, `render.zig` the chrome and the order. `keymap.zig` is what keys mean - bindings, matcher, conflicts - and `keytext.zig` is how they are written: the chord spelling in both directions, the hint strip, the help rows. The types are re-exported from `render.zig`, because "the renderer" stays one idea to everything above it
- [x] 5c, part: **the popup's geometry is now a pure function, and tested as one.** `drawHelpPopup` was 130 lines that measured, laid out and painted in one pass; the layout half - how many columns fit, how many rows each holds, which slice of the list is on screen, where the box sits - is `popup.fit`, taking measurements and returning a `Box`. Five tests cover what could previously only be squinted at in a terminal: one column at 46 columns and two at 100, the row kept for `+N more`, a window that follows the selection a whole column at a time, and the centring. The drawing is what is left
- [x] 5c, part: the split cost nothing again, same protocol as the last one - 91 frames of the same fixed repo: frame 0.132 ms → 0.124, render 0.057 → 0.053. `Frame.print` collapsed the format-draw-measure dance the status and mode rows repeated at six call sites, and `Frame`'s methods are `pub` now that two other files call them - they were private and reachable anyway, which is the kind of thing that is true until it is not
- [x] 5c, part: the `app.zig` tests, which were 60% of what was left of the file. Every test drove the app one codepoint at a time - `fx.key(']'); fx.key('f');` - so `fx.press("]f")`, `press("<Space>nf")`, `press("<Esc>")` now spell a sequence the way the `?` popup prints it and a `[keys]` config writes it, **through the same parser as the config**, so a test and a user's config cannot disagree about what `<Esc>` means. 108 hand-typed keys became 90 sequences. `expectCursor`/`expectFile`/`expectMode`/`expectNotice` replaced 71 `expectEqual(@as(u32, ...))` mouthfuls, and the notice helper asserts what the reader was told rather than pinning the wording
- [x] 5c, part: tests moved to what they are about and merged where they said it twice. The `anchorLine` pair went with the function to `review.zig` (and took its re-export with it); the popup's clamping, column arithmetic and filter reset now live once, in `help.zig`, leaving the app-level tests to assert the wiring they are actually about - that these keys are bindings live in `.help` and nowhere else. Two pairs of near-identical tests became one each: the file ring wraps at both ends in one test, and the leader forms are checked against their bracket forms in one. 246 tests to 244, with nothing uncovered; the file is 638 lines of code and 749 of tests, grouped under eight banners instead of running in the order they were written
- [x] 5c, part: the same pass over the rest of the tree, splitting only where a file was doing two jobs and leaving the rest alone. `config.zig` gave up its parser to `toml.zig`, which makes the header's claim - that a real TOML dependency could replace it without touching a call site - literally true: the parser reports _faults_ and `config.zig` writes the sentences, because what to tell a user about a bad line depends on what the key meant. `lexer.zig` gave up `token.zig` (kinds and runs) and `langdef.zig` (the vocabulary a language is described in), which also fixes the dependency direction - `lang/zig.zig` described a language by importing the scanner that reads it. `anchor.zig` gave up `linemap.zig`: matching two versions line to line is most of the code, and the tiers that were the point of the file were buried under it. `theme.zig` gave up its seven palettes to `palette.zig`, so adding a theme is adding data
- [x] 5c, part: **left alone, deliberately.** `core/diff.zig` parses a unified diff and does nothing else; `syntax/highlight.zig` is choosing a highlighter and memoising it; `io/watch.zig` already separates the pure poller from the thread inside one 267-line file; the five harnesses share about fifteen lines of stdout-and-argv boilerplate, which is less than a module to share it would cost. Splitting those would be motion, not cleaning
- [x] 5c, part: **the cursor keeps its line across a re-diff, not its row.** `rediff` carried a row index, which means the same thing only until something above it changes; `core/anchor.zig` had been finished and gated since phase 1 and nothing called it. The carry is now `anchor.carryLine`, one line from one version of a file to the next, and the row index is the fallback for a line that is genuinely gone (hard rule 7: never moved somewhere that merely looks similar). Measured in a two-pane session, cursor on `demo.txt:22`, three lines inserted above it from outside: `.row` sent `#3 demo.txt:1 (deleted lines in this hunk)`, having stayed on a row that now belongs to a different hunk; `.line` sends `#1 demo.txt:25`, the same line of text
- [x] 5c, part: **`:q` needed a second Enter, and `e` would have hung the same way.** `poll` on macOS answers `POLLNVAL` for `/dev/tty` - the controlling-terminal clone device is not pollable there, though the pty behind it polls normally - and `readable` took any `n > 0` as "bytes waiting". The input thread therefore spent its life parked in a read that only returns on a keystroke: 847 of 861 idle samples were in `readv`, 14 in `poll`. Everything that joins that thread waited for the *next* key, so the first Enter quit the app and the second one released it. `Reader` now probes for a descriptor `poll` will answer for, falling back to stdin when stdin is this terminal, and treats only `IN`/`HUP` as readable. One Enter, 0.11-0.15 s, five runs
- [x] 5c, part: quitting no longer waits out a poll interval. `io/watch.zig` slept the whole 500 ms uninterruptibly and then ran a `git status` before rechecking the stop flag, so `:q` paid for both: 0.64 s measured. The interval is slept in 25 ms slices with the flag checked between, and again before the tick
- [x] 5c, part: `<Tab>`/`<S-Tab>` step either overlay's selection, and a step wraps at both ends the way `]h`/`[h` already do. A page (`H`/`L`) still clamps: wrapping a screenful lands nowhere the eye was looking. Shift-Tab needed `Chord` to carry a shift bit, which meant `io/input.zig` had to stop reporting shift for anything that types a character - the shift is already in the codepoint, terminals disagree about whether to send it as well, and keeping it would have made `V` match on one terminal and miss on another. `sameChord` compares the new bit, or `<Tab>` and `<S-Tab>` would read as the same binding twice. **The Linux build links no libc**, so `std.c` is unreachable there and `isatty` had to become `std.posix.tcgetattr`, which asks the same question as a syscall. macOS always links libc and so never saw it; the ubuntu leg of CI did, on its first real outing
- [x] 5c, part: the seven `test { _ = other_module; }` blocks are not ceremony. The render split lost five tests silently - a module nothing references runs nowhere - and the loss showed up only as a test count dropping from 241 to 236. Every module introduced by these splits is referenced from one, and the count is now part of what a split is checked against
- [x] 5c, part: **long lines soft wrap, and the row model did not move.** A line wider than the pane was cut at the edge with nothing to say so - at 80 columns in a split pane, with markdown or any prose in the review, that is most of what a hunk says. `ui/wrap.zig` answers which bytes of a line go on which screen row: greedy, breaking at the last space that fits and hard-breaking a word longer than the pane, with an ASCII fast path so the common line costs a length comparison. It is one function for two callers - `ui/body.zig` draws the chunks and `ui/app.zig` counts them - because two implementations would disagree the first time one met a double-width glyph, and the disagreement would look like a scroll bug. Wrapping stays a rendering decision: a body row is still one line of the file, so `j`, visual select and the reference are untouched, and `scrollFor` is what learned to count screen rows instead - it takes the heights it needs from a caller, which keeps it arithmetic with a table in its tests. `<C-d>` moves half a screen rather than half the rows on it, `zz` centres by screen rows, and the body draws into a child window so a wrapped line at the bottom is clipped rather than spilling over the rule. `zw` and `ui.wrap` turn it off for reading the shape of the code
- [x] 5c, part: **the cursor is a character now, because a line was not enough to point with.** It was a row index drawn as a full-width wash, and `docs/SPEC.md` had been advertising `h j k l` while two of the four did nothing. `ui/motion.zig` is the missing half: character, word, `0`/`^`/`$` and `f`/`t`/`F`/`T` with `;` and `,`, pure over one line's bytes and returning null where a motion has nowhere to go, so the caller decides whether that means "stay put" (`h` at column zero) or "carry into the next line" (`w` at the last word). The column is drawn as the terminal's own cursor rather than a painted block - the argument `drawPrompt` already made, and it costs no theme slot - located through `wrap.locate`, which is what puts it on the right row of a wrapped line. `want_col` is vim's `curswant`: down a ragged column and back, the cursor returns to where the eye was. `v` selects charwise beside `V`, shaded by splitting the lexer's segments rather than by filling cells, so it wraps for free and the syntax colours survive underneath it. **What the column is for** is the reference: a charwise selection sends ``#3 path:47 `verify_token` `` rather than a column number, because an agent does not count columns - and only within one line, since across two the text would carry the newline hard rule 1 refuses. `W`/`B`/`E` came straight after, and cost a `Width` parameter rather than a second set of functions: a WORD motion is a word motion that cannot see the difference between a letter and a bracket. Driving those in a pane found three fidelity bugs the tests had not: `e` and `E` did not cross lines while `w` and `b` did, an empty line was being stepped over rather than stopped on (vim calls it a word), and `gg` landed on the hunk header above the first line - harmless while the cursor was a whole row, visible the moment it became a character. Three keys changed hands for it (`e`, `t`, `F` to the motions; the editor, the test preset and the file list to `<Space>e`/`<Space>t`/`<Space>f`), which FEATURES.md 4.7's own rule already decided
- [ ] Deferred with the cursor work, and named so none of it is mistaken for missing. **Counts** (`3w`, `5j`): the matcher has no accumulator, and a count parser has to treat a leading `0` differently from a `0` after a digit now that `0` is `line_start`. **`{` and `}`**: advertised in SPEC.md 6.2 and bound to nothing, held back because what a paragraph *is* in a diff is a decision, not an implementation - blank-line delimited within the file, or the hunk that `]h` already walks. **`*`**, searching the review for the word under the cursor: impossible until this week because there was no column to read a word from, and now a `motion` call plus the search that already exists
- [x] 5c, part: **jumps glide.** The screen used to change between one frame and the next, which tells a reader that they moved but not where to. `ui/anim.zig` is the displacement between where the viewport is drawn and where it has settled, closing at constant speed (the second finding below is how it stopped being an exponential decay): frame-rate independent for free, never overshoots, and a second jump landing mid-flight is an addition rather than an animation to schedule against the one already running - which is what holding `<C-d>` is. No clock and no terminal in it, so a frame that took 80 ms, a duration of zero and a jump too far to be motion are all tested without a pane to watch. The unit is **screen rows, never logical ones**: a wrapped line is several, and crossing it in one step would speed the motion up over exactly the lines that are hardest to read. That is what needed `body.draw` to start partway into its top row, and the clipping to be per chunk rather than per window - a window clips against the screen, and would have let a half-scrolled line write over the rule. `j` and `k` are not animated (one row has nothing in between, and a frame of delay per keystroke is latency dressed as motion), a jump past two screens is left as the teleport it is in intent, and a keystroke arriving mid-flight settles it before dispatch. The loop keeps blocking on `drain` while settled and paces itself only while one is running, so the idle pane still costs nothing; `event.Queue.tryDrain` had been sitting there since phase 0 labelled "non-blocking variant for the render loop". **Four findings from driving it that the tests could not have had.** The first: `<C-d>` was not scrolling at all. It moved the cursor half a page and left the viewport where it was, so the text only started moving once the cursor reached the bottom margin - which meant the first press of a page key animated nothing, and that is most of what "I do not feel it" was. Vim moves the window and the cursor by the same amount; `page` now does too. Measured either side on the same six presses in the same file: 39 frames to 73, about four animation frames per scroll to about ten.

The second: **ease-out is the wrong curve for a cell grid.** Exponential decay spends its opening frames moving four and five rows, which the eye reads as a jump, and its closing frames moving less than a row, which a terminal cannot draw at all. Half a row does not exist, so one row per 60 Hz frame is the finest motion available and there is nothing to be gained by asking for less. The animation is constant speed with that as its floor, and `ui.scroll_ms` bounds only how long a long jump may take before it has to move more than a row at a time. A short jump therefore arrives sooner rather than moving more slowly: the velocity is what stays the same.

The third, and the one that was actually being felt as "crack, lag": **every command that moved the view was animating, including `j`.** With soft wrap a single `j` crosses two or three screen rows, so each keystroke started an animation, the next `j` arrived mid-flight and cancelled it with a snap, and the paced loop added up to a frame of input latency per key. `Command.jumps()` now separates asking to be somewhere from walking there: only the first animates. Measured over twenty `j` presses, animation frames went from a hundred-odd to none, while `<C-d>` still renders its ten. Two smaller latency fixes came with it - the frame's sleep is sliced with the queue checked between, so a key waits 4 ms rather than 16, and a second jump adds to the one in flight instead of cancelling it.

The fourth, and the one the whole thing turned on: **the cursor was not animated at all, and it was the cursor being watched.** Two defects sat underneath that. The block was drawn at its *settled* row while the viewport was drawn displaced, so the first frame of a page key put the cursor half a page from where the text still was - it snapped away, often off the bottom edge where it vanished, and crawled back: text and cursor moving opposite ways, which reads worse than not animating at all. And every motion that was not a page key moved it instantly, on the reasoning that four cells of a `w` is nothing to interpolate - which was wrong, because four cells is four frames of visible travel and the comparison that mattered was against none. `anim.Cursor` chases a **screen cell**, not a row and a byte offset: a column, a wrapped line and a scrolling viewport all move the cursor across the same grid, and one chase covers the three without knowing about any of them. Two more came out of driving that: a cursor that has never been drawn has nowhere to travel *from*, so drawing is what places it - without that the animation can never start, because nothing travels until something has been placed; and a row of chrome has no line to find a column in, which blinked the block out for a frame and then teleported it, which is what a held `j` looked like
- [x] 5c, part: **reviewed, and the animation costs frames rather than memory or CPU.** Three paired runs of eight `<C-d>` presses, ReleaseFast under `/usr/bin/time -l`, defaults against `scroll_ms = 0, cursor_ms = 0`. **Peak RSS does not move**: 10016/9920/9888 KB animated against 9888/9888/10000 KB not, ranges that overlap and whose two highest readings sit on opposite sides. That is structural rather than lucky - `ui/anim.zig` imports `std` and nothing else, holds no allocator and allocates nothing, and `Scroll` at 12 bytes beside `Cursor` at 24 are inline fields of `App`: 36 bytes of stack for the whole feature, none of it per frame. **CPU does not move either**, 0.22 s against 0.25 s of user plus sys across a 6.4 s run - consistently the lower of the two across all three pairs, by far too little to claim a mechanism for. The one number that does move is **voluntary context switches, 180 against 127**, which is `pace` waking every 4 ms to look at the queue while a jump is in flight: the price of a keystroke waiting 4 ms rather than 16, bounded by the animation and therefore nothing at all in an idle pane. Ten seconds idle renders **two frames and 30 ms of CPU**, and that 30 ms is the 500 ms watcher rather than the render loop, which is the blocking `drain` doing what it claims. So the eight `displaced` walks `view`, `animating` and `stepAnim` repeat between them every animation frame are left alone: PERFORMANCE.md 0 says instrument before optimising and the instrument says there is nothing there to save. **One real defect the review turned up.** `zw` and `Tab` relay out every row under the cursor - wrap changes what a line is worth in screen rows, zen changes the body's height - and neither placed it, so the block travelled diagonally across a screen that had stopped existing. `resize` and `files_changed` already placed it; these two are the same case and were missed, which is the argument for `placeCursor` being one named thing rather than a line of code at each site. Two cleanups came with it: `settled_rows` and `arrived` were one constant spelled twice at the same value, and the render loop asked `render.bodyHeight` five times an iteration for an answer that cannot change inside one
- [ ] `layout_cache` (PERFORMANCE.md 7.2): not built. Frame cost is 0.171 ms against an 8 ms budget, and 0.21 ms with an animation running, so there is nothing yet for it to save. `lex_cache` **is** in use and is why `lex` costs 0.053 ms across a whole frame
- [x] `diff_cache`: **rejected with a measurement.** See the re-measurement under the 5a gate below

**5a gate: PASSED.** ReleaseFast, `-Dprofile`, rendering this repository's own
working tree in an 80x26 tmux pane.

| Metric                     | Budget     | Measured                                   |
| -------------------------- | ---------- | ------------------------------------------ |
| Cold start                 | 50 ms      | **under 10 ms**                            |
| Frame (keystroke to flush) | 8 ms       | **0.171 ms** (render alone 0.071 ms)       |
| Re-diff, whole tree        | 100 ms     | **3.13 ms** (git subprocess 2.24 ms of it) |
| Peak RSS                   | 40 MB      | **6.3 MB**                                 |
| Binary, stripped           | under 1 MB | **957 KB - see below**                     |

Three things the measurement settled:

- **`diff_cache` is not worth building, and is now closed rather than deferred
  again.** The whole re-diff is 3.1 ms, and 2.2 ms of that is the `git`
  subprocess the cache would not avoid. There is about 0.9 ms on the table.

  Re-measured after phase 6 at a scale an agent turn actually reaches, since a
  handful of changed files was never the case that would justify a cache. A
  scratch clone with 40 changed files, `--once` so every run pays for a first
  re-diff, and a temporary span on `source.load`, which the instrumentation had
  never separated from the work around it:

  | span                                | run 1   | run 2  | run 3  |
  | ----------------------------------- | ------- | ------ | ------ |
  | `git diff` subprocess               | 81.375  | 35.630 | 46.228 |
  | `source.load`, a second `git` spawn  | 26.173  | 18.866 | 20.088 |
  | whole re-diff                       | 107.662 | 54.583 | 66.398 |
  | parse, attach and row rebuild       | 0.114   | 0.087  | 0.082  |

  Two subprocesses are 99.8% of a re-diff, and everything `diff_cache` would
  skip is the last row. Rejected rather than deferred: 40 changed files is
  already past a normal turn, and the figure the cache saves went *down* with
  scale rather than up.

  Two things this does not settle. `--once` measures a cold first re-diff in a
  fresh process against a clone in `/tmp`, which is why these sit an order above
  the 3.1 ms recorded from a warm session on this repository: the shape is
  comparable, the absolute numbers are not. And run 1 crossed the 100 ms re-diff
  budget at 107.662 ms. If re-diff ever does need to be faster, the thing to
  attack is `source.load` re-reading every HEAD blob whose hash has not changed,
  which is a different cache from this one.
- **The frame budget is not close to being a constraint.** 0.171 ms against 8 ms
  means the over-draw strategy is fine and row-level dirty tracking stays
  unbuilt, exactly as ARCHITECTURE.md 5c asks. Note what this measurement does
  _not_ cover: app-side frame cost was well inside budget while the terminal
  was being repainted whole. A profile span cannot see bytes on the wire, so
  the flicker above was invisible to it.

**Bytes per keystroke is now a tracked number, because `--profile` cannot see
it.** Re-check it the same way after any change to the frame path:

```
tmux new-session -d -s x -x 80 -y 26 './zig-out/bin/lgtm'
tmux pipe-pane -o -t x 'cat >> /tmp/pty.raw'
# send N keys, then divide the growth of /tmp/pty.raw by N
```

A healthy frame is a few hundred bytes, wrapped in synchronized-output markers
(`?2026h`/`?2026l`), with the cursor hidden and no `2J`. Thousands of bytes, or
a `2J`, means the damage tracking has been defeated again.

- **Binary size has reached the trigger phase 0 set for it.** That table said
  "recheck if binary size ever approaches 1 MB". It has: 957 KB stripped, 96%
  of budget, with themes, help, config, notes, the finder and the bridge all
  still to come. Details below.

### Binary size needs a decision before 5c

`zigimg` is still fully eliminated, so that half of ARCHITECTURE.md 5c's bet
holds. The other half did not: **the single largest item is 185 KB of `uucode`
Unicode tables, pulled in by `Window.gwidth()`.** 5c predicted this cost but
assumed it stayed hypothetical; calling `gwidth` is what made it real, and
`gwidth` is not optional - the checklist forbids assuming one byte is one
column, and the status line is full of multi-byte glyphs.

Also present and unexamined: `std.compress.flate` and the DWARF self-unwinder,
dragged in by Zig's default panic handler so it can symbolise its own stack
traces.

Neither is a bug and neither needs fixing today, but 5c should not be written
without deciding which lever to pull: `-Dexternal_uucode`, a `ReleaseSmall`
distribution build, a narrower panic handler, or raising the budget with a
reason. Note also that phase 0's 653 KB was measured on macOS arm64, where
debug info lives in a separate `.dSYM` - so that number and this one were never
measuring the same thing, and the honest comparison is stripped-to-stripped.

**Decided: `ReleaseSmall` for distribution builds, and `zig build dist` is
it.** The decision lived only in this paragraph until phase 6 was done, which
made it a decision nothing acted on: no step produced a distribution binary and
nothing checked its size. `dist` builds `ReleaseSmall` and stripped, with stack
traces off, and CI fails the push if the result crosses 1 MB - phase 0 asked for
a recheck near the budget, and this is that recheck run every time rather than
remembered.

Measured on Linux x86-64, stripped-to-stripped:

| Build            | Stripped   |
| ---------------- | ---------- |
| Debug            | 4.15 MB    |
| ReleaseFast      | 982 KB     |
| **ReleaseSmall** | **501 KB** |

`ReleaseFast` has drifted to 98% of the 1 MB budget, so phase 0's trigger was
real. But `ReleaseSmall` comes in at half the budget - under even phase 0's
653 KB - which settles it without pulling any other lever: `uucode` stays,
`gwidth` stays, the default panic handler stays, and no `-Dexternal_uucode`
flag needs to exist. The 185 KB of Unicode tables and the DWARF unwinder are a
_Debug_-build weight problem, not a distribution one.

**Re-measured once `dist` existed**, after the bridge, the anchor wiring and the
overlay work landed: 607,848 bytes on x86-64 Linux and 602,872 on arm64 macOS,
both `zig build dist`. The 501 KB above predates all of that, so the honest
reading of the pair is that a phase costs roughly 100 KB and the budget has
57% of itself left. The CI step prints the figure on every push, which is what
turns "recheck near 1 MB" into something that happens.

**Settled once `dist` existed.** The 5a gate table was measured under
`ReleaseFast`, which is not what ships, so the numbers described a binary
nobody would run. Re-measured with `-Dprofile` in both modes against the same
tree - a clone with 12 changed files, `--once` so every run pays for a cold
first frame - five runs each, medians:

| Span                       | ReleaseFast | ReleaseSmall |
| -------------------------- | ----------- | ------------ |
| frame                      | 0.335 ms    | 0.381 ms     |
| render                     | 0.132 ms    | 0.113 ms     |
| re-diff (`diff_parse`)     | 40.6 ms     | 39.0 ms      |
| whole `--once`, wall clock | 0.04 s      | 0.04 s       |
| stripped binary            | 766 KB      | **603 KB**   |

`ReleaseSmall` costs about 14% of frame time and saves 163 KB. At 0.381 ms
against an 8 ms budget that is 21x headroom, so the trade is free in the only
sense that matters, and the bet this section made is confirmed rather than
assumed. Re-diff and cold start are indistinguishable between the modes,
which follows from two `git` spawns being ~99.8% of a re-diff.

These are cold first frames through `--once`; the 0.171 ms in the 5a table is a
warm steady-state frame in a live session. The two are not the same measurement
and the pair should not be read as a regression.

**Gate for 5b/5c: PASSED.** Flawless at 80 columns in a split tmux pane, and
at 62 and 40 with the overlays open; below that it says "window too small"
rather than drawing a corrupted layout. `--profile` over 91 frames of real
keystrokes against a fixed repo, ReleaseFast:

| Metric                    | Budget     | Measured                             |
| ------------------------- | ---------- | ------------------------------------ |
| Frame, keystroke to flush | 8 ms       | **0.114 ms**                         |
| Re-diff, whole tree       | 100 ms     | **2.4 ms**                           |
| Binary, stripped          | under 1 MB | **778 KB** (1077 KB with `-Dtraces`) |

The binary is the one that needed work rather than luck; see the entry above.

**Verifying the TUI without a human at the keyboard.** `--once` covers the
render path; anything interactive is driven through a throwaway tmux session:

```
tmux new-session -d -s lgtm-test-x -x 100 -y 30 './zig-out/bin/lgtm'
tmux send-keys -t lgtm-test-x '?'
tmux capture-pane -p  -t lgtm-test-x   # text
tmux capture-pane -e  -t lgtm-test-x   # text plus SGR, which is the only way
                                       # to see which row is highlighted
tmux kill-session -t lgtm-test-x
```

Three things that have each cost a debugging cycle:

- **`zig build check` and `zig build test` do not reinstall the binary.** Run
  plain `zig build` before driving `zig-out/bin/lgtm`, or the session under
  test is the previous build and the change appears not to work.
- **`send-keys` bypasses tmux's own key table**, so it cannot reproduce a
  binding the user's tmux swallows. That is why `<C-j>` passed every scripted
  check and failed in a real pane.
- **`capture-pane -p` strips colour**, and the popup's selected row and the
  body's cursor line share a highlight, so grep for the description text rather
  than for the escape sequence alone.

## Phase 6: Bridge - DONE

`bridge/`, tmux + OSC 52 only in v0.1.

- [x] `bridge.zig` tagged union; invariants enforced here, not per backend: a payload containing `\n` is **refused**, trailing space added, carriage returns dropped (ARCHITECTURE.md §6). Refused rather than asserted: `std.debug.assert` is compiled out in ReleaseFast, which is the build where the mistake would be silent, so `normalise` returns `error.Multiline` in every build
- [x] `detect()` from env vars, infallible, falls back to `osc52`; a dead pane degrades to OSC 52 with a status-line notice and never propagates
- [x] `osc52.zig` (works over SSH). libvaxis's implementation was evaluated as §5c asks and not reused: `Vaxis.copyToSystemClipboard` is a method on a receiver it never reads, so reuse means `undefined` at the call site and a vaxis import in `bridge/`. The replacement is `std.base64` and one `print`, and it is what lets the backend tests run with no terminal
- [x] `tmux.zig` via `send-keys -t <pane_id> -l -- <text>`. `-l` is the correctness argument, not a flourish: without it tmux resolves key *names*, so a payload containing the word `Enter` would press Enter
- [x] Target pane: `--pane %N`, else `.lgtm/target`, else inferred. Inference is deliberately narrow - **exactly one other pane in the window** - because three panes is a guess and a wrong guess types into someone's editor. It runs lazily on first send, so a pane opened after `lgtm` started is still reachable, and again after a pane dies, so its replacement costs no restart. Only a target that has actually worked is written to `.lgtm/target`
- [x] `Enter` sends a reference from the internal template table (`#{change_id} {path}:{line}`); `V` range sends `:start-end`; references always resolve against the new file; a deleted line sends the enclosing hunk reference plus `(deleted lines in this hunk)` (SPEC.md §6.3)
- [x] `y` copies the reference, `Y` copies the reference plus the lines, markers kept - a mixed range pasted without `+`/`-` reads as nonsense
- [x] Every outgoing string goes through `bridge/template.zig` from day one. An unknown `{placeholder}` survives verbatim rather than being dropped, the same rule the config loader follows for a key it does not know: a typo should be visible in the message just sent, not a silently shorter one. User-configurable `[templates]` is v0.2 and lands as an override of those fields
- [x] Ask presets `a ! t x` (FEATURES.md §2.1), which were the stretch and cost four enum values and no dispatch of their own

Three things the plan did not anticipate, each from driving it in a real pane:

- **The hint strip has no room for a fourth action.** `<CR> send` had to go on
  it - it is what the tool is for - and adding it pushed `q quit` off the end
  at 80 columns. The `/` search hint was dropped to pay for it: `/` is the most
  universally known key in a vim-like TUI and it keeps its `?` row. The strip
  now measures exactly 80 in both normal and visual mode.
- **The copy path is not the send path.** `y`/`Y` go to the clipboard whatever
  the backend is, and `Y` legitimately contains newlines - hard rule 1 is about
  what `send-keys` does with one, so `copyText` sits beside `sendText` rather
  than under it.
- **A pane id can outlive its pane.** Persisting an inferred target before it
  had been proven would make the next run start by sending the user's first
  reference to the clipboard.

**Gate: PASSED.** Driven in a two-pane tmux session at 80x26 against this
repository's own diff:

| Check | Result |
| --- | --- |
| `Enter` on a line | `#1 src/io/fs.zig:18` in the agent pane, unsubmitted |
| Twice in a row | `...:18 #1 src/io/fs.zig:18` - the trailing space is there |
| `V j j` then `a` | `#1 src/io/fs.zig:18-20 - why this approach?` |
| `y` | `copied to the clipboard` |
| Agent pane killed | `pane is gone: copied to the clipboard instead` |
| No pane left | `no agent pane: restart with --pane %N` |
| Replacement pane opened | `sent to %66`, and `.lgtm/target` follows it |

`send-keys` bypasses tmux's own key table, so it cannot reproduce a binding the
user's tmux swallows - the same caveat phase 5 records. The keys driven above
are `Enter`, `V`, `j`, `a` and `y`, none of which any common tmux config binds.

---

## v0.1 release gate

All phase gates green, plus the success test: the author uses `lgtm` for a week without falling back to `git diff`. Publish the `--profile` numbers.


Run as a week of use rather than a checklist, logged in `DOGFOOD.md`: the
watchlist there is the set of questions the plan cannot answer from the inside,
and what it records is what decides v0.2.

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
- **`--base <ref>`: the diff source becomes a parameter.** Everything above `core/git.zig` already ignores where a diff came from, so `base...HEAD` reuses the hunks, change ids, syntax, search, file list and notes unchanged; what makes this a working-tree tool today is one argv. Two things are not free. `core/source.zig` reads the HEAD side from `cat-file --batch` and the other side off disk, and `attach()` verifies they agree - between two commits both sides are blobs, so the worktree read becomes a second `cat-file`. And the watcher wants turning off, because nothing is moving and `anchor.zig` has nothing to carry notes across. Worth it for reviewing a branch before pushing it, which is the same loop the tool already serves
- **PR review, if it earns itself, is the above plus one command.** v0.2's `core/review.zig` already renders `review-N.md` as anchored notes, and `gh pr review --body-file` posts it. That is the whole cheap version: no API client, no auth, no comment threads. Per-line inline comments are the expensive upgrade and should wait until the batch form has proved insufficient. If it is ever built, shell out to `gh` - `gh` is to GitHub what `tmux` is to the multiplexer, and `io/proc.zig` is already the quarantine for it, the same way the project shells out to `git` rather than linking libgit2. Note what this is and is not for: reviewing a PR **the agent opened**, and replying to it in the pane, is the same loop with a different diff source and is on-thesis. Reviewing a colleague's PR is a different job where the bridge does not apply and the only claim left is "nicer than the web UI", which octo.nvim and Graphite already contest
- **Neovim bridge** (`bridge/nvim.zig`), and a plugin only after it. Inside nvim's built-in terminal there is no pane for `send-keys` to reach, so `Enter` there degrades to the clipboard: shipping the plugin first would mean a tool that looks like it works while quietly not doing the thing it exists for. The backend is the same shape as `tmux.zig` and not an RPC client - `$NVIM` names the parent's socket, and `nvim --server $NVIM --remote-expr "chansend(...)"` is an argv and a subprocess, so no msgpack dependency and no new I/O path. Finding the agent's terminal buffer is `soleOther` again, refusing to guess past two the same way. What earns it over "just run lgtm in a split" is `e`: with the socket it opens the line in the editor the reader is already inside, rather than nesting a second nvim. The plugin on top is ~50 lines of Lua, and is also the discovery channel - lazy.nvim and dotfile repos reach exactly the people already running an agent beside their editor
- Custom TOML themes + live reload + `--theme-preview`; more lexers, or tree-sitter if language demand justifies it
- Turn timeline (`[t` / `]t`) and restore (`R`, `lgtm restore <path> --turn N`), both on the v0.2 snapshot store (SNAPSHOTS.md §5.3-5.4). Comparing any two turns is diff-of-diff with no extra machinery. Restore is the most dangerous action in the tool and gets the most friction: snapshot first, always show a confirmation diff, never restore more than was selected
- Desktop notifications, layer 3 (NOTIFICATIONS.md §2): opt-in, and it stays opt-in because it needs tmux `allow-passthrough` and silently no-ops without it

## Pre-1.0

- Git pager mode: stdin diff parsing, agent features absent (FEATURES.md §3)
- Docs, prebuilt binaries (macOS/Linux; Windows is an open question), README with GIF and measured numbers

---

## Cross-cutting rules (every phase)

The hard rules in CLAUDE.md apply to every line written. The ones easiest to violate accidentally while implementing:

| Rule                                                                  | Where it bites                                                    |
| --------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Byte offsets everywhere                                               | Phases 1, 2, 4; UTF-16 exists only in a future `lsp/position.zig` |
| Notes own their bytes, never arena pointers                           | Phase 2 onward; v0.2 notes                                        |
| `core/` imports no `ui/`/`bridge/`/terminal                           | Phases 1, 2                                                       |
| Only `io/fs.zig`/`io/proc.zig` import `std.fs`/`std.process`          | Every phase                                                       |
| `std.Io.Writer` construction stays in `io/tty.zig`; `ui/` receives it | Phases 0, 5                                                       |
| No `\n` through the bridge, no Enter, trailing space                  | Phase 6                                                           |
| `Wyhash` only, never cryptographic                                    | Phases 1, 2, 4                                                    |
| Instrument before optimising                                          | T1/T2 items wait for `--profile` evidence                         |

## Open questions mapped to phases

Raise these when the phase touches them; do not silently pick an answer.

| Question (source)                                                                    | Surfaces in                                                                           |
| ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| New files: full contents or summary (SPEC OQ2)                                       | Phase 2                                                                               |
| jj support (SPEC OQ1), multi-repo/worktrees (OQ3)                                    | Phase 2                                                                               |
| ~~Where the enclosing-function scan runs (ARCH OQ5)~~                                | **Answered in phase 4:** whole file, eagerly, per changed file. 0.5 ms for 6.4k lines |
| Reviewed-hunks persistence (SPEC OQ4), auto-`addressed` (OQ5), note categories (OQ6) | v0.2 notes                                                                            |
| Windows target (ARCH OQ4)                                                            | Pre-1.0                                                                               |
