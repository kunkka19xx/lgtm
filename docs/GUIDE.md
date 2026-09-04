# Using `lgtm`

A terminal diff reviewer that runs beside your coding agent. This is everything
you need to use it; [CONFIG.md](CONFIG.md) is the full settings reference.

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/kunkka19xx/lgtm/main/scripts/install.sh | sh
```

Any Linux distribution, and macOS; arm64 and x86_64. The Linux build is
statically linked, so there is no libc to match and no distribution to be right
about — this is the path on Debian, Ubuntu, Fedora, Alpine, openSUSE and
anything else without an entry below. The script needs no sudo — one binary
goes in `~/.local/bin` — and it will not install over a copy something else
manages. It verifies every download against the `SHA256SUMS` published in the
same release and stops on a mismatch.

```sh
scripts/install.sh --dry-run       # say what it would do, do nothing
scripts/install.sh --version v0.1.0
scripts/install.sh --dir /opt/bin
scripts/install.sh --uninstall
```

On macOS, from the tap:

```sh
brew install kunkka19xx/tap/lgtm
```

On Arch, from the AUR — with whichever helper you use, or none:

```sh
paru -S lgtm-bin     # or: yay -S lgtm-bin
git clone https://aur.archlinux.org/lgtm-bin.git && cd lgtm-bin && makepkg -si
```

`lgtm-bin` is the release binary and needs no toolchain. `lgtm-git` builds
`main` instead and needs `zig`, which is in `extra` for both architectures.

With Nix, the flake exposes the binary as a package, not just a dev shell:

```sh
nix run github:kunkka19xx/lgtm          # run it once, install nothing
nix profile add github:kunkka19xx/lgtm  # keep it on PATH
```

`nix run` builds into the store and runs it — nothing joins your profile or your
PATH, and the next `nix-collect-garbage` reclaims the build, so trying it costs
nothing. `nix profile add` is the one that persists; `nix profile remove lgtm`
undoes it. Both need flakes enabled. (`nix profile install` is the old spelling
of `add`, and warns.)

No Windows build: `io/input.zig` and `io/tty.zig` are POSIX throughout, so that
needs a port rather than a manifest.

### From source

Needs [Zig](https://ziglang.org), the version pinned in `.zigversion`:

```sh
make local          # build and install to ~/.local/bin
make clean-local    # remove it, restoring whatever it displaced
```

`make local` will not install over a symlink and will not delete a binary it did
not write, so a copy from a package manager is safe from it.

### What else you need

`git`. `tmux` is optional but is what lets `lgtm` type into your agent's input
box; without it, references go to the clipboard over OSC 52, which works over
SSH.

### Checking it works

```
lgtm -v          # version, author, repository
lgtm             # in any git repository
```

In a directory that is not a repository, `lgtm` starts, says so, and lets you
quit or talk to the agent. It never fails to start.

### Configuring it

There is nothing to configure to start: `lgtm` writes no config file and runs
on compiled-in defaults. When you want to change one:

```sh
lgtm --init                              # ~/.config/lgtm/config.toml
lgtm --init --config .lgtm/config.toml   # this repository's, meant to be committed
```

Every line in the file it writes is commented out and shows the default, so it
changes nothing until you uncomment something — and a default improved in a
later release still reaches you. `--init` never overwrites a file that is
already there. [CONFIG.md](CONFIG.md) is the full reference.

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

`*` searches for the identifier under the cursor, and `#` does it backwards.
This is the review's most common question, now that a name has changed: where
else does it appear? It costs one key. Matched whole, so `*` on `id`
walks the places `id` is used rather than stopping in every `width`, `valid` and
`ident` between them. `/` is still there when you mean a fragment.

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

### 5. Watch for a weakened test

The failure with the worst consequences, and the one hardest to catch by
reading: a test deleted because it failed, a `skip` added, a body that stopped
asserting. It turns a red build green while looking like ordinary cleanup.

`lgtm` counts what a change did to its tests on every re-diff and says so on the
status line:

```
1 test removed, 1 skip added, 1 fewer assertion
```

`]w` and `[w` walk to them — to the removed declaration or the added skip, so
you land on the thing rather than near it.

Detected by content, not by path, so it works for languages that keep tests in
the source file. Two of the three signals are near-certain and lead; "fewer
assertions" follows behind, because a refactor that merges two checks into one
looks the same. Zig, Go, Python, JavaScript, TypeScript, Rust and Swift are
described; anything else stays silent rather than guessing.

### 6. Get your work back

`lgtm` snapshots the working tree whenever the agent stops writing, into git's
own object store under `refs/lgtm/**`. The first snapshot is taken before the
agent has written anything, which is the one nothing else could recover:
uncommitted work is invisible to git until you lose it.

| | |
|---|---|
| `]t` `[t` | walk the turns, ending at the working tree |
| `<Space>lt` | list them: what each touched, when, how big |

The list stays a screenful however long the session runs. The newest few turns
are always drawn, and so are the mark, `0 original` and the turn you are
looking at; everything between them collapses into `⋮ 13 turns`. `<CR>` opens a
fold, and typing anything opens all of them — a filter that skipped folded rows
would be a filter that lies.

Four turns in a row on one file collapse too, as `⣿ 1-4 app.zig ×4`: that is
one piece of work that took four tries, not four things to read. A run never
folds across a row that has something of its own to say.

Two markers earn their place:

| | |
|---|---|
| `↺ 4` | **the agent undid its own work** — this turn put a file back to exactly what turn 4 left. Round-tripping is what agents do when they are stuck, and it is nearly invisible in a diff, because a diff only shows the endpoints |
| `↩` | **this turn touched a file you commented on** — the agent answering you, as against doing something else |
| `R` | restore this file from the turn on screen |
| `u` | undo the last restore |

A turn is read-only: comments, `m` and `<C-s>` refuse there and say why. The
badge reads `TURN 2` or `BASELINE` so you always know you are in the past, and
grows a `•` when the working tree changes while you are back there — nothing
updates under you, but you are told the world moved.

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

### 7. Read anything

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
| `;` `,` | repeat the last jump, either way (see below) |
| `<C-d>` `<C-u>` | half a page |
| `gg` `G` | first and last line |
| `}` `{` | next and previous break: a blank line, or a hunk edge |
| `zz` | centre the cursor line |

### Jumping

| Key | |
|---|---|
| `]h` `[h` | next and previous hunk (wraps) |
| `]f` `[f` | next and previous file (wraps) |
| `]c` `[c` | next and previous comment |
| `]m` `[m` | next and previous change since the mark |
| `]t` `[t` | next and previous turn |
| `]w` `[w` | next and previous weakened test |
| `/` `n` `N` | search the review, then step |
| `*` `#` | search for the word under the cursor, forwards or back |
| `<Space>f` | the changed files |
| `<Space>F` | every file in the project |

Every `]x` has a `<Space>nx` spelling and every `[x` a `<Space>px`, for anyone
whose terminal makes brackets awkward.

**`;` repeats whichever of these you used last, and `,` goes back.** After `]h`
they walk hunks, after `]w` weakened tests, after `n` search matches. After `f(`
they are vim's, exactly. That is the whole rule: `;` is "that again", so the
keystroke you spend most costs one key instead of two, and you never have to
remember which family you are in.

A second `,` keeps going back rather than turning round, the way vim's does.

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
| `<Space>lt` | list the turns. Typing a number finds that turn; typing a word searches the row |
| `R` | restore this file from the turn on screen |
| `u` | undo the last restore |
| `]w` `[w` | walk the weakened tests |

### View

| Key | |
|---|---|
| `<Tab>` | zen: hide the chrome |
| `zw` | soft wrap long lines |
| `\|` or `-` | side by side, or back to the flow view |
| `H` `L` | side by side: focus the old or the new column |
| `zi` | show the files `[review] ignore` hides |
| `zo` `zc` | open a file too large to render inline, or fold it |
| `<C-r>` | re-diff now |
| `<Space>e` | open this line in `$EDITOR` |
| `?` | every key, from your bindings |
| `:` | run any command by name, `<Tab>` completes (see below) |
| `:q` | quit |

### The command line

`:` runs any command by the name `[keys]` binds it by, so everything in
[CONFIG.md](CONFIG.md)'s command list is typeable whether or not it has a key:

```
:next_file        :turn_list        :toggle_wrap
:q  :qa           :noh              :nomark
```

`<Tab>` completes. The first press extends to whatever every candidate shares,
so `:n` becomes `:next_` without choosing between them; the next presses cycle,
and `<S-Tab>` goes back. The candidates appear on the line above, which is the
rule the prompt was covering anyway, so nothing on screen moves to make room:

```
next_hunk  next_file  next_comment  next_turn  next_fresh  next_risk
:next_
```

If nothing starts with what you typed it falls back to a loose match, so `:nf`
still reaches `next_file`.

The short spellings are vim's and mean the same as the long ones. A name that
does not exist suggests the nearest one that does, and a command that only lives
inside the compose box or a list says so rather than running somewhere it has no
meaning. Neither the suggestion nor `<Tab>` will ever offer a command `:` would
then refuse.

`?` shows the keys and `:` runs the names. Both read the same table, so neither
can drift from what the tool actually does.

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
in. It infers the only other one; with more than two it will say so rather than
guess. Start it with `--pane` to be explicit: `%3` in tmux, `w1:p1` in herdr,
`3` in WezTerm and kitty. kitty calls its splits *windows* rather than panes, and `lgtm` says so
too — the flag is still `--pane`, because it is one flag.

**kitty says `set allow_remote_control yes`** — kitty refuses to let any process
type into your terminal until you allow it. Put `allow_remote_control yes` in
`kitty.conf` and restart it. Until then `<CR>` degrades to the clipboard, which
still works; it is a paste away rather than a keystroke away.

### Which terminals it can type into

| | how | |
|---|---|---|
| **tmux** | `send-keys` | also carries the clipboard, because tmux's default `set-clipboard external` swallows an application's OSC 52 |
| **herdr** | `herdr pane send-text` | pane ids are `w1:p1`. Built for agents, so `send-text` inserts and never submits |
| **WezTerm** | `wezterm cli send-text` | detected by `$WEZTERM_PANE` |
| **kitty** | `kitten @ send-text` | needs `allow_remote_control yes` in `kitty.conf` — off by default, on purpose |
| **Ghostty** | AppleScript | **macOS, Ghostty 1.3+.** Needs Automation access the first time — macOS will ask |
| **anything else** | OSC 52 | `<CR>` copies instead of sending. Still a paste away |

**Alacritty, iTerm2, Terminal.app** and the rest have no way for one program to
type into another's split, so `lgtm` falls back to the clipboard there. **Run
tmux or herdr inside them** and you get the full loop — which is what most
people already do, and why both are detected ahead of the terminal they are
running in.

**Ghostty is a special case.** It gained an AppleScript dictionary in 1.3, so
`lgtm` can type into another split — on macOS, and after you allow it in
System Settings → Privacy & Security → Automation. Ghostty is also the one
terminal that does not tell a pane which pane it is: there is no
`$GHOSTTY_PANE`. `lgtm` takes the *focused* split as its own the first time it
needs to know, which is right because that is the split you just typed `lgtm`
into — but if you have moved focus first, pass `--pane N`. `osascript -e 'tell
application "Ghostty" to get id of every terminal'` lists them.

### Reviewing something other than the working tree

| | |
|---|---|
| `lgtm` | HEAD against the working tree — the default, and what the tool is about |
| `lgtm --base main` | your whole branch, **including what you have not committed**. Live: the tree is still the right-hand side, so it still updates as the agent writes |
| `lgtm --base main --target HEAD` | committed work only, as two trees. **Static** — nothing can move, so the watcher, the snapshots and the mark are all off |

The badge says which: `main` or `main..HEAD` in the accent instead of `NORMAL`,
because a diff against a branch looks exactly like a diff against HEAD and
reading one as the other is the mistake worth preventing.

**Snapshots are not happening** — they need a git repository, and a turn is
taken ten seconds after the agent *stops* writing. Changes made in the first
half-second of a session are part of the starting state rather than a turn.
