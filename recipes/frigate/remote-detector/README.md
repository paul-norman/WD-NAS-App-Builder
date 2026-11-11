# Frigate remote detector

Object detection for the NAS's [Frigate](../README.md), done by **another machine on your network** - a Raspberry Pi 5 with a Hailo-8L, or a PC. Frigate on the NAS still does everything else *(recording, watching for motion, its web interface)*; for each frame where something moved, it sends the frame here and gets back what was found.

It's Frigate's own detector code, in Frigate's own image: `detector_server.py` starts one of Frigate's detectors *(as Frigate itself would)* and answers Frigate's built-in **`zmq` detector** over the network. Frames are sent uncompressed *(about 300KB at 320x320)*, which takes a few milliseconds on a wired gigabit network.

| Hardware | Profile | Detector | Model | Notes |
|---|---|---|---|---|
| **Raspberry Pi 5 + Hailo-8L** *(AI Kit / AI HAT+)* or Hailo-8 | `hailo` | `hailo8l` | YOLOv6n, 320x320 *(downloaded on first use)* | The best fit: small and quiet |
| **PC with an Intel GPU** *(6th generation Core or newer)* | `openvino` | `openvino` *(GPU)* | SSDLite MobileNet v2, 300x300 | `OPENVINO_DEVICE=CPU` for the processor *(Intel or AMD)* |
| **Coral USB accelerator** on another machine | `coral` | `edgetpu` | SSD MobileNet, 320x320 | E.g. a Pi 4 or 5 - or plug it into the NAS instead |
| Any machine *(testing only)* | `cpu` | `cpu` | SSD MobileNet, 320x320 | Slow - to try the connection |

## Setting it up

You need Docker with Docker Compose on the machine *(on a Pi: Raspberry Pi OS 64-bit, then `curl -fsSL https://get.docker.com | sh`)*, and a **fixed address** for it on your network *(a reserved address in your router's DHCP settings)*.

1. **The hardware's driver** - on the machine itself, not in Docker:
   - **Hailo**: the Hailo driver *(`hailo_pci`)* must be the **same version as the HailoRT in Frigate's image** - 4.21 for Frigate 0.18. Raspberry Pi OS's `hailo-all` package may be a different version; Frigate's documentation has a script that installs the matching one: [Frigate - Hailo-8](https://docs.frigate.video/configuration/object_detectors#hailo-8). Afterwards, `ls /dev/hailo0` should show the device.
   - **Intel GPU**: nothing to install *(Linux's own `i915` driver)* - `ls /dev/dri` should show `renderD128`.
   - **Coral**: nothing to install for the USB version.
2. Copy this folder *(`compose.yaml` and `detector_server.py`)* to the machine, e.g. to `~/frigate-detector`.
3. Start the one for your hardware, in that folder:
   ```sh
   docker compose --profile hailo up -d
   ```
   *(or `openvino`, `coral`, `cpu`)*. The first time, Docker downloads Frigate's image *(a few GB)*. Check its log:
   ```sh
   docker logs frigate-detector
   ```
   It should end with `Frigate 0.18.2-... remote detector: hailo8l, 320x320, listening on port 5555`.
4. On the NAS, in the Store: **Frigate → Settings** *(or when installing)* - **Object detection: Another machine**, and **Remote detector address**: the machine's address and port, e.g. `192.168.1.50:5555`. Save: the recipe asks the server which model it runs, writes the matching settings into Frigate and restarts it - the Store's log shows `The remote detector at 192.168.1.50:5555: hailo8l`. *(By hand: set `DETECTOR=remote` and `REMOTE_DETECTOR=192.168.1.50:5555` in the NAS's `.env`, and run `setup.sh` again.)*
5. In Frigate's **System metrics**, the detector `remote` shows its inference speed. The server's log says `Described the model to a Frigate` each time the NAS's settings are saved.

## Good to know

- **The same Frigate version on both**: the server answers Frigate's `zmq` detector, which is recent and may change between versions. `compose.yaml` follows `FRIGATE_VERSION` *(0.18.2 by default)* - update the server when the NAS's recipe updates: set it in a `.env` next to `compose.yaml`, then `docker compose --profile hailo pull && docker compose --profile hailo up -d`.
- **If the server stops** *(or the machine is off)*, Frigate on the NAS carries on recording, but detects nothing - its log says the `zmq` requests time out - until the server's back. For a long outage, switch the recipe's Object detection to the NAS's processor.
- **The port** *(5555)* is changed with `PORT` in the `.env` next to `compose.yaml`. It answers anything on your network that speaks Frigate's protocol, with no login - keep it on your home network, not forwarded from the internet. It only ever runs detections: frames in, boxes out.
- **A model of your own** *(e.g. a YOLO model for the Hailo-8 or a PC's GPU)*: put it in `model_cache/`, and set `MODEL_JSON` to its model section, as JSON - e.g. `MODEL_JSON={"path": "/config/model_cache/yolov8s.hef", "width": 640, "height": 640, "input_tensor": "nhwc", "input_pixel_format": "rgb", "input_dtype": "int", "model_type": "yolo-generic", "labelmap_path": "/labelmap/coco-80.txt"}` in the `.env`, then save the NAS's recipe settings again so Frigate there matches.
- **Several NASes or Frigates** can share one server: it handles their frames in turn.
- **Tested** with the `cpu` profile, end to end with Frigate through the Store *(the NAS's settings written from the server's answer, detections over the network)*. The `hailo`, `openvino` and `coral` profiles use the same code with Frigate's own detectors, but haven't been run on that hardware here yet.
