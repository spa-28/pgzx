My Extension
============

## Development

1. Start development shell

```
$ nix develop
```

The template follows pgzx's default supported Postgres version (currently Postgres 18).

2. Relocate the postgres installation into our development environment and create a database.

```
$ pglocal && pginit
```

3. Start the local postgres development server

```
$ pgstart
```

4. The pgzx dependency follows `main`, so Zig must record the hash of its current contents. Run `zig build`, then copy the complete hash suggested by Zig into the commented `.hash` field in `build.zig.zon`:

```
$ zig build

build.zig.zon:12:20: error: dependency is missing hash field
            .url = "https://github.com/xataio/pgzx/archive/main.tar.gz",
                   ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
note: expected .hash = "pgzx-0.1.0-...",
```

5. Compile and install the extension into the development server

```
$ zig build -freference-trace -p $PG_HOME
...

$ psql -U postgres -c 'CREATE EXTENSION my_extension'
```

6. Verify extension is working

```
$ psql -U postgres -c 'SELECT hello()'
```

7. Stop development server

```
$ pgstop
```
