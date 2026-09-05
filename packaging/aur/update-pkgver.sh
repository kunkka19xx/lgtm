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

url="https://github.com/$repo/releases/download/v$version/SHA256SUMS"

# curl first, `gh` only as the fallback: the asset is public, so a plain HTTPS
# fetch needs no token and works in a container that has no `gh` at all. That
# is what lets CI run this script rather than reimplementing it.
#
# Success is the file existing *and* having tarballs in it. A release whose
# assets never uploaded answers with an empty or HTML body rather than a 404,
# and every checksum below would then be missing one at a time.
fetch() {
  curl -fsSL "$url" -o "$sums" 2>/dev/null ||
    { command -v gh >/dev/null 2>&1 &&
      gh release download "v$version" --repo "$repo" --pattern SHA256SUMS \
        --output "$sums" --clobber >/dev/null 2>&1; } ||
    return 1
  grep -q 'lgtm-.*\.tar\.gz$' "$sums"
}

# Waiting, not failing. Publishing a release fires the event that runs this
# minutes before the assets exist: pressing Publish creates the tag, and the
# workflow that cross-compiles the four targets and uploads them starts at that
# moment and takes a few minutes to finish. One fetch raced that and lost,
# which is how the AUR sat on 0.1.0 while every other channel had 0.1.1.
#
# A budget rather than forever, so a release that genuinely never uploaded
# still fails and says why. Zero waits not at all, which is what a person
# running this by hand after the fact wants.
wait_secs="${SHA256SUMS_WAIT_SECS:-300}"
until fetch; do
  if (( SECONDS >= wait_secs )); then
    echo "no usable SHA256SUMS at $url after ${wait_secs}s" >&2
    echo "  the release exists but its assets do not - did the release workflow finish?" >&2
    exit 1
  fi
  echo "waiting for the release assets: ${SECONDS}s of ${wait_secs}s"
  sleep 15
done

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
