# SPDX-License-Identifier: Apache-2.0
{
  description = "lgtm - a terminal diff reviewer for agentic coding";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Kept in step with .zigversion and build.zig.zon's minimum_zig_version.
      zigVersion = "0.16.0";

      # Kept in step with build.zig.zon's `.version`, which is what the binary
      # itself prints. Nix cannot read a .zon at evaluation time, so this is the
      # one place the number is repeated - bump both together.
      lgtmVersion = "0.1.0";

      # git and a bridge backend (tmux, wezterm or kitty) are runtime
      # dependencies, but they are assumed to be on the host already - mkShell
      # prepends to PATH rather than replacing it, so they stay reachable.
      toolchain = pkgs: [
        pkgs.zig_0_16 # pinned; .zigversion is authoritative
        pkgs.zls # language server, same 0.16 series
      ];

      # The subprocess tests (src/io/proc.zig, src/io/watch.zig) build their own
      # `Io.Threaded` with an empty environ, so zig 0.16 resolves argv[0] against
      # its `default_PATH` - /usr/local/bin:/bin/:/usr/bin - rather than the
      # inherited PATH. Those directories are empty on NixOS, so spawning `echo`,
      # `cat` or `rm` fails with FileNotFound and five tests fail. This wrapper
      # supplies an FHS layout so the fallback resolves. Linux only; buildFHSEnv
      # does not exist on darwin, where /bin and /usr/bin are populated anyway.
      fhsShell =
        pkgs:
        pkgs.buildFHSEnv {
          name = "lgtm-fhs";
          # Unlike mkShell, this shell replaces PATH, so the runtime
          # dependencies have to be named explicitly here.
          targetPkgs =
            p:
            toolchain p
            ++ [
              p.coreutils
              p.git
            ];
          runScript = "bash";
        };

      # The three dependencies from build.zig.zon, fetched into a Zig cache.
      #
      # Its own derivation because a Nix build has no network, and Zig's package
      # manager wants one. A fixed-output derivation is the exception that is
      # allowed to reach out, and it pays for that with a hash: change
      # build.zig.zon and this hash changes, and `nix build` will tell you the
      # new one rather than silently building something else.
      zigDeps =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "lgtm-zig-deps";
          version = lgtmVersion;
          src = ./.;
          nativeBuildInputs = [ pkgs.zig_0_16 ];

          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$out"
            zig build --fetch
            # Zig writes a lock and timestamps into the cache; neither is
            # content and both would make the hash depend on when it ran.
            rm -rf "$out/tmp" "$out/h" 2>/dev/null || true
          '';

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          # The hash of the fetched dependency tree. Deliberately not silenced
          # with a permissive setting: an unpinned dependency tree is the one
          # thing a reproducible build cannot have. Change build.zig.zon and
          # this changes; nix reports the new one and refuses to continue.
          outputHash = "sha256-k0J10N4QnJ9j2MhPZLbh7lqxDj05nYCt/9pzzfKjVvk=";
        };

      lgtmPackage =
        pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "lgtm";
          version = lgtmVersion;
          src = ./.;

          nativeBuildInputs = [ pkgs.zig_0_16 ];
          # git is how lgtm reads a diff, so it is a runtime dependency and not
          # a build one. tmux is optional - without it references go to the
          # clipboard over OSC 52 - so it is not wrapped in.
          buildInputs = [ pkgs.git ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            cp -r --no-preserve=mode,ownership ${zigDeps pkgs} "$ZIG_GLOBAL_CACHE_DIR"
            # `dist` rather than the default: ReleaseSmall and stripped is what
            # a user should be installing, and it is the same binary the
            # release workflow ships.
            zig build dist --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR"
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 zig-out/bin/lgtm "$out/bin/lgtm"
            runHook postInstall
          '';

          meta = {
            description = "A terminal diff reviewer for agentic coding";
            homepage = "https://github.com/kunkka19xx/lgtm";
            license = nixpkgs.lib.licenses.asl20;
            mainProgram = "lgtm";
            platforms = systems;
          };
        };
    in
    {
      devShells = forAllSystems (
        pkgs:
        {
          default = pkgs.mkShell {
            name = "lgtm";

            packages = toolchain pkgs;

            # `zig build` fetches libvaxis over the network into zig's global
            # cache on first run, so this shell is not hermetic by design.
            shellHook = ''
              wanted=$(cat .zigversion 2>/dev/null || echo ${zigVersion})
              actual=$(zig version)
              if [ "$actual" != "$wanted" ]; then
                echo "warning: .zigversion wants $wanted but this shell provides $actual"
                echo "         update zigVersion/zig_0_16 in flake.nix, or .zigversion"
              fi

              echo "lgtm dev shell - zig $actual, zls $(zls --version 2>/dev/null || echo '?')"
              echo "  zig build test     unit tests"
              echo "  zig build check    tests + SPDX header check"
              echo "  zig build anchor   re-anchoring harness (phase 1 gate)"
              echo "  zig build run      the binary"
            ''
            + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              echo "  note: the subprocess tests need an FHS /bin - run them under"
              echo "        'nix develop .#fhs' or 'nix run .#fhs -- -c \"zig build check\"'"
            '';
          };
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Interactive use: `nix develop .#fhs`. Non-interactive callers (CI,
          # scripts) want `nix run .#fhs -- -c "zig build check"` instead, since
          # `nix develop --command` bypasses the hook that enters the FHS mount
          # namespace.
          fhs = (fhsShell pkgs).env;
        }
      );

      packages = forAllSystems (
        pkgs:
        {
          default = lgtmPackage pkgs;
          lgtm = lgtmPackage pkgs;
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux { fhs = fhsShell pkgs; }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
