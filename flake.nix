{

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";

    flake-compat.url = "github:input-output-hk/flake-compat";
    flake-compat.flake = false;

    cardano-node.url = "github:IntersectMBO/cardano-node/10.4.1";
    cardano-node.flake = false; # prevent lockfile explosion

    crane.url = "github:ipetkov/crane";

    dolos.url = "github:txpipe/dolos/v0.30.0";
    dolos.flake = false;

    cardano-playground.url = "github:input-output-hk/cardano-playground/39ea4db0daa11d6334a55353f685e185765a619b";
    cardano-playground.flake = false; # otherwise, +9k dependencies in flake.lock…

    cardano-js-sdk.url = "github:input-output-hk/cardano-js-sdk/@cardano-sdk/cardano-services@0.35.10";
    cardano-js-sdk.flake = false; # we patch it & to prevent lockfile explosion

    blockfrost-platform = {
      # 2025-07-17T15:46:21.000Z, Dolos integration – not yet released
      url = "github:blockfrost/blockfrost-platform/303e3d411059297c5113892ca76a5fdd79c0d18c";
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

    # FIXME: ‘nsis’ can’t cross-compile with the regular Nixpkgs (above)
    nixpkgs-nsis.url = "github:input-output-hk/nixpkgs/be445a9074f139d63e704fa82610d25456562c3d";
    nixpkgs-nsis.flake = false; # too old

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs: let
    supportedSystem = ["x86_64-linux" "x86_64-darwin" "aarch64-darwin"];
    inherit (inputs.nixpkgs) lib;
  in {
    packages = lib.genAttrs supportedSystem (buildSystem:
      import ./nix/packages.nix { inherit inputs buildSystem; }
    );

    internal = import ./nix/internal.nix { inherit inputs; };

    devShells = lib.genAttrs supportedSystem (buildSystem:
      import ./nix/devshells.nix { inherit inputs buildSystem; }
    );

    hydraJobs = {
      installer = {
        x86_64-linux   = inputs.self.packages.x86_64-linux.installer;
        x86_64-darwin  = inputs.self.packages.x86_64-darwin.installer;
        aarch64-darwin  = inputs.self.packages.aarch64-darwin.installer;
        x86_64-windows = inputs.self.packages.x86_64-linux.installer-x86_64-windows;
      };

      package = {
        x86_64-linux   = inputs.self.packages.x86_64-linux.default;
        x86_64-darwin  = inputs.self.packages.x86_64-darwin.default;
        aarch64-darwin  = inputs.self.packages.aarch64-darwin.default;
        x86_64-windows = inputs.self.packages.x86_64-linux.default-x86_64-windows;
      };

      inherit (inputs.self) devShells;

      required = inputs.nixpkgs.legacyPackages.x86_64-linux.releaseTools.aggregate {
        name = "github-required";
        meta.description = "All jobs required to pass CI";
        constituents =
          __attrValues inputs.self.hydraJobs.installer ++
          __attrValues inputs.self.hydraJobs.package ++
          map (a: a.default) (__attrValues inputs.self.hydraJobs.devShells);
      };
    };
  };

}
