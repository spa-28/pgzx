{
  pkgs,
  lib,
  project,
  postgresql,
  postgresVersion,
  ...
}: let
  menu = ''
    My Postgres Extension Development Environment
    =============================================

    Available commands:
      menu        - Show this menu
      pglocal     - Relocate the local Postgres installation to the project's out folder
      pginit      - Initialize the local Postgres installation
      pgstart     - Start the local Postgres installation
      pgstop      - Stop the local Postgres installation
      pgstatus    - Show the run status of the local Postgres installation
  '';

  makeScripts = scripts:
    lib.mapAttrsToList
    (name: script: pkgs.writeShellScriptBin name script)
    scripts;

  scripts = makeScripts {
    menu = ''
      cat <<EOF
      ${menu}
      EOF
    '';
  };
in {
  # Make project build dependencies available to the shell
  inputsFrom = [project];

  packages =
    scripts
    ++ [
      # Get pgzx development scripts like pglocal, pginit, pgstart...
      # We also need a local postgres for pglocal that we install in the devshell.
      pkgs.pgzx_scripts
      postgresql

      # Additional Zig tools.
      pkgs.zls # Zig Language Server
    ];

  # On shell startup we must set some environment variables for the pgzx scripts:
  shellHook = ''
    export PRJ_ROOT=$PWD
    export PG_HOME=$PRJ_ROOT/out/default
    export PGZX_POSTGRES_VERSION=${postgresVersion}
    export PGZX_SOURCE_PG_CONFIG=${postgresql}/bin/pg_config
    export PATH="$PG_HOME/lib/pgxs/src/test/regress:$PATH"
    export PATH="$PG_HOME/bin:$PATH"
    export NIX_PGLIBDIR=$PG_HOME/lib

    alias root='cd $PRJ_ROOT'

    menu
  '';
}
