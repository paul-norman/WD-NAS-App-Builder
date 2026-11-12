# ntfy App

[ntfy](https://ntfy.sh/) sends push notifications to phones *(its Android and iPhone apps)* and browsers *(its web app)*. Anything that can make a web request can send one - the NAS's apps *(Uptime Kuma, Grafana alerts, Kopia)* and your own scripts, e.g. `curl -d "Backup finished" https://ntfy.<domain>/nas`. Notifications are grouped into topics *(e.g. `nas`)*, which devices subscribe to. It runs natively on the NAS *(no Docker)*.

- It's at `https://ntfy.<domain>` through the [Nginx app](../nginx/README.md), if installed *(added automatically, with streaming turned on for it)*, and at `http://<nas-ip>:2586` on the local network unless limited to the Nginx app on the management page. ntfy's own web app is at the same address.
- **Nobody can read or send without logging in.** The app creates an `admin` user, for the phone apps and the web app *(its password is generated - the management page shows, copies or replaces it)*, and an **access token** for the apps and scripts that send notifications. Both are declared in ntfy's configuration, which holds only the password's bcrypt hash; sign-ups are off.
- Messages are kept for a day *(so a phone that was offline still gets them)*, attachments up to 15MB.
- It runs as its own `ntfy` user *(created by the app, ID 76)*, not as root.
- Its data is kept next to the app, e.g. `/mnt/HD/HD_a2/Nas_Prog/_ntfy`, and survives reinstalls and removal: the messages, users and attachments in `data/` *(with the generated `server.yml`)*, the admin password and token *(root only)*, the page's settings, and `ntfy.log` *(warnings only, kept under 1MB)*.
- On the Intel models it's the official static program; on the ARM ones it's built from ntfy's source *(its official ARM program is laid out for 4KB memory pages, and the ARM models' kernels use larger ones - it crashes there)*, with its web app and documentation, linked statically for 64KB pages *(both prepared by `static/ntfy`)*. ntfy doesn't update itself: updates come with new versions of the app, and the NAS shows an alert when a new release is out, checked weekly.
- For the Intel and ARM models *(the ARM ones' packages are checked under emulation when they're built - it serves, takes a message and gives it back - but haven't yet been tried on an ARM NAS)*.

## Phones

Install the ntfy app, add the server *(the address on the management page)* and log in as `admin`, then subscribe to the topics the apps send to.

- **Android** keeps a connection to the server open, so notifications arrive at once.
- **iPhones** only get notifications at once through Apple's push service. ntfy reaches it through ntfy.sh's relay, which is sent only each message's ID, not its contents - the phone then fetches the message from the NAS. Turn it on on the management page *(it's off by default, as it contacts ntfy.sh)*; without it, an iPhone only sees new messages when the app is opened.

**Away from home**: the phone fetches messages from the NAS, so it needs to reach it. The Nginx app is reachable from the local network only by default, so either connect to home over a VPN *(e.g. the project's Tailscale app, or your router's own VPN)*, or make ntfy reachable from the internet *(e.g. by forwarding the router's port 443 to the NAS - which exposes every site of the Nginx app; ntfy itself requires its login)*.

## Sending notifications

With the access token *(from the management page)*:

```sh
curl -H "Authorization: Bearer <token>" -H "Title: Backup" -H "Tags: floppy_disk" -d "Backup finished" https://ntfy.<domain>/nas
```

- **Uptime Kuma**: Settings → Notifications → ntfy, with the server address, a topic and the token *(access token authentication)*.
- **Grafana**: a contact point of type **Webhook** to `https://ntfy.<domain>/nas?template=grafana` *(ntfy formats Grafana's alerts)*, with the header `Authorization: Bearer <token>`.
- **Kopia**: a notification profile of type **Webhook** to `https://ntfy.<domain>/nas`, with the same header.

The management page can send a test notification to any topic.

## Management page

ntfy's page in the NAS dashboard *(Apps → ntfy)* shows whether it's running, its version and address, the phone apps' login *(with the password)* and the access token *(both can be replaced)*, an example command, and how to set up Uptime Kuma, Grafana and Kopia. It sends test notifications, limits access to the Nginx app, turns iPhone instant notifications on or off, restarts ntfy, and shows its latest warnings. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the ntfy app

From the project root directory:

```bash
./build.sh ntfy
```

This first runs `static/ntfy` *(once per version)*. The WD bin files will be created in `packages/ntfy/`. To update, change the version in `apkg.rc` and `static/ntfy/build.sh` *(with the new release's checksum)*.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
