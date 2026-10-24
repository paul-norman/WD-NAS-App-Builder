Pi-hole blocks adverts and trackers for every device on your home network - phones, TVs and games consoles included,
with no app to install on them - by answering their DNS lookups and refusing the ones for advert and tracking servers.

- **Every device**: point your router's DNS setting at the NAS, and everything on the network uses Pi-hole.
- **A dashboard** of what's asked for and what's blocked, per device, at `http://<nas-ip>:8053/admin`.
- **Block lists** you choose (a well-known default list to start with), and allow lists for anything that breaks.
- **DNS only**: your router keeps handing out addresses (DHCP); Pi-hole just answers names.

After installing, set your **router's DNS server** to the NAS's address (in its DHCP or LAN settings), so that devices
use Pi-hole - or set it on a single device first to try it. The NAS needs a fixed address on your network for this
(e.g. a reserved address in the router). It's light: about 100MB of memory.
