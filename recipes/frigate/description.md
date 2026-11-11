Frigate is a video recorder for IP security cameras that recognises what it sees, running on your NAS.

- **Records your cameras** to a share on the NAS: where there was motion (kept 7 days by default), and clips of what
  it spotted (30 days). Old recordings are deleted by Frigate itself.
- **Spots people, cars, cats and dogs** in the video, rather than every shadow and raindrop: alerts and a timeline of
  what happened, with snapshots.
- **Live view and playback** in a browser on any device, at `https://cameras.<domain>` with the Nginx app.
- **Your cameras** are added in Frigate's own camera wizard: most IP cameras with an RTSP stream work.

**Object detection** needs some help for more than a camera or two: the NAS's processor manages one or two quiet
cameras. For 4 to 8, plug a **Coral USB accelerator** into the NAS, or let **another machine** do it - a Raspberry Pi 5
with a Hailo-8L, or a PC - with the recipe's remote detector (see its README).

It needs about **2GB of memory for Docker**, and Frigate's image is large (about 9GB on disk). The NAS's GPU decodes the
cameras' video (H.264, and 8-bit H.265).

After installing, open Frigate and log in as **admin** with the password you chose, then add your cameras (Settings ->
Cameras). Give each camera a small second stream for detection if it has one (e.g. 640x360) - it's much lighter for the
NAS.
