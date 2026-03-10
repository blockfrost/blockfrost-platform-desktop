{inputs, ...}: {
  perSystem = {pkgs, ...}: {
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
    };
  };
}
