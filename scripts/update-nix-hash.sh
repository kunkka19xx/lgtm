#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Refreshes flake.nix's `outputHash` - the hash of the fetched Zig dependency
# tree, which changes every time build.zig.zon does.
#
# Every other checksum in this project is read from a file the release
# publishes: the Homebrew formula and the AUR package both take theirs from
# SHA256SUMS. This one has nothing to read. It is a hash of what `zig build
# --fetch=all` produces, so the only way to learn it is to build and be told,
# which is what this does: run the build, catch the mismatch, write the number
# it reports.
#
# Needs `nix`, or Docker as a stand-in - this is not a machine that has nix.

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
flake="$root/flake.nix"

build() {
  if command -v nix >/dev/null 2>&1; then
    nix build --no-link .#lgtm 2>&1
  elif command -v docker >/dev/null 2>&1; then
    echo "no nix here, using a container" >&2
    # A named volume keeps the store between runs; without it every attempt
    # re-downloads 600 MB of nixpkgs. --privileged is what lets nix turn its
    # own sandbox on, which is the thing being tested: the sandbox has no
    # network, so a dependency that was not fetched ahead of time fails here
    # exactly as it fails in CI.
    docker volume create lgtm-nix-store >/dev/null
    docker run --rm --privileged \
      -v lgtm-nix-store:/nix -v "$root:/src:ro" nixos/nix \
      bash -lc 'cd /src
        export NIX_CONFIG="experimental-features = nix-command flakes
sandbox = true"
        nix build --no-link --print-build-logs .#lgtm' 2>&1
  else
    echo "needs nix or docker" >&2
    exit 1
  fi
}

out="$(build || true)"

# "got:    sha256-..." is what a fixed-output derivation says when its content
# is not what was claimed. No match means the build agreed with the file.
got="$(printf '%s\n' "$out" | sed -n 's/.*got: *\(sha256-[A-Za-z0-9+/=]*\).*/\1/p' | tail -1)"

if [[ -z "$got" ]]; then
  if printf '%s\n' "$out" | grep -q '^error:'; then
    printf '%s\n' "$out" | tail -20 >&2
    echo "build failed for a reason that is not the hash" >&2
    exit 1
  fi
  echo "outputHash is already correct"
  exit 0
fi

current="$(sed -n 's/.*outputHash = "\(sha256-[^"]*\)".*/\1/p' "$flake")"
python3 - "$flake" "$got" <<'PY'
import pathlib, re, sys
path, got = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
s, n = re.subn(r'(outputHash = ")sha256-[^"]*(")', rf'\g<1>{got}\g<2>', p.read_text(), count=1)
if not n:
    sys.exit("flake.nix has no outputHash to replace")
p.write_text(s)
PY
echo "outputHash: ${current:-none} -> $got"
echo "re-run to confirm the build is green."
