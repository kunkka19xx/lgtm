# `lgtm` - Dogfood log

**Companion docs:** PLAN.md, SPEC.md
**Status:** week 1, opened 2026-08-29

The v0.1 release gate is not a feature list. It is one sentence from PLAN.md:
_the author uses `lgtm` for a week without falling back to `git diff`_.

This file is the evidence for that, and it is where v0.2 gets decided. The plan
was written before anything was used; what goes below was written after. Where
the two disagree, this file wins.

## The rule

Reach for `lgtm` every time you would have typed `git diff`. **Every fallback is
a finding** - note what made you reach for git instead, not just that you did.

Do not fix things mid-week unless they block the work. A bug fixed on day one is
a bug whose shape you stop noticing, and the accumulated list is the point.

## The watchlist

Ten questions nobody has answered, roughly by how likely they are to bite.
Answer them in the log below rather than here; tick one only when a week of use
has actually settled it.

- [ ] **Cursor-follow.** Wired the day before this file opened. When the agent
      rewrites the file under you, does the cursor land where you were
      _reading_? The measurement says line 22 becomes line 25; the question is
      whether that is what it feels like at speed.
- [ ] **Re-diff hitch.** Worst case measured at 107 ms on a 40-file change, on
      the main thread, against a 100 ms budget. Does a big agent turn produce a
      stall you can feel, or does the 500 ms poll plus 200 ms debounce hide it?
- [ ] **Pane inference.** It refuses to guess past two panes (`soleOther`). If a
      real layout has three, every session needs `--pane %N`. This is the most
      likely daily annoyance in the whole tool.
- [ ] **80 columns.** Tested there, but a real split pane is the judge.
- [ ] **The character cursor.** `h l w b e`, `f t F T`, and `v` for a charwise
      selection. Does pointing at a word actually beat pointing at a line when
      the agent reads the line either way? And do the three moved keys (`e`,
      `t`, `F`) cost more than the motions are worth?
- [ ] **Soft wrap.** On by default. Does a wrapped continuation read as part of
      the line above it, or does the diff start to look like prose? `zw` is
      there for the second answer - if it gets pressed daily, the default is
      wrong.
- [ ] **Discoverability.** The strip is down to `:q quit  ? help`. Is `?` enough,
      or is there hunting?
- [ ] **Dead weight.** Zen mode, the file list, search, and the four ask presets
      (`a ! t x`) all exist. Which get used? Anything untouched after a week is a
      candidate for deletion, not for polish.
- [ ] **Torn reads.** `file changed while reading, re-diffing` should fire when
      the agent writes mid-read. Does it appear at all, and is it useful or
      noise?
- [ ] **Large files.** Deferred rendering exists above `large_file_lines`. Does
      it ever trigger in real work?
- [ ] **Terminal quirks.** macOS `poll` answering `POLLNVAL` for `/dev/tty` is
      fixed. Anything else off with keys, resize, or the clipboard?
- [ ] **The premise.** Does pointing at lines actually change how you reply to
      the agent, or do you keep typing prose at it?

Two `SPEC.md` open questions will answer themselves if they come up: **jj
support** (OQ1) and **multi-repo / worktrees** (OQ3). Neither needs chasing.

## What counts as a finding

Worth writing down: anything that made you fall back to git, any keystroke that
did not do what you expected, anything you wanted and reached for out of habit,
anything you never once used, and any number that felt wrong even if the profile
says it is fine.

Not worth writing down: ideas for features you have not missed while using it.

## Log

### 2026-08-29 - day 0

Installed `zig build dist` (603 KB) to `~/.local/bin/lgtm`. Nothing used yet.

<!-- Append dated entries. Keep them short and specific: what happened, what you
     expected, what you did instead. A measurement beats an adjective. -->
