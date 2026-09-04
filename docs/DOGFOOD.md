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

**The ask presets sat on keys vim will want back.** `a` was "why this
approach?", `x` was "explain what this does", `!` was "revert this". In vim
those are append, delete-a-character and the filter operator - three of the
keys insert mode needs on the day editing lands, and editing is designed *for*
rather than out (ARCHITECTURE.md 11).

Moved to `<Space>a` `<Space>r` `<Space>t` `<Space>x`. Doing it now costs one
keystroke; doing it after v0.1 ships costs a user's muscle memory twice, once
to learn the wrong thing and once to unlearn it. This is the cheapest kind of
decision to get right early and among the most expensive to defer, which is
why it went in mid-week rather than onto the list.

**The status row's file name learned what the file list already knew.** It was
one colour whatever had happened to the file, while the `F` overlay had said
green/red/amber/blue for arrived/left/changed/moved since it was built. Same
two signals now, and for the same reason: the row has to answer "which file"
and "what happened to it" without being read word by word.

The icon comes with it, in its filetype hue rather than the status colour - the
split `popup.zig` already used, and it is the right one: shape and hue together
find the Rust file without reading a name, while the path's colour still says
what happened to it. Two questions, two channels. It costs two columns, taken
out of the path's budget rather than out of the counts, and nothing at all when
`ui.icons` is not `nerd`.

Nothing new was written for either half. `theme.file_*`, `devicon.forPath` and
`statusFit` all existed; this was three call sites finding them.

### 2026-09-03 - the doc audit, and what it found in the code

Scanning the docs for present-tense claims about things that were never built
turned up two claims that were about the *code* rather than about the writing.

**A file over 5,000 changed lines had nowhere to go.** SPEC.md said "the diff
loads lazily on open"; `core/diff.zig` had `materialise`, with two tests, and
nothing in `ui/` ever called it. So the summary row was where a large file
stopped: no key, no hint, no way in. A `package-lock.json` is exactly the file
you skip, which is presumably why it went a month without being noticed - and
exactly the file you eventually need to look at once.

Now `zo` opens it and `zc` folds it again, which is what those keys already
mean in vim: a deferred file is a fold in everything but name. Three things it
had to get right beyond calling the function. The file has to be materialised
*before* buffers are attached and ids inherited, because both skip a summarised
file - do it after and the diff renders from git's text rather than from the
buffers, which is the one thing ARCHITECTURE.md 11.1 says never to do. Opening
has to survive a re-diff, or a file the agent is writing folds itself every
500 ms, which is precisely when you want it open; `ui/review.zig` keeps the
opened paths on the gpa, next to `prev_work`, for that reason. And folding
re-diffs rather than filtering, the same way `zi` does: git decided the file was
large, so git is what gets asked again.

The summary row names the key, read from the keymap rather than written into
the string, so a remapped `zo` still tells the truth.

**The one outgoing string that is not a template.** `submitReview` builds
`review ready: .lgtm/review-3.md (4 comments)` with `bufPrint`. Every other
outgoing string goes through `bridge/template.zig`. Logged rather than fixed:
changing it changes what the agent is told, which is a decision and not a
tidy-up.

### 2026-09-03 - since I last looked

The second read was the tax the tool had not removed. You comment, the agent
revises, the diff comes back looking almost the same, and finding the twelve
lines that answer you means re-reading eight hundred. Change ids do not help:
they say a hunk is the *same* change, not that its contents held still.

`m` now marks the working tree as read. `core/checkpoint.zig` keeps those bytes
on the session allocator, every re-diff line-maps them against the current tree,
and rows with no antecedent get a bar in the gutter, `]m` to walk them, and a
count on the mode row.

Three decisions worth keeping.

**It annotates rather than filters.** FEATURES.md 1.3 specified a view showing
only the delta since the mark. That is wrong, and using it makes it obvious
within a minute: `if (!t) return false;` means nothing without the line above it
that the agent wrote an hour ago. What the reader approves is still the diff
against HEAD; the mark only says which of its rows are new. It also costs one
gutter column that was already blank, rather than a mode.

**It compares working trees, not diffs.** That is what makes it a `linemap`
lookup instead of a second diff algorithm - the map was already written,
already measured, already what anchoring trusts. Nothing new was written for
the comparison itself.

**Only added and removed rows can be fresh.** A context row is unchanged code
by definition. Marking it because the lines around it moved would light up half
the file the first time the agent inserted an import, which is the failure this
feature exists to prevent, not one to reproduce. There is a test named after it.

Measured before believing it: 0.93 ms per re-diff over this repository's
fourteen changed files, against `diff_parse` at 43 ms in the same run. That is
what made "recompute everything, every time" the design - a cache would have to
be invalidated by exactly the events that already trigger the recompute.

One thing the measurement turned up that is *not* about the mark: `git_subprocess`
and `diff_parse` together are about 73 ms on this repo. Each is inside its own
100 ms budget, but a re-diff is both, and they are the two that will grow with
the repository rather than with the feature list. Worth a look before the next
thing that runs per re-diff.

`Ctrl-s` takes the mark as well as sending. That was the missing half: a mark
you have to remember to set *before* the thing it measures is a mark you set
afterwards, when it is worth nothing. Submitting is the one moment the reader
has demonstrably read everything, so it is where the mark belongs. `<Space>sc`
deliberately does not - sending one remark claims nothing about the rest - and
`[nav] mark_on_submit = false` turns it off for a mark meant to span rounds.
It marks even when the bridge fails, because "I have read this" is true whether
or not the send worked.

The keys went on `m` `M` `]m` `[m` after a first pass put the walk on `]n` and
`<Space>nn`. `n` was meant to be "new" and read as "next", which the leader
spelling made obvious: `<Space>nn` is two different `n`s in one sequence. The
established pattern is `]<thing>` and `<Space>n<thing>` - `h` hunk, `f` file,
`c` comment - and the thing here is the mark.

Asking "is all of it configurable?" turned up the half that was not. `[keys]`
resolves straight off the `Command` enum, so a new command is remappable the
moment it exists; but the *messages* said `]m` and `` `m` `` as string literals,
so remapping them made the screen advertise keys the reader did not have. The
`View` now carries the keymap - one field rather than one per message - and
`keytext.firstKeyFor` answers "what is this bound to now". `keysFor` joins every
spelling, which a help row wants and a sentence cannot afford. The summarised
row's `open_key` field went away in the same change, which is the sign it was
the right shape.

Still literal, and pre-existing: "no comments yet - `<Space>c` writes one" and
"comment added - `<C-s>` submits the review". Same one-line fix, not made here.

Also fixed in passing: `]c` and `[c` had the same description, so the `?` popup
printed the same sentence twice - `mergeByDesc` could not join them because
their keys were past the merge width. They now say "next" and "previous", which
is what `]h` and `[h` already did.

### 2026-09-03 - every key, not most of them

"All features with keys must be configurable." The audit found three layers,
and only the first was already true.

**Commands.** `[keys]` resolves off the `Command` enum, so anything in it has
always been remappable the moment it existed. Fine.

**Messages naming a key.** Six notices spelled `<Space>c`, `<C-d>` and `<C-s>`
as string literals, for commands that *are* remappable - so a remap turned them
into instructions for keys the reader did not have. They read the keymap now,
through one `keyFor` helper.

**The compose box.** The real gap: it read keys directly, so none of `<CR>`
`<Esc>` `<C-s>` `<C-i>` `@` `<C-j>` could be changed. They are bindings now
(`Modes.compose_only`, using one of the `Modes` pad bits), and `compose.zig` no
longer knows what any key means - `Result` collapsed from five values to one.

The motions stayed hardcoded, deliberately and at the author's instruction. The
reason is not laziness: in a text box every printable key is data, so a keymap
able to bind `x` is a keymap able to take `x` away from typing. Vim splits the
same way.

Two rules the box forced that the review never had to think about. Bindings are
single chords, because a box cannot hold a prefix waiting to see whether a
sequence completes - the key after it is usually a letter someone is typing. And
a pending operator outranks the keymap, or `d<Esc>` would cancel the box instead
of the operator and take a half-written message with it.

The footers and the `?` rows are generated from the bindings now instead of
being static tables, which is what makes the whole thing hold: a remap moves the
key, the footer and the help together, and an unbound command drops out of the
footer rather than advertising a key nobody has. Checked with everything moved
at once - `compose_presets` on `<C-p>`, `compose_mention` on `#`, `compose_cancel`
on `<C-q>` - and the box, its footer and `?` all agreed.

### 2026-09-04 - the snapshot store, step 1

`snapshot/gitobj.zig`: git plumbing, argv in and object ids out, no policy and
no UI. SNAPSHOTS.md 5.6 step 1.

The design says the check that matters is made **from outside, with stock git**,
and it was right to say so. Unit tests assert the argv - which subcommand, which
flags, which ref namespace - and all ten passed while the code was still wrong
in two ways that only a real repository could show.

**`git read-tree --empty HEAD` is a contradiction.** `--empty` clears the index,
`HEAD` fills it; together git refuses. The failure was swallowed by a `catch`
that treated any read-tree failure as "repo with no commits, an empty index is
fine", so every snapshot silently contained *only the changed files*. It looked
like it worked. `git show <ref>:changed.zig` printed the file, because that file
was one of the changed ones. A store that cannot restore an unchanged file is
not a store, and nothing in the tool would ever have said so.

**A double free on the failure path.** `errdefer r.deinit()` plus an explicit
`r.deinit()` in the `exit_code != 0` branch. Only reachable when git fails,
which no test did and the first real run did immediately.

**And `.lgtm/` has to exist before git is handed a path inside it.** git creates
the index file but not its directory, and says so as a `fatal:` about a lock
file that names the wrong cause. `io/fs.zig` grew `ensureStateDir` - the same
directory and the same self-ignore every other durable write already uses.

Verified in a scratch repo with a staged change, an unstaged change and an
untracked file, which is the state the hard boundaries are about:

    status unchanged, .git/index untouched, HEAD did not move, no branch created
    the snapshot holds the working-tree version, not the staged one
    the tree is whole: HEAD's files plus the new ones, not just what changed

**Asking "what about a project without git?" found two crashes that had nothing
to do with snapshots.** In a directory that is not a repository, and in a
repository with no commits yet, `git diff HEAD` fails, `GitFailed` propagated
out of `main`, and lgtm printed a Zig stack trace and died. Both are hard rule
8's territory even though neither is a config problem: a pane that crashed
cannot tell you what went wrong.

They want opposite answers, which is why one fix would have been wrong. **No
repository** is the end of the road - the tool reads `git diff` for a living -
so the review is empty and the wordmark screen says "not a git repository -
nothing to review", with `?`, `:q` and the compose box all still working, the
same as a clean tree. **No commits yet** is the opposite: everything is new.
`--cached` diffs against the empty tree where `HEAD` will not resolve, the
untracked scan already covers the rest, and lgtm now shows a freshly scaffolded
project in full. That is the state a project is in right after an agent creates
it, which is exactly when losing the work would hurt most - and snapshots work
there too, because `commit-tree` with no parent is a perfectly good first turn.

The extra `rev-parse --git-dir` that tells the two apart runs only after a diff
has already failed, so the ordinary path pays nothing for it.

The empty screen then grew two lines, and the second one is the interesting
decision. "Run `git init`" is the obvious hint and it is wrong on its own:
being in the wrong directory is a likelier reason to be reading that screen than
having meant to review an uninitialised one, and someone who mistyped a `cd`
would follow the advice and leave a repository behind in their downloads folder.
So the screen shows **the directory** first, elided from the head so the last
component survives, and then offers both readings - `cd to a repository, or git
init here`. The path is what settles which applies, and it settles it without
the tool having guessed.

Both lines are counted in the row budget `place()` gets, so a pane too short to
hold them drops the wordmark rather than drawing over its own byline. On a pane
too small for any of it, the one line that survives is what is wrong, not the
help - checked at 80x13, 60x20 and 40x8.

Also fixed while in there: `<Space>F` in a non-repo said "no file matches" with
no filter typed, blaming a filter nobody had entered. `nothing to list` and `no
file matches` are different facts, and `popup.emptyWhy` is now a pure function
that says which.

The harness that runs it is `zig build snap`. It asserts nothing on purpose - a
harness checking the code that wrote it would be testing agreement rather than
correctness - it takes a snapshot and prints the four git commands to check it
with.

<!-- Append dated entries. Keep them short and specific: what happened, what you
     expected, what you did instead. A measurement beats an adjective. -->
