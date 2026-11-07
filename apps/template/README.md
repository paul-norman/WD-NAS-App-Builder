# Template App

The starting point for a new app: copy it and change it. It's a small, working app built the way the project's simpler apps are *(e.g. [pgweb](../pgweb/README.md), [ntfy](../ntfy/README.md))*: one official static program, run as its own user by a control script, with its own management page in the NAS dashboard, a site in the [Nginx app](../nginx/README.md) and a weekly check for new releases. Its example program is [miniserve](https://github.com/svenstaro/miniserve), which shares a folder *(`Nas_Prog/_template/www`)* in a web browser, so the template can be built, installed and tried as it is.

## What's in it

| File | What it does |
|------|--------------|
| `apkg.rc` | The package's name, version *(the program's, plus `-<n>` for a new package of the same one)* and settings - see the [guide](../../guides/README.md) |
| `build.sh` | Packages the app for each model, with the files `static/template` prepared *(run by the root `build.sh`)* |
| [`static/template`](../../static/template) | Downloads the program *(its official release, checked against the SHA256 pinned there)* and builds `template_runas`, which runs it as the app's own user *(the NAS has no `su`)* - for the Intel and ARM models |
| `template_ctl.sh` | Everything the app does on the NAS: its user, folders and settings *(`setup`)*, `start`, `stop`, `restart`, its Nginx site *(`nginx`)* and its daily jobs *(`daily`)* |
| `install.sh`, `init.sh`, `start.sh`, `stop.sh`, `clean.sh`, `preinst.sh`, `remove.sh` | What WD's installer runs *(the comment at the top of each says when)*: they hand over to `template_ctl.sh`. `init.sh` also runs at every boot, so it adds the app's cron lines again *(OS5 rewrites root's crontab at boot)* |
| `check_update.sh` | Weekly: a NAS alert when the program has a new release |
| `nginx.json` | Its site in the Nginx app: `https://template.<domain>` - see [how apps bring their own site](../nginx/README.md#how-apps-bring-their-own-site) |
| `manage/index.php`, `manage/api.php` | Its management page *(Apps → Template)*: status, version, addresses, restart, "Only through the Nginx app" and its latest log lines - see [Management pages](../README.md#management-pages) |
| `web/` | Its icon and its description in each language *(`desc.xml`: English, French, Spanish and German)* |
| [`tests/template`](../../tests/template) | Its test suite: `tests/common/run.sh template` |

How it behaves:

- With the Nginx app installed, it's only reachable through it by default *(it listens on `127.0.0.1:8090`)*. Without the Nginx app *(or with that setting off, on the page)* it's also at `http://<nas-ip>:8090` on the local network, over plain HTTP.
- It runs as its own user *(`template`, ID 62)*. Its data is kept in `Nas_Prog/_template`, across reinstalls and removal.

## Making a new app from it

1. Copy the app, its static build and its test suite, and rename them *(e.g. for an app called `myapp`)*:

   ```bash
   cp -R apps/template apps/myapp
   cp -R static/template static/myapp
   cp -R tests/template tests/myapp
   mv apps/myapp/template_ctl.sh apps/myapp/myapp_ctl.sh
   grep -rl template apps/myapp static/myapp tests/myapp | xargs sed -i 's/template/myapp/g; s/Template/My App/g'
   ```

   Then check what that changed: `Package` in `apkg.rc` must be exactly the folder's name.
2. Pick its port and its user's ID, unused by the other apps *(the IDs count down from 99: see the other apps' `*_ctl.sh`)*, and set them in `myapp_ctl.sh`, `nginx.json`, `manage/` and the test.
3. In `static/myapp/build.sh`, download the app's own program instead of miniserve *(its release's SHA256 pinned; or build it)*, and list its files in `apps/myapp/build.sh`. Drop the ARM models *(`armhf`)* from both if it's for the Intel models only.
4. In `myapp_ctl.sh`, change `start()` to run the program with its settings, and `wait_up()` to check that it's the program answering. Set `check_update.sh`'s releases address, and the version in `manage/api.php`.
5. Write `apkg.rc`'s `Description` and `web/desc.xml`, replace `web/logo.svg` with the app's icon, and rewrite this README for the app.
6. Register it:
   - [`store/metadata.json`](../../store/metadata.json): its categories, license, data folder and site *(see the other apps)*
   - [`tests/apps/apps.conf`](../../tests/apps/apps.conf): what the shared package test checks *(e.g. `port:8090`)*
   - [`ci/updates.conf`](../../ci/updates.conf): where its releases are, for the daily update check
   - `ci/sources/myapp.conf`: each file its build downloads, with its license *(CI's plan fails without it - `python3 ci/sources.py check`)*
   - [`phpstan.neon`](../../phpstan.neon): `apps/myapp/manage/api.php` *(and `apps/myapp/lib`, if it has one)*
   - [`tests/common/README.md`](../../tests/common/README.md): what its suite tests
7. Build it for one model and test it:

   ```bash
   MODEL_OVERRIDE=MyCloudPR4100 ./build.sh myapp
   tests/common/run.sh myapp --php both
   tests/apps/run_tests.sh myapp
   ```

The template itself isn't released *(CI leaves it out)*. If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
