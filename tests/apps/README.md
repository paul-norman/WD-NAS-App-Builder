# The shared package test (every app)

Every app's built package through its life as WD's installer runs it, each in a fresh stand-in for the NAS *(the PHP 7.4 test image from [`tests/images`](../images): the NAS's glibc, BusyBox's `sh`, `adduser` and `ip`, the `share` group, `/dev/urandom` readable by root only)*:

```bash
MODEL_OVERRIDE=MyCloudPR4100 ./build.sh ntfy    # first: the apps' packages
tests/apps/run_tests.sh                         # every app in apps.conf
tests/apps/run_tests.sh ntfy navidrome          # some of them
```

For each app:

1. **Install, initialise, start** - `install.sh`, `init.sh` and `start.sh` from the package, as WD's installer calls them.
2. **Its files** are root's and not writable by other users *(a build on a Windows drive once made them all `0777`)*.
3. **Its management page** *(if it has one)* is linked at `/apps/<app>/`, where nasAdmin requires a NAS login, and its PHP parses.
   **Its cron jobs** *(if it has any)* are in WD's own list too *(a stand-in [`xmldbc`](../common/xmldbc))*, so they're still there when the firmware rewrites root's crontab.
4. **It runs**, as `apps.conf` says: it answers on its port *(within 120 seconds)*, or a command works *(e.g. `go version`, through the links it makes)*. Apps whose program needs the NAS itself *(Docker's kernel modules, the PHP swap, WD's MySQL start-up, a login...)* are marked `lifecycle`, with the reason: everything else is still checked.
5. **Stop, clean, remove** - its port closed, its pages and cron jobs gone *(from WD's list too)*, its folder removed, and its data folder *(from `store/metadata.json`)* kept.

It's the first of the project's test tiers: every app gets it. Apps with logic of their own also have their own suites *(e.g. [`calibre-web`](../calibre-web/README.md), [`copyparty`](../copyparty/README.md), [`wireguard`](../wireguard/README.md))*, which test what they do.

**Adding an app**: a line in `apps.conf` - its port or a command, or `lifecycle` and why.

Needs Docker. Logs go in `$APPS_TEST_WORK`, by default `/tmp/apps-tests` *(one per app)*.
