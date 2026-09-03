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

```
◀ turn 0  1  2  3  4 [5] 6  7 ▶     (bracketed = reviewed up to here)
```

`[t` / `]t` step through turns; the diff view shows that turn's changes. Any two turns can be compared, which is diff-of-diff (FEATURES.md §1.4) with no extra machinery.

### 5.4 Restore — the safety net

`R` on a file, or `lgtm restore <path> --turn 4`, writes that version back to the working tree. Requirements: snapshot first, always show a confirmation diff, never restore silently, never restore more than the user selected.

This is the feature people will tell their colleagues about. It is also the most dangerous one in the tool, so it gets the most friction.

### 5.5 Recovering the pre-agent state

`refs/lgtm/<session>/0` is the working tree as it was before the agent ran. "Undo everything this session did" is one diff away — and it is uncommitted work that git alone could never have recovered.

---

## 6. Non-goals

- **Not a VCS.** No branching, no merging, no conflict resolution. A linear chain of snapshots per session.
- **Not a backup.** Local objects only. If the repo is deleted, so are they.
- **Not a commit generator.** `lgtm` never creates commits on any branch, and never suggests commit messages — that is the agent's job.
- **No non-git fallback in v1.** A repo-less directory means snapshots are off. A `.lgtm/objects` store is possible later but is a whole content-addressed store to build and prune.

---

## 7. Where it lives

```
src/
├── snapshot/
│   ├── snapshot.zig    # policy: when, session identity, pruning
│   ├── gitobj.zig      # plumbing calls, GIT_INDEX_FILE isolation
│   └── timeline.zig    # turn navigation, ref ↔ turn mapping
└── core/
    └── anchor.zig      # gains a tree-object source for the previous state
```

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
