#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# Install lgtm from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/kunkka19xx/lgtm/main/scripts/install.sh | sh
#
# What it will not do, because a script piped to a shell should be boring:
#
#   - ask for sudo. One static binary goes in ~/.local/bin, which is yours.
#   - install over something it did not put there. A brew or pacman copy is
#     left alone and reported, the same rule `make clean-local` follows.
#   - trust the download. Every artifact is checked against the SHA256SUMS
#     published in the same release, and a mismatch stops everything.
#
# Flags: --version <tag>  --dir <path>  --dry-run  --uninstall

set -eu

REPO="kunkka19xx/lgtm"
DIR="${LGTM_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="latest"
DRY=0
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a tag}"; shift 2 ;;
        --dir)     DIR="${2:?--dir needs a path}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)
            sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "lgtm: unknown option $1" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'lgtm: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- uninstall ---------------------------------------------------------------
#
# Only what this script put there. A binary from a package manager is that
# package manager's to remove, and deleting it here would leave its own
# database claiming it is still installed.

if [ "$UNINSTALL" -eq 1 ]; then
    target="$DIR/lgtm"
    [ -e "$target" ] || die "nothing at $target"
    [ -L "$target" ] && die "$target is a symlink - something else manages it"
    if [ "$DRY" -eq 1 ]; then say "would remove $target"; exit 0; fi
    rm -f "$target"
    say "removed $target"
    exit 0
fi

# --- what are we ------------------------------------------------------------

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) die "no build for $os. macOS and Linux only - lgtm is POSIX throughout and Windows needs a port, not a manifest." ;;
esac
case "$arch" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) die "no build for $arch" ;;
esac
TARGET="$arch-$os"

have curl || have wget || die "needs curl or wget"
fetch() {
    if have curl; then curl -fsSL "$1"; else wget -qO- "$1"; fi
}
fetch_to() {
    if have curl; then curl -fsSL -o "$2" "$1"; else wget -qO "$2" "$1"; fi
}

# --- which release ----------------------------------------------------------

if [ "$VERSION" = "latest" ]; then
    # The redirect target of /releases/latest names the tag, which avoids
    # needing an API token and works from behind most proxies.
    url="https://github.com/$REPO/releases/latest"
    if have curl; then
        VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$url" | sed 's|.*/tag/||')"
    else
        VERSION="$(wget -qS --spider "$url" 2>&1 | sed -n 's|.*/tag/\(v[^ ]*\).*|\1|p' | tail -1)"
    fi
    [ -n "$VERSION" ] || die "could not work out the latest version - pass --version vX.Y.Z"
fi

BASE="https://github.com/$REPO/releases/download/$VERSION"
TARBALL="lgtm-$TARGET.tar.gz"

say "lgtm $VERSION"
say "  target      $TARGET"
say "  install to  $DIR/lgtm"

# --- refuse to clobber someone else's copy ----------------------------------

existing="$(command -v lgtm 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$existing" != "$DIR/lgtm" ]; then
    say "  note        another lgtm is first on your PATH at $existing"
    say "              this will not touch it; that copy will keep winning"
fi
if [ -L "$DIR/lgtm" ]; then
    die "$DIR/lgtm is a symlink - something else manages it, refusing to replace it"
fi

if [ "$DRY" -eq 1 ]; then
    say ""
    say "would download $BASE/$TARBALL"
    say "would verify   against $BASE/SHA256SUMS"
    exit 0
fi

# --- download, verify, install ----------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

say ""
say "downloading..."
fetch_to "$BASE/$TARBALL" "$tmp/$TARBALL" || die "could not download $TARBALL - is $VERSION a release?"
fetch "$BASE/SHA256SUMS" > "$tmp/SHA256SUMS" || die "could not download SHA256SUMS"

want="$(sed -n "s|^\([0-9a-f]\{64\}\)  \./\{0,1\}$TARBALL$|\1|p" "$tmp/SHA256SUMS")"
[ -n "$want" ] || die "SHA256SUMS does not list $TARBALL"

if have sha256sum;   then got="$(sha256sum   "$tmp/$TARBALL" | cut -d' ' -f1)"
elif have shasum;    then got="$(shasum -a 256 "$tmp/$TARBALL" | cut -d' ' -f1)"
else die "needs sha256sum or shasum to verify the download"
fi

if [ "$want" != "$got" ]; then
    die "checksum mismatch - refusing to install
  expected $want
  got      $got"
fi
say "verified    $got"

tar -xzf "$tmp/$TARBALL" -C "$tmp"
[ -f "$tmp/lgtm" ] || die "the archive did not contain lgtm"

mkdir -p "$DIR"
# Written beside the target and moved into place, so an interrupted install
# never leaves half a binary where a working one was.
mv "$tmp/lgtm" "$DIR/lgtm.new"
chmod 755 "$DIR/lgtm.new"
mv -f "$DIR/lgtm.new" "$DIR/lgtm"

say "installed   $DIR/lgtm"

case ":$PATH:" in
    *":$DIR:"*) ;;
    *) say ""
       say "$DIR is not on your PATH. Add it:"
       say "  echo 'export PATH=\"$DIR:\$PATH\"' >> ~/.profile" ;;
esac

say ""
"$DIR/lgtm" -v 2>/dev/null | tail -4 || true
