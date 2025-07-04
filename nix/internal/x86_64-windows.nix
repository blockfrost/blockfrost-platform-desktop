{ inputs, targetSystem }:

assert targetSystem == "x86_64-windows";

let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux; # cross-building for Windows on Linux
  inherit (pkgs) lib;
in rec {
  common = import ./common.nix { inherit inputs targetSystem; };
  package = blockfrost-platform-desktop;
  installer = unsignedInstaller;
  make-signed-installer = make-installer {doSign = true;};

  inherit (common) cardano-node ogmios cardano-submit-api blockfrost-platform;

  patchedGo = pkgs.go.overrideAttrs (drv: {
    patches = (drv.patches or []) ++ [
      ./go--windows-expose-CreateEnvBlock.patch
      ./go--windows-StartupInfoLpReserved2.patch
    ];
  });

  # XXX: we have to be a bit creative to cross-compile Go code for Windows:
  #   • having a MinGW-w64 stdenv (for the C/C++ parts),
  #   • Linux Go (but instructed to cross-compile),
  #   • and taking goModules (vendor) from the Linux derivation – these are only sources
  blockfrost-platform-desktop-exe = let
    noConsoleWindow = true;
    go = patchedGo;
    goModules = inputs.self.internal.x86_64-linux.blockfrost-platform-desktop-exe.goModules;
  in pkgs.pkgsCross.mingwW64.stdenv.mkDerivation {
    name = common.codeName;
    src = common.coreSrc;
    GOPROXY = "off";
    GOSUMDB = "off";
    GO111MODULE = "on";
    GOFLAGS = ["-mod=vendor" "-trimpath"];
    GOOS = "windows";
    GOARCH = "amd64";
    inherit (go) CGO_ENABLED;
    nativeBuildInputs = [ go ];
    configurePhase = ''
      export GOCACHE=$TMPDIR/go-cache
      export GOPATH="$TMPDIR/go"
      rm -rf vendor
      cp -r --reflink=auto ${goModules} vendor

      chmod -R +w vendor
      (
        cd vendor/github.com/getlantern/systray
        patch -p1 -i ${./getlantern-systray--windows-schedule-on-main-thread.patch}
      )
      (
        # XXX: without this, in Task Manager, we change name to “Resync with Mithril?”, because of no main window:
        cd vendor/github.com/sqweek/dialog
        patch -p1 -i ${./sqweek-dialog--windows-title.patch}
      )
      (
        cd vendor/github.com/UserExistsError/conpty
        patch -p1 -i ${./conpty--get-pid-add-env.patch}
      )
      (
        cd vendor/github.com/wailsapp/go-webview2
        patch -p1 -i ${pkgs.fetchurl {
          # Fix an infinite recursion on errors:
          url = "https://github.com/wailsapp/go-webview2/pull/7.patch";
          hash = "sha256-Cj/O131ywEXShaBa116U1ldmLzMT0g3I/7bAtrQen88=";
        }}
      )
    '';
    buildPhase = ''
      ln -sf ${common.go-constants}/constants ./
      ln -sf ${go-assets}/assets ./
      # go:embed forbids symlinks, so:
      cp -R ${ui.dist} ./web-ui
      go build ${if noConsoleWindow then "-ldflags -H=windowsgui" else ""}
    '';
    installPhase = ''
      mkdir -p $out
      mv blockfrost-platform-desktop.exe $out/
    '';
    passthru = { inherit go goModules; };
  };

  go-assets = pkgs.runCommand "go-assets" {
    nativeBuildInputs = with pkgs; [ go-bindata ];
  } ''
    cp ${icon} tray-icon
    cp ${common.openApiJson} openapi.json
    mkdir -p $out/assets
    go-bindata -pkg assets -o $out/assets/assets.go tray-icon openapi.json
  '';

  win-test-exe = let
    go = patchedGo;
  in pkgs.pkgsCross.mingwW64.stdenv.mkDerivation {
    name = "win-test";
    src = ./win-test;
    GOPROXY = "off";
    GOSUMDB = "off";
    GO111MODULE = "on";
    GOFLAGS = ["-mod=vendor" "-trimpath"];
    GOOS = "windows";
    GOARCH = "amd64";
    inherit (go) CGO_ENABLED;
    nativeBuildInputs = [ go ];
    configurePhase = ''
      export GOCACHE=$TMPDIR/go-cache
      export GOPATH="$TMPDIR/go"
      rm -rf vendor
      mkdir -p vendor
      cp ${builtins.path { path = common.coreSrc + "/main_fd_inheritance_windows.go"; }} main_fd_inheritance_windows.go
    '';
    buildPhase = ''
      go build
    '';
    installPhase = ''
      mkdir -p $out
      mv win-test.exe $out/
    '';
    passthru = { inherit go; };
  };

  svg2ico = source: let
    sizes = [16 24 32 48 64 128 256 512];
    d2s = d: "${toString d}x${toString d}";
  in pkgs.runCommand "${baseNameOf source}.ico" {
    buildInputs = with pkgs; [ imagemagick ];
  } ''
    ${lib.concatMapStringsSep "\n" (dim: ''
      magick -background none -size ${d2s dim} ${source} ${d2s dim}.png
    '') sizes}
    magick ${lib.concatMapStringsSep " " (dim: "${d2s dim}.png") sizes} $out
  '';

  icon = svg2ico (builtins.path { path = common.coreSrc + "/cardano.svg"; });

  # FIXME: This is terrible, we have to do it better, but I can’t get the Go cross-compiler
  # to embed Windows resources properly in the EXE. The file increases in size, but is still
  # missing something. I have no time to investigate now, so let’s have this dirty hack.
  blockfrost-platform-desktop-exe-with-icon = pkgs.runCommand "blockfrost-platform-desktop-with-icon" {
    buildInputs = with cardano-js-sdk.fresherPkgs; [
      wineWowPackages.stableFull
      winetricks samba /*samba for bin/ntlm_auth*/
    ];
  } ''
    export HOME=$(realpath $NIX_BUILD_TOP/home)
    mkdir -p $HOME
    ${pkgs.xvfb-run}/bin/xvfb-run \
      --server-args="-screen 0 1920x1080x24 +extension GLX +extension RENDER -ac -noreset" \
      ${pkgs.writeShellScript "wine-setup-inside-xvfb" ''
        set -euo pipefail
        export WINEDEBUG=-all  # comment out to get normal output (err,fixme), or set to +all for a flood
        set +e
        wine ${resourceHacker}/ResourceHacker.exe \
          -log res-hack.log \
          -open "$(winepath -w ${blockfrost-platform-desktop-exe}/*.exe)" \
          -save with-icon.exe \
          -action addoverwrite \
          -res "$(winepath -w ${icon})" \
          -mask ICONGROUP,MAINICON,
        wine_ec="$?"
        set -e
        echo "wine exit code: $wine_ec"
        cat res-hack.log
        if [ "$wine_ec" != 0 ] ; then
          exit "$wine_ec"
        fi
      ''}
    mkdir -p $out
    mv with-icon.exe $out/blockfrost-platform-desktop.exe
  '';

  go-rsrc = pkgs.buildGoModule rec {
    pname = "go-rsrc";
    version = "0.10.2";
    src = pkgs.fetchFromGitHub {
      owner = "akavel"; repo = pname;
      rev = "v${version}";
      hash = "sha256-QsPx3RYA2uc+qIN2LKRCvumeMedg0kIEuUOkaRvuLbs=";
    };
    vendorHash = null;
  };

  go-winres = pkgs.buildGoModule rec {
    pname = "go-winres";
    version = "0.3.1";
    src = pkgs.fetchFromGitHub {
      owner = "tc-hib"; repo = pname;
      rev = "v${version}";
      hash = "sha256-D/B5ZJkCutrVeIdgqnalgfNAPiIUDGy+sRi3bYfdBS8=";
    };
    vendorHash = "sha256-ntLgiD4CS1QtWTYbrsEraqndtWYOFqmwgQnSBhF1xuE=";
    doCheck = false;
  };

  blockfrost-platform-desktop = mkPackage { withJS = true; };

  mkPackage = { withJS }: pkgs.runCommand common.codeName {} ''
    mkdir -p $out/libexec
    cp -Lr ${blockfrost-platform-desktop-exe-with-icon}/* $out/

    mkdir -p $out/libexec/mithril-client
    cp -L ${mithril-client}/*.{exe,dll} $out/libexec/mithril-client/

    mkdir -p $out/libexec/blockfrost-platform
    cp -L ${blockfrost-platform}/*.{exe,dll} $out/libexec/blockfrost-platform/

    mkdir -p $out/libexec/cardano-node
    cp -Lf ${cardano-node}/bin/*.{exe,dll} $out/libexec/cardano-node/

    ${lib.optionalString (!common.blockfrostPlatformOnly) ''
      cp -Lf ${cardano-submit-api}/bin/*.{exe,dll} $out/libexec/cardano-node/

      mkdir -p $out/libexec/ogmios
      cp -L ${ogmios}/bin/*.{exe,dll} $out/libexec/ogmios/

      mkdir -p $out/libexec/nodejs
      cp -L ${cardano-js-sdk.target.nodejs}/node.exe $out/libexec/nodejs/

      mkdir -p $out/libexec/postgres
      cp -Lr ${postgresUnpacked}/{bin,lib,share,*license*.txt} $out/libexec/postgres/

      ${if !withJS then "" else ''
        cp -Lr ${cardano-js-sdk.ourPackage} $out/cardano-js-sdk
      ''}

      mkdir -p $out/libexec/mksymlink
      cp -Lf ${mksymlink}/*.exe $out/libexec/mksymlink/
    ''}

    mkdir -p $out/libexec/sigbreak
    cp -Lf ${sigbreak}/*.exe $out/libexec/sigbreak/

    mkdir -p $out/libexec/ourwebview2/
    cp -Lr ${WebView2}/. $out/libexec/webview2/

    cp -Lr ${common.cardano-node-configs} $out/cardano-node-config
    cp -Lr ${common.swagger-ui} $out/swagger-ui
    cp -Lr ${ui.dist} $out/ui
  '';

  blockfrost-platform-desktop-zip = mkArchive { withJS = true; };

  # This is much smaller, and much quicker to unpack, and very useful
  # if you want to just iteratively test the process manager:
  blockfrost-platform-desktop-zip-nojs = mkArchive { withJS = false; };

  revShort =
    if inputs.self ? shortRev
    then builtins.substring 0 9 inputs.self.rev
    else "dirty";

  # For easier testing, skipping the installer (for now):
  mkArchive = { withJS }: pkgs.runCommand "blockfrost-platform-desktop.7z" {} ''
    mkdir -p $out
    target=$out/${common.codeName}-${common.ourVersion}-${revShort}-${targetSystem}.7z

    ln -s ${mkPackage { inherit withJS; }} blockfrost-platform-desktop
    ${with pkgs; lib.getExe p7zip} a -r -l $target blockfrost-platform-desktop

    # Make it downloadable from Hydra:
    mkdir -p $out/nix-support
    echo "file binary-dist \"$target\"" >$out/nix-support/hydra-build-products
  '';

  # XXX: we’re compiling them with MSVC so that it takes 122 kB, not 100× more…
  mkSimpleExecutable = {
    name,
    srcFile,
    noConsole ? false   # Don’t open a terminal window
  }: pkgs.runCommandNoCC name {
    buildInputs = with cardano-js-sdk.fresherPkgs; [ wineWowPackages.stableFull winetricks ];
  } ''
    export HOME=$(realpath $NIX_BUILD_TOP/home)
    mkdir -p $HOME

    cp ${srcFile} ${name}.cc

    export WINEDEBUG=-all  # comment out to get normal output (err,fixme), or set to +all for a flood
    export WINEPATH="$(winepath -w ${cardano-js-sdk.msvc-installed}/VC/Tools/MSVC/*/bin/Hostx64/x64)"

    inclPath_1="$(winepath -w ${cardano-js-sdk.msvc-installed}/VC/Tools/MSVC/*/include)"
    inclPath_2="$(winepath -w ${cardano-js-sdk.msvc-installed}/kits/10/Include/*/ucrt)"
    inclPath_3="$(winepath -w ${cardano-js-sdk.msvc-installed}/kits/10/Include/*/um)"
    inclPath_4="$(winepath -w ${cardano-js-sdk.msvc-installed}/kits/10/Include/*/shared)"

    libPath_1="$(winepath -w ${cardano-js-sdk.msvc-installed}/VC/Tools/MSVC/*/lib/x64)"
    libPath_2="$(winepath -w ${cardano-js-sdk.msvc-installed}/kits/10/Lib/*/ucrt/x64)"
    libPath_3="$(winepath -w ${cardano-js-sdk.msvc-installed}/kits/10/Lib/*/um/x64)"

    wine cl.exe /EHsc "/I$inclPath_1" "/I$inclPath_2" "/I$inclPath_3" "/I$inclPath_4" /c ${name}.cc

    wine cl.exe ${name}.obj /link "/LIBPATH:$libPath_1" "/LIBPATH:$libPath_2" "/LIBPATH:$libPath_3" \
      ${lib.optionalString noConsole "/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup"} \
      /out:${name}.exe

    mkdir -p $out
    mv ${name}.exe $out/
  '';

  sigbreak = mkSimpleExecutable {
    name = "sigbreak";
    srcFile = ./sigbreak.cc;
  };

  # `mklink /D` is a `cmd.exe` built-in, not a real executable… let’s make it one:
  mksymlink = mkSimpleExecutable {
    name = "mksymlink";
    srcFile = ./mksymlink.c;
    noConsole = true;
  };

  unsignedInstaller = pkgs.stdenv.mkDerivation {
    name = "unsigned-installer";
    dontUnpack = true;
    buildPhase = ''
      ${make-installer {doSign = false;}}/bin/* | tee make-installer.log
    '';
    installPhase = ''
      mkdir -p $out
      cp $(tail -n 1 make-installer.log) $out/

      # Make it downloadable from Hydra:
      mkdir -p $out/nix-support
      echo "file binary-dist \"$(echo $out/*.exe)\"" >$out/nix-support/hydra-build-products
    '';
  };

  make-installer = {doSign ? false}: let
    outFileName = "${common.codeName}-${common.ourVersion}-${revShort}-${targetSystem}.exe";
    installer-nsi =
      pkgs.runCommandNoCC "installer.nsi" {
        inherit outFileName;
        projectName = common.prettyName;
        projectCodeName = common.codeName;
        projectVersion = common.ourVersion;
        installerIconPath = "icon.ico";
        lockfileName = "instance.lock";
      } ''
        substituteAll ${./windows-installer.nsi} $out
      '';
  in
    pkgs.writeShellApplication {
      name = "pack-and-sign";
      runtimeInputs = with pkgs; [bash coreutils nsis];
      runtimeEnv = {
        inherit outFileName;
      };
      text = ''
        set -euo pipefail
        workDir=$(mktemp -d)
        cd "$workDir"

        ${
          if doSign
          then ''
            sign_cmd() {
              echo "Signing: ‘$1’…"
              ssh HSM <"$1" >"$1".signed
              mv "$1".signed "$1"
            }
          ''
          else ''
            sign_cmd() {
              echo "Would sign: ‘$1’"
            }
          ''
        }

        cp ${installer-nsi} installer.nsi
        cp -r ${mkPackage { withJS = true; }} contents
        chmod -R +w contents
        cp ${uninstaller}/uninstall.exe contents/
        cp ${icon} icon.ico

        chmod -R +w contents
        find contents '(' -iname '*.exe' -o -iname '*.dll' ')' | sort | while IFS= read -r binary_to_sign ; do
          sign_cmd "$binary_to_sign"
        done

        makensis installer.nsi -V4

        sign_cmd "$outFileName"

        echo
        echo "Done, you can upload it to GitHub releases:"
        echo "$workDir"/"$outFileName"
      '';
    };

  uninstaller =
    pkgs.runCommandNoCC "uninstaller" {
      buildInputs = [nsis pkgs.wine];
      projectName = common.prettyName;
      projectCodeName = common.codeName;
      projectVersion = common.ourVersion;
      WINEDEBUG = "-all"; # comment out to get normal output (err,fixme), or set to +all for a flood
    } ''
      mkdir home
      export HOME=$(realpath home)
      substituteAll ${./windows-uninstaller.nsi} uninstaller.nsi
      makensis uninstaller.nsi -V4
      wine tempinstaller.exe /S
      mkdir $out
      mv $HOME/.wine/drive_c/uninstall.exe $out/uninstall.exe
    '';

  nsis = import ./nsis.nix { nsisNixpkgs = inputs.nixpkgs-nsis; };

  resourceHacker = pkgs.fetchzip {
    name = "resource-hacker-5.1.7";
    url = "http://www.angusj.com/resourcehacker/resource_hacker.zip";
    hash = "sha256-W5TmyjNNXE3nvn37XYbTM+DBeupPijE4M70LJVKJupU=";
    stripRoot = false;
  };

  # -------------------------------------- cardano-js-sdk ------------------------------------------ #

  # XXX: the main challenge here is that we must cross-build *.node
  # DLLs from Linux to Windows, and it can only be done with Visual
  # Studio running in Wine (Node.js doesn’t support MinGW-w64)
  #
  # See also: similar approach in Daedalus: <https://github.com/input-output-hk/daedalus/blob/94ffe045dea35fd8d638bc466f9eb61e51d4e935/nix/internal/x86_64-windows.nix#L205>
  cardano-js-sdk = rec {
    theirPackage = (common.flake-compat {
      src = inputs.cardano-js-sdk;
    }).defaultNix.${pkgs.system}.cardano-services.packages.cardano-services;

    # Let’s grab the build-time `node_modules` of the Linux build, and
    # we’ll call specific "install" scripts manually inside Wine.
    #
    # One improvement would be to skip building the Linux binaries altogether here.
    theirNodeModules = theirPackage.overrideAttrs (drv: {
      name = "cardano-js-sdk-node_modules";
      buildPhase = ":";
      installPhase = ''
        # Clear the Linux binaries:
        find -type f '(' -name '*.node' -o -name '*.o' -o -name '*.o.d' -o -name '*.target.mk' \
          -o -name '*.Makefile' -o -name 'Makefile' -o -name 'config.gypi' ')' -exec rm -vf '{}' ';'

        mkdir $out
        ${with pkgs; lib.getExe rsync} -Rah \
          $(find -type d -name 'node_modules' -prune) \
          $(find -type f '(' -name 'package.json' -o -name 'yarn.lock' ')' -a -not -path '*/node_modules/*') \
          $out/
      '';
      dontFixup = true;
    });

    # Let’s build the TS/JS files as on Linux, but then copy native Windows DLLs (${nativeModules} below)
    ourPackage = theirPackage.overrideAttrs (drv: {
      name = "cardano-js-sdk";
      nativeBuildInputs = (drv.nativeBuildInputs or []) ++ [ pkgs.rsync ];
      installPhase = ''
        mkdir $out
        rsync -Rah $(find . '(' '(' -type d -name 'dist' ')' -o -name 'package.json' ')' \
          -not -path '*/node_modules/*') $out/

        cp -r ${theirPackage.production-deps}/libexec/incl/node_modules $out/
        chmod -R +w $out

        # Clear the Linux binaries:
        find $out/node_modules/ -type f '(' -name '*.node' -o -name '*.o' -o -name '*.o.d' -o -name '*.target.mk' \
          -o -name '*.Makefile' -o -name 'Makefile' -o -name 'config.gypi' ')' -exec rm -vf '{}' ';'

        # Inject the Windows DLLs:
        rsync -ah ${nativeModules}/. $out/

        # Another bug concerns workspace symlinks, NTFS symlinks made with `mklink /D` do work,
        # and we create them in the installer.exe (which is run as Administrator).
        rm $out/node_modules/@cardano-sdk/*

        find $out/node_modules/ -type l -name 'python3'     -exec rm -vf  '{}' ';'
        find $out/node_modules/ -type d -name '.bin' -prune -exec rm -vfr '{}' ';'

        # Drop the cjs/ prefix, it’s problematic on Windows:
        find $out/packages -mindepth 3 -maxdepth 3 -type d -path '*/dist/cjs' | while IFS= read -r cjs ; do
          mv "$cjs" "$cjs.old-unused"
          mv "$cjs.old-unused"/{.*,*} "$(dirname "$cjs")/"
          rmdir "$cjs.old-unused"
        done
        find $out/packages -mindepth 2 -maxdepth 2 -type f -name 'package.json' | while IFS= read -r packageJson ; do
          sed -r 's,dist/cjs,dist,g' -i "$packageJson"
          sed -r 's,dist/esm,dist,g' -i "$packageJson"
        done
      '';
      postInstall = "";
      dontFixup = true;
    });

    # XXX: `pkgs.nodejs` lacks `uv/win.h`, `node.lib` etc., so:
    nodejsHeaders = pkgs.runCommand "nodejs-headers-${theirPackage.nodejs.version}" rec {
      version = theirPackage.nodejs.version;
      src = pkgs.fetchurl {
        url = "https://nodejs.org/dist/v${version}/node-v${version}-headers.tar.gz";
        hash = "sha256-jHLwhhI3cxo+KSpL4rals8D1EUr+OjoCtfrTXXs7LMI=";
      };
      # XXX: normally, node-gyp would download it only for Windows, see `resolveLibUrl()`
      # in `node-gyp/lib/process-release.js`
      node_lib = pkgs.fetchurl {
        name = "node.lib-${version}";
        url = "https://nodejs.org/dist/v${version}/win-x64/node.lib";
        hash = "sha256-crf6uTga+PSVjIIS89TN//jHxbHjPqrQ59WIgpNWjNU=";
      };
    } ''
      mkdir unpack
      tar -C unpack -xf $src
      mv unpack/* $out
      mkdir -p $out/Release
      ln -s $node_lib $out/Release/node.lib
    '';

    nativeModules = pkgs.stdenv.mkDerivation {
      name = "cardano-js-sdk-nativeModules";
      dontUnpack = true;
      nativeBuildInputs = (with pkgs; [ jq file procps ])
        ++ (with fresherPkgs; [ wineWowPackages.stableFull fontconfig winetricks samba /*samba for bin/ntlm_auth*/ ])
        ;
      configurePhase = ''
        # XXX: `HOME` (for various caches) shouldn’t be under our source root, that confuses some Node.js tools:
        export HOME=$(realpath $NIX_BUILD_TOP/home)
        mkdir -p $HOME

        cp -R ${theirNodeModules}/. ./
        chmod -R +w .
      '';
      FONTCONFIG_FILE = fresherPkgs.makeFontsCache {
        fontDirectories = with fresherPkgs; [
          dejavu_fonts freefont_ttf gyre-fonts liberation_ttf noto-fonts-emoji
          unifont winePackages.fonts xorg.fontcursormisc xorg.fontmiscmisc
        ];
      };
      buildPhase = let
        mkSection = title: ''
          echo ' '
          echo ' '
          echo ' '
          echo ' '
          echo ' '
          echo "===================== ${title} ====================="
        '';
      in ''
        ${pkgs.xvfb-run}/bin/xvfb-run \
          --server-args="-screen 0 1920x1080x24 +extension GLX +extension RENDER -ac -noreset" \
          ${pkgs.writeShellScript "wine-setup-inside-xvfb" ''
            set -euo pipefail

            export WINEDEBUG=-all  # comment out to get normal output (err,fixme), or set to +all for a flood

            ${mkSection "Setting Windows system version"}
            winetricks -q win81

            ${mkSection "Setting up env and symlinks in standard locations"}

            # Symlink Windows SDK in a standard location:
            lx_program_files="$HOME/.wine/drive_c/Program Files (x86)"
            mkdir -p "$lx_program_files"
            ln -svfn ${msvc-installed}/kits "$lx_program_files/Windows Kits"

            # Symlink VC in a standard location:
            vc_versionYear="$(jq -r .info.productLineVersion <${msvc-cache}/*.manifest)"
            lx_VSINSTALLDIR="$lx_program_files/Microsoft Visual Studio/$vc_versionYear/Community"
            mkdir -p "$lx_VSINSTALLDIR"
            ln -svf ${msvc-installed}/VC "$lx_VSINSTALLDIR"/
            ln -svf ${msvc-installed}/MSBuild "$lx_VSINSTALLDIR"/

            export VCINSTALLDIR="$(winepath -w "$lx_VSINSTALLDIR/VC")\\"
            export VCToolsVersion="$(ls ${msvc-installed}/VC/Tools/MSVC | head -n1)"
            export VCToolsInstallDir="$(winepath -w "$lx_VSINSTALLDIR/VC/Tools/MSVC/$VCToolsVersion")\\"
            export VCToolsRedistDir="$(winepath -w "$lx_VSINSTALLDIR/VC/Redist/MSVC/$VCToolsVersion")\\"

            export ClearDevCommandPromptEnvVars=false

            export VSINSTALLDIR="$(winepath -w "$lx_VSINSTALLDIR")\\"

            lx_WindowsSdkDir=("$lx_program_files/Windows Kits"/*)
            export WindowsSdkDir="$(winepath -w "$lx_WindowsSdkDir")\\"

            set -x

            # XXX: this can break, as `v10.0` is not determined programmatically;
            # XXX: the path is taken from `${msvc-installed}/MSBuild/Microsoft/VC/v160/Microsoft.Cpp.WindowsSDK.props`
            wine reg ADD 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0' \
              /v 'InstallationFolder' /t 'REG_SZ' /d "$WindowsSdkDir" /f

            # XXX: This path is taken from `${msvc-installed}/unpack/Common7/Tools/vsdevcmd/core/winsdk.bat`
            wine reg ADD 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Kits\Installed Roots' \
              /v 'KitsRoot10' /t 'REG_SZ' /d "$WindowsSdkDir" /f

            set +x

            ${mkSection "Preparing ‘Find-VisualStudio-cs-output.json’"}
            jq --null-input \
              --arg path "$VSINSTALLDIR" \
              --arg version "$(jq -r .info.productDisplayVersion <${msvc-cache}/*.manifest)" \
              --argjson packages "$( (
                echo "Microsoft.VisualStudio.VC.MSBuild.Base"
                echo "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
                echo "Microsoft.VisualStudio.Component.Windows10SDK.$(ls ${msvc-installed}/kits/10/Source | grep -oP '(?<=^10\.0\.)\d+(?=\.0$)')"
              ) | jq -Rn '[inputs]')" \
              '[{$path,$version,$packages}]' \
              > Find-VisualStudio-cs-output.json

            ${mkSection "Patching all **/node-gyp/lib/find-visualstudio.js"}
            find -path '*/node-gyp/lib/find-visualstudio.js' | while IFS= read -r toPatch ; do
              echo "Patching ‘$toPatch’…"
              sed -r 's/function findVisualStudio2017OrNewer.*/\0\n\nthis.parseData(undefined, '"JSON.stringify($(cat Find-VisualStudio-cs-output.json | tr -d '\n' | sed 's/[\/&]/\\&/g'))"', "", cb);\nreturn;\n/g' \
                -i "$toPatch"
            done

            ${mkSection "Patching ‘buildcheck/lib/findvs.js’"}
            sed -r 's/execFileSync\(ps, args, execOpts\)/'"JSON.stringify($(cat Find-VisualStudio-cs-output.json | tr -d '\n' | sed 's/[\/&]/\\&/g'))"'/g' \
              -i node_modules/buildcheck/lib/findvs.js

            ${mkSection "Setting WINEPATH"}
            export WINEPATH="$(winepath -w ${target.python})"

            ${mkSection "Removing all symlinks to /nix/store (mostly python3)"}
            find node_modules -type l >all-symlinks.lst
            paste all-symlinks.lst <(xargs <all-symlinks.lst readlink) | grep -F /nix/store | cut -f1 | xargs rm -v
            rm all-symlinks.lst

            ${mkSection "Finally, building native modules"}

            # We can’t add the whole ${target.nodejs} to WINEPATH, or it will use their npm.cmd, so:
            ln -s ${target.nodejs}/node.exe node_modules/.bin/

            # Simplify some BAT/.cmd wrappers, the upstream ones assume too much:
            ${let
              batWrappers = {
                "npm"            = "npm/bin/npm-cli.js";
                "node-gyp-build" = "node-gyp-build/bin.js";
                "node-gyp"       = "node-gyp/bin/node-gyp.js";
              };
            in lib.concatStringsSep "\n" (lib.mapAttrsToList (cmd: target: ''
              echo "node.exe \"$(winepath -w node_modules/${target})\" %*" >node_modules/.bin/${cmd}.cmd
            '') batWrappers)}

            # Make it use our node.exe and npm.cmd, etc.:
            export WINEPATH="$(winepath -w node_modules/.bin);$WINEPATH"

            # Tell node-gyp to use the provided Node.js headers for native code builds.
            export npm_config_nodedir="$(winepath -w ${nodejsHeaders})"
            export npm_config_build_from_source=true

            # Make it use our node_modules:
            export NODE_PATH="$(winepath -w ./node_modules)"

            export CHROMEDRIVER_FILEPATH="$(winepath -w ${lib.escapeShellArg (builtins.toFile "fake-chromedriver" "")})";

            find -type f -name package.json | { xargs grep -RF '"install":' || true ; } | cut -d: -f1 \
              | grep -vF 'node_modules/playwright/' \
              | while IFS= read -r package
            do
              if [ "$(jq .scripts.install "$package")" = "null" ] ; then
                continue
              fi

              ${mkSection "Running the install script of ‘$package’"}

              # XXX: we have to do that, so that Node.js sets environment properly:
              windowsScriptName="windows-$(sha256sum <<<"$package" | cut -d' ' -f1)"

              jq \
                --arg key "$windowsScriptName" \
                --arg val "cd \"$(winepath -w "$(dirname "$package")")\" && npm run install" \
                '.scripts[$key] = $val' package.json >package.json.new
              mv package.json.new package.json

              wine npm.cmd run "$windowsScriptName" </dev/null
            done

            # Packages that have a binding.gyp but don’t have an "install" script in their package.json
            # – a weird bunch, but we still have to build them…
            find -name 'binding.gyp' | xargs -n1 dirname | sort | grep -vE --file <(find -type f -name package.json | xargs grep -RF '"install":' | cut -d: -f1 | sort | xargs -n1 dirname | sed -r 's/[]\/$*.^|[]/\\&/g; s/^/^/g') | while IFS= read -r package
            do
              ${mkSection "Running the binding.gyp of ‘$package’"}
              (
                cd "$package"
                wine node-gyp.cmd rebuild
              )
            done
          ''}
      '';
      installPhase = ''
        find -type f -name '*.node' | xargs ${with pkgs; lib.getExe file}

        mkdir $out
        ${with pkgs; lib.getExe rsync} -Rah \
          $(find -type f -name '*.node') \
          $out/
      '';
    };

    target = rec {
      nodejs = pkgs.fetchzip {
        url = "https://nodejs.org/dist/v${theirPackage.nodejs.version}/node-v${theirPackage.nodejs.version}-win-x64.zip";
        hash = "sha256-TDSBxDq2VtUCzVQC7wfdKd9l4eAuK30/dNCMN/L6JIQ=";
      };

      python = pkgs.fetchzip {
        url = "https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip";
        hash = "sha256-p83yidrRg5Rz1vQpyRuZCb5F+s3ddgHt+JakPjgFgUc=";
        stripRoot = false;
      };
    };

    fresherPkgs = import (pkgs.fetchFromGitHub {
      owner = "NixOS"; repo = "nixpkgs";
      rev = "17a689596b72d1906883484838eb1aaf51ab8001"; # nixos-unstable on 2023-05-15T08:29:41Z
      hash = "sha256-YPLMeYE+UzxxP0qbkBzv3RBDvyGR5I4d7v2n8dI3+fY=";
    }) { inherit (pkgs) system; };

    msvc-wine = pkgs.stdenv.mkDerivation {
      name = "msvc-wine";
      src = pkgs.fetchFromGitHub {
        owner = "mstorsjo";
        repo = "msvc-wine";
        rev = "c4fd83d53689f30ae6cfd8e9ef1ea01712907b59";  # 2023-05-09T21:52:05Z
        hash = "sha256-hA11dIOIL9sta+rwGb2EwWrEkRm6nvczpGmLZtr3nHI=";
      };
      buildInputs = [
        (pkgs.python3.withPackages (ps: with ps; [ six ]))
      ];
      configurePhase = ":";
      buildPhase = ":";
      installPhase = ''
        sed -r 's,msiextract,${pkgs.msitools}/bin/\0,g' -i vsdownload.py
        mkdir -p $out/libexec
        cp -r . $out/libexec/.
      '';
    };

    msvc-cache = let
      version = "16";   # There doesn’t seem to be an easy way to specify a more stable full version, 16.11.26
    in pkgs.stdenv.mkDerivation {
      name = "msvc-cache-${version}";
      inherit version;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = "sha256-7+vNhYbrizqhoIDL6vN7vE+Gq2duoYW5adMgOpJgw2w=";
      buildInputs = [];
      dontUnpack = true;
      dontConfigure = true;
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      buildPhase = ''
        mkdir -p $out
        ${msvc-wine}/libexec/vsdownload.py --accept-license --major ${version} \
          --save-manifest \
          --only-download --cache $out --dest ./
        cp -v *.manifest $out/.
      '';
      dontInstall = true;
    };

    msvc-installed = pkgs.stdenv.mkDerivation {
      name = "msvc-installed-${msvc-cache.version}";
      inherit (msvc-cache) version;
      dontUnpack = true;
      dontConfigure = true;
      buildPhase = ''
        mkdir -p $out
        ${msvc-wine}/libexec/vsdownload.py --accept-license --major ${msvc-cache.version} \
          --manifest ${msvc-cache}/*.manifest \
          --keep-unpack --cache ${msvc-cache} --dest $out/
        mv $out/unpack/MSBuild $out/
      '';
      dontInstall = true;
    };
  };

  mithril-client = pkgs.runCommand "mithril-client-${common.mithril-bin.version}" {} ''
    mkdir -p $out
    if [[ ${common.mithril-bin} == *.tar.* ]]; then
      tar -xf ${common.mithril-bin}
    else
      ${lib.getExe pkgs.unzip} ${common.mithril-bin}
    fi
    cp mithril-client.exe $out/
    cp ${cardano-js-sdk.msvc-installed}/VC/Tools/MSVC/*/bin/Hostx64/x64/vcruntime140.dll $out/
  '';

  postgresUnpacked = pkgs.runCommand "postgres-unpacked" {
    buildInputs = with cardano-js-sdk.fresherPkgs; [
      wineWowPackages.stableFull
      winetricks samba /*samba for bin/ntlm_auth*/
    ];
  } ''
    export HOME=$(realpath $NIX_BUILD_TOP/home)
    mkdir -p $HOME
    ${pkgs.xvfb-run}/bin/xvfb-run \
      --server-args="-screen 0 1920x1080x24 +extension GLX +extension RENDER -ac -noreset" \
      ${pkgs.writeShellScript "wine-setup-inside-xvfb" ''
        set -euo pipefail
        #export WINEDEBUG=-all  # comment out to get normal output (err,fixme), or set to +all for a flood
        set +e
        wine ${common.postgresPackage} \
          --extract-only 1 \
          --unattendedmodeui minimal \
          --mode unattended \
          --enable-components server,commandlinetools \
          --disable-components pgAdmin,stackbuilder \
          --prefix 'C:\postgres' \
          --datadir 'C:\postgres-data'
      ''}
    mv $HOME/.wine/drive_c/postgres $out
    cp ${cardano-js-sdk.msvc-installed}/VC/Tools/MSVC/*/bin/Hostx64/x64/{vcruntime140,vcruntime140_1,msvcp140}.dll $out/bin/
  '';

  WebView2-cab = pkgs.fetchurl {
    url = "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/bbde725f-75ff-4201-ace5-f409a285fa16/Microsoft.WebView2.FixedVersionRuntime.128.0.2739.67.x64.cab";
    hash = "sha256-2zkZIF9rEF/6Ev2L+m5ZqNNjaxTlYisGyStGsUOHfGs=";
  };

  WebView2 = pkgs.runCommandNoCC "WebView2" {
    buildInputs = [ pkgs.cabextract ];
  } ''
    mkdir -p $out
    cabextract ${WebView2-cab} --directory $out/
    topdir=$(ls $out/)
    mv $out/"$topdir"/* $out/
    rmdir $out/"$topdir"
  '';

  ui = rec {
    # They’re initially the same as Linux when cross-compiling for Windows:
    node_modules = inputs.self.internal.x86_64-linux.ui.node_modules;

    # So far we don’t have anything special on Windows, let's just use the Linux build:
    dist = inputs.self.internal.x86_64-linux.ui.dist;
  };
}
