{ inputs, buildSystem }:

let

  pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
  inherit (pkgs) lib;
  inherit (inputs.devshell.legacyPackages.${buildSystem}) mkShell;

in {

  default = pkgs.mkShell {
    packages = with pkgs; [
      go
    ] ++ lib.optionals pkgs.stdenv.isLinux [
      pkg-config
      inputs.self.internal.${buildSystem}.webkit2gtk
      (libayatana-appindicator-gtk3.override {
        gtk3 = gtk3-x11;
        libayatana-indicator = libayatana-indicator.override { gtk3 = gtk3-x11; };
        libdbusmenu-gtk3 = libdbusmenu-gtk3.override { gtk3 = gtk3-x11; };
      })
      gtk3-x11
    ];
    shellHook = ''
      export PATH="$HOME/go/bin:$PATH"

      # FIXME: a devshell might be started from anywhere, and we assume `PRJ_ROOT == .`
      ln -svf ${inputs.self.internal.${buildSystem}.go-assets}/assets              ./core/ || exit 1
      ln -svf ${inputs.self.internal.${buildSystem}.common.go-constants}/constants ./core/ || exit 1
    '';
  };

  /*

  # FIXME: numtide/devshell doesn’t set proper stdenv, so `go build` doesn’t work:

  future = mkShell {
    name = "blockfrost-platform-desktop";

    imports = ["${inputs.devshell}/extra/language/c.nix"];

    devshell.packages = with pkgs; [
      go
    ] ++ lib.optionals pkgs.stdenv.isLinux [
#      pkg-config
    ];

    language.c.compiler = pkgs.gcc;
    language.c.includes = with pkgs; lib.optionals pkgs.stdenv.isLinux [
      inputs.self.internal.${buildSystem}.webkit2gtk
      (libayatana-appindicator-gtk3.override {
        gtk3 = gtk3-x11;
        libayatana-indicator = libayatana-indicator.override { gtk3 = gtk3-x11; };
        libdbusmenu-gtk3 = libdbusmenu-gtk3.override { gtk3 = gtk3-x11; };
      })
      gtk3-x11
    ];

    env = [
      { name = "PATH"; eval = "$HOME/go/bin:$PATH"; }
    ];

    devshell.startup.symlink-generated-sources.text = ''
      ln -sf ${inputs.self.internal.${buildSystem}.go-assets}/assets              "$PRJ_ROOT"/core/ || exit 1
      ln -sf ${inputs.self.internal.${buildSystem}.common.go-constants}/constants "$PRJ_ROOT"/core/ || exit 1
    '';
  };
  */

}
