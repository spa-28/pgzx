{
  description = "Description for the project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    parts.url = "github:hercules-ci/flake-parts";

    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls = {
      url = "github:zigtools/zls/0.16.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks-nix = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }: let
    lib = nixpkgs.lib;
    zig-stable = "0.16.0";

    postgresVersions = ["15" "16" "17" "18"];
    defaultPostgresVersion = lib.last postgresVersions;
    mkPostgres = pkgs: version: let
      postgresql = builtins.getAttr "postgresql_${version}_jit" pkgs;
    in
      pkgs.symlinkJoin {
        name = "postgresql-${version}-with-pg-config";
        paths = [
          postgresql
          postgresql.pg_config
        ];
      };

    zig-overlay = _final: prev: let
      orig = inputs.zig-overlay.packages.${prev.system};
    in {
      zigpkgs =
        orig
        // {
          stable = orig.${zig-stable};
        };
    };

    zls-overlay = final: prev: {
      zls = inputs.zls.packages.${prev.system}.zls.overrideAttrs (_oldAttrs: {
        nativeBuildInputs = [final.zigpkgs.stable];
      });
    };
  in
    inputs.parts.lib.mkFlake {inherit inputs;} {
      debug = true;

      imports = [
        inputs.pre-commit-hooks-nix.flakeModule
        ./nix/modules/nixpkgs.nix
      ];

      flake.lib.postgres = {
        versions = postgresVersions;
        defaultVersion = defaultPostgresVersion;
      };

      flake.overlays = rec {
        default = lib.composeManyExtensions [
          zigpkgs
          zls
          pgzx_scripts
        ];
        zigpkgs = zig-overlay;
        zls = zls-overlay;
        pgzx_scripts = _final: prev: {
          pgzx_scripts = self.packages.${prev.system}.pgzx_scripts;
        };
      };

      flake.templates = rec {
        default = init;
        init = {
          path = ./nix/templates/init;
          description = "Initialize postgres extension projects";
        };
      };

      systems = ["x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin"];

      perSystem = {
        config,
        lib,
        pkgs,
        ...
      }: {
        nixpkgs = {
          config.allowBroken = true;
          overlays = [
            zig-overlay
            zls-overlay
          ];
        };

        pre-commit.pkgs = pkgs;
        pre-commit.settings = {
          default_stages = [];
          hooks = {
            # editorconfig-checker.enable = true;

            # check github actions files
            actionlint.enable = true;

            # check nix files
            alejandra.enable = true;
            deadnix.enable = true;

            # check shell scripts
            shellcheck.enable = true;
            shfmt_local = {
              enable = true;
              name = "shfmt";
              description = "Shell script formatter";
              types = ["shell"];
              entry = "${pkgs.shfmt}/bin/shfmt -d -i 0 -ci -s";
            };

            # zig linters
            zigfmt = {
              enable = true;
              name = "Zig fmt";
              entry = "${pkgs.zigpkgs.stable}/bin/zig fmt --check";
              files = "\\.zig$|\\.zon$";
            };
          };
        };

        packages.pgzx_scripts = pkgs.stdenvNoCC.mkDerivation {
          name = "pgzx_scripts";
          src = ./dev/bin;
          installPhase = ''
            mkdir -p $out/bin
            cp -r $src/* $out/bin
          '';
        };

        devShells = let
          mkShell = pkgs.mkShell;
          mkUserShell = postgresVersion: let
            postgresql = mkPostgres pkgs postgresVersion;
            devshell = (import ./devshell.nix) {
              inherit lib pkgs postgresql postgresVersion;
            };
          in
            devshell
            // {
              shellHook = ''
                ${devshell.shellHook or ""}
                ${config.pre-commit.devShell.shellHook or ""}
              '';
            };

          userShells = lib.genAttrs postgresVersions mkUserShell;
          postgresShells =
            lib.mapAttrs'
            (version: userShell: lib.nameValuePair "pg${version}" (mkShell userShell))
            userShells;
          defaultUserShell = userShells.${defaultPostgresVersion};

          # On darwin we expect command line tools to be installed.
          # It is possible to install clang/gcc as nix package, but linking
          # can be quite a pain.
          # On non-darwin systems we will use the nix toolchain for now.
          useSystemCC = pkgs.stdenv.isDarwin;
        in
          postgresShells
          // {
            default = postgresShells."pg${defaultPostgresVersion}";

            # Create development shell with C tools and dependencies to build Postgres locally.
            debug = mkShell (defaultUserShell
              // {
                hardeningDisable = ["all"];

                packages =
                  defaultUserShell.packages
                  ++ [
                    pkgs.flex
                    pkgs.bison
                    pkgs.meson
                    pkgs.ninja
                    pkgs.ccache
                    pkgs.pkg-config
                    pkgs.cmake

                    pkgs.icu
                    pkgs.zip
                    pkgs.readline
                    pkgs.openssl
                    pkgs.libxml2
                    pkgs.llvmPackages_17.llvm
                    pkgs.llvmPackages_17.lld
                    pkgs.llvmPackages_17.clang
                    pkgs.llvmPackages_17.clang-unwrapped
                    pkgs.lz4
                    pkgs.zstd
                    pkgs.libxslt
                    pkgs.python3
                  ]
                  ++ (lib.optionals (!useSystemCC) [
                    pkgs.clang
                  ]);
              });
          };
      };
    };
}
