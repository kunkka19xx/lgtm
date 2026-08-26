# lgtm

**Read what your agent wrote - before you say LGTM.**

A terminal diff reviewer built for agentic coding. Runs in a pane beside your agent CLI, shows what it changed as it changes, and lets you point at exact lines when you reply.

> **Status: pre-alpha.** Design is complete; implementation has not started. See `docs/`.

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
- **Vim motions**, read-only - the agent edits, you review
- **Review notes** - collect remarks like a PR review, submit them in one batch
- **Three-scope file search** - changed files, the repo, or your whole machine via the [`look`](https://github.com/kunkka19xx/look) index

## Non-goals

Not an agent. No editing. No embedded terminal. No LSP. No plugin runtime. See `docs/SPEC.md` §4.

## Requirements

- Zig (version pinned in `.zigversion`)
- git
- tmux, WezTerm, or kitty for the bridge - otherwise falls back to OSC 52 clipboard (works over SSH)

## Documentation

| File | Contains |
|---|---|
| [`docs/SPEC.md`](docs/SPEC.md) | Goals, non-goals, features, keybindings, roadmap |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Modules, memory strategy, forward-design for editing and LSP |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | Algorithms, budgets, rejected optimisations |
| [`docs/FEATURES.md`](docs/FEATURES.md) | Feature strategy and customisation surface |

## License

Apache-2.0 OR MIT, at your option.
