# `lgtm` — Notifications

**Companion docs:** SPEC.md, ARCHITECTURE.md, FEATURES.md
**Status:** draft v0.1
**Milestone:** v0.2, after SNAPSHOTS.md 5.6 step 3 - the pending state *is* the
checkpoint state (rule 3), so building this first would build that state twice

> Added after the initial doc set. Slots into FEATURES.md as §2.4; nothing in the existing docs contradicts it.

---

## 1. The state worth notifying about

`lgtm` can detect a specific, recurring, easily-missed situation:

> **The agent finished, it changed files, and the user has not reviewed them.**

This matters because the user is usually in another window or another pane by then. The agent's own output scrolled past; there is nothing left on screen saying "you have unreviewed changes." The session ends, the branch gets pushed, and nobody read the diff.

Notification scope must therefore be **session-wide, not pane-local**: another pane, another tmux window, another terminal tab, or another application entirely must all still surface the signal. Side by side with the agent is one arrangement among many and the least in need of this - which is exactly why the feature must not be designed around it.

---

## 2. One method per backend, not three layers

An earlier draft of this section ordered the delivery mechanisms as three
layers - bell, then tmux user option, then desktop - and said to build downward.
That ordering was **tmux-shaped**, and it is wrong for a tool that means to run
under ghostty, kitty, WezTerm and whatever comes next.

The whole argument for putting desktop notifications last was that tmux discards
OSC 9 and OSC 777 unless `allow-passthrough` is on, which it has not been since
tmux 3.3. That is a tmux problem. Run `lgtm` directly in a terminal that speaks
OSC 9 and the "hard" layer is a single escape sequence with no setup at all,
while the "easy" layer - a tmux user option - does not exist. The difficulty
ordering inverts the moment you leave tmux, so it was never an ordering.

**Notification delivery is the same problem the bridge already solves.** Sending
a reference to an agent is one method per backend, detected from the
environment, with a fallback for the unknown case and an exhaustive switch so a
new backend cannot be half-added. Notifying is that again, and it belongs beside
it rather than in a subsystem of its own:

| Backend | Native mechanism | Setup |
|---|---|---|
| tmux | `set-option -g @lgtm_pending "3 files"` | user adds `#{@lgtm_pending}` to their status line |
| ghostty, kitty | OSC 9 | none |
| WezTerm | user var, OSC 1337 `SetUserVar` | user renders it in their config |
| Zellij | none worth having | falls through |
| unknown | nothing, said plainly | - |

The fallback is *nothing*, and saying so. There is no universal notification the
way OSC 52 is a universal clipboard, and a bell pretending to be one is worse
than an honest absence - see 2.2.

### 2.1 Prefer a persistent indicator to a transient one

The choice that matters is not which escape sequence. It is whether the signal
**stays**.

A badge - the tmux option, a WezTerm user var - is ambient. Nothing to dismiss,
nothing lost by not looking, and it is still there when you come back. A bell or
a toast happens once and is gone.

That distinction decides the feature, because the trigger is a **guess**.
Quiescence detection (§3.1) says "quiet for ten seconds, therefore done", and a
long-thinking agent trips it mid-turn. Consider what each kind of signal does
with a wrong guess:

- a badge appears slightly early, and then goes on being correct
- a bell rings, you look, nothing has finished, and the signal is spent

An imprecise trigger is survivable behind a persistent indicator and corrosive
behind a transient one. Three early bells in a turn is how a feature gets
muted, and a muted feature is a deleted feature.

So: **badge where the backend has one, notification where the backend has one
for free, bell nowhere by default.**

### 2.2 The bell is not a fallback

`\a` reaches every terminal, which makes it tempting as the universal case. It
is the wrong universal case: it is transient (2.1), it is the sound the terminal
makes when something is *wrong*, and on a mis-timed guess it trains the user to
ignore it. `[notify] bell = false` by default. Available for anyone who wants
it, chosen rather than inherited.

### 2.3 The one that needs no backend at all

`lgtm` can say it in its own status row: "3 unreviewed turns". It reaches
nobody who is looking at another window, which is the case this document exists
for, so it is not a substitute. But it costs nothing, it needs no detection and
no configuration, and it is already half-specified as SNAPSHOTS.md 5.3's
"2 newer turns". Build that first, whatever else happens here.

---

## 3. Detecting that the agent is done

Two independent mechanisms. Ship both; they cover different failure modes.

### 3.1 Quiescence detection (default, no cooperation required)

Files change, then go quiet for `notify.quiet_ms` (default 10,000). Treat that as end-of-turn.

```
write ─ write ─ write ─────────── 10s silence ─────────► "agent done"
                          ▲
                    timer starts on last write
```

Works with every agent, present and future, because it observes the filesystem rather than the agent. Imprecise — a long-thinking agent mid-turn can trip it — but the failure mode is a slightly early notification, which is harmless.

Reuse the existing debounce timer in `io/watch.zig`; this is a second, much longer threshold on the same clock.

### 3.2 Agent hook (opt-in, exact)

Agents that expose lifecycle hooks can call `lgtm` directly. Claude Code's Stop hook fires at end of turn:

```json
{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "lgtm notify --done" }] }] } }
```

Exact, no guessing, no timer. Documented as an upgrade, never a requirement.

### 3.3 Required: a `notify` subcommand

Both paths need `lgtm` to accept a signal from outside the running TUI:

```
lgtm notify --done          # agent finished a turn
lgtm notify --message TEXT  # arbitrary signal
```

Implementation: write to a small state file in `.lgtm/` (or a unix socket if one already exists for other reasons); the running instance picks it up through the existing watcher. **Do not add a daemon** — that contradicts the "kill it and restart it" property in ARCHITECTURE.md §1.

If no instance is running, `lgtm notify` still sets the tmux badge, so the signal survives.

---

## 4. Anti-annoyance rules

These matter as much as the delivery mechanism. A notification feature that fires too often gets muted, and a muted feature is a deleted feature.

1. **One notification per quiet period**, not one per file. Six changed files is one signal.
2. **Silent when the `lgtm` pane is visible.** Check before firing:
   ```sh
   tmux display-message -p -t "$pane" '#{&&:#{window_active},#{pane_active}}'
   ```
   If the user is already looking at the diff, there is nothing to tell them.
3. **Badge clears on `m`** (mark reviewed, FEATURES.md §1.3). The pending state and the checkpoint state are the same state — do not track them separately.
4. **No repeat nagging.** If the user ignores it, that is an answer. Re-notify only after a *new* quiet period following *new* changes.
5. **Nothing fires when there are no changes.** An agent turn that only reads files is not an event.

---

## 5. Configuration

```toml
[notify]
enabled = true
quiet_ms = 10000          # silence after last write before "done"
bell = false              # transient, and the trigger is a guess - see 2.2
badge = true              # the backend's persistent indicator, where it has one
option_name = "@lgtm_pending"
desktop = true            # where the backend does it without setup; no-op elsewhere
only_when_hidden = true   # rule 2
min_changed_lines = 1     # ignore trivial turns
```

`desktop = true` is safe here in a way it was not under the old layering,
because it means "use OSC 9 where the backend natively supports it" rather than
"emit OSC 9 and hope". Under tmux without `allow-passthrough` the backend
reports that it cannot, and nothing is emitted - the same shape as the bridge
falling back to OSC 52 rather than pretending `send-keys` worked.

---

## 6. Where it lives

```
src/
├── bridge/
│   ├── bridge.zig      # gains notify(): the same union, a second verb
│   ├── tmux.zig        # set-option -g @lgtm_pending
│   ├── ghostty.zig     # OSC 9
│   └── ...             # one file per backend, as today
├── notify/
│   └── notify.zig      # policy only: quiescence, dedupe, visibility check
└── io/watch.zig        # gains a second, longer timer
```

Delivery lives in `bridge/`, not in a `notify/` of its own. It is the same
detection, the same pane addressing and the same exhaustive switch, and a second
copy of all three would drift from the first. What `notify/` keeps is the part
that is genuinely its own: when to fire, whether the user is already looking,
and not firing twice for one turn.

`io/watch.zig` gains the longer timer - which the snapshot store needs anyway
for its turn boundaries (SNAPSHOTS.md 4), so it is built there and read here
rather than the other way round.

New `Event` variant (ARCHITECTURE.md §11.4):

```zig
agent_quiescent: struct { files: u32, added: u32, removed: u32 },
```

---

## 7. Later

- **Notify on risk, not just on completion** — "agent finished, and 2 tests were removed" (FEATURES.md §1.2) is a far more urgent signal than "agent finished." Once weakened-test detection exists, fold its result into the notification text.
- **Detached-session case** — a detached tmux session hides its own badge until reattach. A desktop notification or a shell-prompt hook is the only real answer, and only the first is cheap; probably not worth solving.
