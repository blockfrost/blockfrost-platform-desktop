{ inputs, buildSystem }:

let

  mkPackages = targetSystem: let
    internal = inputs.self.internal.${targetSystem}; # don’t eval again
    suffix = if buildSystem != targetSystem then "-${targetSystem}" else "";
  in {
    "default${suffix}" = internal.package;
    "installer${suffix}" = internal.installer;
  };

in {
  x86_64-linux = mkPackages "x86_64-windows" // mkPackages "x86_64-linux";
  x86_64-darwin = mkPackages "x86_64-darwin";
  aarch64-darwin = mkPackages "aarch64-darwin";
}.${buildSystem}
