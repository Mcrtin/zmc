{
  description = "zmc - a Zig Minecraft launcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
            }
          )
        );

    in
    {
      packages = forAllSystems (
        pkgs:
        {
          zmc = pkgs.callPackage ./nix/package.nix {
            zig = zig-overlay.packages.${pkgs.system}."0.16.0";
          };

          default = self.packages.${pkgs.system}.zmc;
        }
      );


      devShells = forAllSystems (
        pkgs:
        {
          default = pkgs.callPackage ./nix/devShell.nix {
            zig = zig-overlay.packages.${pkgs.system}."0.16.0";
          };
        }
      );


      defaultNix = forAllSystems (
        pkgs:
        self.packages.${pkgs.system}.zmc
      );


      formatter = forAllSystems (
        pkgs:
        pkgs.alejandra
      );
    };
}
