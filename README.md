# lgtm

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

Pre-alpha, and now runnable: `zig build run` shows this repository's own uncommitted changes, with syntax highlighting and hunk headers naming the enclosing function. What it cannot yet do is the thing it exists for - `Enter` does not send a reference, because that is the bridge, phase 6.

The parts below the terminal were built first, because that is the order the dependency graph demands rather than the order a demo would want - each one is testable headless, and a wrong decision is far cheaper to find before a TUI is attached to it.

| Phase | | |
|---|---|---|
| 0 - Scaffold and instrumentation | done | 653 KB binary, 1.6 MB RSS |
| 1 - Re-anchoring | done | 100% hit rate across 8 fixtures |
| 2 - Diff model and change ids | done | bar the diff cache, which waits for a loop to profile |
| 3 - File watching | done | one event per settled burst of writes |
| 4 - Syntax lexer | done | 378 MB/s, 0.5 ms to scan 6.4k lines |
| 5 - TUI | in progress | it renders: live unified diff, 0.17 ms per frame |
| 6 - Bridge | | |

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
```

Each phase ships the harness that measures it. They take a real path, so they can be pointed at code that was never a fixture - which is how several of the gaps so far were found:

```
zig build anchor              # re-anchoring hit rate; exits non-zero below the gate
zig build diff  -- [repo]     # parse a repository's diff and print it
zig build watch -- [repo]     # watch a tree and print coalesced change events
zig build lex   -- <file>     # token stream, function spans and timings for one file
zig build bench -- [dir]      # lexer benchmark, run under -Doptimize=ReleaseFast
```

On NixOS, the subprocess tests need an FHS `/bin` to spawn `git` and friends: run them as `nix run .#fhs -- -c "zig build check"`. The default shell warns about this.

## Configuring

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
                           # "nerd" for file-type icons in the F list

[nav]
hunk_crosses_files = true  # ]h walks the whole review, not just this file
scrolloff = 3              # rows kept between the cursor and the edge

[keys]
# Command names come from the `?` popup; keys are spelled the way it spells
# them. A list binds several, of which the first is the one advertised.
next_file = ["]w", "<Space>nf"]
refresh   = ["<C-l>", "<Space>r"]
open_editor = []           # unbind: it stops being offered anywhere
```

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
