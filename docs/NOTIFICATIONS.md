# `lgtm` — Notifications

**Companion docs:** SPEC.md, ARCHITECTURE.md, FEATURES.md
**Status:** draft v0.1
**Milestone:** v0.2 (layers 1–2), v0.3 (layer 3)

> Added after the initial doc set. Slots into FEATURES.md as §2.4; nothing in the existing docs contradicts it.

---

## 1. The state worth notifying about

`lgtm` can detect a specific, recurring, easily-missed situation:

> **The agent finished, it changed files, and the user has not reviewed them.**

This matters because the user is usually in another window or another pane by then. The agent's own output scrolled past; there is nothing left on screen saying "you have unreviewed changes." The session ends, the branch gets pushed, and nobody read the diff.

Notification scope must therefore be **session-wide, not pane-local**: a different tmux window, a different pane, or a detached session must all still surface the signal.

---

## 2. Three layers

Ordered by reliability. Build downward, not upward.

| Layer | Mechanism | Reach | Requires |
|---|---|---|---|
| **1. Bell** | `\a` (BEL) | tmux status bar flash via `monitor-bell`, works over SSH | nothing |
| **2. tmux user option** | `tmux set-option -g @lgtm_pending "3 files"` | persistent badge in the status bar, any window | user adds `#{@lgtm_pending}` to their status line |
| **3. Desktop** | OSC 9 / OSC 777 / OSC 99, or `notify-send` / `terminal-notifier` | OS notification centre | passthrough config, or a local session |

### 2.1 The trap: tmux swallows OSC notification sequences

Since tmux 3.3, `allow-passthrough` is off by default, so OSC 9 and OSC 777 emitted from inside a pane are discarded. Making them work requires wrapping them in a passthrough sequence **and** telling the user to enable the option in their config.

That is a setup instruction, and setup instructions are where features go to die. **Layer 3 is opt-in and must never be the foundation.** Layers 1 and 2 need no user configuration beyond a status-line variable, and layer 1 needs nothing at all.

### 2.2 Why layer 2 is the sweet spot

`@lgtm_pending` is a tmux user option — set it from anywhere, read it from any window's status line. No passthrough, no escape-sequence filtering, no platform branching. And because it is a persistent badge rather than a transient toast, it cannot be missed the way a notification that fired three minutes ago can.

```sh
# what the user adds once, documented in the README
set -g status-right '#{?#{@lgtm_pending},#[fg=yellow]⚠ #{@lgtm_pending} unreviewed ,}%H:%M'
```

`lgtm` sets and clears the option; the user's status line renders it.

Equivalents exist for WezTerm (user vars via OSC 1337 `SetUserVar`) and kitty (`kitty @ set-user-vars`). Same shape, different call — one method per bridge backend.

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
bell = true               # layer 1
tmux_option = true        # layer 2 — sets @lgtm_pending
option_name = "@lgtm_pending"
desktop = false           # layer 3 — opt-in, needs allow-passthrough
only_when_hidden = true   # rule 2
min_changed_lines = 1     # ignore trivial turns
```

`desktop = false` by default is deliberate. Enabling it without `allow-passthrough` produces silent no-ops, which reads as a broken feature; better that the user turns it on after reading what it needs.

---

## 6. Where it lives

```
src/
├── notify/
│   ├── notify.zig      # policy: quiescence, dedupe, visibility check
│   ├── bell.zig        # layer 1
│   ├── tmux_opt.zig    # layer 2 (+ wezterm/kitty user vars)
│   └── desktop.zig     # layer 3, opt-in
└── io/watch.zig        # gains a second, longer timer
```

`notify/` depends on `bridge/` for backend detection and pane addressing — the detection logic already exists there, so do not duplicate it. It does not belong in `core/`: it touches the outside world.

New `Event` variant (ARCHITECTURE.md §11.4):

```zig
agent_quiescent: struct { files: u32, added: u32, removed: u32 },
```

---

## 7. Later

- **Notify on risk, not just on completion** — "agent finished, and 2 tests were removed" (FEATURES.md §1.2) is a far more urgent signal than "agent finished." Once weakened-test detection exists, fold its result into the notification text.
- **Detached-session case** — if the whole tmux session is detached, layers 1–2 are invisible until reattach. Layer 3 or a shell-prompt hook is the only real answer; probably not worth solving.
