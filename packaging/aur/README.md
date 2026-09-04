# AUR packaging

The source of truth for `lgtm-bin` and `lgtm-git`. An AUR repository holds two
files and no history worth keeping, so the files live here and are copied out.

| | |
|---|---|
| `lgtm-bin` | the release tarball, no toolchain needed |
| `lgtm-git` | builds `main`, and runs `zig build test` in `check()` — the package that catches breakage early |

`.SRCINFO` is **generated, never hand-written**: the AUR rejects a push whose
`.SRCINFO` disagrees with its `PKGBUILD`, and that check is the only thing
between a typo and a package that fails at install time.

## Releasing

```sh
./update-pkgver.sh              # or: ./update-pkgver.sh 0.1.0
make srcinfo                    # regenerates both .SRCINFO in a container
make build                      # optional: compiles lgtm-git for real
```

Then, per package:

```sh
git clone ssh://aur@aur.archlinux.org/lgtm-bin.git
cp packaging/aur/lgtm-bin/{PKGBUILD,.SRCINFO} lgtm-bin/
cd lgtm-bin && git commit -am "lgtm-bin 0.1.0" && git push
```

## No Arch machine

Everything here runs in a container, and the `Makefile` picks the image by host
arch. Four things that are not obvious:

- **pacman's sandbox.** `--disable-sandbox`, or every database sync fails with
  "switching to sandbox user 'alpm' failed" - it needs seccomp permissions
  Docker's default profile denies.
- **`makepkg` refuses to run as root**, on purpose: a PKGBUILD is arbitrary
  code. The container makes a user first.
- **`makepkg -s` shells out to `sudo`**, which has no password and no terminal
  in a container, so it fails on the *first* missing dependency rather than
  installing it. `make build` installs them as root beforehand instead.
- **`archlinux:base-devel` is x86_64-only.** Reading a PKGBUILD under emulation
  is fine; compiling one is not - the Zig compiler SEGVs. On Apple silicon the
  Makefile uses a community arm64 Arch image, pinned by digest because that
  image's manifest mislabels its arm64 entry as amd64 and `--platform
  linux/arm64` cannot resolve the tag.

`zig 0.16.0` is in `extra` for both x86_64 and aarch64, so `lgtm-git`'s
`makedepends` resolves without an AUR toolchain package.
