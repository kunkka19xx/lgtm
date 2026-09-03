# `lgtm` - Features & Customisation

**Companion docs:** SPEC.md, ARCHITECTURE.md, PERFORMANCE.md
**Status:** draft v0.1

---

## 0. The framing that generates everything else

**Reviewing an agent's code is a different problem from reviewing a person's code.**

Higher volume, faster arrival, and - the part that matters - **you have no prior about where the risk is**. Reviewing a colleague's PR, you know their habits, you know which part they rushed. With an agent you know nothing, and it produces confident-looking code uniformly across every file it touches.

Every existing diff tool is built for the human case, and they all assume you will read the whole thing. With an agent, that assumption is false. You will not read 800 lines carefully at 11pm.

So the job is not "display a diff nicely." It is **decide where the user's next three minutes go**. That reframe produces most of the features below.

---

## 1. Tier A - the differentiators

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

Patterns come from config (§4.6) so teams can add their own. Sort order is a toggle (`s`), not a lock-in - sometimes you do want file order.

### 1.2 Weakened-test detection

Agents do this constantly, and it is the failure mode with the worst consequences:

- deleting a test that fails
- adding `skip` / `t.Skip` / `@pytest.mark.skip` / `.only` / `xit`
- loosening an assertion - `assertEqual` → `assertTrue`, exact → `contains`, removing a case from a table test
- wrapping a failing call in a catch that swallows the error
- changing an expected value to match the (wrong) actual output

All of it is detectable with lexer-level pattern matching, and all of it hides in test files - exactly where people skim.

A banner at the top of the session: **`⚠ 2 tests removed · 1 assertion weakened · 1 skip added`**, clickable through to the hunks.

This is concrete, verifiable, and instantly recognisable to anyone who has used an agent for a week. It is the screenshot that goes in the README.

### 1.3 Turn checkpoints - "since I last looked"

In a 40-turn session the accumulated diff becomes meaningless. `lgtm` needs a concept of *the last time you looked*.

- `m` marks the current state as reviewed
- default view shows only the delta since that mark
- `a` shows everything
- the file list shows both counts: `src/auth.rs  +6 -2  (of +24 -6)`

Mechanically this is the anchoring machinery you already have, pointed at a different question. Experientially it changes the tool from "here is a pile" to "here is what happened since you last cared."

### 1.4 Diff-of-diff for round two

You send notes, the agent revises, and now you must re-review. Today you re-read *everything*, unable to distinguish the parts that answer your feedback from the parts the agent changed on its own initiative.

Highlight the second-order change distinctly. Combined with `sent` notes, this also answers "was my note actually addressed?" - a note whose anchored region changed after submission is a strong signal, and it feeds Open Question 5 in SPEC.md.

---

## 2. Tier B - small, high-frequency

### 2.1 Ask presets

One keystroke, common intent, reuses the existing bridge:

| Key | Sends |
|---|---|
| `a` | `#3 src/auth.rs:47 - why this approach?` |
| `!` | `#3 src/auth.rs:47 - revert this, keep the rest` |
| `t` | `#3 src/auth.rs:47 - add a test covering this` |
| `x` | `#3 src/auth.rs:47 - explain what this does` |

All templates are config (§4.5). Users will invent better ones than these.

### 2.2 Blame-lite on the current line

`gb` shows the last commit that touched this line - one `git blame -L`, cached. Answers "was this mine or the agent's?" without leaving the pane.

### 2.3 Copy-as

`y` copies a reference, but *which format* varies by target. `gy` opens a small menu: plain `path:line`, GitHub permalink, markdown link, or the raw line content. See §4.5 - the same template system.

---

## 3. Distribution, not a feature

**Make `lgtm` work as a git pager.**

```sh
git config --global core.pager lgtm
```

Now every git user can use it - including people who have never touched an agent CLI. That audience is enormously larger than "agent users who live in tmux," and it is the on-ramp: they come for a nicer `git diff`, they discover the agent half later.

Cost is low, because the rendering, lexing, and navigation already exist. What is needed is a stdin mode that parses a diff stream instead of invoking git, with agent features simply absent. Worth doing before v1.0 purely as a growth channel.

---

## 4. Customisation

Delight is real value, and for a keyboard tool it is also *retention*. But it is also the classic way a side project dies - so the rule here is: **customisation that costs a config file and no architecture is cheap; anything requiring a plugin runtime is not.**

### 4.1 Themes - shipped, bar live reload

Share `look`'s themes so the two tools look like siblings - Catppuccin, Tokyo Night, Gruvbox, Dracula, Rosé Pine, Kanagawa. All six ship, alongside `terminal`, which is the default.

**A theme is a `Palette` - a dozen colours - plus one shared mapping onto the semantic slots.** That mapping is written once, in `fromPalette`, which is what stops seven themes from becoming seven chances to get "the accent, recessed" subtly different, and makes adding a slot one edit rather than seven. The consistency is asserted rather than trusted: every bundled theme is checked for an accent distinguishable from its own greys, an add sign distinguishable from its delete sign, and text that survives being drawn on its cursor line.

Rosé Pine is the case that justified the structure. It has no green, and picking one by eye is how a port ends up with an unreadable add sign, so it uses the palette's own published ANSI mapping instead.

Beyond that:
- **Custom themes in TOML.** Every semantic slot nameable: `added`, `removed`, `context`, `hunk_header`, `note_marker`, `risk_high`, `stale`, `line_number`, `cursor_line`, `accent`. **Shipped**, over the top of a named theme: `[theme] name = "gruvbox"` then any slot. The slot names are the renderer's own, with aliases for the ones this list names differently; the slots for features that do not exist yet (`note_marker`, `risk_high`, `stale`) are reported as unknown rather than accepted and ignored. A style is a colour plus attributes in any order - `"#a6e3a1 bold"`, `"#1e1e2e on 3 underline"` - because a config file is typed by hand.
- **One named primary.** `accent` is the theme's primary colour, set once rather than picked per call site - the `?` popup's key column is the first thing drawn in it, and `popup_border` is the same hue dimmed, so the box and its keys read as one object. A terminal has no opacity, so `dim` is what stands in for it; terminals that ignore the attribute simply get the undimmed hue, which is still correct. It exists because that column shared `hint`'s grey with `comment`, `punct` and `dim`, so the keys read as commented-out code instead of as keys. Any slot that ends up grey next to other greys is a bug in the palette, not in the drawing.
- **Live reload.** Watching files is already core infrastructure - point it at the theme file too. Editing a theme and watching it apply instantly is genuinely fun, and costs almost nothing given the watcher exists. Not built: the watcher follows the git worktree, and pointing it at a file outside the repo is a change to what it watches rather than a change to the theme.
- **`lgtm --theme-preview`** renders a sample diff in every bundled theme so people can choose without restarting. **Shipped**, and `--theme <name>` tries one for a single run. It writes SGR straight to stdout rather than going through vaxis: it runs before any terminal setup, and a preview that needed the alt screen would have to tear it down once per theme. That encoder is the only hand-written escape sequence in the codebase.
- **Terminal-native mode** - use only the 16 ANSI colours, inheriting the user's terminal palette. A surprising number of people want exactly this. **Shipped, and it is the default**: `terminal` is what `lgtm` opens in, so the tool arrives already matching the terminal around it and needs no configuration at all. It steps outside the 16 in exactly one place, the cursor-line background, which the 16 do not contain.

### 4.2 Fonts - an honest correction

**A TUI cannot set the font.** That is the terminal emulator's job, and `lgtm` should not pretend otherwise. What it *can* control:

- **A travelling cursor** (`ui.cursor_ms`, default 80, `0` disables) - the block moves to where a motion put it rather than appearing there, for *every* motion. **Ships on.** Chased in screen cells rather than in rows and byte offsets: a column, a wrapped line and a scrolling viewport all move the cursor across the same grid, and chasing a cell handles the three without knowing about any of them.
- **Smooth scrolling** (`ui.scroll_ms`, default 250, `0` disables) - whether a jump travels into place or the screen changes between one frame and the next. **Ships on.** Constant speed with a floor of one screen row per frame, which is the finest a cell grid can express; the setting bounds how long a *long* jump may take, and a short one arrives sooner because it runs out of rows. One key rather than a flag and a duration, because they are the same decision spelled twice and `0` already says off. The loop blocks while the viewport is settled and paces itself at 60 Hz only while one is in flight, so a review pane that is idle - which is nearly all of the time - still costs nothing.
- **Soft wrap on/off** (`ui.wrap`, `zw`) - whether a line wider than the pane continues on the next screen row or is cut at the edge. **Ships on.** The pane this tool is designed for is a split one, and a diff that hides the end of every long line is a diff of the part that fit. It stays a rendering decision and never reaches the row model: one body row is one line of the file whatever it wraps onto, so motions, selections and references are unchanged, and the reader who wants the shape of the code back gets it with one key.
- **Nerd Font icons on/off** (`ui.icons = "nerd" | "unicode" | "ascii"`) - file-type glyphs, note markers, risk indicators. Must degrade to ASCII cleanly; a broken glyph looks worse than no glyph. **All three ship.** `nerd` adds a file-type icon to the file list and changes nothing else: a patched font puts glyphs *in*, it does not move a box corner, and a set that also restyled the borders would be a second theme rather than an icon switch. It stays opt-in because the icons are private-use codepoints, which draw as tofu in a font that lacks them.
- **The icon is coloured by filetype and the name by status** - the oil.nvim and neo-tree arrangement, where the shape and hue together find the Zig file before any name is read. Both colours come from the theme's palette rather than from six hardcoded brand values, so `[theme] name = "gruvbox"` moves the icons with everything else. `Theme.hues` exists for exactly this: a consumer that wants a raw colour rather than one of the semantic slots.
- **File status is colour, not a letter column.** Green arrived, red left, amber changed, blue moved, grey cannot be read. A column of `A`/`D`/`M` beside the paths is a second alphabet to learn and a column the path does not get; the colour says the same thing in no space at all. Asserted per theme: no two statuses may share a hue, or two statuses are one status.
- **Text attributes** - which semantic slots use bold, italic, underline, or dim. Some people want italic comments; some terminals render italics badly. Make it a choice.
- **Box drawing style** - `ascii | light | heavy | rounded` for borders and separators.
- **Sign column characters** - the `+`/`-`/`●` glyphs are configurable strings, not hardcoded.

### 4.3 Keymaps - fully remappable

Every action is a named command; the keymap is a table from key sequence to command name. No hardcoded keys anywhere in the dispatch path (this is why `Mode` is an enum, ARCHITECTURE.md §11.4).

**Shipped, through `[keys]`:** a command is rebound by naming it and the keys, spelled the way the `?` popup spells them - `next_file = ["]w", "<Space>nf"]`, and `[]` to unbind. `keymap.parseChords` is the exact inverse of the popup's renderer, pinned by a round-trip test over every default binding, because a key read off `?` and pasted into a config that refuses it is a bug only a user would find. A list binds several; the first is the one advertised, the rest are aliases, exactly as `]f` and `<Space>nf` already were.

Remapping is also what caught the status-line strip lying. It held finished text per binding (`"]f [f file"`), so rebinding `next_file` left it advertising a key that did nothing - the precise failure this section says the design prevents. The strip now holds the *label* (`"file"`), renders the keys from the chords, and gives bindings that share a label one entry.

Ship presets: `vim` (default), `helix`, `emacs`, `plain`. Users override individual bindings without redefining the whole map.

**The leader.** `<Space>` fronts the command namespace, so it can grow without competing for single keys. It is defined once as `keymap.leader`, which is what lets a preset move it to `,` or `\` in one edit instead of a sweep over every sequence. Two rules keep it working:

- **Never bind the leader on its own.** The matcher resolves an exact match as soon as it finds one, so a bare-leader binding would shadow every sequence behind it - the sequences would still be listed, and silently never fire. Pinned by a test rather than a comment.
- **A motion outranks a command for a direct key, and three keys changed hands to prove it.** `e`, `t` and `F` were `open_editor`, `ask_test` and `file_list`; they are now `word_end`, `till_char` and `find_char_back`, with the commands on `<Space>e`, `<Space>t` and `<Space>f`. Half a set of vim motions is worse than none - a hand that knows `e` does not un-know it because this is a reviewer - and by the rule below, a key pressed dozens of times a minute beats one pressed a few times an hour. All three keep their row in `?`, and `[keys]` puts them back in one line each for anyone who disagrees.
- **Leader fronts commands, not hot motions.** Anything pressed dozens of times per review earns a direct key; the leader is for what you reach for occasionally. Where both exist (`<Space>nf` alongside `]f`) the leader form is the discoverable alias, not the replacement.

A remapping user can rebind either form independently: both are ordinary rows in the table pointing at the same `Command`.

### 4.3b The empty screen - the wordmark, shipped

A clean tree is not a rare state, it is the resting state: a pane running beside an agent sits on it every moment the agent is thinking, and every moment before it has written anything at all. It was one dim sentence in the top-left corner, which is the screen the tool is looked at on most saying the least.

**Shipped:** the README's wordmark, centred, over the version, the author, and the key that opens the help. Four facts and nothing else - a screen this frequent earns its space by staying quiet, so there is no border, no box and no tip of the day.

The wordmark lives in `Glyphs` beside the box corners rather than in the theme, because a terminal that cannot draw block elements needs a different *picture*, not a different colour: `ui.icons = "ascii"` swaps in a 26-column figlet that is pure 7-bit, which the same test that guards the rest of the ascii set now checks row by row. The key is looked up from the bindings rather than written as `?`, so a remapped keymap still documents itself - this screen is the only place a reader who has not opened the popup yet can learn how to.

The name is a **clickable link** to the author's GitHub, as an OSC 8 hyperlink rather than a printed URL: the address itself is noise on a screen this small, the escape occupies no columns so it cannot move the layout, and a terminal that cannot follow it draws the name exactly as it would have anyway. tmux passes OSC 8 through from 3.4 and strips it cleanly before that, so there is nothing for a caller to check. `Frame.putLink` is where it lives, because a file path in the status line is the obvious next thing to want it.

Geometry is a pure function (`splash.place`), which is what makes the awkward sizes testable without a terminal: a pane too narrow for the picture, or too short for the lines under it, falls back to exactly the sentence that was there before rather than spilling over the edge. At 40 columns the unicode wordmark fits precisely, which is the narrowest pane the rest of the UI is tested at.

### 4.4 The `?` popup - conflict resolved, overlay shipped

`?` opens a **context-aware** help overlay: only the keys valid in the current mode, with the user's *actual* bindings rather than the defaults.

This is the highest-value discoverability feature in any TUI. Every key the user never finds is a feature that does not exist.

**Shipped:** `?` opens a box floating over the diff - and over the empty screen too, which is when a reader is most likely to want it, since a review with nothing in it offers nothing to learn the keys from - sized to its contents and centred, so the review stays visible around it and the overlay reads as a layer rather than a screen. `Esc` closes it, as does backspacing past the start of an empty filter.

`help` is a real `Mode`, and inside it the keymap serves only navigation: `J`/`K` move the selection by a row and `H`/`L` change tab in `?` and page the grid in the file list (the arrow keys and `<C-n>`/`<C-p>` alias them), and every other keystroke is filter text - so `j` cannot scroll a body the user cannot see and `q` cannot quit. Navigation stays in the binding table rather than being hardcoded in the popup, so it is remappable like everything else.

Shifted rather than `<C-j>`/`<C-k>`, deliberately. A Ctrl chord is the one thing a multiplexer takes before the application sees it: vim-tmux-navigator binds `C-h`/`C-j`/`C-k`/`C-l` at the tmux **root** table and forwards them only to processes matching its vim pattern, which `lgtm` does not match - so under that very common config `<C-j>` switches a tmux pane and never arrives. tmux decides from the *process name*, so an application cannot ask for the chord back only while a popup is open; adding `lgtm` to `@vim_navigator_pattern` claims those keys for the whole session instead. `<C-j>`/`<C-k>` are therefore not bound at all: a footer advertising a key the user cannot press is worse than one key fewer. The shifted pair is free, and nothing intercepts an arrow either.

Capitals cost nothing here: inside the popup every other key is filter text, and the filter matches case-insensitively, so `J` was never going to be typed as a query.

The same reasoning applied to `<C-l>` for refresh, which that config also swallows, leaving reload unreachable under it. **Resolved by moving the key rather than adding a second one:** reload is `<C-r>`, which is the reload key everywhere else and which nothing in that config takes, so there is one key to learn instead of two.

Typing filters as you go, over the descriptions **and** the rendered keys, so `space` finds the leader bindings. Matching is a subsequence in two tiers - a run of the query as typed sorts above scattered letters, without which "file" surfaces "gg first line" next to "next file" and the list reads as noise.

Every row is rendered from the bindings by `keymap.writeChords`, so a remapped key moves in the overlay too, and a test refuses a binding that is advertised in the hint strip but explains nothing in `?`. Two columns where the width allows, one where it does not, and the selected row marked the way the body marks its cursor line. The popup's own keys sit along the bottom border with the filter hint, and keys that share a description collapse into one label - four bindings become `J K move  H L tab`, because four rows each saying the same word is the verbose spelling of it. **The list is tabbed**, because forty-eight keys in one column is a list nobody reads to the end of: `move`, `jump`, `send`, `find`, `view`, with `H`/`L` cycling them. The strip is let into the *top border* rather than given a row of its own - a box already has a top edge, and a popup in an 80x24 pane cannot spend one of its rows on labels for its rows. `H`/`L` cost nothing to reassign because they were already bound and already advertised: sideways used to be one column of the grid, and the grid has been one column wide since the two-column layout was rejected, so both keys were bound to a movement that could not happen. **The filter cuts across every tab** and un-highlights the strip while it has text in it, because *finding* a key must not require knowing which tab it was filed under; the tabs are for browsing, the filter is for finding, and they are not the same task. Five groups and no more: the strip has to fit the top border at 80 columns, and a reader hunting for a key already knows which of those five things they are trying to do. A list too tall for the box scrolls a whole column at a time so the columns stay aligned, with `+N more` counting what is below, and "no key matches" when the filter excludes everything - a silently short key list is indistinguishable from a keymap that really is that small.

**Still to come:** grouping by category, and ranking beyond the two tiers. `F1` and `g?` aliases are not bound.

**`?` was triple-booked**, and was resolved before muscle memory could form:

| Claimant | Resolution |
|---|---|
| vim reverse search | **Drop it.** `/` plus `N` covers reverse search completely. Genuinely redundant. |
| "ask why" preset | **Move to `a`.** Free, mnemonic, one key. |
| help popup | **Wins `?`.** Every TUI people already use (lazygit, k9s, btop) binds `?` to help. Discoverability beats a redundant vim binding. |

`F1` and `g?` are intended to alias the same popup; neither is bound yet.

### 4.5 Template strings - the sleeper feature

Different agents like different reference formats, and users have strong opinions. Make every outgoing string a template:

```toml
[templates]
ref_single = "#{change_id} {path}:{line}"
ref_range  = "#{change_id} {path}:{start}-{end}"
ask_why    = "{ref} - why this approach?"
review_header = "# Review {n} - {date}"
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

Teams add their own sensitive paths. This is also how the feature stays honest - the heuristic is visible and editable rather than a black box.

### 4.7 Layout

```toml
[layout]
file_list = "hidden"     # top | left | hidden
file_list_size = 0.25
statusline = "{mode} {file} {change_id} {notes} {risk}"
```

**The file list ships as an overlay** rather than as any of the three panes: the same box the `?` popup uses, with the same filter, `J`/`K` to move, `H`/`L` to page, and `Enter` to jump.

**A path too long for the box loses its middle, not its name.** A terminal clips from the right for free, and for a path that removes exactly the wrong end: eight rows of `apps/macos/LauncherApp/look-app/Views/Launcher/LauncherVi` are the same row eight times, because the directories they share are all that survived and the name that told them apart is what fell off. `ui/path.zig` keeps the file name whole and spends the head instead, so the reader still knows roughly where in the tree they are and can still tell two files apart. When even the name will not fit, the *name* is elided in its middle rather than at one end, because names that collide usually collide at one end - `LauncherView.swift` beside `LauncherViewModel.swift` differ only in the middle. The counts keep their column rather than being pushed off by a long path, so a narrow pane shows the name and the size of the change instead of neither. It costs rows only while it is open, which is the argument that made `hidden` the default in the first place - a list is navigation, and navigation should not hold territory while you read. `file_list = "top" | "left"` remain unbuilt.

**The default changed to `hidden` after the mockups** (`lgtm TUI Mockups.dc.html`,
option 2a). A persistent list costs about five of twenty-six rows permanently,
and the list is navigation, which should not hold territory while you read.
Files are reached with `]f` and the full list on `<Space>f`. `top` and `left` remain
supported - they are 1a and 1b, and both were drawn.

Two consequences worth recording. The side-by-side view (1c) already uses this
same chrome, so when it lands in v0.3 it swaps the body rather than re-laying
out the screen. And the sign column defaults to classic `+`/`-` (option 1o B),
which is what every other mockup in the doc already draws; `ui.icons` below
still selects the glyph set.

Statusline as a format string, tmux/lualine style. People will spend an hour on this and enjoy every minute.

### 4.7b Navigation policy

Motions that could reasonably go either way are settings rather than opinions baked into dispatch. The first is `nav.hunk_crosses_files` (default **true**): `]h` walks the whole review, carrying on into the next file rather than looping inside the current one. The default follows from the status line, which already counts hunks across every file - "4 of 17" describes a sequence, and the primary motion should be able to traverse it. Set it false to keep `]h` inside one file, wrapping at its ends.

These live in an `app.Nav` struct, which `config.zig` now owns and fills from `[nav]` - adding the file was a parse plus an assignment rather than a hunt through dispatch for hardcoded policy, which is what declaring the struct early bought. `nav.scrolloff` joined it as the last hardcoded policy constant in `app.zig`, clamped to a third of the body so a large value degrades on a short pane instead of welding the cursor to the middle.

### 4.8 Per-repo config - shipped

`.lgtm/config.toml` overrides `~/.config/lgtm/config.toml` (or `$XDG_CONFIG_HOME/lgtm/config.toml`). Different repos want different risk rules, different languages, different bridge targets. Merge, do not replace: the repo file overrides the keys it names and leaves the rest of the global file standing, which is asserted rather than assumed.

`--config <path>` reads one file instead of both. It exists because a config feature that can only be exercised by editing the user's home directory is a config feature nobody tests.

The format is a small TOML subset - tables, `key = value`, strings, booleans, integers, single-line arrays of strings - and nothing outside `config.zig` knows what the format is, so a real TOML dependency can replace the parser later without touching a call site. What is configurable today: `[nav]`, `[ui] icons` and `wrap`, and `[keys]`. Themes, templates (§4.5) and risk rules (§4.6) add their sections when they land.

### 4.9 Config errors must be excellent - shipped

A tool that fails to start because of a typo in a theme file is a tool people uninstall. Rules: never fail to start on a bad config. Report the file, line, and the offending key; fall back to defaults for that key only; show the error in the status line, not a crash.

All four hold. A bad line costs that one key its value and nothing else - the line either side of it still applies - and the first problem plus a count of the rest goes to the status line on the first frame, cleared by the first keystroke like any other notice. Three refinements the rules did not anticipate, each from writing a wrong config on purpose:

- **An unknown `[section]` is reported once, at its header.** Its keys are then skipped in silence. A `[templates]` block read by a binary too old to know it should cost one line of complaint, not one per setting.
- **Out of range is a problem, not a clamp.** Silently clamping `scrolloff = 900` leaves the user reading a config that says one thing and watching a screen that does another.
- **A remap that would shadow another binding is refused**, with the pair it would have shadowed. `quit = "<Space>"` is a prefix of every leader sequence, so accepting it would leave those bindings listed in `?` and silently dead - the failure this rule exists to prevent, one level up from a typo.

---

## 5. Where these land

| Feature | Milestone | Notes |
|---|---|---|
| `?` help popup | **v0.1** | Ship with the first keybinding, not after |
| Themes (bundled) | v0.1 | Reuse `look`'s |
| Ignore patterns | v0.1 | `[review] ignore = ["package-lock.json", "**/*.pb.go"]`. Passed to git as `:(exclude)` pathspecs, so the glob semantics are gitignore's and there is no matcher of our own to get wrong - and git never parses the hunks, so a 900-line lockfile costs nothing. Hidden by default, counted in the mode row, `zi` reveals. What `.gitignore` cannot do: these files are tracked on purpose |
| Compose box | v0.1 | Every send opens it (`ui/compose.zig`), holding the reference and nothing else: a canned question typed in for you is a sentence you have to read and mostly delete. Modal, sharing `ui/motion.zig` with the review so `w` means the same thing inside the box as outside it - which is also why it cost little: the motions already existed and only the operators are new. `[ui] compose` places it - bottom, top or centre - and the lists it opens take whichever side has more room. `Ctrl-i` inserts a `[presets]` entry at the caret and `@` inserts a changed file's path, both without deleting anything. A file the review does not contain is drawn dim rather than in a status colour - it has no status, and borrowing one claims something happened to it. `@` reuses the `<Space>f` overlay whole - same list, same fuzzy filter, same drawing - with one field deciding whether Enter jumps or mentions. Reused by v0.2 notes - same box, different destination |
| Ask presets | v0.1 | Four keys with four fixed questions became one key and a list: `<Space>a` opens the compose box with the question list up, and `[presets]` decides what is in it. One key beats four once the questions are the user's own and there can be any number of them - but the *shortcut* had to stay. Removing it entirely, on the grounds that it and `Enter` both open a box, lost the thing it was for: getting to a question in one keystroke |
| Keymap remapping | v0.2 | Needs the command-name indirection from day one |
| Template strings | v0.2 | The table itself shipped in v0.1 (`bridge/template.zig`); `[templates]` overrides it in v0.2 |
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
