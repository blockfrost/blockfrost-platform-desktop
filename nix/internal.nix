{inputs}:
builtins.mapAttrs (targetSystem: src: import src {inherit inputs targetSystem;}) {
  x86_64-linux = ./internal/x86_64-linux.nix;
  x86_64-windows = ./internal/x86_64-windows.nix;
  aarch64-darwin = ./internal/any-darwin.nix;
}
