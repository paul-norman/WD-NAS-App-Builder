"""
A remote object detector for Frigate on the NAS: runs one of Frigate's own
detectors (a Hailo-8 / Hailo-8L, OpenVINO on an Intel CPU or GPU, a Coral, or
the CPU) on another machine, and answers Frigate's "zmq" detector over the
network. Run inside Frigate's own image (see compose.yaml):

    python3 -u detector_server.py

Settings, from the environment:

    DETECTOR         hailo8l (default), openvino, edgetpu or cpu
    PORT             The TCP port to listen on (default 5555)
    OPENVINO_DEVICE  For openvino: GPU (default) or CPU
    CPU_THREADS      For cpu: threads per detection (default 3)
    MODEL_JSON       Optional: a model section of Frigate's settings, as JSON,
                     in place of the detector's usual model (e.g. a YOLO model
                     of your own)

The NAS's Frigate sends each frame (already sized and laid out for the
model) and gets back up to 20 detections. Beyond Frigate's own messages, it
answers {"describe": true} with the detector and the model section Frigate on
the NAS needs - the recipe's hook asks it, so the two always match.
"""

import json
import logging
import os
import sys

import numpy as np
import zmq

sys.path.insert(0, "/opt/frigate")

from pydantic import TypeAdapter  # noqa: E402

from frigate.detectors import DetectorConfig, create_detector  # noqa: E402
from frigate.version import VERSION  # noqa: E402

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("detector_server")

# Each detector's usual model: its section of Frigate's settings. The path is
# the model on this machine - none for Hailo's, which its plugin downloads on
# first use (Frigate's usual YOLOv6n for the chip it finds)
MODELS = {
    "hailo8l": {
        "width": 320,
        "height": 320,
        "input_tensor": "nhwc",
        "input_pixel_format": "rgb",
        "input_dtype": "int",
        "model_type": "yolo-generic",
        "labelmap_path": "/labelmap/coco-80.txt",
    },
    "openvino": {
        "path": "/openvino-model/ssdlite_mobilenet_v2.xml",
        "width": 300,
        "height": 300,
        "input_tensor": "nhwc",
        "input_pixel_format": "bgr",
        "labelmap_path": "/openvino-model/coco_91cl_bkgr.txt",
    },
    "edgetpu": {
        "path": "/edgetpu_model.tflite",
        "width": 320,
        "height": 320,
    },
    "cpu": {
        "path": "/cpu_model.tflite",
        "width": 320,
        "height": 320,
    },
}

# The largest frame accepted (bytes): 1280x1280, 3 channels, float32
LARGEST = 1280 * 1280 * 3 * 4

NO_DETECTIONS = np.zeros((20, 6), np.float32)


def detector_settings(name):
    """
    The detector's section of Frigate's settings, from the environment.

    :param str name: The detector (DETECTOR)

    :return: Its settings
    """
    if name == "openvino":
        return {
            "type": "openvino",
            "device": os.environ.get("OPENVINO_DEVICE", "GPU"),
        }

    if name == "edgetpu":
        return {"type": "edgetpu", "device": "usb"}

    if name == "cpu":
        return {
            "type": "cpu",
            "num_threads": int(os.environ.get("CPU_THREADS", "3")),
        }

    return {"type": name}


def start_detector(name, model):
    """
    Starts one of Frigate's detectors, as Frigate itself would.

    :param str  name:  The detector (DETECTOR)
    :param dict model: Its model section

    :return: The detector
    """
    settings = detector_settings(name)
    settings["model"] = model
    config = TypeAdapter(DetectorConfig).validate_python(settings)

    return create_detector(config)


def reply_json(socket, data):
    """
    Answers a request with a JSON message.

    :param zmq.Socket socket: The socket
    :param dict       data:   The answer
    """
    socket.send_multipart([json.dumps(data).encode()])


def detect(detector, model, header, frames):
    """
    Runs one detection.

    :param object detector: The detector
    :param dict   model:    Its model section
    :param dict   header:   The request's header: the frame's shape and dtype
    :param list   frames:   The request's frames (the second is the frame)

    :return: The detections: up to 20 rows of label, score, ymin, xmin, ymax,
             xmax (0-1)
    """
    shape = tuple(int(n) for n in header.get("shape", []))
    dtype = np.dtype(header.get("dtype", "uint8"))

    if (
        len(frames) < 2
        or not shape
        or len(frames[1]) > LARGEST
        or len(frames[1]) != int(np.prod(shape)) * dtype.itemsize
    ):
        log.warning("Ignored a frame of the wrong size: %s", header)

        return NO_DETECTIONS

    if model["width"] not in shape or model["height"] not in shape:
        log.warning(
            "A %s frame, but the model takes %dx%d: is Frigate on the NAS set"
            " up for this server? (save its recipe's settings again)",
            shape, model["width"], model["height"],
        )

        return NO_DETECTIONS

    tensor = np.frombuffer(frames[1], dtype=dtype).reshape(shape)
    result = detector.detect_raw(tensor)

    return np.asarray(result, dtype=np.float32).reshape((20, 6))


def main():
    """
    Answers the NAS's Frigate until stopped.
    """
    name = os.environ.get("DETECTOR", "hailo8l")

    if name not in MODELS:
        log.error("DETECTOR must be one of %s", ", ".join(MODELS))
        sys.exit(1)

    model = dict(MODELS[name])

    if os.environ.get("MODEL_JSON"):
        model = json.loads(os.environ["MODEL_JSON"])

    detector = start_detector(name, model)
    port = int(os.environ.get("PORT", "5555"))
    context = zmq.Context()
    socket = context.socket(zmq.REP)
    socket.bind(f"tcp://*:{port}")
    log.info(
        "Frigate %s remote detector: %s, %dx%d, listening on port %d",
        VERSION, name, model["width"], model["height"], port,
    )

    while True:
        frames = socket.recv_multipart()

        try:
            header = json.loads(frames[0].decode())
        except ValueError:
            header = {}

        # The NAS's Frigate needs a model path: only its name is used (it asks
        # whether this server has the model)
        if header.get("describe"):
            nas_model = dict(model)
            nas_model.setdefault("path", f"remote-{name}")
            reply_json(
                socket,
                {"detector": name, "model": nas_model, "frigate": VERSION},
            )
            log.info("Described the model to a Frigate")

            continue

        # Frigate asks whether the model is here, and may send its own: this
        # server always uses its own
        if header.get("model_request"):
            reply_json(socket, {"model_available": True, "model_loaded": True})

            continue

        if header.get("model_data"):
            reply_json(socket, {"model_saved": True, "model_loaded": True})

            continue

        try:
            result = detect(detector, model, header, frames)
        except Exception as problem:  # noqa: BLE001
            log.error("Detection failed: %s", problem)
            result = NO_DETECTIONS

        socket.send_multipart([
            json.dumps({"shape": [20, 6], "dtype": "float32"}).encode(),
            result.tobytes(),
        ])


if __name__ == "__main__":
    main()
