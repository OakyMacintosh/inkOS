{
  description = "InkOS Development flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            pkgs = import nixpkgs { inherit system; };
          });
    in
    {
      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            gcc
            python3
            rustc
            luajit
            just
         #   wasmer
            minicom
            hexedit

            # AVR toolchain
            # pkgsCross.avr.buildPackages.gcc
            # pkgsCross.avr.buildPackages.avrlibc
            # pkgsCross.avr.buildPackages.binutils

            avrdude
            uv
            koreader
          ];
        };
      });
    };
}
