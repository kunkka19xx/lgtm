# lgtm

```
██╗      ██████╗ ████████╗███╗   ███╗
██║     ██╔════╝ ╚══██╔══╝████╗ ████║
██║     ██║  ███╗   ██║   ██╔████╔██║ 👍
██║     ██║   ██║   ██║   ██║╚██╔╝██║
███████╗╚██████╔╝   ██║   ██║ ╚═╝ ██║
╚══════╝ ╚═════╝    ╚═╝   ╚═╝     ╚═╝
```

**Read what your agent wrote - before you say LGTM.**

A terminal diff reviewer for agentic coding. It runs in a pane beside your
agent, shows what changed as it changes, and lets you point at exact lines
when you reply.

**You keep your editor.** `hjkl`, `w b e`, `f t F T`, `/` and `n`, `V` to
select, `zz` to centre - the same motions you already have in your fingers,
now pointed at the agent's work. Reviewing a diff should not mean leaving the
keyboard you know for a mouse and a browser tab. The agent writes; you still
get to be a vim user while it does.

> **Status: pre-alpha**, and used daily by its author.
>
> It started a long time ago as a Go tool for reading diffs in a terminal.
> This is a rewrite in Zig, rebuilt around a coding agent rather than a person:
> the diff re-renders as the agent writes, references go straight to its input,
> and review comments follow the code when it rewrites the file underneath
> them. The loop works end to end; the numbers below are measured, not
> estimated.

## Why

Reviewing an agent's code is a different problem from reviewing a person's:
higher volume, faster arrival, and no prior about where the risk is. The loop
without this tool is - the agent edits six files, you scroll `git diff` in a
pager, you spot something at `src/auth.zig:47`, and you **retype** that path
into the chat. `lgtm` removes the retyping.

## Install

Needs [Zig](https://ziglang.org) (version pinned in `.zigversion`), git, and
tmux for the bridge - without one, references go to the clipboard over OSC 52,
which works over SSH.

```
make local          # build and install to ~/.local/bin
make clean-local    # remove it, restoring whatever it displaced
```

There are no packages yet.

## The loop

Run `lgtm` in a pane next to your agent. It polls every 500 ms; there is
nothing to re-run.

**Point at code.** `Enter` opens a box holding `#3 src/auth.zig:47`. Type what
you want to say and `Enter` sends it - inserted into the agent's input, never
submitted, so you decide when to press return. `V` selects a range and sends
`:47-52`; `v` selects inside a line and sends the words themselves.

**In the box:** `<Esc>` for normal mode, where the same vim motions work and
`o` opens a line. `Ctrl-i` inserts one of your `[presets]`, `@` mentions any
file in the project. Both drop in at the caret.

**Collect comments, submit once.** `<Space>c` writes one against a line - on
removed code too. `]c` walks them, `<Space>lc` lists them, `<Space>vc` opens
the nearest to edit. `Ctrl-s` writes `.lgtm/review-3.md` and sends the agent
one line naming it: a dozen remarks is a dozen interruptions, or it is one
file. Comments follow the code when the agent rewrites it, survive a restart,
and say so when they can no longer be placed.

**Read anything.** `<Space>f` lists the changed files, `<Space>F` every file
git knows about - an unchanged one opens whole, outside the review, still
readable and commentable. A file too large to render inline opens with `zo`.

**Come back to what's new.** Submitting a review marks the working tree as
read, and `m` does it by hand. When the agent revises, the lines that arrived
since carry a bar in the gutter and `]m` walks them, so round two is the twelve
lines that answer you rather than the eight hundred you already read.

`?` shows every key, generated from your bindings rather than from this page,
so a remapped keymap documents itself.

## Configure

`~/.config/lgtm/config.toml`, then `.lgtm/config.toml` in the repo, merged key
by key. A bad key is reported on the status line; it never stops the tool
starting.

```toml
[review]
ignore = ["package-lock.json", "**/*.pb.go"]   # generated files .gitignore can't hide

[presets]
why  = "why this approach?"
perf = "is this hot path allocating?"

[ui]
icons = "nerd"        # or "unicode", "ascii"
comments = "inline"   # or "marker": just the gutter dot
compose = "bottom"    # or "top", "centre"

[theme]
name = "gruvbox"      # seven bundled; `lgtm --theme-preview` shows them all

[nav]
mark_on_submit = true   # Ctrl-s marks what you just read

[keys]
next_hunk = ["]h", "<Space>nh"]
compose_presets = ["<C-p>"]   # the box's keys are bindings too
```

Every key is remappable, inside the compose box as well as outside it - only
the vim motions are fixed, because in a text box every printable key is data.
The `?` popup and the box's own footer are generated from your bindings, so a
remap moves the key and everything that names it together.

## Not this

Not an agent - no model calls, no API. No embedded terminal. No plugin
runtime. Read-only: the agent edits, you review. Editing and LSP are designed
*for* rather than out, so they can arrive later without a rewrite.

## Numbers

Measured on macOS arm64, ReleaseFast, in this repository:

| | |
|---|---|
| Binary | 726 KB, one dependency (`libSystem`) |
| Peak RSS | 1.6 MB |
| Cold start | under 10 ms |
| Frame | 0.11 ms at 80x26 |
| Re-anchoring comments | 100% across the fixture set |

Everything durable is a plain file in `.lgtm/` - comments as jsonl, reviews as
markdown. Kill it and restart it; you lose scroll position.

Snapshots, when they land, live in git's own object store under
`refs/lgtm/**`. That namespace is invisible to `git branch` and `git status`,
but `git log --all` walks every ref, so those commits will show up there. They
are ordinary objects: `git show refs/lgtm/<session>/3:src/auth.zig` reads a file
out of one without lgtm installed, and deleting the refs is all it takes to be
rid of them.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
