{
  inputs,
  targetSystem,
}: let
  buildSystem =
    if targetSystem == "x86_64-windows"
    then "x86_64-linux"
    else targetSystem;
  pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
  inherit (pkgs) lib;
in rec {
  flake-compat = import inputs.flake-compat;

  prettyName = "Blockfrost Platform Desktop";
  codeName = "blockfrost-platform-desktop";

  ourVersion = "0.0.3-rc.1";

  blockfrostPlatformOnly = true;

  cardano-node-configs-verbose = builtins.path {
    name = "cardano-playground-configs";
    path = inputs.cardano-playground + "/static/book.play.dev.cardano.org/environments";
  };

  cardano-node-configs =
    pkgs.runCommandNoCC "cardano-node-configs" {
      buildInputs = with pkgs; [jq];
    } ''
      mkdir -p $out
      cp -r ${cardano-node-configs-verbose}/{mainnet,preview,preprod} $out/
      chmod -R +w $out
      find $out -name 'config.json' | while IFS= read -r configFile ; do
        jq '.
          | .TraceConnectionManager = false
          | .TracePeerSelection = false
          | .TracePeerSelectionActions = false
          | .TracePeerSelectionCounters = false
          | .TraceInboundGovernor = false
        ' "$configFile" >tmp.json
        mv tmp.json "$configFile"
      done
    '';

  cardanoNodeFlake = (flake-compat {src = inputs.cardano-node;}).defaultNix;

  blockfrostPlatformFlake = (flake-compat {src = inputs.blockfrost-platform;}).defaultNix;

  ogmiosPatched = {
    outPath = toString (pkgs.runCommand "ogmios-patched" {} ''
      cp -r ${inputs.ogmios} $out
      chmod -R +w $out
      find $out -name cabal.project.freeze -delete -o -name package.yaml -delete
      grep -RF -- -external-libsodium-vrf $out | cut -d: -f1 | sort --uniq | xargs -n1 -- sed -r s/-external-libsodium-vrf//g -i
      cd $out
      patch -p1 -i ${./ogmios-6-5-0--missing-srp-hash.patch}
      patch -p1 -i ${./ogmios--on-windows.patch}
      patch -p1 -i ${./ogmios-6-9-0--fix-cabal-doctest.patch}
    '');
    inherit (inputs.ogmios.sourceInfo) rev shortRev lastModified lastModifiedDate;
  };

  inherit (cardanoNodeFlake.project.${buildSystem}.pkgs) haskell-nix;

  ogmiosProject = haskell-nix.project {
    compiler-nix-name = "ghc96";
    projectFileName = "cabal.project";
    inputMap = {"https://input-output-hk.github.io/cardano-haskell-packages" = cardanoNodeFlake.inputs.CHaP;};
    src = ogmiosPatched + "/server";
    modules = [
      ({
        lib,
        pkgs,
        ...
      }: {
        packages = {
          cardano-crypto-praos.components.library.pkgconfig = lib.mkForce [[pkgs.libsodium-vrf]];
          cardano-crypto-class.components.library.pkgconfig = lib.mkForce [
            ([pkgs.libsodium-vrf pkgs.secp256k1]
              ++ (
                if pkgs ? libblst
                then [pkgs.libblst]
                else []
              ))
          ];
          ogmios.components.library.preConfigure = "export GIT_SHA=${inputs.ogmios.rev}";
        };
      })
      ({lib, ...}: {
        packages = {
          entropy.package.buildType = lib.mkForce "Simple";
          ouroboros-network-framework.doHaddock = false;
        };
      })
    ];
  };

  ogmios =
    {
      x86_64-linux = ogmiosProject.projectCross.musl64.hsPkgs.ogmios.components.exes.ogmios;
      x86_64-windows = ogmiosProject.projectCross.mingwW64.hsPkgs.ogmios.components.exes.ogmios;
      x86_64-darwin = ogmiosProject.hsPkgs.ogmios.components.exes.ogmios;
      aarch64-darwin = ogmiosProject.hsPkgs.ogmios.components.exes.ogmios;
    }.${
      targetSystem
    };

  blockfrost-platform =
    blockfrostPlatformFlake.internal.${targetSystem}.bundle
    // {
      inherit (blockfrostPlatformFlake.internal.${targetSystem}.blockfrost-platform) version;
    };

  cardano-node =
    {
      x86_64-linux = cardanoNodeFlake.hydraJobs.x86_64-linux.musl.cardano-node;
      x86_64-windows = cardanoNodeFlake.hydraJobs.x86_64-linux.windows.cardano-node;
      x86_64-darwin = cardanoNodeFlake.packages.x86_64-darwin.cardano-node;
      aarch64-darwin = cardanoNodeFlake.packages.aarch64-darwin.cardano-node;
    }.${
      targetSystem
    };

  cardano-submit-api =
    {
      x86_64-linux = cardanoNodeFlake.hydraJobs.x86_64-linux.musl.cardano-submit-api;
      x86_64-windows = cardanoNodeFlake.hydraJobs.x86_64-linux.windows.cardano-submit-api;
      x86_64-darwin = cardanoNodeFlake.packages.x86_64-darwin.cardano-submit-api;
      aarch64-darwin = cardanoNodeFlake.packages.aarch64-darwin.cardano-submit-api;
    }.${
      targetSystem
    };

  postgresPackage =
    {
      x86_64-linux = pkgs.postgresql_15_jit;
      x86_64-darwin = pkgs.postgresql_15_jit;
      aarch64-darwin = pkgs.postgresql_15_jit;
      x86_64-windows = let
        version = "15.4-1";
      in
        (pkgs.fetchurl {
          url = "https://get.enterprisedb.com/postgresql/postgresql-${version}-windows-x64.exe";
          hash = "sha256-Su4VKwJkeQ6HqCXTIZIK2c4AJHloqm72BZLs2JCnmN8=";
        })
        // {inherit version;};
    }.${
      targetSystem
    };

  blockfrost-platform-desktop-exe-vendorHash = "sha256-3mz58RaOQvbZbTMCDwXTmIWUqMqpPlzy8222kvm9SOU=";

  go-constants = pkgs.writeTextDir "constants/constants.go" ''
    package constants

    const (
      BlockfrostPlatformDesktopVersion = ${builtins.toJSON ourVersion}
      BlockfrostPlatformDesktopRevision = ${builtins.toJSON (inputs.self.rev or "dirty")}
      CardanoNodeVersion = ${builtins.toJSON cardanoNodeFlake.project.${buildSystem}.hsPkgs.cardano-node.identifier.version}
      CardanoNodeRevision = ${builtins.toJSON inputs.cardano-node.rev}
      BlockfrostPlatformOnly = ${builtins.toJSON blockfrostPlatformOnly}
      BlockfrostPlatformVersion = ${builtins.toJSON blockfrost-platform.version}
      BlockfrostPlatformRevision = ${builtins.toJSON inputs.blockfrost-platform.rev}
      OgmiosVersion = ${builtins.toJSON ogmios.version}
      OgmiosRevision = ${builtins.toJSON inputs.ogmios.rev}
      DolosVersion = ${builtins.toJSON dolos.version}
      DolosRevision = ${builtins.toJSON blockfrostPlatformFlake.inputs.dolos.rev}
      PostgresVersion = ${builtins.toJSON postgresPackage.version}
      PostgresRevision = ${builtins.toJSON postgresPackage.version}
      CardanoJsSdkVersion = ${builtins.toJSON (builtins.fromJSON (builtins.readFile (inputs.cardano-js-sdk + "/packages/cardano-services/package.json"))).version}
      CardanoJsSdkRevision = ${builtins.toJSON inputs.cardano-js-sdk.rev}
      CardanoJsSdkBuildInfo = ${builtins.toJSON (let
      self = inputs.cardano-js-sdk;
    in
      builtins.toJSON {
        inherit (self) lastModified lastModifiedDate rev;
        shortRev = self.shortRev or "no rev";
        extra = {
          inherit (self) narHash;
          sourceInfo = self;
          path = self.outPath;
        };
      })}
      MithrilClientRevision = ${builtins.toJSON inputs.mithril.sourceInfo.rev or "dirty"}
      MithrilClientVersion = ${builtins.toJSON mithril-bin.version}
      MithrilGVKPreview = ${builtins.toJSON mithrilGenesisVerificationKeys.preview}
      MithrilGVKPreprod = ${builtins.toJSON mithrilGenesisVerificationKeys.preprod}
      MithrilGVKMainnet = ${builtins.toJSON mithrilGenesisVerificationKeys.mainnet}
      MithrilAVKPreview = ${builtins.toJSON mithrilAncillaryVerificationKeys.preview}
      MithrilAVKPreprod = ${builtins.toJSON mithrilAncillaryVerificationKeys.preprod}
      MithrilAVKMainnet = ${builtins.toJSON mithrilAncillaryVerificationKeys.mainnet}
      MithrilAggregatorPreview = ${builtins.toJSON mithrilAggregator.preview}
      MithrilAggregatorPreprod = ${builtins.toJSON mithrilAggregator.preprod}
      MithrilAggregatorMainnet = ${builtins.toJSON mithrilAggregator.mainnet}
      NetworkStartPreview uint64 = ${builtins.toJSON (builtins.fromJSON (builtins.readFile "${cardano-node-configs}/preview/byron-genesis.json")).startTime}
      NetworkStartPreprod uint64 = ${builtins.toJSON (builtins.fromJSON (builtins.readFile "${cardano-node-configs}/preprod/byron-genesis.json")).startTime}
      NetworkStartMainnet uint64 = ${builtins.toJSON (builtins.fromJSON (builtins.readFile "${cardano-node-configs}/mainnet/byron-genesis.json")).startTime}
    )
  '';

  # Minimize rebuilds:
  coreSrc = builtins.path {
    path = inputs.self + "/core";
  };

  uiSrc = builtins.path {
    path = inputs.self + "/ui";
  };

  swagger-ui = let
    name = "swagger-ui";
    version = "5.2.0";
    src = pkgs.fetchFromGitHub {
      owner = "swagger-api";
      repo = name;
      rev = "v${version}";
      hash = "sha256-gF2bUTr181MePC+FJN+BV2KQ7ZEW7sa4Mib7K0sgi4s=";
    };
  in
    pkgs.runCommand "${name}-${version}" {} ''
      cp -r ${src}/dist $out
      chmod -R +w $out
      sed -r 's|url:.*,|url: window.location.origin + "/openapi.json",|' -i $out/swagger-initializer.js
    '';

  # OpenAPI linter
  vacuum = pkgs.buildGoModule rec {
    pname = "vacuum";
    version = "0.2.6";
    src = pkgs.fetchFromGitHub {
      owner = "daveshanley";
      repo = pname;
      rev = "v${version}";
      hash = "sha256-G0NzCqxu1rDrgnOrbDGuOv4Vq9lZJGeNyXzKRBvtf4o=";
    };
    vendorHash = "sha256-5aAnKf/pErRlugyk1/iJMaI4YtY/2Vs8GpB3y8tsjh4=";
    doCheck = false; # some segfault in OAS 2.0 tests…
  };

  openApiJson = let
    src = builtins.path {path = coreSrc + "/openapi.json";};
  in
    pkgs.runCommand "openapi.json" {
      buildInputs = [pkgs.jq vacuum];
    } ''
      vacuum lint --details ${src}

      jq --sort-keys\
        --arg title ${lib.escapeShellArg "${prettyName} API"} \
        '.info.title = $title' \
        ${src} >$out
    '';

  mithrilGenesisVerificationKeys = {
    preview = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/pre-release-preview/genesis.vkey");
    preprod = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/release-preprod/genesis.vkey");
    mainnet = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/release-mainnet/genesis.vkey");
  };

  mithrilAncillaryVerificationKeys = {
    preview = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/pre-release-preview/ancillary.vkey");
    preprod = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/release-preprod/ancillary.vkey");
    mainnet = builtins.readFile (inputs.mithril + "/mithril-infra/configuration/release-mainnet/ancillary.vkey");
  };

  mithrilAggregator = {
    preview = "https://aggregator.pre-release-preview.api.mithril.network/aggregator";
    preprod = "https://aggregator.release-preprod.api.mithril.network/aggregator";
    mainnet = "https://aggregator.release-mainnet.api.mithril.network/aggregator";
  };

  # FIXME: build from source (Linux, and Darwins are available in their flake.nix, but Windows not)
  mithril-bin = let
    ver = (builtins.fromJSON (builtins.readFile (inputs.self + "/flake.lock"))).nodes.mithril.original.ref or "unknown-ref";
  in
    {
      x86_64-linux = inputs.mithril.packages.${targetSystem}.mithril-client-cli;
      x86_64-windows = pkgs.fetchurl {
        name = "mithril-${ver}-windows-x64.tar.gz";
        url = "https://github.com/input-output-hk/mithril/releases/download/${ver}/mithril-${ver}-windows-x64.tar.gz";
        hash = "sha256-OEKxmcfN9hDfVtasI1tZAYKj5F8vWNpQiO4KKiLgYWk=";
      };
      x86_64-darwin = inputs.mithril.packages.${targetSystem}.mithril-client-cli;
      aarch64-darwin = inputs.mithril.packages.${targetSystem}.mithril-client-cli;
    }.${
      targetSystem
    }
    // {version = ver;};

  inherit (blockfrostPlatformFlake.internal.${targetSystem}) dolos;

  # Aligned with blockfrost-platform's nix/internal/unix.nix `dolos-configs`:
  dolos-configs = let
    networks = ["mainnet" "preprod" "preview"];

    tokenRegistryUrl = {
      mainnet = "https://tokens.cardano.org";
      preprod = "https://metadata.world.dev.cardano.org";
      preview = "https://metadata.world.dev.cardano.org";
    };

    mkConfig = network: let
      byronGenesis = builtins.fromJSON (builtins.readFile "${cardano-node-configs}/${network}/byron-genesis.json");
      magic = toString byronGenesis.protocolConsts.protocolMagic;
    in
      pkgs.writeText "dolos.toml" (''
          [genesis]
          alonzo_path = "''${GENESIS_PATH_ALONZO}"
          byron_path = "''${GENESIS_PATH_BYRON}"
          conway_path = "''${GENESIS_PATH_CONWAY}"
        ''
        + lib.optionalString (network == "preview") ''
          force_protocol = 6
        ''
        + ''
          shelley_path = "''${GENESIS_PATH_SHELLEY}"

          [logging]
          include_grpc = false
          include_pallas = false
          include_tokio = false
          include_trp = false
          max_level = "INFO"

          [mithril]
          aggregator = "${mithrilAggregator.${network}}"
          ancillary_key = "${mithrilAncillaryVerificationKeys.${network}}"
          genesis_key = "${mithrilGenesisVerificationKeys.${network}}"

          [serve.minibf]
          listen_address = "[::]:''${DOLOS_MINIBF_PORT}"
          token_registry_url = "${tokenRegistryUrl.${network}}"

          [storage]
          max_wal_history = 25920
          path = "''${DOLOS_STORAGE_PATH}"
          version = "v3"

          [submit]

          [sync]
          pull_batch_size = 100

          [upstream]
        ''
        + lib.optionalString (network != "mainnet") ''
          is_testnet = true
        ''
        + ''
          network_magic = ${magic}
          peer_address = "''${PEER_ADDRESS}"
        '');
  in
    pkgs.runCommandNoCC "dolos-configs" {} ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n" (network: ''
          mkdir -p $out/${network}
          cp ${mkConfig network} $out/${network}/dolos.toml
        '')
        networks}
    '';

  ui = rec {
    inherit (pkgs) nodejs;

    yarn = pkgs.yarn.override {inherit nodejs;};

    yarn2nix = let
      src = builtins.path {path = pkgs.path + "/pkgs/development/tools/yarn2nix-moretea";};
    in
      import src {
        inherit pkgs nodejs yarn;
        allowAliases = true;
      };

    lockfiles = pkgs.lib.cleanSourceWith {
      src = uiSrc;
      name = "ui-lockfiles";
      filter = name: _type: let b = baseNameOf (toString name); in b == "package.json" || b == "yarn.lock";
    };

    favicons =
      pkgs.runCommand "favicons" {
        buildInputs = with pkgs; [imagemagick];
        original = builtins.path {path = uiSrc + "/favicon.svg";};
      } ''
        mkdir -p $out
        convert -background none -size 32x32 $original $out/favicon-32x32.png
        convert -background none -size 16x16 $original $out/favicon-16x16.png
        convert $out/favicon-*.png $out/favicon.ico
      '';

    offlineCache = yarn2nix.importOfflineCache (yarn2nix.mkYarnNix {
      yarnLock = lockfiles + "/yarn.lock";
    });

    setupCacheAndGypDirs = ''
      # XXX: `HOME` (for various caches) cannot be under our source root:
      export HOME=$(realpath $NIX_BUILD_TOP/home)
      mkdir -p $HOME

      # Do not look up in the registry, but in the offline cache, cf. <https://classic.yarnpkg.com/en/docs/yarnrc>:
      echo '"--offline" true' >>$HOME/.yarnrc
      echo '"--frozen-lockfile" true' >>$HOME/.yarnrc
      yarn config set yarn-offline-mirror ${offlineCache}

      # Don’t try to download prebuilded packages (with prebuild-install):
      export npm_config_build_from_source=true
      ( echo 'buildFromSource=true' ; echo 'compile=true' ; ) >$HOME/.prebuild-installrc

      ${pkgs.lib.concatMapStringsSep "\n" (cacheDir: ''

          # Node.js headers for building native `*.node` extensions with node-gyp:
          # TODO: learn why installVersion=9 – where does it come from? see node-gyp
          mkdir -p ${cacheDir}/node-gyp/${nodejs.version}
          echo 9 > ${cacheDir}/node-gyp/${nodejs.version}/installVersion
          ln -sfn ${nodejs}/include ${cacheDir}/node-gyp/${nodejs.version}

        '') [
          "$HOME/.cache" # Linux, Windows (cross-compiled)
          "$HOME/Library/Caches" # Darwin
        ]}

      # These are sometimes useful:
      #
      # npm config set loglevel verbose
      # echo '"--verbose" true' >>$HOME/.yarnrc
      # export NODE_OPTIONS='--trace-warnings'
      # export DEBUG='*'
      # export DEBUG='node-gyp'
    '';
  };
}
