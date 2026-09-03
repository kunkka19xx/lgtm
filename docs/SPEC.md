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
| G6 | Collect comments while reading and **send them in one batch** | Five comments → one submit, none lost or misaligned |

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
   ● = a review comment is anchored here
```

---

## 6. Feature spec

### 6.1 Diff view

- Source: `git diff` against HEAD (staged + unstaged). Agent-agnostic by construction.
- **Change detection:** v0.1 polls every 500 ms; v0.2 replaces it with native filesystem events. Either way, **debounce 200 ms before re-diffing** - agents write in bursts and often leave a file half-written for a few milliseconds. Without debounce you render torn states and the screen flickers.
- Only re-diff files that changed. Never re-diff the whole repo.
- Hunk headers show the **enclosing function name** plus a **change id** (`#3`) for referring to it in conversation. See §6.5 for how ids stay stable. The name is still git's own guess, the text after the second `@@` - replacing it with the lexer's brace-depth scan is **not built**, and is worth doing only once the guess is visibly wrong often enough to notice.
- Layout: **no persistent file list.** One status row, then the diff to the bottom of the pane; files are reached with `]f` and the full list on `<Space>f` - an overlay, not a pane, so it costs rows only while it is open (both shipped). Changed after the mockups (`lgtm TUI Mockups.dc.html`, option 2a): a list costs about five of twenty-six rows permanently, and navigation should not hold territory while you read. `file_list = "top" | "left"` (options 1a and 1b) were left as future config and **are not read today** - the overlay made them a preference nobody asked for. `Tab` is zen mode: it hides the chrome and gives the diff the whole pane.
- Files with more than 5,000 changed lines render a summary row instead of a body; `zo` opens one and `zc` folds it again. Deferring is a rendering decision and never a discard: `core/diff.zig` keeps the file's byte range in git's output and parses it on demand. An opened file stays open across re-diffs - `ui/review.zig` remembers the path and materialises it again before the buffers are attached, because a file that folded itself every time the agent wrote would be unreadable exactly while it was worth reading.

**Unified vs side-by-side - responsive. Not built; v0.3.** The block below is the shape it should take, not a key the config reads today.

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
| `h j k l` | move: a character sideways, a line up or down |
| `w` / `b` / `e` | next / previous word, end of word - a change of character class is a boundary; `w` and `b` carry into the neighbouring line |
| `W` / `B` / `E` | the same over WORDs, where only blanks are a boundary, so a path or a whole call is one step |
| `0` / `^` / `$` | first column / first non-blank / last column |
| `f` `t` `F` `T` | to, or up to, a character on this line; `;` and `,` repeat it |
| `Ctrl-d` / `Ctrl-u` | half page |
| `gg` / `G` | top / bottom |
| `/` `n` `N` | search within the diff; matches light up as the query is typed; `N` runs it backwards |
| `<Space>f` | the changed files; `Enter` goes to one |
| `<Space>F` | every file in the project; `Enter` opens it. A file with a diff opens in the review; one without opens **whole**, every line context, outside the review - readable, notable, and referenceable, which is what a file browser is for. `]f` or `<Space>f` returns to the review |
| `<Esc>` `:noh` | clear the search highlight, keeping the pattern for `n` |
| `m` | mark the working tree as read; every change after this shows a bar in the gutter. `<C-s>` marks too - submitting a review is the one moment the reader has read all of it - which `[nav] mark_on_submit` turns off |
| `]m` / `[m` | next and previous change since the mark, wrapping across the whole review. `<Space>nm` and `<Space>pm` are the leader spellings. By row rather than by hunk: what the reader came back for is the lines that answer the last comment, and a hunk containing one of them is a coarser answer |
| `M` / `:nomark` | drop the mark. The review reads as one whole change again - which it always was: the mark annotates, it never hid a row, so this removes marks rather than revealing anything |
| `zi` | show the files `[review] ignore` hides, and hide them again |
| `zo` / `zc` | open a file too large to render inline, and fold it again. `zc` re-diffs rather than filtering, for the same reason `zi` does: git decided the file was large, so git is what gets asked again |
| `<Space>c` | write a comment on this line |
| `<Space>vc` | open the nearest comment to read or edit |
| `<Space>lc` | list every comment in the review; the filter reaches the file, the line **and** the text, so typing part of a remark finds it. `<C-s>` sends the highlighted one, `<C-x>` sends every open one as the review file (not `<C-a>`: it is the most common tmux prefix after `C-b`, so it never reaches an application running under one), `<C-d>` deletes it. `Enter` goes to it - to its row in the diff when the line is still drawn, and
**to the file itself when it is not**. A diff draws hunks, not files, so a line
someone commented on stops being drawn as soon as the change around it is
reverted or re-shaped; the comment is still perfectly good and "nothing
happened" is the one answer that tells the reader nothing. A comment that is
`[sent]` or `[stale]` says so, because neither has a dot in the gutter and a list showing four when two are visible has to explain itself |
| `<Space>sc` | send this one comment to the agent on its own, through the compose box. Works on a comment that has already been sent: asking twice is sometimes the point, and refusing would make the tool the judge of that |
| `<Space>dc` | delete the comment here - the one on this line, or the one whose row the cursor is on |

`[ui] comments` chooses how a comment shows. `marker`, the default, is the gutter dot
alone: a diff is dense already, and prose spliced between two lines of code
puts sentences where the reader is scanning structure. `<Space>vc` is one
keystroke away and opens the comment in a box big enough to edit it in. `inline`
draws the text under its line for readers who would rather have it in front of
them; inline comments are rows like any other, so they scroll, wrap, and the
motions step past them the way they step past a hunk header.

**Every comment key is behind the leader,** because bare `c`, `C` and `dc` are
vim's change operators - the most-used keys after `d` - and editing is designed
for rather than out (ARCHITECTURE.md 11). `c` after the leader keeps the
mnemonic without owing the debt.

**They are "comments", not "notes".** `comment` is what every review tool calls
the thing you write on a line, and `c` is only a sensible key if that is what
the thing is called. The cost is that `comment` also names a *source* comment
in the lexer and the theme; the code keeps them apart by suffix -
`theme.comment` is the syntax colour, `theme.comment_open` is the review
marker - and `.lgtm/notes.jsonl` is still read once and rewritten as
`comments.jsonl`, so renaming the idea does not lose anyone's remarks.
| `]c` `[c` `<Space>nc` `<Space>pc` | next and previous comment; **wraps** at either end, the way `]h` and `]f` do. It walks *every* comment, not only the ones on files the review still contains - a comment outlives the change it was written against, and a walk that could not reach those was a walk that hid them. The changed files come first, in review order, then everything else by path |
| `<Space>nc` `<Space>pc` | the leader spellings of those, as `<Space>nh` is of `]h` |
| `<Space>vc` | open the nearest comment to read or edit - the one under the cursor if there is one, otherwise the closest in this file |
| `<C-s>` | every open comment as one file: write `.lgtm/review-N.md` and send one line naming it |

`<C-s>` works from inside the comment box too, where it saves *and* sends that
one comment: a remark that cannot wait should not have to be typed, saved,
found again and sent. It counts as sent, so it drops out of the next
`review-N.md` rather than asking twice, and editing it reopens it.

Two ways out, and they are for different moments. `<C-s>` is the batch the tool
is built around - a dozen remarks is a dozen interruptions, or it is one file.
`<Space>sc` is for the remark that cannot wait for the batch: one line, the
reference and the text, into the box where it can be edited before it goes.

Comments live in `.lgtm/comments.jsonl` and outlive the process, which is the whole
point of `.lgtm/` (ARCHITECTURE.md 1). Two mechanisms keep them on the right
line, because they answer different questions. **Within a session**, every
re-diff carries them through a line map (PERFORMANCE.md 3.1) - both versions of
the file exist at that moment, so the answer is a lookup. **Across a restart**
there is no previous version to diff against: the file may have been rewritten
while lgtm was not running. Each comment therefore stores the text of the line it
was written against, and the first diff of a session finds that line again -
the nearest occurrence, so a line that appears twice does not drag the comment to
the top of the file. A line that is nowhere leaves the comment stale rather than
somewhere plausible and wrong.
| `}` `{` | paragraph - **not built.** What a paragraph is in a diff needs deciding first: blank-line delimited within the file, or the hunk, which `]h` already walks |
| `]h` / `[h` | next / previous hunk, across the whole review |
| `<Space>nh` / `<Space>ph` | next / previous hunk, leader aliases |
| `]f` / `[f` | next / previous file (wraps at either end) |
| `<Space>nf` / `<Space>pf` | next / previous file, leader aliases |
| `v` / `V` | visual select, by character or by line; either switches to the other |
| `zz` | center current line |
| `zw` | soft wrap on / off |
| `<Space>e` | open current line in `$EDITOR` |
| `q` | quit |
| `?` | help popup: every key live in the current mode, fuzzy-filtered as you type, `HJKL` or arrows to move: `J`/`K` a row, `H`/`L` a column |

**Word motions cross lines, and know what a line is.** `w`, `b`, `e` and their capitals carry into the neighbouring diff line rather than stopping at the end of one, which is what vim does and what a hand expects. Two rules come with that: a hunk header is not a word, so the motions step over it; and an empty line *is* a word, so `w` and `b` stop on one - but `e` and `E` pass over it, because an empty line has no word end for a cursor to sit on. `gg` lands on the first line for the same reason: it says "first line", and row zero is a hunk header.

**The viewport catches up rather than teleporting.** A jump - `<C-d>`, `]h`, `gg`, a search landing - travels into place instead of the screen changing between one frame and the next, which is what makes it possible to see *where* you went rather than only that you went.

**One screen row per frame is the floor, and it is also the ceiling.** Half a row cannot be drawn, so a row per 60 Hz frame is the finest motion a cell grid can express; the animation moves at constant speed with that as its minimum, and `ui.scroll_ms` (default 250) only bounds how long a *long* jump may take before it starts moving more than a row at a time. An ease-out curve was tried first and is worse for exactly this reason - it spends its opening frames moving four and five rows, which reads as a jump, and its closing frames moving less than a row, which the terminal cannot draw at all.

**The cursor travels for every motion.** `h l w b e`, `f t F T`, `j k`, a page key, a hunk jump - the block moves to where the motion put it a cell at a time rather than appearing there, at one cell per frame with `ui.cursor_ms` (default 80) bounding a long hop. A `w` of four columns is four frames of travel: not much, and far more than none. It travels in screen cells rather than in rows and byte offsets, which is the space a column, a wrapped line and a scrolling viewport all move it through - so one chase handles the three of them. Only the *drawn* block lags: every reference, every send and every motion resolves against where the cursor actually is.

**The viewport is the part that only animates for a jump - never for a step.** `<C-d>`, `]h`, `gg`, `zz` and a search landing take you somewhere you asked to go; `j`, `k` and the word motions move the view only because the cursor walked off the edge of it, and those are always instant. With soft wrap a single `j` can cross three screen rows, so animating a step would start a fresh animation on every keystroke and a held `j` would spend its life cancelling the last one - which reads as stutter and costs a frame of input latency per key on top of it. A jump further than two screens is a teleport in intent and is left as one; a second jump arriving mid-flight joins the first rather than queueing behind it; anything that is not a jump arrives at once. `ui.scroll_ms = 0` turns it off.

**This is as smooth as a terminal gets, and that is a hard ceiling.** A GPU frontend like Neovide owns pixels and can slide a viewport sub-pixel; an application drawing into any terminal writes cells, and a cell is the smallest thing that can move. Beating it would mean rasterising our own glyphs and pushing them through the kitty graphics protocol - becoming a font renderer, for one family of terminals. Cursor motion is not animated at all for the same reason: a word motion covers three or four cells and there is nothing to put between them.

**The cursor is a character, not a line.** It is a `(row, column)` pair drawn as the terminal's own cursor inside the line highlight, and the column survives a vertical motion the way vim's `curswant` does: down through a short line and back onto a long one returns to where the eye was, not to the short line's end. Word motions treat a change of character class as a boundary, so `w` steps through `foo.bar(baz)` a piece at a time. What the column is *for* is §6.3: pointing at a word rather than at a line.

**A line wider than the pane wraps rather than being cut.** The continuation sits under the gutter with no sign and no line number, so a wrapped line still reads as one line of the file, and the cursor highlight covers every row of it. The row model does not change: `j` moves a line of the file, not a row of the screen, and a selection is still a range of lines - wrapping is a rendering decision, which is what makes `zw` free to turn it off (`ui.wrap = false` for the default). Off, a long line is clipped at the edge, which is what a reader comparing the *shape* of two versions wants. Rows are broken at the last space that fits; a word longer than the pane is broken where the columns run out.

No insert mode. No `:` command mode in v1, except `:q` and `:noh` - the second because a search highlight with no way off the screen is a search you stop using. `<Esc>` does the same thing and is the discoverable half: it was unbound in normal mode, and the highlight is the only thing there to cancel. Both keep the pattern, so `n` still works and repaints, which is vim's split exactly. No `?` reverse search: it is redundant with `/` plus `N`, and `?` belongs to the help popup (FEATURES.md 4.4).

**Matches highlight while the query is being typed**, vim's `incsearch`. It earns its place by answering two questions a keystroke earlier than Enter would: whether the query is already unambiguous, and whether it matches anything at all - a query that has gone one character too far goes dark while there is still a backspace left to fix it. The cursor does **not** preview-jump to the first match yet; the highlight is the half that costs nothing and cannot lose the reader's place.

Hunk and file stepping both wrap. `]h` walks every hunk in the review, crossing into the next file at the end of one - the status line already counts hunks across all files ("4 of 17"), so stopping at a file boundary would leave the primary motion unable to reach most of what it advertises. It wraps only at the far end of the last file. `nav.hunk_crosses_files = false` keeps hunk motions inside the current file, wrapping there instead. `]f` from the last file lands on the first, `[f` from the first lands on the last, and the wrap is announced in the status line the way a wrapped search is. A review is a ring; stopping dead at the end reads as a dropped keystroke.

### 6.3 Chat bridge - core feature #1

With the cursor on a diff line:

- `Enter` → open the compose box on `#3 src/auth.rs:47`; Enter again sends it
- in a file with no hunks - one opened with `<Space>F` and read rather than reviewed - the reference is `src/auth.rs:47` with no `#id`. The id is a claim that the hunk changed, and inventing one for a file that did not change would say something untrue; the line is real either way
- **the box is modal.** `<Esc>` leaves insert for normal; a second `<Esc>` leaves the box. Normal mode has the motions the review has - `h l w b e W B E 0 ^ $ f t F T`, plus `j k` over the lines the box holds - and `i a I A o O x D C dd cc d{motion} c{motion} u`. It exists because the terminal made the alternative worse: `Shift-Enter` cannot be told from `Enter` without the kitty protocol *and* a tmux with `extended-keys on`, while `o` needs a terminal that can send `o`. Modality is how vim solved this in 1976 and the problem has not changed
- in the box: `@` mention any file in the project - changed ones first, then everything else git tracks or does not ignore, capped at 50,000 (PERFORMANCE.md 9b) - `Ctrl-i` insert a preset at the caret, `Ctrl-j` line break, `Ctrl-a/e/u/w` readline editing, `<Esc>` abandon
- **those keys are bindings, the motions are not.** Everything the box does that is not typing or a motion is a named command in `Modes.compose_only` - `compose_submit`, `compose_cancel`, `compose_send_now`, `compose_presets`, `compose_mention`, `compose_newline` - so `[keys]` moves them, and the box's footer and its rows in `?` are generated from the same bindings rather than written out. The motions stay vim's, and not only because they are vim's: in a text box every printable key is data, so a keymap able to bind `x` is one able to take `x` away from typing. Two rules follow - a compose binding is a **single chord**, because a box cannot hold a prefix while the next key is probably a letter someone is typing; and a **pending operator outranks the keymap**, so with `d` waiting `<Esc>` cancels the operator rather than the box
- `V` to select a range → `Enter` → send `#3 src/auth.rs:47-52`
- `v` to select within one line → `Enter` → send ``#3 src/auth.rs:47 `verify_token` ``
- `y` → yank the selected text (the characters under `v`, the lines under `V`, the cursor line with no selection)
- `Y` → yank whole lines, whatever `v` selected - vim's linewise yank
- with **nothing to review**, `Enter` still opens the box, empty. A clean tree is where a review pane spends most of its day, and talking to the agent is a thing to want there; requiring a change first would be the tail wagging the dog. The prompt and any notice are drawn over the empty screen too, so `:q` is not typed blind
- `<Space>a` → open the box **with the question list already up**. It was four keys carrying four fixed questions; the questions moved into `[presets]`, where they are the user's own and there can be any number of them, so one key that opens the list beats four that each hard-code a row of it. Nothing is inserted until a question is chosen
- `<Space>y` → copy the reference to the clipboard
- `<Space>Y` → copy the reference **and** the line contents

`y` carried the reference until day 3 of the dogfood week, and it was the wrong
key for it. The tool advertises vim motions, `y` is the most-known key in vim
after `hjkl`, and the surprise was silent: nothing looks wrong until the paste
lands somewhere else, by which time the selection is gone. Pointing at code
already had its own key (`Enter`), so `y` did not need to carry it too. The
yanked text drops the diff's sign column, because code pasted into an editor
should still compile.

**A charwise selection sends the words, not the columns.** `47:12` is no use to an agent - it does not count columns, it reads the line - so the reference carries the selected text instead, which is what a human would have said. Only within one line: across two, the text would have to carry the newline between them, and that is what hard rule 1 forbids, so a selection that grows past a line falls back to the line range it always was.

**Inviolable rule: insert text, never press Enter.** The payload ends with a trailing space; the user types their question and decides when to submit. `lgtm` never submits on the user's behalf.

**Backends - a tagged union, selected by environment variable**

| Backend | Detect | Command | Notes |
|---|---|---|---|
| tmux | `$TMUX` | `tmux send-keys -t <pane_id>` | **Built.** Cleanest. Also carries the clipboard: `load-buffer -w -`, because tmux's default `set-clipboard external` swallows an application's OSC 52 |
| WezTerm | `$WEZTERM_PANE` | `wezterm cli send-text --pane-id N` | v0.2. Equivalent to tmux |
| kitty | `$KITTY_WINDOW_ID` | `kitty @ send-text --match id:N` | v0.2. Needs `allow_remote_control`; show setup hint when missing |
| Zellij | `$ZELLIJ` | `zellij action write-chars` | v0.3, **degraded** - see below |
| OSC 52 | always | escape sequence | **Built.** Universal fallback |

**Zellij is the broken one.** `write-chars` only writes to the focused pane; it cannot address a specific one. Doing it properly means focus → write → refocus, which makes the screen jump. Decision: default to OSC 52 under Zellij, with `bridge.zellij_focus_hack = true` for anyone who wants it. Document the limitation instead of papering over it.

**OSC 52 rather than the system clipboard** as the fallback, because it works over SSH - the tool stays usable on a remote box. Cheap; ship it in v0.1.

**Choosing the target pane:** on first run, list the panes of the detected backend (`tmux list-panes -a -F "#{pane_id} #{pane_current_command}"`), show a picker, persist to `.lgtm/`. `Ctrl-t` changes it. A dead pane produces a clear error and reopens the picker.

**Ambiguous references in split view:** left is HEAD, right is the working tree. A cursor on a *deleted* line on the left has a line number that means nothing to the agent. Rule: **references always resolve against the new file**; on a deleted line, send the enclosing hunk's reference with a short note (`deleted lines in this hunk`).

### 6.4 File search - three scopes

| Scope | Key | Contents | Purpose |
|---|---|---|---|
| **Changed** | `<Space>f` | files in the current diff | fast jumping while reviewing |
| **Project** | `<Space>F` | every file the repo tracks or could (`git ls-files --cached --others --exclude-standard`) | add in-repo context |
| **Machine** | v0.2 | the `look` index | **pull context from outside the repo** - schemas, logs, configs, other repos |

Two of the three are built, each on its own key rather than behind a `Tab` that
cycles: the scopes turned out to be different questions, not one question with a
setting. "Where in this review" and "where in this repo" get asked at different
moments, and a cycle makes the second one cost a keystroke and a glance at which
mode you are in.

Machine scope is the one thing nothing else has. Claude Code, Zed, every agent
CLI is confined to the working directory. That is the differentiator worth
marketing - not "fast fuzzy finder." It is also the one that costs a
dependency, which is why it waits for v0.2.

`Enter` opens the file: in the review if it has a diff, whole and outside the
review if it does not. `@` in the compose box runs the same overlay to insert a
path into what you are writing.

### 6.5 Review comments - core feature #2

Collect remarks while reading, submit once. Instead of interrupting the agent five times, you review the whole change like a PR and send it all at once.

The keys are in 6.2 with the rest of the keymap, not repeated here: a second
table is a second thing to keep true, and this one had gone stale - it still
named `c`, `C` and `dc`, which were given to the motions when it became clear
the tool would edit one day. What follows is the part that is not keys.

Comments show as `●` in the gutter; `[ui] comments = "inline"` folds the body
beneath the anchored line as well.

**Change ids - the id is a label, the hash is what keeps it still**

Every hunk gets a short change id (`#1`, `#2`, …) shown in its header. This is what **the user and the agent actually say to each other** - "fix `#3`" is shorter and clearer than `src/auth.rs:47-52`.

But an id cannot survive on its own, because **a hunk is not an object with identity**: `git diff` recomputes hunks from scratch every run and has no memory that `#3` ever existed. Three ways plain sequence numbers break:

- **Merge** - two hunks less than 3 context lines apart collapse into one. `#3` and `#4` become a single hunk.
- **Split** - the agent reverts the middle, and `#3` becomes two hunks. A 1:1 mapping becomes 1:N.
- **Drift inside a hunk** - even with perfect hunk tracking, an insertion *within* the hunk above your line still shifts your offset.

So ids are **backed by a content hash**. On each re-diff, a new hunk matching an old `hunk_hash` inherits that id. On merge, the lower id wins and the other becomes an alias. On split, the original id follows the fragment with the most matching lines; the rest get new ids. No match → new id.

In short: **the id is for talking, the hash is what stops the id from lying.**

**Storage** - `.lgtm/comments.jsonl` in the repo (lgtm ignores `.lgtm/` itself, so nothing need be added to `.gitignore`). One comment per line:

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
3. Still nothing → `state = "stale"`, **listed as stale by `<Space>lc` and marked stale in the review file, never silently dropped.** The user decides whether to keep or delete it.

This is how GitHub handles outdated review comments. Do not reinvent it.

**Submitting - write a file, send a path**

⚠️ **Never send comment bodies through `send-keys`.** A newline in `send-keys` is interpreted as pressing Enter, so the agent submits mid-message and the remainder lands as garbage. This is a guaranteed bug, not a hypothetical one.

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

2. Sends exactly **one line** through the bridge: `review ready: .lgtm/review-3.md (4 comments) ` - the one outgoing string that is still a format literal rather than a `bridge/template.zig` entry
3. Marks those comments `state = "sent"` and keeps them as history.

Side benefits: no length limit, and the review history lives on disk.

**Not built:** snippets - a line or three of the code around each comment, so the agent can locate it even if the line numbers have moved. The review file carries the path, the line and the remark today.

**Non-goal:** not a team review system. No sync, no threading, no resolve/approve. A single-user scratchpad for one session.

### 6.6 Syntax highlighting

A hand-written lexer, not a parser. `lgtm` needs token colouring and the enclosing function name for hunk headers - neither requires a parse tree, and a lexer handles diff fragments (unbalanced braces, truncated functions) more gracefully than a parser, which falls into error recovery on exactly that input.

One generic lexer engine plus a small `LangDef` per language. The plan was **Zig, Rust, Go, Python**; what shipped is those four plus JavaScript, TypeScript, Swift, HTML and CSS, because once the engine existed a language was a table rather than a lexer. Everything else renders as plain text without crashing. The highlighter is a tagged union, so tree-sitter can be added later for context-sensitive languages (JS/TS especially) without touching the call sites. See ARCHITECTURE.md §5.

Consequence worth stating: **v0.1 has no C dependency for highlighting**, links nothing, and adds ~50 KB to the binary.

Themes are shared with `look` (Catppuccin, Tokyo Night, Gruvbox, Dracula, Rosé Pine, Kanagawa, plus `terminal`, which paints nothing and lets the emulator's own sixteen colours through) so the two tools look like siblings.

---

## 7. Why no LSP in v1

What people actually want from LSP *while reviewing* is "which function is this hunk in" - and the lexer already produces that from brace-depth tracking, at no extra cost. Go-to-definition sounds appealing but is used far less during diff review, and the cost is real: spawning and supervising servers, handshakes, crash recovery, per-language configuration. Poor trade.

Revisit as a plugin once the review experience is solid.

---

## 8. Roadmap

**v0.1 - useful to me** (shipped)
Unified diff, 500 ms polling, vim motions, `Enter` opens the compose box and sends a reference. Lexer highlighting for nine languages. Bridge: tmux + OSC 52. Zero C dependencies.
*Success test: you use it for a week without falling back to `git diff`.*

Three things arrived earlier than this plan expected, because each turned out to be cheap once the thing under it existed: **review comments** (`<Space>c` / `Ctrl-s`, re-anchoring, file-based submit) came with `core/anchor.zig` already written and tested; **themes, config and `[keys]` remapping** came with the command-name indirection that was mandatory from day one anyway; the **compose box** came out of `ui/motion.zig`, which the review already needed. Read the milestones below as what is *not yet built*, not as a record of what was.

**v0.2 - useful to other people**
Native filesystem watching. Three-scope search (adds the SQLite dependency). Pane picker. Bridge: WezTerm + kitty.

Turn checkpoints (`m`, FEATURES.md 1.3) shipped in v0.1 too, and took 1.4 with them: once `core/anchor.zig` existed the feature was one small module and a gutter column.

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
| 80 columns is not enough | Unified is the default and must be flawless at 80. Split is a bonus for wide panes. Test at 80 from day one. Long lines soft wrap (§6.2), so a narrow pane loses no content. |
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
4. Should "hunks I have already reviewed" persist across runs? Useful in long sessions. (Probably folds into the comment anchoring machinery - it is the same problem.)
5. After submission, if a `sent` comment's anchor changes, should it be auto-marked `addressed`? Wrong guesses mislead; right guesses make second-pass review much faster.
6. Should comments have categories (bug / question / nit), or stay untyped? Leaning untyped for v1.
7. Repo name vs binary name - the binary is `lgtm`; if search collisions with Grafana's LGTM stack prove annoying, the repo can be `lgtm-cli` without changing the command.
