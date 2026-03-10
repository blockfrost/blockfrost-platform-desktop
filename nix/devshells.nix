{inputs}: {
  config,
  pkgs,
  ...
}: let
  inherit (pkgs) lib;
  internal = inputs.self.internal.${pkgs.system};

  # Let stdenv's setup hooks resolve all transitive C dependencies
  # (pkg-config paths, include paths, linker flags) – the same
  # machinery that `buildGoModule` uses internally:
  cEnvFile =
    pkgs.runCommand "go-c-env" {
      nativeBuildInputs = [pkgs.pkg-config pkgs.stdenv.cc];
      buildInputs = lib.optionals pkgs.stdenv.isLinux [
        internal.webkit2gtk
        (pkgs.libayatana-appindicator-gtk3.override {
          gtk3 = pkgs.gtk3-x11;
          libayatana-indicator = pkgs.libayatana-indicator.override {gtk3 = pkgs.gtk3-x11;};
          libdbusmenu-gtk3 = pkgs.libdbusmenu-gtk3.override {gtk3 = pkgs.gtk3-x11;};
        })
        pkgs.gtk3-x11
        pkgs.xorg.libX11 # sqweek/dialog: #include <X11/Xlib.h> + #cgo LDFLAGS: -lX11
      ];
    } ''
      {
        echo "export PKG_CONFIG_PATH='$PKG_CONFIG_PATH'"
        echo "export NIX_CFLAGS_COMPILE='$NIX_CFLAGS_COMPILE'"
        echo "export NIX_LDFLAGS='$NIX_LDFLAGS'"
        echo "export NIX_CC_WRAPPER_TARGET_HOST_${wrapperTargetSuffix}=1"
        echo "export NIX_BINTOOLS_WRAPPER_TARGET_HOST_${wrapperTargetSuffix}=1"
      } > $out
    '';

  wrapperTargetSuffix =
    builtins.replaceStrings ["-"] ["_"] pkgs.stdenv.hostPlatform.config;
in {
  name = "blockfrost-platform-desktop-devshell";

  imports = ["${inputs.devshell}/extra/language/c.nix"];

  commands = [
    {package = inputs.self.formatter.${pkgs.system};}
    {package = pkgs.go;}
    {package = pkgs.gopls;}
  ];

  language.c.compiler = pkgs.stdenv.cc;

  env = [
    {
      name = "PATH";
      prefix = "$HOME/go/bin";
    }
  ];

  devshell = {
    packages = [pkgs.pkg-config];

    startup.c-env.text = "source ${cEnvFile}";

    startup.symlink-generated-sources.text = ''
      ln -sf ${internal.go-assets}/assets              "$PRJ_ROOT"/core/ || exit 1
      ln -sf ${internal.common.go-constants}/constants "$PRJ_ROOT"/core/ || exit 1
      # go:embed cannot follow symlinks, so we rsync the UI dist (with u+w to allow re-sync):
      ${pkgs.rsync}/bin/rsync -a --no-owner --no-group --chmod=u+w --delete ${internal.ui.dist}/ "$PRJ_ROOT"/core/web-ui/ || exit 1
    '';

    motd = ''

      {202}🔨 Welcome to ${config.name}{reset}
      $(menu)

      You can now run '{bold}cd core/ && go build{reset}'.
    '';
  };
}
