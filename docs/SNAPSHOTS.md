# `lgtm` — Snapshots & Turn History

**Companion docs:** SPEC.md, ARCHITECTURE.md, PERFORMANCE.md, FEATURES.md, NOTIFICATIONS.md
**Status:** draft v0.1
**Milestone:** v0.2 (core), v0.3 (timeline UI, restore)

> Added after the initial doc set. Fills a gap: checkpoints and the anchor chain currently exist only in memory.

> **Status, 2026-09-03.** The *behaviour* of §5.1 shipped and nothing else here
> did. `m` marks, `]m` walks what arrived since, and `core/checkpoint.zig`
> holds the marked working tree in RAM on the session allocator - so it dies
> with the process, and it copies whole file contents rather than addressing
> them by content. Everything that makes this document worth having is still
> unbuilt: the git object store (§3), snapshotting per agent turn (§4),
> durable checkpoints and restart-safe anchoring (§5.1-5.2), the timeline
> (§5.3), and restore (§5.4-5.5). Read the present tense below as design.
> `m` is the right key on the wrong storage, which is the cheap half to
> replace: `Checkpoint.find` is the only thing the review layer asks it.
> §5.6 has the build order; step 1 is `snapshot/gitobj.zig`.

---

## 1. The gap

Three features assume a notion of "the previous state of the working tree":

- **Turn checkpoints** (FEATURES.md §1.3) — "show me only what changed since I last looked"
- **Line-map re-anchoring** (PERFORMANCE.md §3.1) — diffing previous worktree against new worktree, which turns anchoring from a search problem into a lookup
- **Diff-of-diff** (FEATURES.md §1.4) — distinguishing the agent's response to your feedback from its other changes

All three currently hold that state in RAM. Quit `lgtm` and the checkpoint, the anchor chain, and the ability to compare turns are gone. In a long session — exactly the case these features exist for — that is the wrong durability.

**Meanwhile the user is not staging and not committing.** Between the last commit and now there may be an hour of agent work with no recoverable intermediate states.

## 2. The bigger prize

Agents destroy uncommitted work. They rewrite a file you had hand-edited, revert something they wrote twenty minutes ago, or "clean up" a file you never asked them to touch. Today the only recovery is the editor's local history, if you happen to have the file open.

A tool that silently snapshots the working tree before every agent turn is a safety net — and that value is **independent of reviewing**. It may well be a stronger reason to install `lgtm` than the review features are.

---

## 3. Design: borrow git's object store, touch nothing of the user's

Do not invent a content store. Use the one already in the repo, through plumbing that never touches the user's index, HEAD, branches, or stash.

```
GIT_INDEX_FILE=.lgtm/index git update-index --add --remove -- <changed paths>
GIT_INDEX_FILE=.lgtm/index git write-tree                 → <tree>
git commit-tree <tree> -p <prev> -m "turn 7"              → <commit>
git update-ref refs/lgtm/<session>/7 <commit>
```

This is essentially how `git stash` works internally, and it buys a lot for very little:

| Property | Why it matters here |
|---|---|
| Content-addressed | Unchanged files cost zero bytes. A turn touching 3 of 4,000 files stores 3 blobs and a few trees. |
| Real git objects | `git diff refs/lgtm/s1/3 refs/lgtm/s1/7` works with stock plumbing — no custom diff format |
| Refs keep objects alive | Safe from `git gc`. Prune by deleting refs and letting gc follow. |
| Separate index file | The user's staging area is never read or written |
| Custom ref namespace | Invisible to `git branch`, `git status`, and plain `git log` |
| Recoverable by hand | Even without `lgtm`, `git show refs/lgtm/s1/7:src/auth.zig` retrieves a file |

### 3.1 Hard boundaries

Violating any of these turns a safety net into a hazard.

1. **Never write `.git/index`.** Always `GIT_INDEX_FILE=.lgtm/index`. The user's staged changes are sacred.
2. **Never move `HEAD`.** No `checkout`, no `reset`, no `commit`.
3. **Never touch `refs/heads`, `refs/tags`, or `refs/stash`.** Only `refs/lgtm/**`.
4. **Never modify the working tree** without explicit user action (§6).
5. **Respect `.gitignore`.** Do not snapshot `node_modules`, build output, or `.env`.
6. **Degrade silently.** No git repo, shallow clone, or a failing plumbing call → snapshots off, everything else still works. Never block startup.

### 3.2 One caveat to document

Custom refs under `refs/lgtm/` are hidden from `git branch` and `git status`, but `git log --all` does include everything under `refs/`. Users of `--all` will see these commits. Mention it in the README rather than letting someone discover it and file a bug.

---

## 4. When to snapshot

| Trigger | Ref | Notes |
|---|---|---|
| `lgtm` starts | `refs/lgtm/<session>/0` | Baseline. Captures pre-existing uncommitted work. |
| Agent quiescence (NOTIFICATIONS.md §3.1) | `refs/lgtm/<session>/<n>` | The main one — one snapshot per agent turn |
| Agent hook `lgtm notify --done` | same | Exact version of the above |
| User presses `m` (mark reviewed) | tag the current ref as reviewed | Checkpoint and snapshot are the same state — see §5 |
| Before any `lgtm`-initiated write (revert-hunk, restore) | `refs/lgtm/<session>/<n>` | Never destroy without a snapshot first |

Session id: timestamp plus a short random suffix, recorded in `.lgtm/session`. A new `lgtm` process in the same repo continues the existing session if the last snapshot is recent (< 4h), otherwise starts a new one.

### 4.1 Cost

`git add -A` stats every file in the repo — noticeable on a large monorepo. Avoid it: the watcher already knows which paths changed, so update only those:

```
git update-index --add --remove -- src/auth.zig src/routes.zig
```

O(changed files), not O(repo). The baseline snapshot at startup is the one full pass, and it happens once, off the critical path (PERFORMANCE.md §8.5).

New files created by the agent need `--add`; deleted ones need `--remove`. Both come from the watcher event.

### 4.2 Pruning

```toml
[snapshots]
keep_turns = 200        # per session
keep_days = 14          # across sessions
```

Prune by deleting refs; objects become unreachable and normal `git gc` reclaims them. `lgtm gc` runs the ref deletion explicitly for anyone who wants it now.

---

## 5. What this unlocks

### 5.1 Durable checkpoints

`m` stores a ref name in `.lgtm/state.json`, not an in-memory marker. Restart, and "since I last looked" still means the same thing.

The pending-notification badge (NOTIFICATIONS.md §4 rule 3) reads the same state: pending is simply *latest snapshot ≠ reviewed snapshot*. One source of truth, not two.

### 5.2 Restart-safe anchoring

PERFORMANCE.md §3.1 needs the previous worktree content to build the line map. With snapshots that content is a tree object, so the fast path survives a restart instead of falling back to hash search on the first re-diff.

### 5.3 Turn timeline

**The tool is already the viewer.** This is the whole design, and it is what
keeps the feature small. A turn is a *diff source*, and everything above
`core/git.zig` already ignores where a diff came from - hunks, change ids,
syntax, search, the file list, wrapping, the gutter. PLAN.md v0.3 makes that
explicit for `--base <ref>`: the diff source becomes a parameter. The timeline
is that parameter plus a way to choose it.

So the timeline needs a **selector, not a viewer**, and nothing here renders a
file, a hunk or a line. That is the difference between a week of work and an
afternoon.

**There is no tree.** The data is a chain per session (§6) and sessions are a
list, so the deepest structure in the feature is two levels, and the second one
is reached by opening the first rather than by expanding it. A turn *contains* a
set of changed files, which is the shape that invites an expandable tree - and
the answer is that the diff view is already the best display of exactly that.
Building a second, worse one inside a popup, with its own navigation and its own
idea of what a file is, would be the largest thing in the tool and would show
less than pressing Enter does.

**Three ways in, in the order they are reached for.**

| | |
|---|---|
| `]t` / `[t` | one turn back and forward. No overlay, no list: the common case is "what did the last turn do", and it should cost one key |
| `<Space>lt` | the turn list, when the target is further away than stepping |
| `:turn 4` | when the number is already known, usually from something the agent said |

`]t` and `[t` are the primary path on purpose. Stepping is how `]h` and `]f`
already work, the reader knows it, and a list that has to be opened to move one
step is a list that gets opened constantly.

**The list is the list.** `<Space>lt` opens the same overlay as `<Space>f` and
`<Space>lc` - same box, same fuzzy filter, same `J`/`K`, same footer - because a
third kind of list would be a third thing to learn for no gain. One row per
turn:

```
╭─ turns ──────────────────────────────────────────────────╮
│ >                                                        │
│ │   working tree            now        2 files  +12 −3   │
│ ▸ 7  src/auth.zig           2m ago     3 files  +42 −8   │
│ │ 6  tests/                 14m ago    1 file   +9  −0   │
│ ├╯                                                       │
│ │ 5  src/ui/app.zig    ✓    31m ago    6 files  +88 −21  │
│ │ 4  src/ui/app.zig         38m ago    2 files  +14 −6   │
╰─ type to filter  J K move  <CR> open  <Esc> close ───────╯
```

A rail, then four columns and no more: which turn, what it touched, when, how
big. The rail is one column wide and draws `│` for every turn until a restore
forks it (§5.3a), at which point it draws the fork and nothing else changes. The
path column is the turn's largest changed file, elided with `ui/path.zig` like
every other path in the tool - it is what makes a turn recognisable at a glance,
and "3 files" is what stops it pretending to be the whole story. `✓` is the mark
(§5.1): reviewed up to here. `@` is the turn being viewed, in the rail column
where undotree puts its brackets and smartlog puts its `@`. Runs of read turns
fold - see 5.3b, which is the half of this design that makes it work at forty
turns rather than at seven.

**`working tree` is a row, pinned at the top.** The way back has to be in the
same list as the way out, or the reader is somewhere with no visible exit -
which is the one thing a history view must never be. `]t` past the newest turn
lands there too.

**The status row says which turn is on screen, always.** A turn's diff looks
exactly like the working tree's, and mistaking one for the other is the failure
mode that matters here: reading old code as though it were current, or writing a
comment against a line that has since moved. It takes the slot the mark's count
uses, in the accent colour, and it is not optional or elidable.

**The watcher does not move the view.** While a turn is on screen the agent
keeps writing and turns keep accumulating, and re-diffing under the reader would
throw them back to the present mid-sentence. New turns are counted and said -
"2 newer turns" - and `]t` walks to them when the reader is ready.

**Comments are disabled while viewing a turn**, and the status says so rather
than the key doing nothing. A comment anchors to a line in the working tree
(`core/comments.zig`); one written against a historical turn either anchors to a
line that is not there any more, which is a stale comment born stale, or
silently retargets to whatever now occupies that line number, which is worse.
Hard rule 7 is about not losing a reader's remark, and the honest way to keep it
is to not take it. This is an open question below rather than a settled one.

### 5.3a Prior art: undotree, and the branch it forces us to admit

`mbbill/undotree` solves the closest problem anyone has solved: a history of
states, in a terminal, that you step through and restore from. It draws a flat
vertical list with a narrow graph column, newest first, relative times, and the
current node in brackets:

```
  [3] 4 seconds ago
   |
   2  1 minutes ago
   |/
   1  2 minutes ago
   |
   0  Original
```

`git log --graph`, lazygit and tig all draw the same shape. The pattern is worth
copying almost exactly, and three parts of it in particular:

- **A flat list with a rail, not indentation.** Depth as a left margin is for
  containment - files inside a directory, `nvim-tree` and `neo-tree` and
  diffview's file panel. History is not containment, it is sequence, and a
  sequence read down a column is easier than one read across an indent
- **Relative times.** "2m ago" is the question actually being asked of a turn.
  A timestamp is a lookup; an age is an answer
- **The current node marked in the list itself.** undotree's `[3]`; the row
  saying where you are rather than a header saying it somewhere else

**And now the part that changes this document.** undotree draws a graph because
vim's undo history *branches* - undo three times, type something new, and there
are two futures from that point. §6 above says "a linear chain of snapshots per
session", and that is true right up until §5.4 ships: restore to turn 4, let the
agent write, and turn 8's parent is turn 4. `commit-tree <tree> -p <prev>` gives
real parentage, so the branch is not a metaphor, it is in the object store.

That is the same situation vim is in, for the same reason, which is why
undotree's shape is the one to take. It costs nothing to adopt early: with no
branching the rail is a straight line down one column, and the first restore
turns it into a fork without a rewrite. Designing the linear list first and
retrofitting a graph is how this feature becomes a week of work.

So §6's "linear chain" should read **linear until a restore, a shallow tree
after one** - and the list should have its rail column from the first version,
drawing `│` and nothing else until there is something to fork.

### 5.3b The better reference: smartlog, and elision

undotree gets the *shape* right. What it does not have to solve is length: a vim
undo history is browsed in the moment and is usually short. A 40-turn session is
the stated problem this feature exists for (FEATURES.md 1.3), and forty rows in
a twenty-row pane is a scroll, not a view.

Two tools solve exactly that, and better than anything else in a terminal.

**Sapling's smartlog** (`sl`, and `git-branchless`'s `git sl`) is the best commit
graph rendering there is, and the reason is not the rails. It is that **it does
not draw the whole graph**. It draws the commits you are working on, the points
where they join, and it replaces everything uninteresting between them with a
single elided row. `@` marks where you are. The graph stays a screenful no matter
how long the history is, because length was never what the reader wanted.

**broot** does the same thing for depth instead of length: it fits a whole deep
directory tree into the rows available by collapsing branches nobody asked about
and printing a count instead. The tree is never truncated, it is *summarised* -
which is the difference between "there is more" and "there are 340 more, here".

**The idea to take is elision with a count, and it belongs in version one.**
Turns before the mark have been read. They are not gone and they are not
uninteresting - they are the ones the reader has already dealt with, which is
exactly what makes them the ones to fold:

```
╭─ turns ──────────────────────────────────────────────────╮
│ >                                                        │
│ │   working tree            now        2 files  +12 −3   │
│ @ 7  src/auth.zig           2m ago     3 files  +42 −8   │
│ │ 6  tests/                 14m ago    1 file   +9  −0   │
│ ✓ 5  src/ui/app.zig         31m ago    6 files  +88 −21  │
│ ⋮    12 older turns, all read                            │
│ │ 0  original                2h ago                      │
╰─ type to filter  J K move  <CR> open  <Esc> close ───────╯
```

Six rows for a nineteen-turn session, and the two that matter - what is new, and
where you stopped reading - are both on screen without moving. `<CR>` on the
elided row expands it, because a summary that cannot be opened is a wall. Typing
a filter expands everything, because a search that skipped folded rows would be
a search that lies.

`@` rather than `▸` for the current turn: it is what smartlog, `hg log -G` and
half the graph tools in the terminal already use, and it costs nothing to spell
a familiar thing familiarly.

`0 original` is pinned the way `working tree` is. The two ends of the history
are the two places a reader most often wants to jump to, and neither should
require scrolling to a boundary to reach.

### 5.3c Three things a commit graph cannot do

smartlog and undotree are both browsing histories whose rows are *meaningful on
their own*: a commit has a message, an undo state is a thing you did and
remember doing. A turn has neither. It has no message, nobody wrote it, and one
turn looks much like the next - which is why 5.3's row currently falls back to
"the largest file it touched", and why that is the weakest column in this
design.

But a turn history has three things a commit graph does not, and each of them
makes a better row than a message would.

**1. The agent undid its own work, and finding out is a hash comparison.**

Every snapshot is a git tree, so every file in every turn has a blob id, and
`core/diff.zig` already captures `old_blob`/`new_blob` for exactly this kind of
use ("captured even though nothing consumes them yet"). If turn 7's blob for
`auth.zig` equals turn 4's, the agent has walked the file back to where it was
three turns ago. That is not a heuristic and not a diff - it is `==` on two
hashes, O(turns) per file, free.

It is also the single most useful thing anyone can tell a reviewer of agent
output, and no other tool in this space can tell them: *it reverted itself.*
Round-tripping is what agents do when they are stuck, and spotting it in a diff
is nearly impossible because the diff only shows the endpoints.

```
│ ↺ 7  src/auth.zig      2m ago    3 files  +42 −8    back to turn 4
```

**2. Which turn answered your review.**

`core/comments.zig` knows which comments were sent and what line each anchors
to. A turn that touches those lines is the agent responding to you, and a turn
that does not is the agent doing something else. That distinction is the whole
of FEATURES.md 1.4 and half of SPEC.md open question 5, and it is a range
intersection rather than anything cleverer:

```
│ ↩ 6  src/ui/app.zig    14m ago   1 file   +9  −0    answers 2 comments
```

The pair `↺` and `↩` is most of what a reader wants from this list. One says
the agent went backwards, the other says it was listening.

**3. Runs, because agent turns come in them.**

smartlog does not fold adjacent commits, because commits are individually
meaningful. Agent turns are not: four turns in a row on `app.zig` is one piece
of work that took four tries, and drawing it as four rows spends four lines
saying one thing. Fold a run of turns over the same dominant file:

```
│ ⣿ 4-7  src/ui/app.zig  ×4       31m ago   +88 −21   4 turns, one file
```

This is elision by *content* where 5.3b's is elision by *read state*, and the
two compose: a run that is entirely read folds into the `⋮` row with everything
else. `<CR>` expands, the same as the other fold.

**What earns its place and what does not.** The three above are cheap and say
something nothing else says. Two more were considered and rejected for now: a
per-turn sparkline of churn, which costs a column the path needs more and
answers a question nobody asked; and labelling a turn with the enclosing
function name from `syntax/lexer.zig`, which would read beautifully - `turn 7
login()` - and costs a lex of every changed file of every turn, which is the
opposite of the budget this feature is trying to keep.

**Cost, honestly.** `↺` needs blob ids per path per turn, which `git ls-tree -r`
gives in one subprocess per turn and which should be read once and cached beside
the ref, not recomputed per frame. `↩` needs the sent comments' anchors, already
in memory. Run folding needs the dominant path per turn, which falls out of the
same `ls-tree`. None of it needs a diff to be parsed, which is the line to hold:
**the list is built from trees and hashes, never from diffs.** A list that
parses forty diffs to draw itself is the version of this feature that takes a
week and then feels slow.

**What not to take from undotree.** Its persistent split window: `lgtm` has no
persistent panes on purpose (SPEC.md 6.1), the diff owns the screen, and the
list floats over it and closes. And its live preview - undotree redraws the diff
panel as the cursor moves, which here would mean a `git diff` and a parse per
`J`, measured at 30 ms and 43 ms. `<CR>` commits to a turn; moving is free.

**What this is not, so it stays an afternoon.**

- No tree view, no expandable file nodes, no per-hunk turn attribution
- No two-turn comparison UI. It is nearly free once the base is a parameter, but
  the *selection* of two things is a second interaction model, and `[t` from a
  turn already gives the diff of one step, which is the comparison anyone
  actually wants
- No cross-session browsing in the list. Sessions are a second level, and the
  reason to open an old one is recovery, which is `lgtm restore` (§5.4) rather
  than a browser
- No turn *editing*: no squashing, no renaming, no annotating. §6 says not a
  VCS, and every one of those is a VCS

**Build order.** Each step is usable on its own, which is the test of whether
the split is real: 1. `]t` / `[t` with the status row saying where you are, 2.
the list, 3. `:turn N`. Restore (§5.4) is not on this path and does not belong
in the same pass.

**One thing to size before building.** A turn row wants a reviewed marker, and
`FileEntry` has no field for it. Borrowing `status` would be the mistake this
project has already made three times - a default that asserts something false,
which is how `+0 −0` and `.modified` ended up on files that had neither. The
list widget needs a row type that admits it is showing something other than a
file, or a small field that says so.

### 5.4 Restore — the safety net

`R` on a file, or `lgtm restore <path> --turn 4`, writes that version back to the working tree. Requirements: snapshot first, always show a confirmation diff, never restore silently, never restore more than the user selected.

This is the feature people will tell their colleagues about. It is also the most dangerous one in the tool, so it gets the most friction.

### 5.5 Recovering the pre-agent state

`refs/lgtm/<session>/0` is the working tree as it was before the agent ran. "Undo everything this session did" is one diff away — and it is uncommitted work that git alone could never have recovered.

---

## 5.6 Build order for the whole feature

Each step is usable and verifiable on its own, which is the test of whether the
split is real rather than a list of file names.

| | | |
|---|---|---|
| 1 | `snapshot/gitobj.zig` | The plumbing and nothing else: argv in, object ids out. No policy, no UI, no idea what a turn is. Verified from outside with stock git - `git show refs/lgtm/<s>/3:src/auth.zig` must print the file, and `git status` must be untouched. That external check is worth more than any test written against our own code |
| 2 | `snapshot/snapshot.zig` | Policy: session identity, when to take one, pruning. Gated on the watcher's two-consecutive-polls signal (§4), because hashing a file mid-write stores a corrupt turn under a ref that claims to be good |
| 3 | the mark becomes a ref | `core/checkpoint.zig` keeps its interface - `find(path)` returning bytes - and stops holding them. `.lgtm/state.json`. Nothing above it changes, which is the point of having built it that way |
| 4 | `]t` / `[t` + the status row | The timeline, minus the list. Usable: stepping is the common case anyway (§5.3) |
| 5 | the list | `<Space>lt`, with the rail, the elision and the three signals (§5.3a-c) |
| 6 | restore | Its own pass, and the most friction (§5.4) |

Steps 1 to 3 are invisible: at the end of them the tool looks identical and the
mark survives a restart. That is deliberate. The visible half is cheap once the
store is right, and dangerous to build on a store that is not.

---

## 6. Non-goals

- **Not a VCS.** No merging, no conflict resolution, no rebasing, no naming or editing of turns. The chain is linear until a restore and a shallow tree after one (§5.3a) - that much branching is forced by the object store's own parentage and is not a feature, it is what honestly recording "the agent continued from here" looks like.
- **Not a backup.** Local objects only. If the repo is deleted, so are they.
- **Not a commit generator.** `lgtm` never creates commits on any branch, and never suggests commit messages — that is the agent's job.
- **No non-git fallback in v1.** A repo-less directory means snapshots are off - and, since the tool reads `git diff` for a living, it means an empty review that says "not a git repository" rather than one that pretends. A `.lgtm/objects` store is possible later but is a whole content-addressed store to build and prune.
- **A repository with no commits is not the same case, and is fully supported.** `HEAD` does not resolve, so `core/git.zig` retries against `--cached` and every file reads as new, which is what it is. Snapshots work there too: `read-tree HEAD` fails, the empty index is the right start, and `commit-tree` with no parent is the first turn. This is the state a scaffolded project is in, which is exactly when losing work would hurt most.

---

## 7. Where it lives

```
src/
├── snapshot/
│   ├── snapshot.zig    # policy: when, session identity, pruning
│   ├── gitobj.zig      # plumbing calls, GIT_INDEX_FILE isolation
│   └── timeline.zig    # turn navigation, ref ↔ turn mapping
└── core/
    ├── anchor.zig      # gains a tree-object source for the previous state
    └── checkpoint.zig  # the mark, whose store becomes a ref (§5.1)
```

Nothing under `ui/` is listed, and that is the design rather than an omission.
The timeline draws through the file-list overlay and the diff view, both of
which exist; what `ui/` gains is a fourth purpose for the list it already has,
a row type for it, and the status-row line that says which turn is on screen.

`snapshot/` depends on `io/proc.zig` for subprocess calls. It does **not** belong in `core/` — it touches the outside world and shells out.

State file, `.lgtm/state.json`:

```json
{
  "session": "20260826-141822-a3f9",
  "latest_turn": 7,
  "reviewed_turn": 5,
  "baseline_ref": "refs/lgtm/20260826-141822-a3f9/0"
}
```

New `Event` variant (ARCHITECTURE.md §11.4):

```zig
snapshot_taken: struct { turn: u32, ref: []const u8 },
```

---

## 8. Open questions

1. Should untracked-but-not-ignored files be snapshotted? Leaning yes — new files are the agent's most common creation, and losing one is exactly the failure this prevents.
2. Should a snapshot happen on *user* edits too, or only agent turns? Snapshotting everything is simpler and cheaper than deciding who wrote a change.
3. Should `lgtm` offer to convert a turn range into a real commit? Useful, but it edges toward "commit generator" (§6). Probably not.
4. Worktrees and submodules — each worktree has its own `.lgtm/`, but they share an object store. Verify the ref namespace does not collide.
5. Should a comment be writable against a turn (§5.3)? Disabling is the honest default and the one to ship, but the case for allowing it is real: the moment a reader most wants to say something is while looking at what the agent did two turns ago. The middle answer - anchor it to the working tree if the line still exists there, refuse and say so if it does not - is more code than it sounds and needs the line map either way.
6. What happens to the timeline when `--base <ref>` is also set? Two diff sources, one view. Probably: `--base` replaces the working tree as the timeline's "now", and turns above it are still turns. Not designed.
