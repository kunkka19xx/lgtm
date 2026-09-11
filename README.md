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

**You keep your editor, and review code with vim motions.**



https://github.com/user-attachments/assets/0eb27774-9c64-43c2-ba22-b392fb58c734



- _Side-by-side diff view_

<img width="1400" height="900" alt="side-by-side" src="https://github.com/user-attachments/assets/2c585a09-129f-4377-bfca-ce25ceb2f704" />

> It began a long time ago as a Go tool for reading diffs in a terminal.
> This is a rewrite in Zig, rebuilt around a coding agent rather than a person:
> the diff re-renders as the agent writes, references go straight to its input, and
> comments follow the code when it rewrites the file underneath them. The loop works end to end.

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
nix run --refresh github:kunkka19xx/lgtm          # run once, install nothing
nix profile add --refresh github:kunkka19xx/lgtm  # keep it on PATH
```

`--refresh` is not optional: Nix caches what a `github:` ref points at for an
hour, and without it you can get handed a build you already have.

Upgrading is a _different_ command, and this is the one that catches people:

```sh
nix profile upgrade --refresh lgtm
```

`add` does not upgrade. A profile entry is locked to the commit it was
installed from, so running the install line again will not move it - `add`
refuses to install over itself, and `--refresh` only re-checks where the
`github:` ref points, not where your entry is pinned. `upgrade` re-resolves
the URL the entry was added with and re-locks it to whatever `main` is now.
`nix profile list` prints the locked commit and store path, which is the
quickest way to see that a stale entry, not the release, is why `lgtm -v`
still says the old number.

**Arch**, from the AUR: `lgtm-bin` (the release binary) or `lgtm-git` (builds
`main`), with any helper or `makepkg -si` from a clone.

**From source** - needs [Zig](https://ziglang.org), the version pinned in
`.zigversion`:

```sh
make local          # build and install to ~/.local/bin
make clean-local    # remove it, restoring whatever it displaced
make dev            # install as lgtm-dev, beside a packaged lgtm
make clean-dev      # remove that one
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

## License

Apache-2.0. See [`LICENSE`](LICENSE).
