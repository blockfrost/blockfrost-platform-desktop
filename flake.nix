{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    flake-parts.follows = "blockfrost-platform/flake-parts";
    # FIXME: Linux' `webkitgtk_4_1` 2.48 (from `nixos-25.05`) has a white-screen
    # bug when used with Wails v3. For now, let's pin it to the last known-good
    # version (2.44.3) from the old Nixpkgs:
    nixpkgs-webkitgtk = {
      url = "github:nixos/nixpkgs/nixpkgs-24.05-darwin";
      flake = false;
    };
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/11.0.1";
      flake = false; # prevent lockfile explosion
    };
    crane.follows = "blockfrost-platform/crane";
    cardano-playground.follows = "blockfrost-platform/cardano-playground";
    # FIXME: update to `main` when this is merged:
    blockfrost-platform.url = "github:blockfrost/blockfrost-platform";
    mithril.follows = "blockfrost-platform/mithril";
    nix-bundle-exe.follows = "blockfrost-platform/nix-bundle-exe";
    # FIXME: follow blockfrost-platform
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devshell.follows = "blockfrost-platform/devshell";
  };

  outputs = inputs: let
    inherit (inputs.nixpkgs) lib;
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({config, ...}: {
      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
        ./nix/checks.nix
        ./nix/devshells.nix
      ];

      systems = ["x86_64-linux" "aarch64-darwin"];

      perSystem = {system, ...}: let
        internal = inputs.self.internal.${system};
      in {
        packages =
          {
            default = internal.package;
            inherit (internal) installer;
          }
          // (
            if system == "x86_64-linux"
            then {
              default-x86_64-windows = inputs.self.internal.x86_64-windows.package;
              installer-x86_64-windows = inputs.self.internal.x86_64-windows.installer;
            }
            else {}
          );

        treefmt = {
          projectRootFile = "flake.nix";
          programs = {
            alejandra.enable = true; # Nix
            clang-format.enable = true;
            gofumpt.enable = true; # Go
            shfmt.enable = true; # Shell
            prettier.enable = true;
            yamlfmt.enable = true;
            yamllint.enable = true;
            xmllint.enable = true;
          };
          settings.formatter.clang-format.includes = ["*.m"];
          settings.global.excludes = [
          ];
        };
      };

      flake = let
        crossSystems = ["x86_64-windows"];
      in {
        internal = import ./nix/internal.nix {inherit inputs;};

        hydraJobs = let
          allJobs = {
            installer = lib.genAttrs (config.systems ++ crossSystems) (
              targetSystem: inputs.self.internal.${targetSystem}.installer
            );
            package = lib.genAttrs (config.systems ++ crossSystems) (
              targetSystem: inputs.self.internal.${targetSystem}.package
            );
            devShell = lib.genAttrs config.systems (
              targetSystem: inputs.self.devShells.${targetSystem}.default
            );
            inherit (inputs.self) checks;
          };
        in
          allJobs
          // {
            required = inputs.nixpkgs.legacyPackages.x86_64-linux.releaseTools.aggregate {
              name = "github-required";
              meta.description = "All jobs required to pass CI";
              constituents = lib.collect lib.isDerivation allJobs;
            };
          };
      };
    });
}
