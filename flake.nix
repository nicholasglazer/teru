{
  description = "teru - AI-first terminal emulator, multiplexer, and tiling manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # Zig 0.16 is currently a dev release; pin to master.
        # Replace with "0.16.0" once stable in the overlay.
        zig = zig-overlay.packages.${system}.master;
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "teru";
          version = "0.4.1";

          src = ./.;

          nativeBuildInputs = [
            zig
            pkgs.pkg-config
          ];

          buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.libxkbcommon
            pkgs.xorg.libxcb
            pkgs.wayland
          ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild

            # Zig needs writable cache dirs; nix sandbox blocks $HOME writes
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/.zig-cache
            export ZIG_LOCAL_CACHE_DIR=$TMPDIR/.zig-local-cache

            zig build -Doptimize=ReleaseSafe --prefix $out

            runHook postBuild
          '';

          meta = with pkgs.lib; {
            description = "AI-first terminal emulator, multiplexer, and tiling manager";
            homepage = "https://teru.sh";
            license = licenses.mit;
            maintainers = [ ];
            platforms = platforms.linux ++ platforms.darwin;
            mainProgram = "teru";
          };
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            zig
            pkgs.pkg-config
          ];

          buildInputs = pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.libxkbcommon
            pkgs.xorg.libxcb
            pkgs.wayland
          ];
        };
      }
    );
}
