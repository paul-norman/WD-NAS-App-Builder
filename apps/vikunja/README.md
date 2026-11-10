# Vikunja App

[Vikunja](https://vikunja.io/) is for to-do lists and projects: tasks with due dates, reminders, priorities, labels and attachments, seen as a list, a kanban board, a Gantt chart or a table - private, or shared with other people on the NAS. Phone and desktop to-do apps *(e.g. Tasks.org, Thunderbird, Apple Reminders)* can use it over CalDAV. The app runs it natively on the NAS *(no Docker)*, with its tasks in SQLite.

For the Intel and ARM models *(the ARM ones' package is checked under emulation when it's built, but hasn't yet been tried on an ARM NAS)*.

- **Its web interface** is on port 3456 - by default, with the Nginx app installed, only through it, at `https://vikunja.<domain>` *(the page's setting: on the network too, over plain HTTP)*. Vikunja is told its address *(the Nginx app's site, else the NAS's own on port 3456)* for its links: restart it from the page if the Nginx app's address changes.
- **Nobody else can claim it.** The app makes the `admin` account before Vikunja first starts, with a generated password the page shows, copies or resets. Vikunja only reads passwords from a terminal: the app types them in through a pseudo-terminal *(`vikunja_runas --pty`)*, so they're never on a command line or in a log. You can change the admin's password in Vikunja's own settings - the page then no longer knows it until you reset it.
- **Other people's accounts** are added on the page *(a user name and an email address - Vikunja needs one, but sends nothing)*, each with a generated password shown once; the page also gives anyone a new password. Vikunja's own "forgot password" emails don't work, as the NAS has no mail server set up for it.
- **No sign-ups** unless the page turns them on *(then anyone who can reach Vikunja can make an account)*.
- **CalDAV** is at `https://vikunja.<domain>/dav/`: in Vikunja, make a CalDAV token *(Settings → CalDAV)* and use it as the to-do app's password.
- **Backups** every night at 03:05, and from the page: Vikunja's database *(copied safely while it runs, with SQLite's own backup, and checked)* and its attachments, as one `.tar.gz` in `Nas_Prog/_vikunja/backups` *(root's only; the newest 14 kept, set on the page)*. To restore one: stop Vikunja *(the dashboard's switch)*, unpack it into `Nas_Prog/_vikunja/data`, start it again.
- Its reminders and due dates use the NAS's time zone *(from WD's `php.ini`)*.
- Vikunja runs as its own `vikunja` user *(created by the app, ID 59)*. Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_vikunja`, and survives reinstalls and removal: `data/` *(the database and attachments - its user's only)*, `config.yml` *(written by the app at every start)*, its secret *(it signs logins: they last across restarts)*, the admin password, backups, the page's settings and `vikunja.log` *(kept under 1MB)*.
- Vikunja is the official program from its releases *(its web app is built into it; the paid "Pro" features stay off - its log says so at every start)*. It doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.

## Management page

Vikunja's page in the NAS dashboard *(Apps → Vikunja)* shows whether it's running, its version and its addresses, the admin login *(with the password)*, its users and the latest backup. It resets passwords, adds users, backs up now, sets whether it's only reachable through the Nginx app, whether anyone can sign up and how many backups are kept, restarts it and shows its log. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Vikunja app

From the project root directory:

```bash
./build.sh vikunja
```

This first runs `static/vikunja` *(once per version: Vikunja's release for each architecture, checked against its SHA256, SQLite's shell for the backups and the run-as helper)*. The WD bin files will be created in `packages/vikunja/`. To update, change the version in `apkg.rc` and `static/vikunja/build.sh` *(with the new release's checksums)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
