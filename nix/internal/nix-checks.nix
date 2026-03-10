{inputs, ...}: {
  perSystem = {
    pkgs,
    system,
    lib,
    ...
  }: let
    internal = inputs.self.internal.${system};
    inherit (internal) common;
  in {
    checks = {
      nix-statix =
        pkgs.runCommandNoCC "nix-statix" {
          buildInputs = [pkgs.statix];
        } ''
          touch $out
          cd ${inputs.self}
          exec statix check .
        '';

      nix-deadnix =
        pkgs.runCommandNoCC "nix-deadnix" {
          buildInputs = [pkgs.deadnix];
        } ''
          touch $out
          cd ${inputs.self}
          exec deadnix --fail .
        '';

      nix-nil =
        pkgs.runCommandNoCC "nix-nil" {
          buildInputs = [pkgs.nil];
        } ''
          ec=0
          touch $out
          cd ${inputs.self}
          find . -type f -iname '*.nix' | while IFS= read -r file; do
            nil diagnostics "$file" || ec=1
          done
          exit $ec
        '';

      # From `nixd`:
      nix-nixf =
        pkgs.runCommandNoCC "nix-nil" {
          buildInputs = [pkgs.nixf pkgs.jq];
        } ''
          ec=0
          touch $out
          cd ${inputs.self}
          find . -type f -iname '*.nix' | while IFS= read -r file; do
            errors=$(nixf-tidy --variable-lookup --pretty-print <"$file" | jq -c '.[]' | sed -r "s#^#$file: #")
            if [ -n "$errors" ] ; then
              cat <<<"$errors"
              echo
              ec=1
            fi
          done
          exit $ec
        '';

      go-staticcheck = pkgs.buildGoModule {
        name = "go-staticcheck";
        src = common.coreSrc;
        vendorHash = common.blockfrost-platform-desktop-exe-vendorHash;
        nativeBuildInputs = [pkgs.go-tools] ++ lib.optionals pkgs.stdenv.isLinux [pkgs.pkg-config];
        buildInputs = internal.goBuildInputs;
        overrideModAttrs = oldAttrs: {
          buildInputs = (oldAttrs.buildInputs or []) ++ internal.goBuildInputs;
        };
        preBuild = ''
          ln -sf ${common.go-constants}/constants ./
          ln -sf ${internal.go-assets}/assets ./
          # go:embed forbids symlinks, so:
          cp -R ${internal.ui.dist} ./web-ui
        '';
        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR
          staticcheck ./...
          runHook postBuild
        '';
        installPhase = "touch $out";
        doCheck = false;
      };
    };
  };
}
