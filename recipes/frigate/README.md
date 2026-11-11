# Frigate (security cameras) - Docker recipe

[Frigate](https://frigate.video/) records your IP security cameras and recognises what's in the video - people, cars, cats and dogs - so you get alerts and a timeline of what happened rather than every shadow and raindrop. It runs in Docker, through the project's [Docker app](../../apps/docker/README.md), from Frigate's own image, with the recordings on one of the NAS's shares.

## How much the NAS can do

Frigate does three kinds of work for each camera, and they decide how many cameras the NAS can handle:

- **Recording**: the camera's full-quality stream is saved as it arrives, without being decoded - almost no processor time, only disk space *(4 cameras at 4 Mbit/s, recording all the time, use about 170GB a day; this recipe only keeps recordings with motion, alerts and detections)*.
- **Watching for motion**: a small second stream from each camera *(e.g. 640x360 at 5 frames a second)* is decoded all the time - by the NAS's GPU *(VA-API: H.264, and 8-bit H.265)* - and compared frame to frame on the processor. On a PR4100 *(Pentium N3710)* this is the real limit: about **6-8 cameras** with small detection streams.
- **Object detection**: only where there's motion, a model looks for people, cars and animals. That's the heavy part, and where you choose what does it:

| Object detection | Cameras | Measured / expected | Notes |
|---|---|---|---|
| **The NAS's processor** | 1-2, quiet | 178ms per detection on a PR4100 *(about 5 a second for the whole NAS)* | No hardware needed - good for trying Frigate out |
| **Coral USB accelerator**, plugged into the NAS | 4-8 | about 10ms | No longer made, but still sold. Plug it into one of the NAS's USB ports |
| **Another machine** on your network | 4-8 | depends on the machine, plus a few ms for the network | A **Raspberry Pi 5 with a Hailo-8L** *(AI Kit / AI HAT+)*, or a PC - see [Remote detector](remote-detector/README.md) |

A **Hailo-8L can't go in the NAS**: it needs a PCIe slot *(M.2)*, which the NAS doesn't have, and USB enclosures for M.2 cards only carry storage, not PCIe. On a Raspberry Pi 5 it's on PCIe - so the Pi does the detecting, and the NAS everything else.

Frigate's checks happen several times a second for each moving object, so with the NAS's processor alone, two cameras seeing movement at once already fall behind - detection gets late, not wrong. Start with it, and add a Coral or a remote detector when you add cameras.

## Before you start

- **A share for the recordings**: by default `Cameras` *(the recordings go in `Cameras/Frigate`)* - create it in the NAS dashboard first *(Shares)*, or choose a folder on another share.
- **Memory**: about **1-1.5GB** for Frigate with a few cameras *(the Docker app's memory share must allow 2GB)* - the 4GB standard models manage, with less room for other containers.
- **Disk**: Frigate's image is about **9GB** unpacked *(3GB to download)*, plus the recordings.
- **Ports**: 8971 *(its web interface, with login)* and 8554 *(its RTSP restream, e.g. for Home Assistant)* - checked before installing. Frigate's unauthenticated port 5000 isn't published.
- **The NAS's Intel GPU** decodes the cameras' video *(`/dev/dri`, with Intel's i965 driver - the N3710's graphics are too old for the newer iHD one)*. Models without an Intel GPU *(DL2100 / DL4100: Atom C2338)* can't use this recipe as it is - remove the `devices:` lines from `compose.yaml` and `hwaccel_args` from Frigate's settings.
- **Your cameras' addresses**: an RTSP address for each stream, from the camera's manual or app *(e.g. `rtsp://user:password@192.168.1.60:554/stream1` for the main stream and `/stream2` for the small one)*. Give each camera a fixed address on your network.

## Files

- `compose.yaml` - the container; `example.env` - its settings, for `setup.sh`
- `recipe.json`, `description.md`, `icon.svg`, `hooks/` - the [recipe format](../../store/SPEC.md#4-recipes), for the [Store app](../../apps/store/README.md):
  - `hooks/pre_install.sh` checks the ports and writes Frigate's first settings
  - `hooks/configure.sh` *(with `configure.py`, run inside Frigate's own image)* writes the "Object detection" setting into Frigate's settings - asking a remote detector which model it runs - restarts Frigate if they changed, and sets the admin password on a new install
- `setup.sh` - installs it by hand, over SSH (below)
- `remote-detector/` - the detector server for another machine *(a Raspberry Pi 5 with a Hailo-8L, or a PC)* - see [its README](remote-detector/README.md)

## Setting it up

**With the [Store app](../../apps/store/README.md)**: **Recipes → Frigate → Install** - choose the recordings folder, the object detection and an admin password, and the Store does the rest *(including the Nginx site)*. Then carry on from step 3.

**By hand**, over SSH:

1. Copy this folder to the NAS, e.g. to `Public/frigate` over SMB.
2. Over SSH, run:
   ```sh
   sh /mnt/HD/HD_a2/Public/frigate/setup.sh
   ```
   It puts `compose.yaml` and a `.env` *(with a generated admin password, shown once)* in `/mnt/HD/HD_a2/Nas_Prog/_frigate`, checks the ports, writes Frigate's first settings, downloads Frigate's image and starts it. With the [Nginx app](../../apps/nginx/README.md) installed it also adds `https://cameras.<domain>`. To change the object detection, edit `DETECTOR` *(and `REMOTE_DETECTOR`)* in `.env` and run it again.
3. Open `http://<nas-ip>:8971` *(or the Nginx app's address)* and log in as **admin**.
4. **Add your cameras**: **Settings → Cameras** has a wizard that tries the camera's address and finds its streams. Use the small stream for detection and the main one for recording.
5. Watch **System metrics** *(the gauge icon)* for a day: the detector's inference speed, and each camera's detection frames per second. If detection can't keep up, add a Coral or a remote detector.

## Object detection

Chosen in the Store *(Install, or Frigate's **Settings** in the Store later)* - "Object detection":

- **The NAS's processor** *(`cpu`)*: Frigate's standard model *(SSD MobileNet, 320x320)* with 3 threads. It works on the N3710 *(it has no AVX, which Frigate doesn't need)*, at 178ms per detection.
- **Coral USB accelerator** *(`coral`)*: plug it into the NAS, then choose this. The container sees the NAS's USB devices *(`/dev/bus/usb`, with a rule allowing USB devices only)*: the Coral changes its USB ID once its firmware is loaded, so a single fixed device wouldn't do. Frigate's log says `TPU found` when it's working.
- **Another machine** *(`remote`)*: start the [remote detector](remote-detector/README.md) on it first, then choose this and enter its address and port *(e.g. `192.168.1.50:5555`)*. When the settings are saved, the recipe asks the server which model it runs and writes the matching settings into Frigate - so the two always agree. If it doesn't answer, the settings are left as they were, and the Store's log says why.
- **Manual** *(`manual`)*: the `detectors` and `model` sections of Frigate's settings are left alone - for a model of your own, [Frigate+](https://frigate.video/plus/), or any of [Frigate's other detectors](https://docs.frigate.video/configuration/object_detectors).

The recipe owns only those two sections *(at the end of `config.yml`)*: everything else in Frigate's settings is yours, and kept when the recipe's settings change or it's updated.

## An example camera

The wizard writes something like this into Frigate's settings *(**Settings → Configuration editor**, or `/mnt/HD/HD_a2/Nas_Prog/_frigate/config/config.yml` - restart Frigate after editing the file)*:

```yaml
cameras:
  front_door:
    ffmpeg:
      inputs:
        # The small stream: watched for motion and objects
        - path: rtsp://user:password@192.168.1.60:554/stream2
          roles:
            - detect
        # The main stream: recorded as it is
        - path: rtsp://user:password@192.168.1.60:554/stream1
          roles:
            - record
    detect:
      width: 640
      height: 360
      fps: 5
```

Recordings are kept 7 days where there was motion, and alerts and detections 30 days *(`record` in the settings - set `continuous: days:` to also keep everything)*. Snapshots of what's detected, 30 days.

## Good to know

- **The admin password** is set when installing *(the wizard's, or the one `setup.sh` shows)*; change it, and add other users, in **Settings → Users**. Lost it? Add `auth: reset_admin_password: true` to the settings, restart Frigate, and the new password is in its log *(`docker logs frigate`)* - then remove the line.
- **HTTPS** is the Nginx app's: Frigate's own TLS is off *(`tls: enabled: false`)*, so on the local network it's plain HTTP at `:8971`, with its login.
- **Live view** uses MSE through the web interface, which works in current browsers *(Safari on iPhone and iPad too, from iOS 17.1)*. WebRTC *(two-way audio)* needs port 8555 and [more settings](https://docs.frigate.video/configuration/live) - not set up here.
- **Home Assistant**: the [Frigate integration](https://docs.frigate.video/integrations/home-assistant) needs Frigate's API: point it at `http://<nas-ip>:8971` with a Frigate user. MQTT is off in these settings - turn it on, with your broker's address, for the integration's events.
- **Its data**: the settings and database in `/mnt/HD/HD_a2/Nas_Prog/_frigate/config`, the recordings in the share. Removing the recipe keeps the recordings folder.
- **Updating**: the Store updates the recipe *(a newer Frigate image)*. Update a remote detector to the same version.
- **The NAS's own Python isn't used**: the recipe's settings hook runs inside Frigate's image *(`docker compose run`)*, which has what it needs.
