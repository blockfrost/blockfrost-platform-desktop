{

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    # FIXME: Linux' `webkitgtk_4_1` 2.48 (from `nixos-25.05`) has a white-screen
    # bug when used with Wails v3. For now, let's pin it to the last known-good
    # version (2.44.3) from the old Nixpkgs:
    nixpkgs-webkitgtk.url = "github:nixos/nixpkgs/nixpkgs-24.05-darwin"; #893e9c69f3324ae99e87f1e8e49014c3c0ab12cf
    nixpkgs-webkitgtk.flake = false; # only used for webkitgtk_4_1

    flake-compat.url = "github:input-output-hk/flake-compat";
    flake-compat.flake = false;

    cardano-node.url = "github:IntersectMBO/cardano-node/10.4.1";
    cardano-node.flake = false; # prevent lockfile explosion

    crane.url = "github:ipetkov/crane";

    cardano-playground.url = "github:input-output-hk/cardano-playground/39ea4db0daa11d6334a55353f685e185765a619b";
    cardano-playground.flake = false; # otherwise, +9k dependencies in flake.lock…

    cardano-js-sdk.url = "github:input-output-hk/cardano-js-sdk/@cardano-sdk/cardano-services@0.35.10";
    cardano-js-sdk.flake = false; # we patch it & to prevent lockfile explosion

    blockfrost-platform = {
      # FIXME: update to `main` when this is merged:
      url = "github:blockfrost/blockfrost-platform/pull/471/head";
      flake = false; # to prevent lockfile explosion
    };

    ogmios = {
      url = "https://github.com/CardanoSolutions/ogmios.git";
      ref = "refs/tags/v6.11.2";
      type = "git";
      submodules = true;
      flake = false;
    };

    mithril.url = "github:input-output-hk/mithril/2517.1";

    nix-bundle-exe.url = "github:3noch/nix-bundle-exe";
    nix-bundle-exe.flake = false;

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: let
    inherit (inputs.nixpkgs) lib;
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} ({config, ...}: {
      systems = ["x86_64-linux" "x86_64-darwin" "aarch64-darwin"];

      perSystem = {system, ...}: let
        internal = inputs.self.internal.${system};
      in {
        packages =
          {
            default = internal.package;
            installer = internal.installer;
          }
          // (
            if system == "x86_64-linux"
            then let
              win = inputs.self.internal.x86_64-windows;
            in {
              default-x86_64-windows = win.package;
              installer-x86_64-windows = win.installer;
            }
            else {}
          );
        devShells = import ./nix/devshells.nix {inherit inputs; buildSystem = system;};
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
