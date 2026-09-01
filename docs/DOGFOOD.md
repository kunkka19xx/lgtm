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
- [ ] **The travelling cursor.** Every motion moves it a cell at a time. Does
      it help you keep track of where you went, or is it a block sliding around
      in the way? `ui.cursor_ms = 0` is the answer if it is the second.
- [ ] **Smooth scrolling.** One screen row per frame, 250 ms budget for a long
      jump. Too slow, too fast, or in the
      way? `ui.scroll_ms` tunes it and `0` turns it off - if that gets set to
      zero in the first hour, the default is wrong. Watch it over SSH too: an
      animated frame repaints the whole body.
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

### 2026-09-01 - day 3

Three findings, all from using it in the `look` repo rather than from testing it.

**`.lgtm/target` shows up in its own review.** The first send writes the pane id
into `.lgtm/`, git reports it as untracked, and lgtm renders it as a changed
file - `+1 %102`, one line, sitting between real files at 7/8. The tool adding
noise to the diff it exists to keep clean, in the first five minutes.

Fixed rather than logged-and-left, because it is the first thing a new user
would see and it costs them a `.gitignore` edit to a file lgtm does not own.
`.lgtm/.gitignore` is now written by lgtm itself (`*`, then `!config.toml`, so a
repo can still commit its own config). Two things that were wrong on the first
attempt and are worth remembering: a blanket `.lgtm/` cannot work, because git
does not descend into an excluded directory and a negation underneath one does
nothing; and `!.gitignore` put the ignore file straight back into the review,
which is the noise it was written to remove.

The migration is the part that was nearly missed. Writing the ignore only on the
write path is not enough: the pane id is saved only when it *changes*, so a repo
whose target is still correct never writes again and would have stayed noisy
for good. It is now written at startup too.

**Search: `n` lands on the line, not on the match.** `/` finds the right line and
the cursor arrives on it, but at whatever column `want_col` was carrying, so on a
long line the cursor is nowhere near the text that matched. Vim puts it on the
first character of the match, which is what makes `n` readable at speed - you
follow the cursor, not the highlight.

Root cause is in the code rather than in the feel: `search.contains` returns a
bool and throws away the offset it has just computed, `findLine` returns a line
index only, and `searchStep` calls `moveTo(row)`, which sets the column from
`want_col`. The offset never reaches the caller. `ui/body.zig` has a second copy
of the same case-insensitive scan (`indexOfMatch`) that already computes the
offset for highlighting, so the fix collapses two scans into one.

**`y` says "copied to the clipboard" and the clipboard is empty.** Selected
lines, pressed `y`, got the notice, pasted nothing.

Root-caused, and it was never lgtm's encoder. A bare probe from the pane -
`printf '\033]52;c;%s\033\\' "$(printf probe | base64)"` - left the clipboard
untouched, so OSC 52 from inside a pane does not reach macOS here at all.

The cause is tmux's **default**, not a local misconfiguration: `set-clipboard`
is not in `~/.tmux.conf`, and its built-in default `external` means *tmux may
set the terminal clipboard itself, but ignores an application that tries*. lgtm
was the application. Measured on tmux 3.7b: the escape from a pane sets nothing,
while `printf x | tmux load-buffer -w -` sets both the system clipboard and the
paste buffer, exit 0. Same operation, from the side tmux permits.

So `y` was broken for every tmux user on defaults, which is most of them, and
the tool said it had worked. Fixed: inside tmux the clipboard now goes through
`tmux load-buffer -w -`, falling back to the escape outside tmux or on a tmux
too old for `-w`. Driven live afterwards - `y` on a diff line, and `pbpaste`
returns `#1 s.zig:2`.

Three things came with it. `prefix + ]` now pastes a reference, which the escape
never gave. The degrade path in `sendText` uses the same route, which is the case
where losing the text silently hurts most - the agent's pane died and the
clipboard is the only copy left. And the notice is finally checkable: a command
has an exit code, where an escape sequence has no reply at all.

The general lesson is worth more than the fix. **The tool asserted a success it
had no way to observe**, and did it for months. Any future backend that reports
an outcome it cannot read back should be treated as suspect on the same grounds.

**`y` gave a reference where vim gives text.** Selected `normalizeLayout` with
`v`, pressed `y`, pasted somewhere else, and got
``#11 apps/linows/src/js/ipc.js:245 `normalizeLayout` ``. Behaving exactly as
FEATURES.md specified, so not a bug - a wrong decision, which is the kind of
thing only use finds.

Two arguments settled it. The surprise is **silent**: nothing looks wrong at the
time, and the paste lands somewhere else long after the selection is gone.
And `y` never needed to carry the reference, because pointing at code already
had its own key: `Enter` sends one to the agent, which is the whole thesis.
Overloading the most-known key in vim after `hjkl` bought nothing.

The deciding fact was that no keybinding could fix it. There were only two
commands, `copy_ref` and `copy_ref_lines`, and both wrapped the text. A user who
wanted vim's yank could not get it by remapping, which made this a gap rather
than a preference.

Split, and the reference kept a home rather than being taken away:

| key | now |
| --- | --- |
| `y` | yank the selection - characters under `v`, lines under `V`, cursor line with none |
| `Y` | yank whole lines, whatever `v` selected (vim's linewise yank) |
| `<Space>y` | copy the reference |
| `<Space>Y` | copy the reference and the lines under it |

The yanked text drops the diff's sign column: `+` is lgtm's, not the file's, and
code pasted into an editor should still compile. Newlines are allowed on this
path and only this path - hard rule 1 is about what `send-keys` does with one,
and a yank never reaches `send-keys`. The test that guards the rule now drives
`<Space>y` instead of `y`, so it still covers everything that can reach a pane.

Worth noting what this cost to find: nothing but using it. No test would have
caught it, because every test asserted the behaviour that turned out to be wrong.

<!-- Append dated entries. Keep them short and specific: what happened, what you
     expected, what you did instead. A measurement beats an adjective. -->
