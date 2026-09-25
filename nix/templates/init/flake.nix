{
  description = "Description for the project";

  # Inputs are the flake references that are used in the flake.
  # Nix will fetch the flake and stores the hash in the flake.lock file.
  inputs = {
    # Keep nixpkgs aligned with the version used and tested by pgzx.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Flake parts is a library to write flakes in a more modular way similar to
    # NixOS modules.
    parts.url = "github:hercules-ci/flake-parts";

    # pgzx flake provides us with extra tools and a supported version of the Zig compiler.
    # The flake re-exports the zig-overlay and zls flakes.
    pgzx = {
      url = "github:xataio/pgzx";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let
    name = "example";
    version = "0.1";
  in
    inputs.parts.lib.mkFlake {inherit inputs;} {
      # Supported system for which we want to be able to build the project on.
      systems = ["x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin"];

      perSystem = {
        config,
        lib,
        pkgs,
        system,
        ...
      }: {
        # Ensure that 'pkgs' has the dependencies from the pgzx flake available.
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            inputs.pgzx.overlays.default
          ];
          config = {
            # extra configurations
            #allowBroken = true;
            #allowUnfree = true;
          };
        };

        # The projects default package is the package that is built when we run `nix build`
        #
        # The devshell will import the projects build dependencies.
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          pname = name;
          version = version;

          src = ./.;
          nativeBuildInputs = [
            pkgs.zigpkgs.stable
            pkgs.pkg-config
          ];

          buildInputs = [
            pkgs.openssl
            pkgs.gss
            pkgs.krb5
          ];
        };

        devShells.default = let
          postgresVersion = inputs.pgzx.lib.postgres.defaultVersion;
          postgresPackage = builtins.getAttr "postgresql_${postgresVersion}_jit" pkgs;
          postgresql = pkgs.symlinkJoin {
            name = "postgresql-${postgresVersion}-with-pg-config";
            paths = [
              postgresPackage
              postgresPackage.pg_config
            ];
          };

          # Load the shell configuration from devshell.nix.
          userShell = (import ./devshell.nix) {
            inherit lib pkgs postgresql postgresVersion;

            # Pass the default package as project to the devshell. This
            # allows the devshell to import the project and its dependencies.
            project = config.packages.default;
          };

          mkShell = pkgs.mkShell.override {
            # optionally override the default configuration of the mkShell derivation.
          };
        in
          mkShell (userShell
            // {
              # Optionally override or extend the shell configuration.
              # For example when using the pre-commit-hook module we want to
              # merge the merge the shell hooks of our flake with the
              # pre-commit-hook shellHook to ensure the all dependencies are
              # properly configured when entering the shell.
              shellHook = ''
                ${userShell.shellHook or ""}
              '';
            });
      };
    };
}
