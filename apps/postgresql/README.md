# PostgreSQL App

[PostgreSQL](https://www.postgresql.org/) 19 *(supported until November 2031)*, for apps on the NAS - or, if allowed, on the local network. For the Intel models and the ARM ones.

- On the Intel models, built on Debian Bullseye *(the NAS's own Debian version)* by `static/postgresql`, with OpenSSL 3.5 LTS and the libraries it uses *(ICU, LZ4, Zstandard, zlib, readline, libuuid)* bundled - the NAS's system is stripped down, so nothing beyond glibc and libstdc++ is relied on.
- On the ARM models, the same versions *(PostgreSQL and every extension)* are built by `static/postgresql` with clang, linked by LLD, which lays programs and libraries out for the ARM models' large memory pages *(32KB on the EX2 Ultra: those laid out for 4KB pages, as Debian's and Alpine's own are, crash there)*. PostgreSQL loads its extensions as libraries, so it comes with its own build of musl *(the C library)*, and every other library is built into the programs and extensions that use it *(Alpine's static ARM libraries, with libuuid, LZ4, protobuf-c, GMP, GEOS and PROJ built from source; ICU's data built in)*. psql's line editing is libedit's. Its programs use musl by its full path, so the app must be on the NAS's first volume *(`/mnt/HD/HD_a2/Nas_Prog/postgresql`, where the NAS installs apps)*. It's checked with QEMU's emulator: a new cluster, the server, PostGIS *(a coordinate transform)*, pgvector, pgcrypto and pg_trgm - and an upgrade from PostgreSQL 18's data *(see below)*.
- Extensions *(added to a database with `CREATE EXTENSION`)*:
  - **[PostGIS](https://postgis.net/) 3.7** - geometry and geography types, functions and indexes, topology, GeoJSON and vector tiles *(`ST_AsMVT`)*, with **GEOS 3.15** and **PROJ 9.9** *(and its database of coordinate systems)* built from source. No rasters *(they need GDAL, which is very large)*.
  - **[pgvector](https://github.com/pgvector/pgvector) 0.8** - vector similarity search *(e.g. AI embeddings)*, with HNSW and IVFFlat indexes. Built for plain x86-64 *(its default would target the build machine's CPU)*.
  - **[pg_cron](https://github.com/citusdata/pg_cron) 1.6** - scheduled jobs *(from the `postgres` database)*, **[pg_partman](https://github.com/pgpartman/pg_partman) 5.5** - table partitioning, **[pgaudit](https://www.pgaudit.org/) 19** - audit logging.
  - PostgreSQL's own *(`contrib`)*: `pgcrypto`, `uuid-ossp`, `pg_trgm`, `hstore`, `citext`, `postgres_fdw`, `pg_stat_statements` and the rest.
- pg_cron and pgaudit must be loaded at start-up before they can be added: switch them on on the app's page *(`shared_preload_libraries` - PostgreSQL restarts)*.
- Its data is in `Nas_Prog/_postgresql/data` *(kept across reinstalls)*, created with PostgreSQL's own `C.UTF-8` locale *(the NAS has no system locales; ICU collations such as `und-x-icu` sort by language)*.
- Every connection needs a password *(`scram-sha-256`)*. It listens on the NAS only *(port `5432`, and the socket in `/var/run/postgresql`)* until connections from the local network are switched on.
- `psql`, `pg_dump`, `pg_restore`, `createdb` and the other client tools are linked into `/usr/bin` for use over SSH.

## Upgrades to a new major version

A new major version of PostgreSQL can't use the previous one's data, and on an update the old app's programs are gone before the new one starts - so the app carries the previous major version's server *(PostgreSQL 18, with the same extensions, in `binaries/postgresql/previous` - only the programs `pg_upgrade` runs, and `initdb`)*. When it starts on data from that version, `pgsql_ctl.sh` upgrades it first:

- with `pg_upgrade`, **copying** the data into a new cluster made as the app makes one *(the same locale and password settings, data checksums as the data has them)*: the data itself is never changed. It needs as much free space as the data takes, plus 100 MB.
- the data's settings go with it *(`postgresql.conf`, `ALTER SYSTEM`'s, `pg_hba.conf`, `pg_ident.conf` - or, if the new version refuses one of them, its own `postgresql.conf` with the app's settings)*. `pg_upgrade` connects to both servers through its own socket, in a folder only the postgres user can open, with a settings file allowing that without a password.
- only once it has worked does the new cluster become `data`: the old one stays, as it was, as `data-18` - the page lists it, with its size, and removes it. To go back, reinstall the previous app version and rename `data-18` to `data`.
- then the extensions' updates `pg_upgrade` lists *(`update_extensions.sql` - e.g. pgaudit, whose versions follow PostgreSQL's: the build adds the empty step between its two releases, whose SQL is the same)*, and, in the background, the planner's statistics it couldn't carry over *(`vacuumdb --analyze-in-stages --missing-stats-only`)*.
- if it can't be done *(not enough space, data from an older version, `pg_upgrade` failing - its logs kept in `_postgresql/upgrade-logs`)*, nothing changes and PostgreSQL doesn't start: the reason is on the app's page.

## The postgres user

PostgreSQL refuses to run as root, and the NAS has no `su`, so it runs as a `postgres` user with a **fixed ID (70)**, through a small static helper *(`pg_runas`)* that switches to it. The NAS's `/etc` is rebuilt on every boot, so the user is added again each time - its data belongs to that ID whatever happens to the user's entry *(e.g. when WD rewrites `/etc/passwd` after users are added in the dashboard)*. If another user already has ID 70, PostgreSQL doesn't start *(the log says so)*.

## Management page

PostgreSQL's page in the NAS dashboard *(Apps → PostgreSQL)* shows whether it's running and its databases *(with their owners and sizes)*, and can:

- create a database with a user of its own *(and a generated password, shown once)*
- show the data kept from before an upgrade, and remove it
- show and change the `postgres` superuser's password *(generated on install, saved root-only in `Nas_Prog/_postgresql/postgres_password`)*
- choose the extensions loaded at start-up *(pg_cron, pgaudit)*
- switch connections from the local network on or off *(`listen_addresses` plus a `samenet` line in `pg_hba.conf`, between the app's markers - PostgreSQL restarts)*

Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*. Over SSH, `pgsql_ctl.sh` in the app's install directory does `start`, `stop` and `network on` / `off`.

## Building the PostgreSQL app

From the project root directory:

```bash
./build.sh postgresql
```

The WD bin files will be created in `packages/postgresql/`. The PostgreSQL version is set in `apkg.rc` and `static/postgresql/build.sh` *(which must match, with the source's checksum)*.
