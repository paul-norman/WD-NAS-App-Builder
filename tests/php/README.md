# PHP tests

Tests for the [PHP app](../../apps/php/README.md), which makes PHP 8.5 the NAS's own PHP in place of WD's 7.4 - on a stand-in for the NAS's PHP *(`bin/wd.sh`, from the official PHP 7.4 image on Debian 11 - the NAS's glibc)*: WD's binaries where the NAS has them and the links to them, `/etc/php/php.ini` and `php-fpm.conf`, WD's start script *(`php-fpm.sh`: php-fpm started by its name from the PATH, stop, restart, graceful reload)*, and WD's web pages reduced to the three lines the app patches *(which PHP 8 refuses to run)*. WD's own files aren't part of the project: these stand-ins hold only what the app relies on.

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh php    # first: its package
tests/php/run_tests.sh
```

What it checks:

- **The switch to PHP 8.5** *(installed and started)*: php-fpm becomes the app's, with **no failed request** while it happens *(a request every 0.1 seconds, as the dashboard polls while it installs: a graceful reload, not a restart)*; the NAS's `/usr/bin/php` too.
- **WD's pages**: run on PHP 8.5 once patched - and stop with an error without the patches, which is why they're there.
- **php.ini**: the app's settings between its markers, WD's `apcu` line set aside *(built into 8.5)*; real errors logged to `_php/php-errors.log`, deprecations left out.
- **Its page's status**: PHP 8.5 serving, the patched files.
- **Switching back** *(stopped)*: WD's PHP 7.4 serving, **php.ini byte for byte as before**, WD's pages unpatched, `/usr/bin/php` WD's; switching to 8.5 again *(its settings in php.ini once)*.
- **Falling back**: when PHP 8.5 can't start, the NAS is back on 7.4 by itself, php.ini as before - its pages keep working.
- **Removal**: WD's PHP 7.4 serving, php.ini as before, its cron job gone.

Not covered here *(tested on the NAS)*: WD's real pages *(the whole dashboard on PHP 8.5)*, WD's monit and Apache in front of php-fpm.

Needs Docker *(a privileged container: the app bind-mounts its patched copies over WD's pages)*. The log goes in `$PHP_TEST_WORK`, by default `/tmp/php-tests`.
