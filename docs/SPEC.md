# `lgtm` - a TUI review companion for coding agents

> **Read it before you say it.**

**Status:** draft v0.2
**Last updated:** 2026-08-26
**Language:** Zig (pinned per release - see ARCHITECTURE.md)

---

## 1. One sentence

A terminal UI that runs beside your coding agent so you can **read** what it just changed and **point at exact lines** when you talk back to it.

The name is the point: `lgtm` is what you type *after* reviewing. This is the tool that lets you mean it.

---

## 2. Problem

The real loop when working with an agent CLI (Claude Code, Codex, OpenCode) looks like this:

1. The agent edits six files.
2. You want to see what it did → you open another editor, or scroll `git diff` in a pager.
3. You spot something wrong at `src/auth.rs:47`.
4. You **retype** the path and line number into the chat, or describe it in words: "the validate function, somewhere in the middle."

Steps 3–4 are the painful part. You are *looking directly at* the line you want to talk about, and there is no way to point at it. Every reference is retyped by hand, and a typo sends the agent to the wrong place.

A second, smaller but constant problem: the agent needs context that lives **outside the repo** - a schema from another service, a log file, a config in `~/.config`. Agent CLIs are confined to the working directory. You end up hunting for the path yourself and pasting it in.

---

## 3. Goals

| # | Goal | Measured by |
|---|---|---|
| G1 | Show the agent's diff **as it writes**, with no command to run | Diff updates < 500 ms after the write settles |
| G2 | Send a `file:line` reference to the agent in **two keystrokes** | Select → Enter → text is in the agent's input |
| G3 | Navigate the diff with **vim motions**, no mouse | A vim user learns nothing new |
| G4 | Find files across three scopes, **instantly**, including the whole machine | < 50 ms project, < 100 ms machine |
| G5 | Stay small. Survive an 80-column pane | RSS < 40 MB, cold start < 50 ms |
| G6 | Collect notes while reading and **send them in one batch** | Five notes → one submit, none lost or misaligned |

---

## 4. Non-goals

Deliberately out of scope for v1. Written down so scope creep has something to bounce off.

- ❌ **Not an agent.** No LLM loop, no model API calls. This tool reads and points.
- ❌ **No editing in v1.** No insert mode, no save. The agent edits; you review. Press `e` to open `$EDITOR` if you must. Deferred, not refused: §11 of ARCHITECTURE.md keeps it cheap to add, so this is a scheduling call that can be revisited once the review loop is solid.
- ❌ **No embedded terminal.** No PTY, no ANSI emulator. The agent runs in another pane; the multiplexer handles that.
- ❌ **No LSP.** See §7.
- ❌ **No plugin marketplace.**
- ❌ **No ACP in v1.** Read git, nothing else. See Roadmap.

---

## 5. The picture

```
┌─ tmux window ────────────────────────┬──────────────────────────┐
│ lgtm                                 │ claude                   │
│                                      │                          │
│ ▸ src/auth.rs        +24 -6      ●2  │ > I added token          │
│   src/routes/mod.rs  +3  -0          │   validation…            │
│   tests/auth_test.rs +41 -0      ●1  │                          │
│ ──────────────────────────────────── │ > #3 src/auth.rs:47-52 ▊ │
│ @@ #3  fn validate_token @@          │                          │
│  41   let claims = decode(&t)?;      │        ▲                 │
│  42                                  │        └── inserted here │
│ +47   if claims.exp < now() {        │            when you      │
│ ●48       return Err(Expired);       │            press Enter   │
│ +49   }                              │                          │
└──────────────────────────────────────┴──────────────────────────┘
   ● = a review note is anchored here
```

---

## 6. Feature spec

### 6.1 Diff view

- Source: `git diff` against HEAD (staged + unstaged). Agent-agnostic by construction.
- **Change detection:** v0.1 polls every 500 ms; v0.2 replaces it with native filesystem events. Either way, **debounce 200 ms before re-diffing** - agents write in bursts and often leave a file half-written for a few milliseconds. Without debounce you render torn states and the screen flickers.
- Only re-diff files that changed. Never re-diff the whole repo.
- Hunk headers show the **enclosing function name** (from the lexer's brace-depth scan, not git's regex heuristic) plus a **change id** (`#3`) for referring to it in conversation. See §6.5 for how ids stay stable.
- Layout: **no persistent file list.** One status row, then the diff to the bottom of the pane; files are reached with `]f` and the full list on `F`. Changed after the mockups (`lgtm TUI Mockups.dc.html`, option 2a): a list costs about five of twenty-six rows permanently, and navigation should not hold territory while you read. `file_list = "top" | "left"` remain supported (options 1a and 1b). `Tab` toggles a full-screen diff.
- Files with more than 5,000 changed lines render a summary; the diff loads lazily on open.

**Unified vs side-by-side - responsive**

```toml
[diff]
layout = "auto"        # auto | unified | split
split_min_width = 100  # below this, auto falls back to unified
```

The 100 comes from: each side needs ~5 (line number) + 1 (gutter) + ~42 (readable code) = 48, plus a divider. Below that, split is unreadable.

- `|` toggles manually, overriding `auto` for the session.
- **Re-layout on resize (SIGWINCH) must preserve cursor position and scroll offset.** This is the expensive part - mapping the cursor between two layouts - not the threshold check. Get it wrong and every pane resize loses the reader's place.
- Ship unified first (v0.2). Split lands in v0.3. Do not build both while the diff data model is still moving.

### 6.2 Navigation (vim motions, read-only)

| Key | Action |
|---|---|
| `h j k l` | move |
| `Ctrl-d` / `Ctrl-u` | half page |
| `gg` / `G` | top / bottom |
| `/` `n` `N` | search within the diff; `N` runs it backwards |
| `}` `{` | paragraph |
| `]h` / `[h` | next / previous hunk |
| `]f` / `[f` | next / previous file (wraps at either end) |
| `<Space>nf` / `<Space>pf` | next / previous file, leader aliases |
| `V` | visual line select |
| `zz` | center current line |
| `e` | open current line in `$EDITOR` |
| `q` | quit |

No insert mode. No `:` command mode in v1, except `:q`. No `?` reverse search: it is redundant with `/` plus `N`, and `?` belongs to the help popup (FEATURES.md 4.4).

File stepping wraps: `]f` from the last file lands on the first, `[f` from the first lands on the last, and the wrap is announced in the status line the way a wrapped search is. A review is a ring; stopping dead at the end reads as a dropped keystroke.

### 6.3 Chat bridge - core feature #1

With the cursor on a diff line:

- `Enter` → send `#3 src/auth.rs:47`
- `V` to select a range → `Enter` → send `#3 src/auth.rs:47-52`
- `y` → copy the reference to the clipboard
- `Y` → copy the reference **and** the line contents

**Inviolable rule: insert text, never press Enter.** The payload ends with a trailing space; the user types their question and decides when to submit. `lgtm` never submits on the user's behalf.

**Backends - a tagged union, selected by environment variable**

| Backend | Detect | Command | Notes |
|---|---|---|---|
| tmux | `$TMUX` | `tmux send-keys -t <pane_id>` | Cleanest. Build this first. |
| WezTerm | `$WEZTERM_PANE` | `wezterm cli send-text --pane-id N` | Equivalent to tmux |
| kitty | `$KITTY_WINDOW_ID` | `kitty @ send-text --match id:N` | Needs `allow_remote_control`; show setup hint when missing |
| Zellij | `$ZELLIJ` | `zellij action write-chars` | **Degraded** - see below |
| OSC 52 | always | escape sequence | Universal fallback |

**Zellij is the broken one.** `write-chars` only writes to the focused pane; it cannot address a specific one. Doing it properly means focus → write → refocus, which makes the screen jump. Decision: default to OSC 52 under Zellij, with `bridge.zellij_focus_hack = true` for anyone who wants it. Document the limitation instead of papering over it.

**OSC 52 rather than the system clipboard** as the fallback, because it works over SSH - the tool stays usable on a remote box. Cheap; ship it in v0.1.

**Choosing the target pane:** on first run, list the panes of the detected backend (`tmux list-panes -a -F "#{pane_id} #{pane_current_command}"`), show a picker, persist to `.lgtm/`. `Ctrl-t` changes it. A dead pane produces a clear error and reopens the picker.

**Ambiguous references in split view:** left is HEAD, right is the working tree. A cursor on a *deleted* line on the left has a line number that means nothing to the agent. Rule: **references always resolve against the new file**; on a deleted line, send the enclosing hunk's reference with a short note (`deleted lines in this hunk`).

### 6.4 File search - three scopes

`f` opens the fuzzy finder. `Tab` cycles scope:

| Scope | Contents | Purpose |
|---|---|---|
| **Changed** | files in the current diff | fast jumping while reviewing |
| **Project** | every file in the repo (respects `.gitignore`) | add in-repo context |
| **Machine** | the `look` index | **pull context from outside the repo** - schemas, logs, configs, other repos |

Machine scope is the one thing nothing else has. Claude Code, Zed, every agent CLI is confined to the working directory. That is the differentiator worth marketing - not "fast fuzzy finder."

Select a file → `Enter` sends its path to the agent; `o` opens it in `lgtm`.

### 6.5 Review notes - core feature #2

Collect remarks while reading, submit once. Instead of interrupting the agent five times, you review the whole change like a PR and send it all at once.

**Keys**

| Key | Action |
|---|---|
| `c` | add a note at the cursor line or selection (inline single-line input) |
| `Ctrl-e` | open `$EDITOR` for a longer note |
| `]c` / `[c` | next / previous note |
| `C` | open the notes panel for this session |
| `dc` | delete the note at the cursor |
| `Ctrl-s` | **submit all notes** to the agent |

Notes show as `●` in the gutter and fold inline beneath the anchored line.

**Change ids - the id is a label, the hash is what keeps it still**

Every hunk gets a short change id (`#1`, `#2`, …) shown in its header. This is what **the user and the agent actually say to each other** - "fix `#3`" is shorter and clearer than `src/auth.rs:47-52`.

But an id cannot survive on its own, because **a hunk is not an object with identity**: `git diff` recomputes hunks from scratch every run and has no memory that `#3` ever existed. Three ways plain sequence numbers break:

- **Merge** - two hunks less than 3 context lines apart collapse into one. `#3` and `#4` become a single hunk.
- **Split** - the agent reverts the middle, and `#3` becomes two hunks. A 1:1 mapping becomes 1:N.
- **Drift inside a hunk** - even with perfect hunk tracking, an insertion *within* the hunk above your line still shifts your offset.

So ids are **backed by a content hash**. On each re-diff, a new hunk matching an old `hunk_hash` inherits that id. On merge, the lower id wins and the other becomes an alias. On split, the original id follows the fragment with the most matching lines; the rest get new ids. No match → new id.

In short: **the id is for talking, the hash is what stops the id from lying.**

**Storage** - `.lgtm/notes.jsonl` in the repo (add to `.gitignore`). One note per line:

```json
{
  "id": "n7",
  "change_id": 3,
  "file": "src/auth.rs",
  "range": [47, 52],
  "anchor_hash": "b3f2…",
  "hunk_hash": "9ac1…",
  "body": "Use <= - a token expiring on this exact second still passes",
  "state": "open",
  "created_at": "2026-08-26T14:18:02Z"
}
```

**Re-anchoring (mandatory).** When the agent keeps editing, line numbers drift; storing line numbers alone is simply wrong. On every re-diff:

1. Search for `anchor_hash` within ±50 lines of the old position → on a match, update `range`.
2. No match → try `hunk_hash` and anchor to the hunk instead of the line.
3. Still nothing → `state = "stale"`, **surfaced separately in the notes panel, never silently dropped.** The user decides whether to keep or delete it.

This is how GitHub handles outdated review comments. Do not reinvent it.

**Submitting - write a file, send a path**

⚠️ **Never send note bodies through `send-keys`.** A newline in `send-keys` is interpreted as pressing Enter, so the agent submits mid-message and the remainder lands as garbage. This is a guaranteed bug, not a hypothetical one.

`Ctrl-s` instead:

1. Writes `.lgtm/review-<n>.md`:

````markdown
# Review 3 - 2026-08-26 14:22

## #3 - src/auth.rs:47-52
```rust
if claims.exp < now() {
```
Use `<=` - a token expiring on this exact second still passes.

## #7 - tests/auth_test.rs:12
Missing a case for an expired token.
````

2. Sends exactly **one line** through the bridge: `Please address the review notes in .lgtm/review-3.md `
3. Marks those notes `state = "sent"` and keeps them as history.

Side benefits: no length limit, and the review history lives on disk.

Snippets (1–3 lines by default, `notes.snippet_lines`) let the agent locate the code even if line numbers have moved.

**Non-goal:** not a team review system. No sync, no threading, no resolve/approve. A single-user scratchpad for one session.

### 6.6 Syntax highlighting

A hand-written lexer, not a parser. `lgtm` needs token colouring and the enclosing function name for hunk headers - neither requires a parse tree, and a lexer handles diff fragments (unbalanced braces, truncated functions) more gracefully than a parser, which falls into error recovery on exactly that input.

One generic lexer engine plus a small `LangDef` per language. v1 ships **Zig, Rust, Go, Python**; everything else renders as plain text without crashing. The highlighter is a tagged union, so tree-sitter can be added later for context-sensitive languages (JS/TS especially) without touching the call sites. See ARCHITECTURE.md §5.

Consequence worth stating: **v0.1 has no C dependency for highlighting**, links nothing, and adds ~50 KB to the binary.

Themes are shared with `look` (Catppuccin, Tokyo Night, Gruvbox, Dracula, Rosé Pine, Kanagawa) so the two tools look like siblings.

---

## 7. Why no LSP in v1

What people actually want from LSP *while reviewing* is "which function is this hunk in" - and the lexer already produces that from brace-depth tracking, at no extra cost. Go-to-definition sounds appealing but is used far less during diff review, and the cost is real: spawning and supervising servers, handshakes, crash recovery, per-language configuration. Poor trade.

Revisit as a plugin once the review experience is solid.

---

## 8. Roadmap

**v0.1 - useful to me**
Unified diff, 500 ms polling, vim motions, `Enter` sends a reference. Lexer highlighting for Zig/Rust/Go/Python. Bridge: tmux + OSC 52. No search, no notes. Zero C dependencies.
*Success test: you use it for a week without falling back to `git diff`.*

**v0.2 - useful to other people**
Review notes (`c` / `Ctrl-s`, re-anchoring, file-based submit). Native filesystem watching. Three-scope search (adds the SQLite dependency). Themes, config, pane picker. Bridge: WezTerm + kitty.

**v0.3 - finished**
Side-by-side with responsive layout. Stage/unstage hunks (`s` / `u`), revert a single agent hunk, session history. Zellij (degraded). More lexers, or tree-sitter if language demand justifies linking it.

**v1.0** - docs, prebuilt binaries for macOS/Linux/Windows, README with a GIF.

**Later, only if genuinely needed:** an ACP client - consuming the agent's individual edits rather than diffing snapshots, giving **truly stable change ids** (transforming note positions through each edit, OT-style) instead of inferring them from hashes. Expensive: it has to handle every edit that does *not* come from the agent (your own edits, `git checkout`, a formatter), and one missed step corrupts the whole chain. Content hashing gets 95% of the result for 5% of the work - only build ACP when that last 5% actually hurts. Also later: a standalone mode that spawns the agent itself.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Scope creeps into "writing an editor" | §4 is a hard boundary. Re-read it before adding anything. |
| Half-written files produce flickering diffs | 200 ms debounce. If still bad, require file size/mtime to be stable across two ticks. |
| 80 columns is not enough | Unified is the default and must be flawless at 80. Split is a bonus for wide panes. Test at 80 from day one. |
| Bridge inserts text while the agent is mid-run | Never send Enter. The user always owns submission. |
| Every multiplexer behaves differently | Tagged-union `Bridge` with OSC 52 as the floor. A broken backend degrades; it never blocks a release. |
| Notes drift after further edits | Re-anchor by content hash; never trust line numbers. No match → `stale` and visible, never silent. |
| Newlines in `send-keys` submit early | Submitting a review writes a file and sends **one line**. Never multi-line payloads. |
| Zig pre-1.0 churn breaks the build | Pin the compiler per project; isolate `std.Io` usage behind one module. See ARCHITECTURE.md §7. |

---

## 10. Open questions

1. Support jujutsu (jj) alongside git, or defer?
2. ~~Brand-new files created by the agent - show full contents or a summary?~~ **Answered: full contents, always, whatever the size.** A new file is entirely new code; summarising it removes the only thing there is to review. More generally, summarising is a rendering decision and never a discard: an oversized file defers its render but keeps its content reachable (SPEC 6.1 "loads lazily on open").
3. Multi-repo / worktrees: skip in v1?
4. Should "hunks I have already reviewed" persist across runs? Useful in long sessions. (Probably folds into the note anchoring machinery - it is the same problem.)
5. After submission, if a `sent` note's anchor changes, should it be auto-marked `addressed`? Wrong guesses mislead; right guesses make second-pass review much faster.
6. Should notes have categories (bug / question / nit), or stay untyped? Leaning untyped for v1.
7. Repo name vs binary name - the binary is `lgtm`; if search collisions with Grafana's LGTM stack prove annoying, the repo can be `lgtm-cli` without changing the command.
