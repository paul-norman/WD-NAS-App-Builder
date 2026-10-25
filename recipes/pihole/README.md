# Pi-hole (network-wide ad blocking) - Docker recipe

[Pi-hole](https://pi-hole.net/) blocks adverts and trackers for every device on your home network - phones, TVs and games consoles included, with nothing to install on them. Devices ask it for the addresses of the names they use (DNS), and it refuses the ones on its block lists. It runs in Docker, through the project's [Docker app](../../apps/docker/README.md), from Pi-hole's own image.

## Before you start

- **Port 53 must be free on the NAS** *(DNS)*, as must port 8053 *(Pi-hole's web interface - the NAS's own dashboard has 80 and 443)*. The installation checks both and stops, with a message, if something already has them.
- **A fixed address for the NAS** on your network *(e.g. a reserved address in your router's DHCP settings)*: devices will be told to use it for DNS.
- **DNS only**: your router keeps handing out addresses *(DHCP)* - Pi-hole just answers names. That keeps it simple, and the network still works if the NAS is off *(once the router's DNS setting is changed back)*.
- It's light: about 25MB of memory once running, and a few MB of disk for its block lists and query history.

## Files

- `compose.yaml` - the container; `example.env` - its settings, for `setup.sh`
- `recipe.json`, `description.md`, `icon.svg`, `hooks/pre_install.sh` *(the port check)* - the [recipe format](../../store/SPEC.md#4-recipes), for the [Store app](../../apps/store/README.md)
- `setup.sh` - installs it by hand, over SSH (below)

## Setting it up

**With the [Store app](../../apps/store/README.md)**: **Recipes → Pi-hole → Install** - choose a web password and the upstream DNS servers, and the Store does the rest *(including the Nginx site)*. Then carry on from step 3.

**By hand**, over SSH:

1. Copy this folder to the NAS, e.g. to `Public/pihole` over SMB.
2. Over SSH, run:
   ```sh
   sh /mnt/HD/HD_a2/Public/pihole/setup.sh
   ```
   It puts `compose.yaml` and a `.env` *(with a generated web password, shown once)* in `/mnt/HD/HD_a2/Nas_Prog/_pihole`, checks the ports, downloads Pi-hole's image and starts it. With the [Nginx app](../../apps/nginx/README.md) installed it also adds `https://pihole.<domain>/admin/`.
3. Open `http://<nas-ip>:8053/admin` *(or the Nginx app's address)* and log in with the web password.
4. **Try it on one device** first: set its DNS server to the NAS's address, and browse a site with adverts.
5. **Then the whole network**: in your router's settings *(usually DHCP or LAN)*, set the DNS server it gives out to the NAS's address. Devices pick it up when they next reconnect *(or restart them)*.

## Good to know

- **Something broken by blocking** *(a link that won't open, an app that won't log in)*: find the blocked name in Pi-hole's **Query Log** and allow it *(Domains → Allow list)*, or pause blocking for a few minutes from the dashboard.
- **Block lists**: Pi-hole starts with one well-known list; more can be added in **Lists**, then updated *(it updates them by itself every week)*.
- **Upstream DNS servers** *(where it looks up the names it doesn't block)*: chosen when installing *(Cloudflare by default)*, and changeable in Pi-hole's **Settings → DNS** - including your ISP's or encrypted DNS through another service.
- **Its web interface is at `/admin`**: Pi-hole's own page at the site's root just says it's not there.
- **The web password** can be changed in Pi-hole *(Settings → Web interface / API)*, or over SSH: `docker exec -it pihole pihole setpassword`.
- **Its data** *(settings, lists, query history)* is in `/mnt/HD/HD_a2/Nas_Prog/_pihole/etc-pihole`, kept across updates.
- **Updating**: the Store updates the recipe *(a newer Pi-hole image)*; by hand, change the image in `compose.yaml` and run `docker compose pull && docker compose up -d` in `/mnt/HD/HD_a2/Nas_Prog/_pihole`.
- **It runs as root inside its container**: Pi-hole normally gives its DNS server's program the network capabilities it needs and then drops root, but that fails on the NAS's Docker *("Unable to set capabilities for pihole-FTL. Cannot run as non-root.")*, so `DNSMASQ_USER` is `root` - Pi-hole's own answer for such systems. It's still shut in its container, with Docker's default capabilities only.
- **Removing it**: set your router's DNS setting back first - otherwise devices lose DNS while it's gone.
