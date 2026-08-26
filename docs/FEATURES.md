# `lgtm` — Features & Customisation

**Companion docs:** SPEC.md, ARCHITECTURE.md, PERFORMANCE.md
**Status:** draft v0.1

---

## 0. The framing that generates everything else

**Reviewing an agent's code is a different problem from reviewing a person's code.**

Higher volume, faster arrival, and — the part that matters — **you have no prior about where the risk is**. Reviewing a colleague's PR, you know their habits, you know which part they rushed. With an agent you know nothing, and it produces confident-looking code uniformly across every file it touches.

Every existing diff tool is built for the human case, and they all assume you will read the whole thing. With an agent, that assumption is false. You will not read 800 lines carefully at 11pm.

So the job is not "display a diff nicely." It is **decide where the user's next three minutes go**. That reframe produces most of the features below.

---

## 1. Tier A — the differentiators

These are the reasons someone installs the tool rather than living with `git diff`.

### 1.1 Risk-ordered hunks

Path-alphabetical ordering is an artifact of human code review. Replace it: **most suspicious hunk first**, with a cheap heuristic score. No AI, just pattern matching:

| Signal | Weight | Rationale |
|---|---|---|
| Deletions > additions | high | Removing working code is where regressions live |
| Touches `catch` / `recover` / `unwrap` / `panic` / `except` | high | Error paths are where agents cut corners |
| Path matches `auth`, `crypto`, `payment`, `migration`, `secret`, `.env` | high | Blast radius |
| Dependency manifest (`*.zon`, `Cargo.toml`, `package.json`, `go.mod`) | high | Supply chain |
| File not mentioned in the prompt | medium | Agent went somewhere you did not send it |
| Test file | medium | See 1.2 |
| Pure formatting / whitespace | negative | Sink it |

Patterns come from config (§4.6) so teams can add their own. Sort order is a toggle (`s`), not a lock-in — sometimes you do want file order.

### 1.2 Weakened-test detection

Agents do this constantly, and it is the failure mode with the worst consequences:

- deleting a test that fails
- adding `skip` / `t.Skip` / `@pytest.mark.skip` / `.only` / `xit`
- loosening an assertion — `assertEqual` → `assertTrue`, exact → `contains`, removing a case from a table test
- wrapping a failing call in a catch that swallows the error
- changing an expected value to match the (wrong) actual output

All of it is detectable with lexer-level pattern matching, and all of it hides in test files — exactly where people skim.

A banner at the top of the session: **`⚠ 2 tests removed · 1 assertion weakened · 1 skip added`**, clickable through to the hunks.

This is concrete, verifiable, and instantly recognisable to anyone who has used an agent for a week. It is the screenshot that goes in the README.

### 1.3 Turn checkpoints — "since I last looked"

In a 40-turn session the accumulated diff becomes meaningless. `lgtm` needs a concept of *the last time you looked*.

- `m` marks the current state as reviewed
- default view shows only the delta since that mark
- `a` shows everything
- the file list shows both counts: `src/auth.rs  +6 -2  (of +24 -6)`

Mechanically this is the anchoring machinery you already have, pointed at a different question. Experientially it changes the tool from "here is a pile" to "here is what happened since you last cared."

### 1.4 Diff-of-diff for round two

You send notes, the agent revises, and now you must re-review. Today you re-read *everything*, unable to distinguish the parts that answer your feedback from the parts the agent changed on its own initiative.

Highlight the second-order change distinctly. Combined with `sent` notes, this also answers "was my note actually addressed?" — a note whose anchored region changed after submission is a strong signal, and it feeds Open Question 5 in SPEC.md.

---

## 2. Tier B — small, high-frequency

### 2.1 Ask presets

One keystroke, common intent, reuses the existing bridge:

| Key | Sends |
|---|---|
| `a` | `#3 src/auth.rs:47 — why this approach?` |
| `!` | `#3 src/auth.rs:47 — revert this, keep the rest` |
| `t` | `#3 src/auth.rs:47 — add a test covering this` |
| `x` | `#3 src/auth.rs:47 — explain what this does` |

All templates are config (§4.5). Users will invent better ones than these.

### 2.2 Blame-lite on the current line

`gb` shows the last commit that touched this line — one `git blame -L`, cached. Answers "was this mine or the agent's?" without leaving the pane.

### 2.3 Copy-as

`y` copies a reference, but *which format* varies by target. `gy` opens a small menu: plain `path:line`, GitHub permalink, markdown link, or the raw line content. See §4.5 — the same template system.

---

## 3. Distribution, not a feature

**Make `lgtm` work as a git pager.**

```sh
git config --global core.pager lgtm
```

Now every git user can use it — including people who have never touched an agent CLI. That audience is enormously larger than "agent users who live in tmux," and it is the on-ramp: they come for a nicer `git diff`, they discover the agent half later.

Cost is low, because the rendering, lexing, and navigation already exist. What is needed is a stdin mode that parses a diff stream instead of invoking git, with agent features simply absent. Worth doing before v1.0 purely as a growth channel.

---

## 4. Customisation

Delight is real value, and for a keyboard tool it is also *retention*. But it is also the classic way a side project dies — so the rule here is: **customisation that costs a config file and no architecture is cheap; anything requiring a plugin runtime is not.**

### 4.1 Themes

Share `look`'s themes so the two tools look like siblings — Catppuccin, Tokyo Night, Gruvbox, Dracula, Rosé Pine, Kanagawa.

Beyond that:
- **Custom themes in TOML.** Every semantic slot nameable: `added`, `removed`, `context`, `hunk_header`, `note_marker`, `risk_high`, `stale`, `line_number`, `cursor_line`.
- **Live reload.** Watching files is already core infrastructure — point it at the theme file too. Editing a theme and watching it apply instantly is genuinely fun, and costs almost nothing given the watcher exists.
- **`lgtm --theme-preview`** renders a sample diff in every bundled theme so people can choose without restarting.
- **Terminal-native mode** — use only the 16 ANSI colours, inheriting the user's terminal palette. A surprising number of people want exactly this.

### 4.2 Fonts — an honest correction

**A TUI cannot set the font.** That is the terminal emulator's job, and `lgtm` should not pretend otherwise. What it *can* control:

- **Nerd Font icons on/off** (`ui.icons = "nerd" | "unicode" | "ascii"`) — file-type glyphs, note markers, risk indicators. Must degrade to ASCII cleanly; a broken glyph looks worse than no glyph.
- **Text attributes** — which semantic slots use bold, italic, underline, or dim. Some people want italic comments; some terminals render italics badly. Make it a choice.
- **Box drawing style** — `ascii | light | heavy | rounded` for borders and separators.
- **Sign column characters** — the `+`/`-`/`●` glyphs are configurable strings, not hardcoded.

### 4.3 Keymaps — fully remappable

Every action is a named command; the keymap is a table from key sequence to command name. No hardcoded keys anywhere in the dispatch path (this is why `Mode` is an enum, ARCHITECTURE.md §11.4).

Ship presets: `vim` (default), `helix`, `emacs`, `plain`. Users override individual bindings without redefining the whole map.

### 4.4 The `?` popup — and a keybinding conflict to resolve

`?` opens a **context-aware** help overlay: only the keys valid in the current mode, grouped, with the user's *actual* bindings rather than the defaults. Fuzzy-searchable within the popup.

This is the highest-value discoverability feature in any TUI. Every key the user never finds is a feature that does not exist.

**But `?` is currently triple-booked**, and this needs deciding now rather than after muscle memory forms:

| Claimant | Resolution |
|---|---|
| vim reverse search | **Drop it.** `/` plus `N` covers reverse search completely. Genuinely redundant. |
| "ask why" preset | **Move to `a`.** Free, mnemonic, one key. |
| help popup | **Wins `?`.** Every TUI people already use (lazygit, k9s, btop) binds `?` to help. Discoverability beats a redundant vim binding. |

`F1` and `g?` alias to the same popup.

### 4.5 Template strings — the sleeper feature

Different agents like different reference formats, and users have strong opinions. Make every outgoing string a template:

```toml
[templates]
ref_single = "#{change_id} {path}:{line}"
ref_range  = "#{change_id} {path}:{start}-{end}"
ask_why    = "{ref} — why this approach?"
review_header = "# Review {n} — {date}"
review_item   = "## {ref}\n```{lang}\n{snippet}\n```\n{body}"
submit_msg    = "Please address the review notes in {file} "
```

This is cheap to build and disproportionately loved, because it lets people tune the tool to *their* agent's habits without a PR. It also future-proofs against agents that appear after you stop maintaining this.

### 4.6 Risk rules

The §1.1 scoring table is config, not code:

```toml
[[risk.rules]]
pattern = "path:**/migrations/**"
weight = 40
label = "migration"

[[risk.rules]]
pattern = "content:TODO|FIXME|XXX"
weight = 10
```

Teams add their own sensitive paths. This is also how the feature stays honest — the heuristic is visible and editable rather than a black box.

### 4.7 Layout

```toml
[layout]
file_list = "top"        # top | left | hidden
file_list_size = 0.25
statusline = "{mode} {file} {change_id} {notes} {risk}"
```

Statusline as a format string, tmux/lualine style. People will spend an hour on this and enjoy every minute.

### 4.8 Per-repo config

`.lgtm/config.toml` overrides `~/.config/lgtm/config.toml`. Different repos want different risk rules, different languages, different bridge targets. Merge, do not replace.

### 4.9 Config errors must be excellent

A tool that fails to start because of a typo in a theme file is a tool people uninstall. Rules: never fail to start on a bad config. Report the file, line, and the offending key; fall back to defaults for that key only; show the error in the status line, not a crash.

---

## 5. Where these land

| Feature | Milestone | Notes |
|---|---|---|
| `?` help popup | **v0.1** | Ship with the first keybinding, not after |
| Themes (bundled) | v0.1 | Reuse `look`'s |
| Ask presets | v0.1 | Trivial once the bridge exists |
| Keymap remapping | v0.2 | Needs the command-name indirection from day one |
| Template strings | v0.2 | Ships with review notes |
| Turn checkpoints (`m`) | v0.2 | Same machinery as anchoring |
| Weakened-test detection | v0.2 | Needs the lexer |
| Risk ordering | v0.3 | Needs tuning against real sessions |
| Custom themes + live reload | v0.3 | |
| Diff-of-diff | v0.3 | Needs checkpoints first |
| Git pager mode | pre-v1.0 | Growth channel |
| Blame-lite | v1.0+ | |

**The discipline:** `?` and themes ship in v0.1 because they cost nothing and set the tone. Everything else in §4 waits until the thing it customises actually exists. Building a theme engine before the diff renders correctly is how projects die.

---

## 6. What not to build

| Idea | Why not |
|---|---|
| Plugin runtime (Lua/WASM) | An enormous surface for a tool this size. Templates and config cover 90% of what plugins would be used for. |
| AI-powered review summaries | You have an agent in the next pane. Do not compete with it. |
| Team sync / shared notes | SPEC.md §6.5 non-goal. Single user, single session. |
| Mouse support beyond scroll | Contradicts the pitch. Scroll only. |
| Configurable diff algorithm | One good algorithm, well tuned. Choice here is a support burden, not a feature. |
