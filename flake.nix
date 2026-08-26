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
        pkgs: nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux { fhs = fhsShell pkgs; }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
