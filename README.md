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
agent, shows what changed as it changes, and lets you point at exact lines when
you reply.

**You keep your editor.** `hjkl`, `w b e`, `f t F T`, `/` and `n`, `V` to
select, `zz` to centre - the motions already in your fingers, now pointed at the
agent's work.

> **Status: pre-alpha**, and used daily by its author.
>
> It began a long time ago as a Go tool for reading diffs in a terminal. This is
> a rewrite in Zig, rebuilt around a coding agent rather than a person: the diff
> re-renders as the agent writes, references go straight to its input, and
> comments follow the code when it rewrites the file underneath them. The loop
> works end to end; the numbers below are measured, not estimated.

## Why

Reviewing an agent is not reviewing a person: more code, arriving faster, with
no prior about where the risk is. Without this, the loop goes - the agent edits
six files, you scroll `git diff` in a pager, you spot something at
`src/auth.zig:47`, and you **retype** that path into the chat. `lgtm` removes
the retyping.

## Install

**macOS**, from the tap:

```sh
brew install kunkka19xx/tap/lgtm
```

**Linux**, any distribution - the binary is static, so the distro doesn't
matter. (Also macOS):

```sh
curl -fsSL https://raw.githubusercontent.com/kunkka19xx/lgtm/main/scripts/install.sh | sh
```

arm64 and x86_64. No sudo: one binary into `~/.local/bin`, checked against the
release's checksums. `--uninstall` removes it.

**Nix** - the flake ships the binary, not just a dev shell:

```sh
nix run github:kunkka19xx/lgtm          # run once, install nothing
nix profile add github:kunkka19xx/lgtm  # keep it on PATH
```

**Arch**, from the AUR: `lgtm-bin` (the release binary) or `lgtm-git` (builds
`main`), with any helper or `makepkg -si` from a clone.

**From source** - needs [Zig](https://ziglang.org), the version pinned in
`.zigversion`:

```sh
make local          # build and install to ~/.local/bin
make clean-local    # remove it, restoring whatever it displaced
```

You also need `git`. `tmux` is optional: without it, references go to the
clipboard over OSC 52, which works over SSH.

## Configure

Nothing to write: `lgtm` runs on defaults, and `lgtm --init` drops a commented
starter when you want to change one. Settings load from
`~/.config/lgtm/config.toml`, then `.lgtm/config.toml` in the repo, merged key by
key. A bad key is reported on the status line; it never stops the tool starting.

```toml
[review]
ignore = ["package-lock.json", "**/*.pb.go"]   # generated files .gitignore can't hide

[presets]
why  = "why this approach?"
perf = "is this hot path allocating?"

[ui]
icons = "nerd"        # or "unicode", "ascii"
comments = "inline"   # or "marker": just the gutter dot

[theme]
name = "gruvbox"      # seven bundled; `lgtm --theme-preview` shows them all

[keys]
next_hunk = ["]h", "<Space>nh"]
compose_presets = ["<C-p>"]   # the box's keys are bindings too
```

Every key is remappable, inside the compose box as well as outside it - only the
vim motions are fixed, because in a text box every printable key is data.

**[Guide](docs/GUIDE.md)** is install, the loop and every key.
**[Configuration](docs/CONFIG.md)** is every setting, command name and theme slot.

## Numbers

Measured on macOS arm64, ReleaseFast, in this repository:

|                       |                                                    |
| --------------------- | -------------------------------------------------- |
| Binary                | 766 KB, one dependency (`libSystem`)               |
| Frame                 | 0.30 ms at 80x26                                   |
| Re-diff               | 40 ms: one `git diff` plus the parse               |
| Re-anchoring comments | 100% across the fixture set (24/24), 1.8 ms per 50 |

Everything durable is a plain file in `.lgtm/` - comments as jsonl, reviews as
markdown. Kill it and restart it; you lose scroll position.

Snapshots are ordinary git objects under `refs/lgtm/**`. That namespace is
invisible to `git branch` and `git status`, though `git log --all` walks every
ref and will show them. `git show refs/lgtm/<session>/3:src/auth.zig` reads a
file out of one without lgtm installed, and deleting the refs is all it takes to
be rid of them.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
