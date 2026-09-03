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

A terminal diff reviewer built for agentic coding. Runs in a pane beside your agent CLI, shows what it changed as it changes, and lets you point at exact lines when you reply.

> **Status: pre-alpha.** It renders a live diff and you can move around it; the keys that send a reference to your agent are not built yet. See [Status](#status).

## Why

Reviewing an agent's code is a different problem from reviewing a person's. Higher volume, faster arrival, and no prior about where the risk is. Every existing diff tool assumes you will read the whole thing - with an agent, that assumption is false.

The loop today:

1. The agent edits six files.
2. You open another editor, or scroll `git diff` in a pager.
3. You spot something wrong at `src/auth.zig:47`.
4. You **retype** the path and line number into the chat.

`lgtm` removes steps 2–4.

## What it does

- **Live diff** - updates as the agent writes, no command to run
- **Two-keystroke references** - select lines, press Enter, `#3 src/auth.zig:47-52` lands in the agent's input
- **Vim motions**, read-only in v1 - the agent edits, you review
- **Review notes** - collect remarks like a PR review, submit them in one batch
- **Three-scope file search** - changed files, the repo, or your whole machine via the [`look`](https://github.com/kunkka19xx/look) index

## Non-goals

Not an agent. No embedded terminal. No plugin runtime. See `docs/SPEC.md` §4.

**Not in v1, but not ruled out either: editing and LSP.** v1 is read-only so the diff, anchoring and bridge land first. Editing in particular is designed *for*, not designed *out* - the buffer is the source of truth, the diff is an overlay on it, and every mutation would flow through a single `TextEdit` type, so it can arrive later without a rewrite. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §11.

## Status

Pre-alpha, and now the whole loop: `zig build run` shows this repository's own uncommitted changes, with syntax highlighting, hunk headers naming the enclosing function, vim motions across the whole review, search, visual select, a `?` key overlay, a `<Space>f` file list, seven themes and a config file - and `Enter` puts a reference into the agent's pane, which is the thing it exists for. Every v0.1 phase is now green; what is left is a week of using it.

The parts below the terminal were built first, because that is the order the dependency graph demands rather than the order a demo would want - each one is testable headless, and a wrong decision is far cheaper to find before a TUI is attached to it.

| Phase | | |
|---|---|---|
| 0 - Scaffold and instrumentation | done | 653 KB binary, 1.6 MB RSS |
| 1 - Re-anchoring | done | 100% hit rate across 8 fixtures |
| 2 - Diff model and change ids | done | bar the diff cache, which waits for a loop to profile |
| 3 - File watching | done | one event per settled burst of writes |
| 4 - Syntax lexer | done | 378 MB/s, 0.5 ms to scan 6.4k lines |
| 5 - TUI | done | live diff, motions, search, themes, config, file list; 0.11 ms per frame |
| 6 - Bridge | done | tmux + OSC 52; `Enter`, `y`, `Y` and the ask presets |

Every number is measured rather than estimated, but on whichever machine ran it. [`docs/PLAN.md`](docs/PLAN.md) has the conditions, the caveats, and what was deliberately left unbuilt.

## Requirements

- Zig (version pinned in `.zigversion`)
- git
- tmux, WezTerm, or kitty for the bridge - otherwise falls back to OSC 52 clipboard (works over SSH)

## Building

`nix develop` provides the pinned Zig and zls if you use Nix; otherwise install the version in `.zigversion`.

```
zig build            # the binary
zig build check      # tests plus the SPDX header check
zig build dist       # the distribution binary: ReleaseSmall, stripped
```

`dist` is the one the 1 MB budget is about, because it is what a user downloads. It comes in around 600 KB, and CI fails if it ever crosses the budget rather than leaving that to be noticed.

### Installing your own build

There are no packages yet (see `docs/DISTRIBUTION.md` for why, and what would have to be true first). Until then:

```
make local           # build dist and install it to ~/.local/bin
make local PREFIX=/usr/local
make clean-local     # remove it, restoring whatever it displaced
```

`make local` is careful about one thing, because a local build is not a release. If an lgtm from a release tarball or a package manager is already on that path, it is saved first and put back by `make clean-local`; if a release has been installed over the top since, the file is left alone rather than deleted; and a symlinked path - how Homebrew, nix and stow all install - is refused outright rather than replaced with a regular file.

`clean` and `clean-local` are separate on purpose: an installed binary is not build output, so clearing the build directories never takes one away.

Commits are gated by [pre-commit](https://pre-commit.com): `zig fmt` on the staged `.zig` files, then `zig build check`, around 0.75s warm. Once per clone:

```
pre-commit install
```

It runs on the files in the commit only, so the handful that predate the hook are reformatted as they are next touched rather than in one sweep. `git commit --no-verify` skips it.

Each phase ships the harness that measures it. They take a real path, so they can be pointed at code that was never a fixture - which is how several of the gaps so far were found:

```
zig build anchor              # re-anchoring hit rate; exits non-zero below the gate
zig build diff  -- [repo]     # parse a repository's diff and print it
zig build watch -- [repo]     # watch a tree and print coalesced change events
zig build lex   -- <file>     # token stream, function spans and timings for one file
zig build bench -- [dir]      # lexer benchmark, run under -Doptimize=ReleaseFast
```

On NixOS, the subprocess tests need an FHS `/bin` to spawn `git` and friends: run them as `nix run .#fhs -- -c "zig build check"`. The default shell warns about this.

## Sending

With the cursor on a line, `Enter` opens a compose box holding
`#3 src/auth.zig:47` and nothing else; type what you want to say and Enter
again sends it. `Ctrl-i` lists your presets and `@` lists every file git knows about -
changed ones first, then the rest, ignoring whatever `.gitignore` does. Both
drop what you pick in **at the caret**, deleting nothing. `Ctrl-j` types a line break, which is joined back into one line on the
way out - the box says so while one is present, because a newline through
`tmux send-keys` *is* Enter and would submit the agent's half-written message. `V` selects a range first and sends `:47-52`; `v` selects within the line
and sends the words themselves.

`y` is the vim key doing the vim thing: it yanks the selected text, and `Y`
yanks whole lines. The reference lives on `<Space>y`, with `<Space>Y` for the
reference plus the lines under it. `<Space>a` opens the box with the question list
already up. The questions come from `[presets]` in your config, and `Ctrl-i`
reaches them from inside the box at any time.

**It inserts text and never presses Enter.** The payload ends with a trailing
space; you type your question and decide when to submit. A payload containing a
newline is refused rather than truncated, because in `tmux send-keys` a newline
*is* Enter.

Inside tmux the target pane is inferred when the window holds exactly one other
pane, which is the setup this tool is named after. Three panes is a guess and a
wrong guess types into your editor, so it asks instead: start with
`lgtm --pane %3`. The working target is remembered in `.lgtm/target`, and if
that pane dies the reference goes to the clipboard rather than nowhere.

Outside tmux - or when a send fails - everything lands on the clipboard through
OSC 52, which works over SSH.

## Configuring

Generated files that are tracked on purpose - lockfiles, `*.pb.go`, committed
bundles - are the noise `.gitignore` cannot remove. `[review] ignore` does:

```toml
[review]
ignore = ["package-lock.json", "**/*.pb.go", "__snapshots__/**"]
```

They are hidden from the review, the mode row says how many, and `zi` brings
them back for the session. Patterns are git pathspecs, so the globs behave
exactly the way `.gitignore`'s do.


`~/.config/lgtm/config.toml` (or `$XDG_CONFIG_HOME/lgtm/config.toml`), then
`.lgtm/config.toml` in the repository, merged in that order - the repo file
overrides key by key rather than replacing the file. `--config <path>` reads
one file instead of both.

```toml
[theme]
name = "catppuccin"        # terminal, catppuccin, tokyo-night, gruvbox,
                           # dracula, rose-pine, kanagawa
added = "#a6e3a1 bold"     # then any slot, over the top of the named theme
cursor_line = "on #313244"

[ui]
icons = "unicode"          # "ascii" for a terminal without the glyphs,
                           # "nerd" for file-type icons in the file list
wrap = true                # soft wrap long lines; zw toggles it live
scroll_ms = 250            # longest a view jump may take; 0 to turn it off
cursor_ms = 80             # longest the cursor takes to travel; 0 for instant

[nav]
hunk_crosses_files = true  # ]h walks the whole review, not just this file
scrolloff = 3              # rows kept between the cursor and the edge

[keys]
# Command names come from the `?` popup; keys are spelled the way it spells
# them. A list binds several, of which the first is the one advertised.
next_file = ["]w", "<Space>nf"]
refresh   = ["<C-r>", "<Space>r"]
open_editor = []           # unbind: it stops being offered anywhere
```

**File-type icons are off until you ask for them.** `icons = "nerd"` puts a
per-language glyph beside every path in the file list, and the default does not,
because the default cannot know whether your terminal font has the glyphs. It
needs a [Nerd Font](https://www.nerdfonts.com); if the icons come out as boxes
or blank gaps, that is the font rather than the setting, and `"unicode"` puts it
back. Thirty-seven file types have their own icon and everything else gets a
generic one, so the column never comes out ragged. `nerd` changes nothing else:
it patches icons in, and leaves the rules and box borders exactly as `unicode`
draws them.

**The cursor travels rather than teleporting.** Every motion moves it a cell at
a time - `w`, `f`, `$`, `j`, a page key, a hunk jump - at one cell per frame,
which is the finest a terminal can draw. Only the drawn block lags; what you
send always resolves against where the cursor actually is. `cursor_ms = 0` for
instant.

**Jumps glide instead of teleporting.** `<C-d>`, `]h`, `gg` and a search
landing travel into place at one screen row per frame - the finest a cell grid
can draw, since half a row does not exist. A wrapped line is crossed a row at a
time. Only jumps animate - `j`, `k` and the word motions are always instant,
because they move the view only as a side effect of the cursor reaching the edge
and animating that would stutter on every keystroke. A second jump mid-flight
joins the first; anything else arrives at once, so it never costs you latency.
`scroll_ms` bounds how long a long jump may take before it starts moving more
than a row at a time, and `0` turns the whole thing off.

This is as smooth as a terminal gets. Neovide owns pixels and can slide a
viewport sub-pixel; anything drawing into a terminal writes cells. That is also
why the cursor itself is not animated - a word motion covers four cells and
there is nothing to put between them.

**Point at a word, not just a line.** The cursor is a character: `h l w b e`
and `W B E` for the whitespace-delimited kind, `0 ^ $`, and `f t F T` with `;`
and `,` to repeat. `v` selects within a line and
`V` selects lines. A charwise selection sends the text you highlighted rather
than a column number - ``#3 src/auth.rs:47 `verify_token` `` - because a column
number is no use to an agent, and the word is what you would have said out loud.
Three keys moved to make room: `e`, `t` and `F` are motions now, and the editor,
the test preset and the file list are `<Space>e`, `<Space>t` and `<Space>f`.

**Long lines wrap instead of being cut off.** In a split pane most prose and
plenty of code runs past the edge, and a review of the half that fit is not a
review. The continuation sits under the gutter with no sign and no line number,
so a wrapped line still reads as one line: `j` moves a line of the file, a
selection is still a range of lines, and the reference you send is unchanged.
`zw` turns it off for as long as you want to compare the shape of the code
rather than read it, and `wrap = false` makes that the default.

**A bad config never stops `lgtm` starting.** The offending key keeps its
default, the file and line are reported on the status line, and everything
else in the file still applies. A remap that would make another binding
unreachable - anything that is a prefix of a longer sequence, `<Space>` being
the obvious one - is refused with the pair it would have shadowed.

`lgtm --theme-preview` draws every bundled theme so you can pick one without
restarting, and `lgtm --theme <name>` tries one for a single run. A style is
written as a colour and any attributes - `"#a6e3a1"`, `"bright-blue bold"`,
`"#1e1e2e on 3 underline"` - and the slot names are the ones the preview shows
plus the obvious aliases (`added`, `removed`, `line_number`, `hunk_header`).

The default theme is `terminal`: 16-colour indexes, so it inherits whatever
palette your terminal already uses. The rest are true colour and assume a
terminal that renders it.

The file format is a small TOML subset: tables, `key = value`, strings,
booleans, integers, and single-line arrays of strings.

## Documentation

| File | Contains |
|---|---|
| [`docs/PLAN.md`](docs/PLAN.md) | Phase-by-phase status, exit gates, measured results |
| [`docs/SPEC.md`](docs/SPEC.md) | Goals, non-goals, features, keybindings, roadmap |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Modules, memory strategy, forward-design for editing and LSP |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | Algorithms, budgets, rejected optimisations |
| [`docs/FEATURES.md`](docs/FEATURES.md) | Feature strategy and customisation surface |

## License

Apache-2.0. See [`LICENSE`](LICENSE).
