# `lgtm` - Distribution

**Companion docs:** PLAN.md, DOGFOOD.md
**Status:** draft, not scheduled. Opened 2026-09-01, nothing here is being built yet.

This file exists so the question "can we ship to brew / apt / nix / AUR?" has an
answer that does not have to be re-derived. It is a decision record, not a task
list: the work is deliberately deferred until the v0.1 gate in PLAN.md is met,
because packaging software nobody uses yet is a way of avoiding the thing that
decides whether it should be packaged at all.

Where a channel is rejected, the reason is written down. Reasons change; the
next person to ask should be arguing with a recorded reason rather than guessing.

---

## 0. The framing

**Packaging is downstream of two artifacts, not of five package managers.**

Every channel below wants the same two things: a tarball at a stable URL with a
stable checksum, and ideally a binary that does not have to be built on the
user's machine. Produce those once and the per-channel work collapses to a
twenty-line manifest each. Skip them and every channel is blocked on the same
missing thing, which is what makes this look like five problems instead of one.

The corollary is the ordering in section 3: nothing about brew or nix or AUR
comes first. The release job comes first.

---

## 1. The two gates

Neither is packaging work. Both are blocking for every channel.

### 1.1 A tagged, versioned release

`build.zig.zon` declares `version = "0.0.0"` and `git tag` is empty. Packagers
key off an immutable tarball; `main` is not one. Nothing ships before `v0.1.0`
exists as a tag, and the tag is a release claim, so it is the author's to make
and not a side effect of packaging.

The version string already has one source of truth (`build.zig` reads it from
the manifest, `ui/splash.zig` prints it), so a bump is one line and the banner,
the empty screen and `--version` follow.

### 1.2 Prebuilt binaries in CI

`zig build dist` produces a stripped ReleaseSmall binary and CI already checks
it against the 1 MB budget, but nothing publishes it. Zig cross-compiles almost
for free, so one release job on one runner emits every target worth shipping:

| Target | Why |
|---|---|
| `aarch64-macos` | The author's machine, and most of the audience |
| `x86_64-macos` | Intel Macs still in use |
| `x86_64-linux` | Servers, WSL, most CI |
| `aarch64-linux` | Asahi, cloud arm, Raspberry Pi |

One artifact set feeds the AUR `-bin` package, the Homebrew tap and a `.deb`
simultaneously. This is the single highest-leverage item in the file.

**Not shipping Windows.** `io/input.zig` and `io/tty.zig` are POSIX throughout
(`poll`, `tcgetattr`, `TIOCGWINSZ`), so winget and scoop are blocked on a port,
not on a manifest. Out of scope for v1 the same way LSP is.

---

## 2. The channels

Ranked by what actually stands in the way, which is rarely the packaging.

| Channel | Gatekeeper | Verdict |
|---|---|---|
| AUR (`yay`, `paru`) | None | **Do first.** Publish on the day of the tag |
| Homebrew tap | None | **Do first.** One formula in `homebrew-lgtm` |
| Nix flake output | None | **Do first.** Missing today, ~20 lines |
| nixpkgs | Review + maintainer | **Achievable.** Weeks, one real blocker |
| homebrew-core | Popularity heuristic | **Later.** Nothing to engineer |
| Debian / Ubuntu apt | Sponsor + Policy | **Rejected.** See 2.6 |
| winget / scoop | Windows support | **Blocked on the code** |

### 2.1 AUR

No review, no gatekeeper: anyone can push a `PKGBUILD`. Convention is two
packages, and both are worth having:

- `lgtm-bin` - the release tarball, no toolchain needed by the user.
- `lgtm-git` - builds `main`, which is the package that catches breakage early.

An hour of work once 1.1 and 1.2 exist. `yay` is a helper that installs from the
AUR rather than a separate registry, so there is nothing extra to do for it.

### 2.2 Homebrew tap

`brew tap kunkka19xx/lgtm && brew install lgtm` needs a formula in a repo named
`homebrew-lgtm` and nothing else. No rules, no notability bar, no review. This
is the macOS answer until 2.5 becomes possible, and it may remain the answer
indefinitely.

### 2.3 Nix flake output

`flake.nix` currently exposes `devShells` and an `fhs` package, so
`nix run github:kunkka19xx/lgtm` does **not** work today. A `packages.default`
using the standard Zig build hook is roughly twenty lines and gives every Nix
user an install path with no registry, no review and no release cadence.

It also front-loads the hard part of 2.4, because it forces the offline-build
question below to be answered in a repo where the answer can be iterated on.

### 2.4 nixpkgs

Genuinely achievable. `pkgs.zig_0_16` already exists in unstable, which
`flake.nix` depends on, and Zig packaging in nixpkgs is well-trodden.

**The one real blocker is the offline build.** nixpkgs builds with no network,
and `zig-pkg/` is gitignored - it is a local cache mirror, not vendored source -
so `zig build` fetches libvaxis from a pinned git commit at build time. That
needs a fixed-output derivation for the dependency cache before a PR will land.
Solvable, and it is the same problem 2.3 raises, which is why 2.3 comes first.

Costs a maintainer entry, which is a standing commitment to keep it building.

### 2.5 homebrew-core

Not yet, and the obstacle is popularity rather than code. The acceptable-formulae
policy wants a stable versioned release - pre-alpha is explicitly excluded - and
applies a notability heuristic in the neighbourhood of 75 stars, 30 forks and
30 watchers. There is nothing to engineer here. Ship the tap, and revisit when
the numbers are there; the formula itself will already exist from 2.2.

### 2.6 Debian and Ubuntu apt - rejected

Four independent blockers, any one of which is enough:

1. **Sponsorship.** Needs an ITP bug and a Debian Developer willing to sponsor
   an unknown package. That is a social problem, not a technical one.
2. **Vendored dependencies.** Policy dislikes them. Debian would want libvaxis
   packaged separately, and libvaxis is pinned to a main-branch commit
   deliberately (ARCHITECTURE.md 5c) because its tags lag Zig 0.16. Those two
   positions cannot both hold.
3. **Toolchain.** Debian's Zig lags 0.16 badly, and Zig is pre-1.0, which is
   exactly the kind of dependency Debian is slowest to carry.
4. **Cadence.** The freeze cycle means a stable release lands years out, which
   for a tool moving this fast means shipping a version nobody should run.

**The substitute:** a `.deb` attached to GitHub Releases, built by the same job
as 1.2. `apt install ./lgtm.deb` works, upgrades do not. If `apt install lgtm`
is ever genuinely wanted, a PPA is the next step up and is entirely within our
control, unlike Debian proper.

---

## 3. Order of work

Nothing here starts before the v0.1 gate in PLAN.md. When it does:

1. Bump `build.zig.zon` and tag `v0.1.0`. One line plus a tag.
2. Release workflow: cross-compile the four targets from 1.2, attach tarballs
   and checksums. Reuses the existing `dist` step and its size budget.
3. `packages.default` in `flake.nix`. Instant Nix install, no gatekeeper.
4. AUR `lgtm-bin` and `lgtm-git`, plus the Homebrew tap. Both trivial once 2
   exists.
5. `.deb` in the release job, if anyone asks for it.
6. Much later, and only with users: the nixpkgs PR, then homebrew-core.

Steps 2 and 3 are pure repo work and require no decision beyond the version
number. Steps 4 onward create maintenance commitments and should not be taken
on faster than they are wanted.

---

## 4. Open questions

- **The name.** `lgtm` is a common word and was the name of GitHub's Semmle
  code-analysis product. Availability in the AUR, nixpkgs and Homebrew has not
  been checked, and finding out after publishing three manifests is the
  expensive order to find out in. **Check before step 4, not during.**
- **How the dependency cache is vendored.** 2.3 and 2.4 both need offline
  builds. A fixed-output derivation and a committed vendor directory are both
  viable and pull in opposite directions; whichever is picked, `.gitignore` and
  the CI cache assumptions have to move with it.
- **Whether a release is signed.** Homebrew and the AUR both verify checksums
  and neither requires signatures, so this is a question about what a user
  should be able to verify rather than about what a channel demands.
- **Who maintains what.** Every entry past step 4 is a standing commitment.
  A stale AUR package is worse than no AUR package, because it fails at install
  time in a way that reads as the tool being broken.
