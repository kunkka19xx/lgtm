# `lgtm` - Implementation plan

**Derived from:** SPEC.md, ARCHITECTURE.md, PERFORMANCE.md, FEATURES.md
**Status:** draft v0.1

Phases are ordered by the dependency graph (ARCHITECTURE.md §10), not the roadmap. Each phase has an exit gate; do not start the next phase until the gate passes. T0 performance items (PERFORMANCE.md) are built inside the phase that owns them, never retrofitted.

---

## Phase 0: Scaffold and instrumentation

No product code until the skeleton builds, tests, and measures.

- [ ] `.zigversion` (0.16.0), `build.zig`, `build.zig.zon` with `minimum_zig_version` and libvaxis pinned to a **main-branch commit hash**, not a release tag (ARCHITECTURE.md §5c; tags lag 0.16 and v0.5.0 announced breaking changes)
- [ ] `zig build` produces a stub binary; `zig build test` runs a test step covering all modules
- [ ] Baseline measurement of the empty vaxis binary: **size first** (that is the budget `zigimg` and uucode tables threaten), plus RSS and cold start. Measure before real code hides it (ARCHITECTURE.md §5c)
- [ ] `src/io/fs.zig` + `src/io/proc.zig`: the only files importing `std.fs` / `std.process`. fs: whole-file read in one `read()` into a caller-supplied arena. proc: run argv, capture stdout
- [ ] `src/io/tty.zig`: constructs the buffered `std.Io.Writer` handed to `vx.render()`. Writer construction lives in `io/`, never in `ui/` (ARCHITECTURE.md §5c)
- [ ] `src/io/metrics.zig` + `--profile` flag: comptime-gated timed spans, histogram dump on exit (PERFORMANCE.md §0, ~20 lines)
- [ ] `src/text/edit.zig`: `Position`, `Range`, `TextEdit`, all byte offsets
- [ ] `src/text/buffer.zig`: line-array `Buffer` over owned bytes; read-only; `apply()` returns `error.NotImplemented` (ARCHITECTURE.md §11.1)
- [ ] Full `Mode` enum (normal, visual, note_input, finder, insert, command) and `Event` union (key, files_changed, resize); one mutex+condvar event queue (ARCHITECTURE.md §11.4)
- [ ] SPDX header on every source file, enforced by a test or build step

**Gate:** `zig build` and `zig build test` pass; `--profile` prints.

## Phase 1: Anchor harness (the go/no-go gate)

Standalone, no terminal. This decides whether review notes are viable (docs estimate ~300 lines).

- [ ] Line interner: `Wyhash` string to `u32` id (PERFORMANCE.md §1.1)
- [ ] Window hashing: k=5 lines of interned ids, never single lines (PERFORMANCE.md §2.2)
- [ ] In-process line diff over interned ids with common prefix/suffix trimming (PERFORMANCE.md §1.2, §1.3; histogram preferred, simple algorithm acceptable behind the same interface): produces the exact old-to-new line map between previous and current buffer
- [ ] Primary re-anchor path: table lookup through the line map, O(1) per note (PERFORMANCE.md §3.1)
- [ ] Fallback tiers 1-5: exact window hash ±50 lines; whole-file window-hash multimap index; whitespace-normalised hash; token-multiset similarity; `hunk_hash`. Tier 6 = `stale` (PERFORMANCE.md §3.2). No edit distance, ever (§3.3)
- [ ] Harness: replays edit sequences from `tests/fixtures/`, reports hit rate and timing
- [ ] Fixtures: insert-above drift, in-hunk drift, formatter pass (indent change), hunk merge (<3 context lines apart), hunk split, revert-and-rewrite, plus at least one recorded real agent session

**Gate:** hit rate >= ~90% and 50 notes re-anchor in <= 5 ms. Below 90%: STOP, redesign review notes before writing any more code.

## Phase 2: Diff domain model

`core/diff.zig` + `core/hunk.zig`, still headless.

- [ ] One batched `git diff -- <paths>` subprocess, never per-file (PERFORMANCE.md §8.1); parse unified output
- [ ] HEAD-side content loaded into a `Buffer` (git cat-file/show); hunks stored as annotations pointing into the HEAD and worktree Buffers, never as diff text (ARCHITECTURE.md §11.1)
- [ ] `DiffLines` struct-of-arrays: `kind`, `old_no`, `new_no`, `text` (PERFORMANCE.md §7.3)
- [ ] `hunk_hash`; change-id assignment and inheritance: exact hash match first, then greedy max line-range overlap under the Phase 1 line map; merge keeps the lower id plus alias; split follows the fragment with most matching lines (SPEC.md §6.5, PERFORMANCE.md §4)
- [ ] `diff_cache` LRU keyed on content hashes, not paths (PERFORMANCE.md §7.2)
- [ ] Files with >5,000 changed lines: summary record, full parse deferred until opened

**Gate:** recorded `git diff` fixtures parse byte-exact; change-id stability tests pass for merge, split, and drift cases.

## Phase 3: File watching

`io/watch.zig`, polling only (docs estimate ~50 lines). Native backends are v0.2.

- [ ] Watch thread: 500 ms poll (one `git status --porcelain` style batch, not N stat calls)
- [ ] 200 ms debounce and burst coalescing inside the watch thread; emits a single `FilesChanged{paths}`; the main loop never sees a burst (ARCHITECTURE.md §3)
- [ ] Optional torn-write guard behind a flag: require size/mtime stable across two ticks (SPEC.md §9)

**Gate:** scripted burst of writes produces exactly one event after settling.

## Phase 4: Lexer

`syntax/`, pure function from bytes to token runs (docs estimate 200-400 lines engine, ~60 per language).

- [ ] `LangDef` comptime struct; generic engine: line/block comments, strings with escapes, keywords, `fn_decl` markers
- [ ] Token runs `{start: u32, len: u16, kind: u8}`, never per-character styles (PERFORMANCE.md §6.4)
- [ ] Brace-depth scan for the enclosing function name (feeds hunk headers)
- [ ] Checkpoints every 64 lines `{brace_depth, lex_state}`; lex any region from the nearest checkpoint; invalidate from first changed line (PERFORMANCE.md §6.2)
- [ ] `lang/rust.zig` first; then `go.zig`, `python.zig`; everything else renders plain without crashing
- [ ] `Highlighter` union `{lexer, tree_sitter, plain}` with `tree_sitter` unimplemented (ARCHITECTURE.md §5)
- [ ] Guard rails: >500 KB or >10k lines falls to plain; lex visible range plus margin; LRU token-run cache by content hash, ~32 files

**Gate:** fragment tests pass (unbalanced braces, truncated functions, half-written files); enclosing-function names correct on fixtures.

## Phase 5: TUI

`ui/` with libvaxis. First phase that needs a terminal. Test at 80 columns from day one.

- [ ] Main loop: drain event queue, re-diff only changed paths, inherit change ids, re-anchor (order fixed by ARCHITECTURE.md §3), render. Diff arena resets per re-diff, frame arena per render (ARCHITECTURE.md §4)
- [ ] Rendering via the libvaxis **low-level API only** (`Window.writeCell`, `child()` for sub-regions). Do not import `vxfw` (ARCHITECTURE.md §5c)
- [ ] Output through the `io/tty.zig` buffered writer passed into `vx.render()`: one flush per frame (PERFORMANCE.md §7.4)
- [ ] Per-frame regeneration must be cheap: `lex_cache` and `layout_cache` (PERFORMANCE.md §7.2) and lazy layout for visible rows plus margin (§7.5) are required, not optional. Vaxis's internal cell diff handles terminal output; app-side regeneration cost is ours
- [ ] Start by over-drawing the visible region each frame and letting the vaxis diff absorb it. Vaxis does not clear its cell buffer between frames, so row-level dirty tracking is available as a later option - do not build it until `--profile` shows the caches are insufficient (ARCHITECTURE.md §5c)
- [ ] Use `Window.gwidth()` for display width; never assume one byte or one codepoint equals one column
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

Order within v0.2 follows the same logic: core before UI.

1. Review notes: `core/notes.zig` (jsonl store, owned bytes, session allocator), note lifecycle open/sent/stale (ARCHITECTURE.md §8), `c` / `Ctrl-e` / `C` / `dc` / `]c [c`, gutter markers, `core/review.zig` renders `review-N.md`, `Ctrl-s` writes the file and sends exactly one line
2. Native filesystem watching behind the same `watch.zig` interface
3. Three-scope finder: SQLite reader for the `look` index (first C dependency, `schema_version` check, degrade with a message), fzf-style scoring, incremental narrowing (T0), bitmask prefilter, parallel top-k
4. Bridges: WezTerm, kitty (with `allow_remote_control` hint); pane picker UI + `Ctrl-t`
5. Config surface: keymap remapping with presets (vim/helix/emacs/plain), user `[templates]`, per-repo `.lgtm/config.toml` merged over the global file
6. Turn checkpoints (`m` / `a`, delta-since-mark view): same machinery as anchoring
7. Weakened-test detection banner (needs the lexer)

## v0.3 outline (finished)

- Side-by-side layout with responsive fallback below `split_min_width`; re-layout preserves cursor and scroll
- Stage/unstage hunks (`s`/`u`) and revert-a-hunk, both as `TextEdit` through `Buffer.apply()`
- Risk-ordered hunks with configurable rules; session history; Zellij (degraded, OSC 52 default)
- Custom TOML themes + live reload + `--theme-preview`; more lexers, or tree-sitter if language demand justifies it

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
| Where the enclosing-function scan runs (ARCH OQ5) | Phase 4/5, decide after measuring a 5k-line file |
| Reviewed-hunks persistence (SPEC OQ4), auto-`addressed` (OQ5), note categories (OQ6) | v0.2 notes |
| Windows target (ARCH OQ4) | Pre-1.0 |
