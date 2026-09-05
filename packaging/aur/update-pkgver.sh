#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Points lgtm-bin at a release and fills in its checksums.
#
# `sha256sums=('SKIP')` is what the committed PKGBUILD carries, because a
# checksum is a claim about a file that does not exist until the release does.
# This replaces it with the release's own SHA256SUMS - the same file
# `install.sh` verifies against, so the two agree by construction rather than
# by two people copying a hash.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="kunkka19xx/lgtm"
version="${1:-}"

if [[ -z "$version" ]]; then
  version="$(gh release view --repo "$repo" --json tagName --jq '.tagName')"
fi
version="${version#v}"

sums="$(mktemp)"
trap 'rm -f "$sums"' EXIT

# curl first, `gh` only as the fallback: the asset is public, so a plain HTTPS
# fetch needs no token and works in a container that has no `gh` at all. That
# is what lets CI run this script rather than reimplementing it.
url="https://github.com/$repo/releases/download/v$version/SHA256SUMS"
if ! curl -fsSL "$url" -o "$sums"; then
  command -v gh >/dev/null 2>&1 ||
    { echo "cannot fetch $url, and no gh to fall back on" >&2; exit 1; }
  gh release download "v$version" --repo "$repo" --pattern SHA256SUMS --output "$sums" --clobber
fi

# A release whose assets never uploaded returns an empty or HTML body rather
# than failing, and every checksum below would then be missing one at a time.
# Say so once, here, in the words that name the actual problem.
grep -q 'lgtm-.*\.tar\.gz$' "$sums" ||
  { echo "SHA256SUMS at $url has no lgtm tarballs in it - did the release publish its assets?" >&2; exit 1; }

sha_for() {
  local line
  line="$(grep -E "lgtm-$1\.tar\.gz\$" "$sums" || true)"
  [[ -n "$line" ]] || { echo "no checksum for $1" >&2; exit 1; }
  awk '{print $1}' <<<"$line"
}

pkg="$here/lgtm-bin/PKGBUILD"
sed -i.bak \
  -e "s/^pkgver=.*/pkgver=$version/" \
  -e "s/^pkgrel=.*/pkgrel=1/" \
  -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('$(sha_for x86_64-linux)')/" \
  -e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('$(sha_for aarch64-linux)')/" \
  "$pkg"
rm -f "$pkg.bak"
echo "lgtm-bin now points at v$version"
grep -E '^pkgver=|^sha256sums' "$pkg"

cat <<'NEXT'

Next, on a machine with the AUR tools (Arch, or a container):

  cd lgtm-bin && makepkg --printsrcinfo > .SRCINFO
  # then push PKGBUILD and .SRCINFO to ssh://aur@aur.archlinux.org/lgtm-bin.git

`.SRCINFO` is generated, never hand-written: the AUR rejects a push whose
.SRCINFO disagrees with its PKGBUILD, and that check is the only thing standing
between a typo and a package that fails at install time.
NEXT
