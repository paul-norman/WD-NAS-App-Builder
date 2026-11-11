# Store tests

Tests for the [Store app](../../apps/store/README.md), run in a container standing in for the NAS - so they need no NAS and no published repository:

```bash
tests/store/run_tests.sh                       # everything (except ui), on PHP 7.4 - WD's version
tests/store/run_tests.sh recipes --php both    # one group, on PHP 7.4 and 8.5 (the PHP app's)
```

| Group | What it checks |
|---|---|
| `repos_apps` | Adding repositories (HTTPS only, confirming third-party ones, a catalogue escaping its recipe folder refused); signed catalogues (a changed `store.json` refused while the previous catalogue stays, a new key refused until its fingerprint is accepted); native apps installed, updated and removed through the stand-ins for WD's installer (release redirects followed, checksums checked, plain-HTTP downgrades and other models refused, nothing left behind) |
| `recipes` | The small test recipe (`fixtures/hello-1`, `hello-2`): requirements, the wizard's checks, `.env` values with `$`, quotes and `#` reaching the container exactly, secrets kept out of the install record, hooks, read-only mounts, the Nginx site, changing settings, updating, removing, reinstalling with the same secrets, a failed install undone, a tampered recipe refused |
| `auto` | Automatic updates: the cron lines (added once, removed by `clean.sh`), ticking apps and recipes, nothing started when nothing is newer, an app updated from its repository, updates left for the user and said why (no `keeps_data`, `manual_update`, a recipe's new password), new recipe options at their defaults, ntfy told (a stand-in on port 2586) once per version, and the Store updating itself last |
| `immich` | The real Immich recipe *(downloads Immich's images, about 4.5GB)*: containers healthy, face recognition off, existing photos mounted read only, its Nginx site, removal keeping the photos |
| `pihole` | The real Pi-hole recipe: refused by its port check while this machine has port 53 in use *(as a NAS might)*, then a copy on ports 1053 and 18053 - DNS answered, a name on its deny list blocked, its web interface and password, its Nginx site, removal |
| `arr` | The real Arr stack recipe *(downloads about 5GB of images)*, every optional app on: its hook connects everything - checked with the apps' own connection tests *(download clients, Prowlarr's applications and FlareSolverr)*, Bazarr and Seerr's settings, the folders and hard links, the password in every app; a change of settings *(two apps off, a new password)*; removal keeping the library |
| `frigate` | The real Frigate recipe *(downloads its 9GB image)*: its first settings *(TLS off, the CPU detector)*, the admin password from the wizard *(and not another)*, its Nginx site, a test camera *(a looping video)* detected on the CPU; a change to a remote detector that doesn't answer *(said so, settings kept)*, then to the recipe's remote detector server *(run here on the CPU)* - asked for its model and used over the network; removal keeping the recordings |
| `signatures` | Checking signatures without sodium in PHP *(as WD's own PHP may lack it)*: refused when nothing can check them, and checked with the PHP app's PHP |
| `ui` | Not a test: a Store with a few things installed, kept running for 10 minutes at `http://127.0.0.1:8080/wrap.html` *(standing in for the NAS dashboard; `?view=app`, `wizard`, `installed` or `repos` opens a view)* |

## How it works

- **The NAS**: a PHP 7.4 or 8.5 container *(`tests/images/`, shared with the other test suites, built once)* with BusyBox's `sh` *(as the NAS has)*. The Store is installed from its built package as the NAS does it *(`install.sh`, `init.sh`)*, and its page's API is called as the dashboard calls it, with an admin's WD session. `upload_apkg` and `del_apkg` are stand-ins for WD's *(they don't unpack packages - real installs are tested on the NAS)*, keeping a stand-in for WD's list of apps up to date. The Nginx app's files are installed too *(not started)*, for recipes' sites.
- **The repositories**: `store/tools/make_test_repo.sh` builds one from the built packages and the recipes; `bin/repotool.py` signs it, adds the test recipe and changes it during the tests; `bin/server.py` serves it over HTTPS as `repo.test`, plus two hostile repositories as `evil.test`, with a test certificate authority trusted only inside the container. Package downloads go through a redirect, as GitHub's release downloads do.
- **Docker**: recipes run on this machine's Docker *(its socket is passed to the container)*. Folders are given to containers by their path, so the stand-in NAS volume is at the same path inside the container as outside *(`STORE_TEST_VOLUME` replaces `/mnt/HD/HD_a2` in the Store for this)*.

Needs Docker on Linux *(host networking; ports 8080, 8443, 18081 and 2283 free)*, Python 3, OpenSSL and the apps' packages built for the PR4100 *(Docker's and Nginx's; the Store's is built by the script, and the apps it installs are test apps of its own)*. Work files *(certificates, keys, the repositories, logs)* go in `$STORE_TEST_WORK`, by default `/tmp/store-tests`.
