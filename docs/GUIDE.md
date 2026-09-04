# Using `lgtm`

A terminal diff reviewer that runs beside your coding agent. This is everything
you need to use it; [CONFIG.md](CONFIG.md) is the full settings reference.

Comments in the source cite design documents by section - `SPEC.md 6.5`,
`PERFORMANCE.md 3.1`. Those documents are the author's and are not published;
the citation is there so the reasoning has a name, not so you can look it up.

---

## Install

You need [Zig](https://ziglang.org) (the version is pinned in `.zigversion`) and
`git`. `tmux` is optional but is what lets `lgtm` type into your agent's input
box; without it, references go to the clipboard over OSC 52, which works over
SSH.

```
make local          # build and install to ~/.local/bin
make clean-local    # remove it, restoring whatever it displaced
```

`make local` will not install over a symlink and will not delete a binary it did
not write, so a copy from a package manager is safe from it.

There are no packages yet.

### Checking it works

```
lgtm -v          # version, author, repository
lgtm             # in any git repository
```

In a directory that is not a repository, `lgtm` starts, says so, and lets you
quit or talk to the agent. It never fails to start.

---

## The loop

Run `lgtm` in a pane next to your agent. It polls every 500 ms; there is nothing
to re-run and nothing to refresh.

### 1. Read

The diff against `HEAD`, staged and unstaged, with untracked files included. The
motions are vim's: `j k h l`, `w b e`, `W B E`, `0 ^ $`, `f t F T` with `;` and
`,`, `gg` and `G`, `<C-d>` and `<C-u>`, `zz`.

`]h` and `[h` walk hunks across the whole review; `]f` and `[f` walk files. Both
wrap, and say so when they do.

`/` searches the whole review, not just the file on screen. Matches highlight as
you type. `n` and `N` step; `<Esc>` or `:noh` clears the highlight and keeps the
pattern.

### 2. Point at something

`Enter` opens the compose box holding a reference to the line under the cursor:

```
#3 src/auth.zig:47
```

Type what you want to say and `Enter` sends it — inserted into your agent's
input box, never submitted, so you decide when to press return.

- `V` selects lines and sends `:47-52`; `v` selects inside a line and sends the
  words themselves.
- `<Space>a` opens the box with your `[presets]` list already up.
- `<Space>y` copies the reference to the clipboard instead of sending it.
- `y` yanks the selected *text*, the way `y` does in vim.

**In the box:** `<Esc>` leaves insert for normal mode, where the same vim
motions work and `o` opens a line; a second `<Esc>` leaves the box. `<C-i>`
inserts a preset at the caret, `@` inserts a file path, `<C-j>` is a line break.
Nothing you type is deleted by either.

### 3. Collect comments, submit once

A dozen remarks is a dozen interruptions, or it is one file.

| | |
|---|---|
| `<Space>c` | write a comment on this line — on removed code too |
| `]c` `[c` | walk them |
| `<Space>vc` | open the nearest one to read or edit |
| `<Space>lc` | list every comment; the filter reaches the file, the line and the text |
| `<Space>sc` | send just this one, now |
| `<Space>dc` | delete the one here |
| `<C-s>` | write `.lgtm/review-3.md` and tell the agent about it |

Comments follow the code when the agent rewrites it, survive a restart, and say
so when they can no longer be placed — a comment is never silently dropped.

In the comment list, `<C-s>` sends the highlighted one, `<C-x>` sends every open
one as the review file, `<C-d>` deletes one.

### 4. Come back to what's new

`<C-s>` marks the working tree as read, and `m` does it by hand. When the agent
revises, the lines that arrived since carry a bar in the gutter:

```
   1  fn login(u: []const u8) bool {
−  2      return check(u);
+  2      const t = trace(u);            ← was there when you marked
+┃ 3      if (!t) return false;          ← arrived since
+┃ 4      return check(u) and audit(u);
```

`]m` and `[m` walk those changes, `M` or `:nomark` drops the mark. The mark
survives quitting `lgtm`: come back tomorrow and it still means the same thing.

The mark never hides anything. You are always looking at the whole diff against
`HEAD`; the bars are an annotation on top of it.

### 5. Get your work back

`lgtm` snapshots the working tree whenever the agent stops writing, into git's
own object store under `refs/lgtm/**`. The first snapshot is taken before the
agent has written anything, which is the one nothing else could recover:
uncommitted work is invisible to git until you lose it.

| | |
|---|---|
| `]t` `[t` | walk the turns, ending at the working tree |
| `<Space>lt` | list them: what each touched, when, how big |
| `R` | restore this file from the turn on screen |
| `u` | undo the last restore |

A turn is read-only: comments, `m` and `<C-s>` refuse there and say why. The
badge reads `TURN 2` or `BASELINE` so you always know you are in the past.

`R` takes a snapshot **before** it writes, asks before it writes, restores one
file and no more, and then names the turn that undoes it. It is the only thing
in `lgtm` that writes to your files.

`u` undoes that restore — one step, this session only. It refuses if anything
has changed the file since, because then putting the old bytes back would not be
undoing your action, it would be discarding whatever came after it. Going the
other way is the move the notice names: `[t` to the turn it made, then `R`. That
is the real mechanism; `u` is its shortcut.

The snapshots are ordinary git objects. Without `lgtm` installed:

```
git show refs/lgtm/<session>/0:src/auth.zig    # the pre-agent version
git log --graph refs/lgtm/<session>/7          # the session
```

They are invisible to `git branch` and `git status`. `git log --all` walks every
ref, so they do appear there. Deleting the refs is all it takes to be rid of
them.

### 6. Read anything

`<Space>f` lists the changed files; `<Space>F` lists every file git knows about.
An unchanged file opens whole, outside the review — still readable, still
commentable. A file too large to render inline opens with `zo` and folds again
with `zc`.

---

## Every key

`?` shows this list generated from *your* bindings, so a remapped keymap
documents itself. What follows is the defaults.

### Moving

| Key | |
|---|---|
| `j` `k` | down and up a line |
| `h` `l` | left and right a character |
| `w` `b` `e` | next, previous, end of word |
| `W` `B` `E` | the same over WORDs — only blanks separate |
| `0` `^` `$` | first, first non-blank, last column |
| `f` `t` `F` `T` | to or before a character on this line |
| `;` `,` | repeat the last `f`/`t`/`F`/`T`, either way |
| `<C-d>` `<C-u>` | half a page |
| `gg` `G` | first and last line |
| `zz` | centre the cursor line |

### Jumping

| Key | |
|---|---|
| `]h` `[h` | next and previous hunk (wraps) |
| `]f` `[f` | next and previous file (wraps) |
| `]c` `[c` | next and previous comment |
| `]m` `[m` | next and previous change since the mark |
| `]t` `[t` | next and previous turn |
| `/` `n` `N` | search the review, then step |
| `<Space>f` | the changed files |
| `<Space>F` | every file in the project |

Every `]x` has a `<Space>nx` spelling and every `[x` a `<Space>px`, for anyone
whose terminal makes brackets awkward.

### Talking to the agent

| Key | |
|---|---|
| `<CR>` | compose a message about this line |
| `<Space>a` | compose, with the question list open |
| `<Space>y` `<Space>Y` | copy the reference, or the reference and the lines |
| `y` `Y` | yank the selection, or whole lines |
| `v` `V` | visual select, characters or lines |

### Comments

| Key | |
|---|---|
| `<Space>c` | write one here |
| `<Space>vc` | open the nearest to read or edit |
| `<Space>lc` | list every comment |
| `<Space>sc` | send this one on its own |
| `<Space>dc` | delete the one here |
| `<C-s>` | submit the review, and mark what you read |

### Turns and the mark

| Key | |
|---|---|
| `m` | mark: everything after this is new |
| `M` | drop the mark |
| `<Space>lt` | list the turns |
| `R` | restore this file from the turn on screen |
| `u` | undo the last restore |

### View

| Key | |
|---|---|
| `<Tab>` | zen: hide the chrome |
| `zw` | soft wrap long lines |
| `zi` | show the files `[review] ignore` hides |
| `zo` `zc` | open a file too large to render inline, or fold it |
| `<C-r>` | re-diff now |
| `<Space>e` | open this line in `$EDITOR` |
| `?` | every key, from your bindings |
| `:q` | quit |

### In a list

`J` and `K` move, `H` and `L` page, `<CR>` opens, `<Esc>` closes, and typing
filters. `<Tab>` and `<S-Tab>`, the arrow keys, and `<C-n>`/`<C-p>` all move too.

### In the compose box

`<Esc>` leaves insert then leaves the box, `<CR>` sends, `<C-i>` inserts a
preset, `@` inserts a file path, `<C-j>` is a line break, `<C-s>` saves a
comment and sends it at once. In normal mode: the review's motions plus
`i a I A o O x D C dd cc d{motion} c{motion} u`.

---

## Where things live

Everything durable is a plain file in `.lgtm/`, which `lgtm` keeps out of your
review with its own `.gitignore`:

| | |
|---|---|
| `.lgtm/comments.jsonl` | your comments |
| `.lgtm/review-N.md` | what `<C-s>` wrote |
| `.lgtm/state.json` | the session, the turn count, where you read to |
| `.lgtm/config.toml` | this repository's settings, if you commit one |

Kill `lgtm` and restart it; you lose scroll position and nothing else.

---

## When something is wrong

**"not a git repository"** — `lgtm` reads `git diff` for a living. The screen
shows which directory it means, so you can tell a wrong `cd` from a directory
that needs `git init`.

**A setting was ignored** — a bad key is reported on the status line with the
file and the line. It never stops `lgtm` starting, and it only costs that one
key its value.

**`y` says copied but the clipboard is empty** — under `tmux`, application OSC
52 is discarded unless `set-clipboard` allows it. `lgtm` uses `tmux
load-buffer` instead, so this should not happen; if it does, check that `tmux`
is on your `PATH`.

**Nothing is sent to the agent** — `lgtm` needs to know which pane your agent is
in. It infers the only other pane; with more than two it will say so rather than
guess. Start it with `--pane %N` to be explicit.

**Snapshots are not happening** — they need a git repository, and a turn is
taken ten seconds after the agent *stops* writing. Changes made in the first
half-second of a session are part of the starting state rather than a turn.
