# Tasks App

Runs your own scripts on the NAS - at boot, on a schedule, when the NAS shuts down or restarts, or only when you click Run now - set up on its page in the NAS dashboard, with each task's last run, its output and an alert on your phone when it fails *(through the [ntfy app](../ntfy/README.md))*. It's this project's own app: nothing is downloaded, and it's the same for every model.

- **A task** is a name, a script typed on the page and when it runs. A shell script runs with the NAS's BusyBox `sh`; a script whose first line names another program *(`#!/opt/bin/python3`, from Entware...)* runs with that. Scripts run **as root**, in `/`, with Entware's programs *(`/opt/bin`)* found first, as in an SSH login. They get `TASK_ID`, `TASK_NAME` and `TASK_REASON` *(`boot`, `schedule`, `shutdown` or `manual`)*. Exiting with a code other than 0 marks the run as failed.
- **Schedules**: every hour, day, week or month at a chosen time, or any cron schedule *(minute, hour, day of the month, month, day of the week - numbers, `*`, ranges, lists and steps)*, in the NAS's time zone. They're kept in root's crontab and in WD's own list of cron jobs, which the firmware rewrites the crontab from every night *(see `cron_add` in [helpers.sh](../helpers.sh))* - lines only added to the crontab are gone the next morning.
- **At boot**: once each time the NAS starts, when WD starts the app *(after the apps before it)*, in the background and one after another - not when the app is switched on again or updated.
- **At shutdown**: when the NAS shuts down or restarts, as WD stops the app *(it looks for WD's shutdown and reboot programs running - switching the app off, updating or removing it doesn't run them)*. Keep them short: the NAS doesn't wait long.
- **Each run** has a time limit *(1 minute to a day; 30 minutes by default)*: a task that runs over it is stopped, with everything it started *(it runs in its own process group)*. A task that's still running isn't started again *(the skipped run is noted in the history)*. Running tasks can be stopped from the page.
- **Its page** lists the tasks, when each runs and how its last run went, with Run now / Stop, its output *(the last run's, up to 256 KB)*, Change, Switch on / off and Remove, and the most recent runs. Switching the app off on WD's Apps page pauses every schedule *(Run now still works)*.
- **ntfy**: with the ntfy app installed, set a topic on the page and choose, for each task, to be told when it fails, after every run, or never. The message has the end of its output.
- **Two example tasks** are added on the first install, switched off: a nightly copy of a share to a USB drive *(rsync, never deleting)* and an hourly check that fails when a volume is over 90% full - change their folders or limits and switch them on.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_tasks` *(root's only)*, and survives reinstalls and removal: `tasks.json`, the scripts *(`scripts/<id>.sh`)*, each task's last run *(`status/`)*, `history.log` *(its last 1000 runs)* and the ntfy topic.
- **Not yet tried on the NAS**: telling a shutdown from the app being switched off *(WD's `shutdown.sh` / `do_reboot` / `reboot` processes are looked for)*.

Anyone who can change the tasks can run anything as root - as they can by installing an app. The page is for NAS admins only *(see [Management pages](../README.md#management-pages))*, and every change needs its CSRF token.

## Management page

The Tasks page in the NAS dashboard *(Apps → Tasks)* adds, changes, runs, stops, switches on and off and removes tasks, shows their last runs and output and the recent runs, and sets the ntfy topic.

## Building the Tasks app

From the project root directory:

```bash
./build.sh tasks
```

The WD bin files will be created in `packages/tasks/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
