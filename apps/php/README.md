# PHP App

Replaces the NAS's own PHP 7.4 *(end of life since 2022)* with PHP 8.5 - for WD's web interface, and for the PHP scripts the NAS runs itself. Intel models only.

- PHP 8.5's CLI and FPM are fully static binaries built by `static/php` *(with [static-php-cli](https://github.com/crazywhalecc/static-php-cli))*, so they don't depend on any of the NAS's own libraries. Every extension of WD's PHP 7.4 is built in, plus `opcache`, `intl`, `redis` *(with igbinary)*, `sodium`, `zip`, `sockets` and `pcntl`, and the others popular PHP apps *(WordPress, Nextcloud, Laravel, Drupal...)* ask for: `pgsql` and `pdo_pgsql` *(e.g. for the [PostgreSQL app](../postgresql/README.md))*, `gmp`, `ldap`, `igbinary`, `xsl`, `soap`, `calendar`, `ftp`, `shmop`, `sysvsem`, `sysvshm`, `sysvmsg`, `tidy` and `yaml` - and mbstring's regular expressions *(`mb_split()`, `mb_ereg()`... - Laravel needs them)*. *(Not `imagick`, which would roughly double PHP's size.)*
- **Enabling** the app switches the NAS to PHP 8.5, and **disabling** it switches back to WD's PHP 7.4. php-fpm switches over with a graceful reload, keeping its socket, so the NAS's web interface carries on *(a restart leaves seconds without a socket, which hangs the dashboard's "Updating..." window)*. The NAS's `/` and `/etc` are rebuilt on every boot, so the switch is made again on every boot.
- If PHP 8.5 isn't serving after the switch, the app switches back to PHP 7.4 by itself. Removing the app restores WD's PHP 7.4 completely.

## How it works

WD's web interface is served by `php-fpm`, through the socket Apache uses *(`/var/run/php-fpm.socket`)*. WD's own `/usr/sbin/php-fpm.sh` starts it by name from the `PATH` *(and `monit` uses that script to watch it)*, so `php_swap.sh`:

1. Patches three lines of WD's PHP 7.4 code that PHP 8 refuses to run *(see below)*, in copies placed over WD's own *(read-only)* files with bind mounts.
2. Adjusts `/etc/php/php.ini`: PHP 7.4's `apcu.so` isn't loaded *(apcu is built in)*, and the app's settings are added between marker lines *(WD may rewrite the file itself, e.g. for a new timezone, so the app takes its lines out again rather than restoring a copy)*.
3. Points `/usr/sbin/php-fpm` and `/usr/bin/php` at PHP 8.5, and has php-fpm reload gracefully *(WD's `php-fpm.sh reload`)*: it lets running requests finish, then starts its binary again by the name it was started with - now PHP 8.5 - keeping its PID and socket.

The patches only go ahead if WD's code is found exactly as expected *(otherwise PHP 7.4 carries on)*. The NAS is end of life, so WD's files won't change:

| File | WD's PHP 7.4 code | Why PHP 8 refuses it |
| ---- | ----------------- | -------------------- |
| `cgi_api.php` | `$_SERVER[QUERY_STRING]` | An undefined constant: PHP 7 used the string `'QUERY_STRING'` instead |
| `cgi_api.php` | `$r->ip_address = ...` with no `$r` | PHP 7 created an empty object |
| `restSDK/cloudAccess.php` | `array_key_exists('statusCode', $id_token)` on a string | PHP 7 only warned |

These were found by scanning all of WD's PHP files *(PHP 8.5's syntax check, PHPCompatibility, and a scan for undefined constants)* and by clicking through the whole web interface on a PR4100 with every error logged.

## Errors

Only real errors are logged *(not deprecations or notices, of which WD's PHP 7.4 code causes plenty)*, to `Nas_Prog/_php/php-errors.log`. It becomes `php-errors.log.1` once it's over 256KB *(checked daily)*. The app's page in the NAS dashboard *(Apps → PHP)* shows which PHP is in use, the patches, the built-in extensions and the most recent errors. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

`php_swap.sh status` shows the same over SSH.

## Building the PHP app

From the project root directory:

```bash
./build.sh php
```

The WD bin files will be created in `packages/php/`. The PHP version is set in `apkg.rc` and `static/php/build.sh` *(which must match)*. `static/php/php85-test.sh` is the manual test that the app is based on *(a temporary switch with every error logged)*.
