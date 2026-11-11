"""
Sets Frigate up from the recipe's settings - run by configure.sh inside
Frigate's own image (its Python, with ruamel.yaml and pyzmq: not the NAS's
Python), with Frigate's settings folder at /config:

    python3 configure.py detectors
        Writes the detectors and model sections of /config/config.yml for
        DETECTOR (cpu, coral, remote - asking the remote detector at
        REMOTE_DETECTOR which model it runs - or manual: left alone). Exits
        with 10 when the file was changed (Frigate must be restarted), 0
        when it already said that, 1 on a problem

    python3 configure.py password
        Sets the admin user's password to ADMIN_PASSWORD: waits (up to 10
        minutes) for Frigate to create the user on its first start
"""

import json
import os
import sys
import time

CONFIG = "/config/config.yml"
DATABASE = "/config/frigate.db"

# The NAS's own detectors: Frigate's bundled models for each
LOCAL = {
    "cpu": (
        {"cpu": {"type": "cpu", "num_threads": 3}},
        {"path": "/cpu_model.tflite", "width": 320, "height": 320},
    ),
    "coral": (
        {"coral": {"type": "edgetpu", "device": "usb"}},
        {"path": "/edgetpu_model.tflite", "width": 320, "height": 320},
    ),
}

# How long the remote detector has to say which model it runs (ms)
DESCRIBE_TIMEOUT = 5000


def describe_remote(address):
    """
    Asks the recipe's remote detector server which model it runs.

    :param str address: Its address and port (e.g. 192.168.1.50:5555)

    :return: Its answer: detector (its type), model (the model section for
             Frigate on the NAS) and frigate (its Frigate version)

    :raises RuntimeError: When it doesn't answer, or answers wrongly
    """
    import zmq

    context = zmq.Context()
    socket = context.socket(zmq.REQ)
    socket.setsockopt(zmq.RCVTIMEO, DESCRIBE_TIMEOUT)
    socket.setsockopt(zmq.SNDTIMEO, DESCRIBE_TIMEOUT)
    socket.setsockopt(zmq.LINGER, 0)
    socket.connect(f"tcp://{address}")

    try:
        socket.send_multipart([json.dumps({"describe": True}).encode()])
        reply = json.loads(socket.recv_multipart()[0].decode())
    except zmq.Again:
        raise RuntimeError(
            f"the remote detector at {address} didn't answer - is its server"
            " running (see the recipe's README: remote-detector), and"
            " reachable from the NAS?"
        )
    except ValueError:
        raise RuntimeError(
            f"{address} answered, but not as the recipe's remote detector"
            " server does"
        )
    finally:
        socket.close()
        context.term()

    if not isinstance(reply.get("model"), dict):
        raise RuntimeError(f"{address} didn't say which model it runs")

    return reply


def wanted_sections(detector, address):
    """
    The detectors and model sections Frigate's settings should have.

    :param str detector: The recipe's DETECTOR setting
    :param str address:  REMOTE_DETECTOR (for remote)

    :return: The detectors and model sections, as a tuple

    :raises RuntimeError: When the setting can't be applied
    """
    if detector in LOCAL:
        return LOCAL[detector]

    if not address:
        raise RuntimeError(
            "\"Another machine\" is chosen, but its address isn't set"
            " (Remote detector address, e.g. 192.168.1.50:5555)"
        )

    reply = describe_remote(address)
    print(
        f"The remote detector at {address}: {reply.get('detector', '?')}"
        f" (Frigate {reply.get('frigate', '?')})"
    )
    mine = os.environ.get("FRIGATE_VERSION", "")

    if mine and reply.get("frigate", "").split("-")[0] != mine:
        print(
            f"Note: it runs Frigate {reply.get('frigate')}, the NAS"
            f" {mine} - use the same version on both if detection fails"
        )

    detectors = {"remote": {"type": "zmq", "endpoint": f"tcp://{address}"}}

    return detectors, reply["model"]


def plain(value):
    """
    A section of the settings as plain dicts and lists (ruamel's own types
    compare unequal to them).

    :param object value: The section

    :return: The same, as plain dicts and lists
    """
    return json.loads(json.dumps(value))


def set_detectors():
    """
    Writes the detectors and model sections of Frigate's settings for the
    recipe's DETECTOR setting.

    :return: The exit code (0 unchanged, 10 changed, 1 a problem)
    """
    from ruamel.yaml import YAML

    detector = os.environ.get("DETECTOR", "cpu")

    if detector == "manual":
        print("Object detection: manual - Frigate's settings left as they are")

        return 0

    if detector not in LOCAL and detector != "remote":
        print(f"Unknown object detection setting: {detector}")

        return 1

    try:
        detectors, model = wanted_sections(
            detector, os.environ.get("REMOTE_DETECTOR", "").strip()
        )
    except RuntimeError as problem:
        print(f"Object detection wasn't changed - {problem}")
        print("Save the recipe's settings again once that's fixed.")

        return 1

    yaml = YAML()
    yaml.indent(mapping=2, sequence=4, offset=2)
    yaml.preserve_quotes = True

    with open(CONFIG) as file:
        config = yaml.load(file)

    if (
        plain(config.get("detectors")) == detectors
        and plain(config.get("model")) == model
    ):
        print(f"Object detection: {detector} (unchanged)")

        return 0

    # They replace the ones there - or go last, before version (a comment
    # after a replaced section would go with it)
    for key, value in (("detectors", detectors), ("model", model)):
        if key in config:
            config[key] = value
        else:
            at = (
                list(config.keys()).index("version")
                if "version" in config
                else len(config)
            )
            config.insert(at, key, value)

    with open(CONFIG + ".new", "w") as file:
        yaml.dump(config, file)

    os.chmod(CONFIG + ".new", 0o600)
    os.replace(CONFIG + ".new", CONFIG)
    print(f"Object detection: {detector} - written to Frigate's settings")

    return 10


def set_password():
    """
    Sets Frigate's admin password, once Frigate has created its admin user.

    :return: The exit code (0 set, 1 a problem)
    """
    import sqlite3

    sys.path.insert(0, "/opt/frigate")
    from frigate.api.auth import hash_password

    password = os.environ.get("ADMIN_PASSWORD", "")

    if not password:
        return 0

    for _ in range(120):
        try:
            with sqlite3.connect(DATABASE, timeout=30) as db:
                changed = db.execute(
                    "UPDATE user SET password_hash = ? WHERE username = ?",
                    (hash_password(password), "admin"),
                ).rowcount
        except sqlite3.Error:
            changed = 0

        if changed:
            print("Frigate's admin password is set (user: admin)")

            return 0

        time.sleep(5)

    print(
        "Frigate didn't create its admin user within 10 minutes: its password"
        " is in Frigate's log (docker logs frigate)"
    )

    return 1


if __name__ == "__main__":
    if sys.argv[1:] == ["detectors"]:
        sys.exit(set_detectors())

    if sys.argv[1:] == ["password"]:
        sys.exit(set_password())

    print(__doc__)
    sys.exit(1)
