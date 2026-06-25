{
  inputs,
  targetSystem,
}:
assert builtins.elem targetSystem ["aarch64-darwin"]; let
  pkgs = inputs.nixpkgs.legacyPackages.${targetSystem};
  inherit (pkgs) lib;
in rec {
  common = import ./common.nix {inherit inputs targetSystem;};
  package = blockfrost-platform-desktop;
  installer = unsigned-dmg;
  inherit (common) cardano-node blockfrost-platform;

  goBuildInputs = with pkgs.darwin.apple_sdk_11_0.frameworks; [Cocoa WebKit UniformTypeIdentifiers];

  blockfrost-platform-desktop-exe = pkgs.buildGoModule {
    name = common.codeName;
    src = common.coreSrc;
    vendorHash = common.blockfrost-platform-desktop-exe-vendorHash;
    buildInputs = goBuildInputs;
    overrideModAttrs = oldAttrs: {
      buildInputs = (oldAttrs.buildInputs or []) ++ goBuildInputs;
    };
    preBuild = ''
      ln -sf ${common.go-constants}/constants ./
      ln -sf ${go-assets}/assets ./
      # go:embed forbids symlinks, so:
      cp -R ${ui.dist} ./web-ui

      if [ -e vendor ] ; then
        chmod -R +w vendor
        (
          cd vendor/github.com/getlantern/systray
          patch -p1 -i ${./getlantern-systray--darwin-no-app-delegate.patch}
        )
        (
          cd vendor/github.com/wailsapp/wails
          patch -p1 -i ${./wails--darwin-handle-reopen.patch}
        )
      fi
    '';
  };

  go-assets =
    pkgs.runCommand "go-assets" {
      nativeBuildInputs = with pkgs; [imagemagick go-bindata];
    } ''
      magick -background none -size 66x66 ${builtins.path {path = common.coreSrc + "/cardano-template.svg";}} cardano.png
      cp cardano.png tray-icon
      cp ${common.openApiJson} openapi.json
      mkdir -p $out/assets
      go-bindata -pkg assets -o $out/assets/assets.go tray-icon openapi.json
    '';

  infoPlist = pkgs.writeText "Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>blockfrost-platform-desktop</string>
        <key>CFBundleIdentifier</key>
        <string>io.blockfrost.blockfrost-platform-desktop</string>
        <key>CFBundleName</key>
        <string>${common.prettyName}</string>
        <key>CFBundleDisplayName</key>
        <string>${common.prettyName}</string>
        <key>CFBundleVersion</key>
        <string>1.0</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0.0</string>
        <key>CFBundleIconFile</key>
        <string>iconset</string>
        <key>LSMinimumSystemVersion</key>
        <string>10.14</string>
        <key>NSHighResolutionCapable</key>
        <string>True</string>
        <!-- avoid showing the app on the Dock -->
        <key>LSUIElement</key>
        <string>1</string>
    </dict>
    </plist>
  '';

  svg2icns = source: let
    sizes = [16 18 19 22 24 32 40 48 64 128 256 512 1024];
    d2s = d: "${toString d}x${toString d}";
  in
    pkgs.runCommand "${baseNameOf source}.icns" {
      buildInputs = with pkgs; [imagemagick];
    } ''
      mkdir -p iconset.iconset
      ${lib.concatMapStringsSep "\n" (dim: ''
          magick -background none -size ${d2s dim}       ${source} iconset.iconset/icon_${d2s dim}.png
          magick -background none -size ${d2s (dim * 2)} ${source} iconset.iconset/icon_${d2s dim}@2x.png
        '')
        sizes}
      /usr/bin/iconutil --convert icns --output $out iconset.iconset
    '';

  icons = svg2icns ./macos-app-icon.svg;

  cardano-node-bundle = mkBundle {
    "cardano-node" = lib.getExe cardano-node;
  };

  blockfrost-platform-desktop =
    pkgs.runCommand common.codeName {
      meta.mainProgram = blockfrost-platform-desktop-exe.name;
    } ''
      app=$out/Applications/${lib.escapeShellArg common.prettyName}.app/Contents
      mkdir -p "$app"/MacOS
      mkdir -p "$app"/Resources

      ln -s ${infoPlist} "$app"/Info.plist

      cp ${blockfrost-platform-desktop-exe}/bin/* "$app"/MacOS/
      mkdir -p $out/bin/
      ln -s "$app"/MacOS/blockfrost-platform-desktop $out/bin/

      ln -s ${cardano-node-bundle} "$app"/MacOS/cardano-node

      ln -s ${blockfrost-platform}/libexec "$app"/MacOS/blockfrost-platform
      ln -s ${mkBundle {"dolos" = lib.getExe common.dolos;}} "$app"/MacOS/dolos
      ln -s ${mkBundle {"mithril-client" = lib.getExe mithril-client;}} "$app"/MacOS/mithril-client

      ln -s ${common.cardano-node-configs} "$app"/Resources/cardano-node-config
      ln -s ${common.dolos-configs} "$app"/Resources/dolos-config
      ln -s ${common.swagger-ui} "$app"/Resources/swagger-ui
      ln -s ${ui.dist} "$app"/Resources/ui

      ln -s ${icons} "$app"/Resources/iconset.icns
    '';

  nix-bundle-exe-same-dir = pkgs.runCommand "nix-bundle-exe-same-dir" {} ''
    cp -R ${inputs.nix-bundle-exe} $out
    chmod -R +w $out
    sed -r 's+@executable_path/\$relative_bin_to_lib/\$lib_dir+@executable_path+g' -i $out/bundle-macos.sh
  '';

  mkBundle = exes: let
    unbundled = pkgs.linkFarm "exes" (lib.mapAttrsToList (name: path: {
        name = "bin/" + name;
        inherit path;
      })
      exes);
  in
    (import nix-bundle-exe-same-dir {
        inherit pkgs;
        bin_dir = "bundle";
        exe_dir = "_unused_";
        lib_dir = "bundle";
      }
      unbundled).overrideAttrs (drv: {
      buildCommand =
        (
          builtins.replaceStrings
          ["'${unbundled}/bin'"]
          ["'${unbundled}/bin' -follow"]
          drv.buildCommand
        )
        + ''
          mv $out/bundle/* $out/
          rmdir $out/bundle
        '';
    });

  # XXX: this has no dependency on /nix/store on the target machine
  blockfrost-platform-desktop-bundle = let
    unbundled = blockfrost-platform-desktop;
  in
    pkgs.runCommand "blockfrost-platform-desktop-bundle" {
      meta.mainProgram = blockfrost-platform-desktop-exe.name;
    } ''
      mkdir -p $out/{Applications,bin}
      cp -r --dereference ${unbundled}/Applications/${lib.escapeShellArg common.prettyName}.app $out/Applications/

      chmod -R +w $out
      rm $out/Applications/${lib.escapeShellArg common.prettyName}.app/Contents/MacOS/blockfrost-platform-desktop
      cp -r --dereference ${mkBundle {"blockfrost-platform-desktop" = "${unbundled}/Applications/${common.prettyName}.app/Contents/MacOS/blockfrost-platform-desktop";}}/. $out/Applications/${lib.escapeShellArg common.prettyName}.app/Contents/MacOS/.

      ln -s $out/Applications/${lib.escapeShellArg common.prettyName}.app/Contents/MacOS/blockfrost-platform-desktop $out/bin/
    '';

  hfsprogs = pkgs.hfsprogs.overrideAttrs (drv: {
    buildInputs =
      (with pkgs; [openssl darwin.cctools gcc])
      ++ [
        (
          pkgs.runCommand "gcc-symlink" {} ''
            mkdir -p $out/bin
            ln -s ${pkgs.stdenv.cc}/bin/cc $out/bin/gcc
          ''
        )
      ];
    postPatch =
      (drv.postPatch or "")
      + ''
        sed -r 's+-lbsd++g' -i fsck_hfs.tproj/Makefile.lnx
        grep -RF '<endian.h>' | cut -d: -f1 | while IFS= read -r file ; do
          sed -r 's+#include <endian\.h>+#include <machine/endian.h>+g' -i "$file"
        done
        grep -RF '<byteswap.h>' | cut -d: -f1 | while IFS= read -r file ; do
          sed -r 's+#include <byteswap\.h>+#include <libkern/OSByteOrder.h>\n#define bswap_16(x) OSSwapInt16(x)\n#define bswap_32(x) OSSwapInt32(x)\n#define bswap_64(x) OSSwapInt64(x)+' -i "$file"
        done
        grep -RF '<bsd/string.h>' | cut -d: -f1 | while IFS= read -r file ; do
          sed -r 's+#include <bsd/string.h>+#include <string.h>+g' -i "$file"
        done
      '';
    meta =
      drv.meta
      // {
        platforms = lib.platforms.darwin;
      };
  });

  # Reading: <http://newosxbook.com/DMG.html>
  libdmg-hfsplus = pkgs.stdenv.mkDerivation {
    name = "libdmg-hfsplus";
    src = pkgs.fetchFromGitHub {
      owner = "fanquake";
      repo = "libdmg-hfsplus";
      rev = "1cc791e4173da9cb0b0cc16c5a1aaa25d5eb5efa";
      hash = "sha256-FdpuRq6vmvM10RMILDVRYsDcu64ItKvjdfB4CmuU2UQ=";
    };
    buildInputs = with pkgs; [cmake zlib];
  };

  # XXX: one can use hdiutil without super-user privileges to generate an ISO
  dmgImage-ugly = pkgs.runCommand "blockfrost-platform-desktop-dmg" {} ''
    mkdir -p $out
    target=$out/${common.codeName}-${common.ourVersion}-${revShort}-${targetSystem}.dmg

    /usr/bin/hdiutil makehybrid -iso -joliet -o tmp.iso \
      ${blockfrost-platform-desktop-bundle}/Applications

    echo 'Converting ISO to DMG…'
    ${libdmg-hfsplus}/bin/dmg tmp.iso $target

    # Make it downloadable from Hydra:
    mkdir -p $out/nix-support
    echo "file binary-dist \"$target\"" >$out/nix-support/hydra-build-products
  '';

  inherit (common.blockfrostPlatformFlake.internal.${targetSystem}) dmgbuild mkBadge;

  badgeIcon = pkgs.runCommand "badge.icns" {} ''
    ${mkBadge} ${svg2icns ./macos-dmg-inset.svg} $out 0.5 0.420
  '';

  revShort =
    if inputs.self ? shortRev
    then builtins.substring 0 9 inputs.self.rev
    else "dirty";

  # XXX: this needs to be `nix run` on `iog-mac-studio-arm-2-signing` or a similar machine.
  # It can’t be a pure derivation because it needs to impurely access the Apple signing machinery.
  make-signed-dmg = make-dmg {doSign = true;};

  unsigned-dmg = pkgs.stdenv.mkDerivation {
    name = "dmg-image";
    dontUnpack = true;
    buildPhase = ''
      ${make-dmg {doSign = false;}}/bin/* | tee make-installer.log
    '';
    installPhase = ''
      mkdir -p $out
      cp $(tail -n 1 make-installer.log) $out/

      # Make it downloadable from Hydra:
      mkdir -p $out/nix-support
      echo "file binary-dist \"$(echo $out/*.dmg)\"" >$out/nix-support/hydra-build-products
    '';
  };

  make-dmg = {doSign ? false}: let
    outFileName = "${common.codeName}-${common.ourVersion}-${revShort}-${targetSystem}.dmg";
    credentials = "/var/lib/buildkite-agent-default/signing.sh";
    codeSigningConfig = "/var/lib/buildkite-agent-default/code-signing-config.json";
    signingConfig = "/var/lib/buildkite-agent-default/signing-config.json";
    # See <https://dmgbuild.readthedocs.io/en/latest/settings.html>:
    settingsPy = pkgs.writeText "settings.py" ''
      import os.path

      app_path = defines.get("app_path", "/non-existent.app")
      icon_path = defines.get("icon_path", "/non-existent.icns")
      app_name = os.path.basename(app_path)

      # UDBZ (bzip2) is 154 MiB, while UDZO (gzip) is 204 MiB
      format = "UDBZ"
      size = None
      files = [app_path]
      symlinks = {"Applications": "/Applications"}
      hide_extension = [ app_name ]

      icon = icon_path

      icon_locations = {app_name: (140, 120), "Applications": (500, 120)}
      background = "builtin-arrow"

      show_status_bar = False
      show_tab_view = False
      show_toolbar = False
      show_pathbar = False
      show_sidebar = False
      sidebar_width = 180

      window_rect = ((200, 200), (640, 320))
      default_view = "icon-view"
      show_icon_preview = False

      include_icon_view_settings = "auto"
      include_list_view_settings = "auto"

      arrange_by = None
      grid_offset = (0, 0)
      grid_spacing = 100
      scroll_position = (0, 0)
      label_pos = "bottom"  # or 'right'
      text_size = 16
      icon_size = 128

      # license = { … }
    '';
    packAndSign = pkgs.writeShellApplication {
      name = "pack-and-sign";
      runtimeInputs = with pkgs; [bash coreutils jq];
      text = ''
        set -euo pipefail

        ${
          if doSign
          then ''
            codeSigningIdentity=$(jq -r .codeSigningIdentity ${codeSigningConfig})
            codeSigningKeyChain=$(jq -r .codeSigningKeyChain ${codeSigningConfig})
            # unused: signingIdentity=$(jq -r .signingIdentity ${signingConfig})
            # unused: signingKeyChain=$(jq -r .signingKeyChain ${signingConfig})

            echo "Checking if notarization credentials are defined..."
            if [ -z "''${NOTARY_USER:-}" ] || [ -z "''${NOTARY_PASSWORD:-}" ] || [ -z "''${NOTARY_TEAM_ID:-}" ] ; then
              echo >&2 "Fatal: please set \$NOTARY_USER, \$NOTARY_PASSWORD, and \$NOTARY_TEAM_ID"
              exit 1
            fi
          ''
          else ''
            echo >&2 "Warning: the DMG will be unsigned"
          ''
        }

        workDir=$(mktemp -d)
        appName=${lib.escapeShellArg common.prettyName}.app
        appDir=${blockfrost-platform-desktop-bundle}/Applications/${lib.escapeShellArg common.prettyName}.app

        echo "Info: workDir = $workDir"
        cd "$workDir"

        echo "Copying..."
        cp -r "$appDir" ./.
        chmod -R +w .

        bundlePath="$workDir/$appName"

        ${
          if doSign
          then ''
            echo
            echo "Signing code..."

            # Ensure the code signing identity is found and set the keychain search path:
            security show-keychain-info "$codeSigningKeyChain"
            security find-identity -v -p codesigning "$codeSigningKeyChain"
            security list-keychains -d user -s "$codeSigningKeyChain"

            # Sign the whole component deeply
            codesign \
              --force --verbose=4 --deep --strict --timestamp --options=runtime \
              --entitlements ${./darwin-entitlements.xml} \
              --sign "$codeSigningIdentity" \
              "$bundlePath"

            # Verify the signing
            codesign --verbose=4 --verify --deep --strict "$bundlePath"
            codesign --verbose=4 --verify --deep --strict --display -r- "$bundlePath"
            codesign -d --entitlements :- "$bundlePath"
          ''
          else ""
        }

        echo
        echo "Making the DMG..."
        ${dmgbuild}/bin/dmgbuild \
          -D app_path="$bundlePath" \
          -D icon_path=${badgeIcon} \
          -s ${settingsPy} \
          ${lib.escapeShellArg common.prettyName} ${outFileName}

        ${
          if doSign
          then ''
            # FIXME: this doesn’t work outside of `buildkite-agent-default`, it seems:
            #(
            #  source ${credentials}
            #  security unlock-keychain -p "$SIGNING" "$signingKeyChain"
            #)

            echo
            echo "Signing the DMG..."
            codesign \
              --force --verbose=4 --timestamp --options=runtime \
              --sign "$codeSigningIdentity" \
              ${outFileName}

            echo
            echo "Submitting for notarization..."
            xcrun notarytool submit \
              --apple-id "$NOTARY_USER" \
              --password "$NOTARY_PASSWORD" \
              --team-id "$NOTARY_TEAM_ID" \
              --wait ${outFileName}

            echo
            echo "Stapling the notarization ticket..."
            xcrun stapler staple ${outFileName}
          ''
          else ""
        }

        echo
        echo "Done, you can upload it to GitHub releases:"
        echo "$workDir"/${outFileName}
      '';
    };
  in
    pkgs.writeShellApplication {
      name = "make-dmg";
      runtimeInputs = with pkgs; [bash coreutils jq];
      text = ''
        set -euo pipefail
        cd /
        ${
          if doSign
          then ''
            exec sudo -u buildkite-agent-default \
              "NOTARY_USER=''${NOTARY_USER:-}" \
              "NOTARY_PASSWORD=''${NOTARY_PASSWORD:-}" \
              "NOTARY_TEAM_ID=''${NOTARY_TEAM_ID:-}" \
              ${lib.getExe packAndSign}
          ''
          else ''
            exec ${lib.getExe packAndSign}
          ''
        }
      '';
    };

  mithril-client = lib.recursiveUpdate {meta.mainProgram = "mithril-client";} common.mithril-bin;

  ui = rec {
    node_modules = pkgs.stdenv.mkDerivation {
      name = "ui-node_modules";
      src = common.ui.lockfiles;
      nativeBuildInputs = [common.ui.yarn common.ui.nodejs] ++ (with pkgs; [python3 pkg-config jq]);
      configurePhase = common.ui.setupCacheAndGypDirs;
      buildPhase = ''
        # Do not look up in the registry, but in the offline cache:
        ${common.ui.yarn2nix.fixup_yarn_lock}/bin/fixup_yarn_lock yarn.lock

        # Now, install from offlineCache to node_modules/, but do not
        # execute any scripts defined in the project package.json and
        # its dependencies we need to `patchShebangs` first, since even
        # ‘/usr/bin/env’ is not available in the build sandbox
        yarn install --ignore-scripts

        # Remove all prebuilt *.node files extracted from `.tgz`s
        find . -type f -name '*.node' -not -path '*/@swc*/*' -exec rm -vf {} ';'

        patchShebangs . >/dev/null  # a real lot of paths to patch, no need to litter logs

        # And now, with correct shebangs, run the install scripts (we have to do that
        # semi-manually, because another `yarn install` will overwrite those shebangs…):
        find node_modules -type f -name 'package.json' | sort | ( xargs grep -F '"install":' || true ; ) | cut -d: -f1 | while IFS= read -r dependency ; do
          # The grep pre-filter is not ideal:
          if [ "$(jq .scripts.install "$dependency")" != "null" ] ; then
            echo ' '
            echo "Running the install script for ‘$dependency’:"
            ( cd "$(dirname "$dependency")" ; yarn run install ; )
          fi
        done

        patchShebangs . >/dev/null  # a few new files will have appeared
      '';
      installPhase = ''
        mkdir $out
        cp -r node_modules $out/
      '';
      dontFixup = true; # TODO: just to shave some seconds, turn back on after everything works
    };

    dist = pkgs.stdenv.mkDerivation {
      name = "ui-dist";
      src = common.uiSrc;
      nativeBuildInputs = [common.ui.yarn common.ui.nodejs] ++ (with pkgs; [python3 pkg-config jq]);
      CI = "nix";
      NODE_ENV = "production";
      BUILDTYPE = "Release";
      configurePhase =
        common.ui.setupCacheAndGypDirs
        + ''
          cp -r ${node_modules}/. ./
          chmod -R +w .
        '';
      buildPhase = ''
        patchShebangs .
        yarn build
      '';
      installPhase = ''
        cp -r dist $out
        cp -r ${common.ui.favicons}/. $out/
      '';
      dontFixup = true;
    };
  };
}
