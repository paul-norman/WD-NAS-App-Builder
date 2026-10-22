"""Music Assistant's admin user and the management page's access token, through its API on the NAS itself.

Run as root by ma_ctl.sh with the app's own Python (passwords and tokens stay in root-only files, never on a command line):
    python3 -I ma_api.py setup <data path>         - the first time: creates the admin user (with a generated password)
                                                    before anyone else can, and the page's token
    python3 -I ma_api.py new-password <data path>  - gives the admin user a new generated password (and a new page token)
"""

import json
import os
import secrets
import string
import sys
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8095"
ADMIN = "admin"
TOKEN_NAME = "NAS dashboard page"


def request(path, data=None, token=None, timeout=20):
    """A JSON request: (HTTP status, decoded response or None)."""
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(API + path, data=body, headers=headers, method="GET" if body is None else "POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status, text = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, text = error.code, error.read()
    except (urllib.error.URLError, OSError):
        return 0, None
    try:
        return status, json.loads(text)
    except ValueError:
        return status, None


def command(token, api_command, **args):
    """A command on Music Assistant's JSON-RPC API: (HTTP status, result)."""
    return request("/api", {"message_id": "nas", "command": api_command, "args": args}, token)


def write_secret(path, value):
    """Writes a root-only file in one step."""
    temp = path + ".tmp"
    with open(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as file:
        file.write(value + "\n")
    os.replace(temp, path)


def new_password():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(20))


def wait_until_up(seconds=120):
    """Waits for Music Assistant to answer (its first start takes a while): its server information, or None."""
    for _ in range(seconds):
        status, info = request("/info", timeout=5)
        if status == 200 and info:
            return info
        time.sleep(1)
    return None


def make_page_token(data_path, token):
    """A long-lived token for the management page (so it doesn't log in at every refresh)."""
    status, page_token = command(token, "auth/token/create", name=TOKEN_NAME)
    if status != 200 or not isinstance(page_token, str):
        print("Could not create the page's access token")
        return False
    write_secret(os.path.join(data_path, "page_token"), page_token)
    return True


def remove_smart_fades(token):
    """Removes the Smart Fades provider Music Assistant adds by default: it needs on-device audio analysis (PyTorch and
    a CPU with AVX2 - which no WD NAS has), left out of the app, so it would otherwise try to install it at every start.
    Music Assistant only adds it once, so it stays removed (it can be added again in its settings)."""
    status, providers = command(token, "config/providers")
    for provider in providers if status == 200 and isinstance(providers, list) else []:
        if provider.get("domain") == "smart_fades":
            command(token, "config/providers/remove", instance_id=provider["instance_id"])
            print("removed the Smart Fades provider (it needs on-device audio analysis)")


def setup(data_path):
    if wait_until_up() is None:
        print("Music Assistant did not answer")
        return 1
    password_file = os.path.join(data_path, "admin_password")
    if os.path.exists(password_file):
        return 0
    password = new_password()
    status, result = request("/setup", {"username": ADMIN, "password": password, "device_name": TOKEN_NAME})
    if status == 200 and result and result.get("success"):
        write_secret(password_file, password)
        print("created the admin user: " + ADMIN)
        remove_smart_fades(result["token"])
        return 0 if make_page_token(data_path, result["token"]) else 1
    # (its data was kept without the password file, or someone else set it up)
    print("Could not create the admin user (is one already set up?): %s" % (result or status))
    return 1


def change_password(data_path):
    password_file = os.path.join(data_path, "admin_password")
    try:
        with open(password_file) as file:
            current = file.read().strip()
    except OSError:
        print("No admin password saved by the app")
        return 1
    status, result = request("/auth/login", {"credentials": {"username": ADMIN, "password": current},
                                             "device_name": TOKEN_NAME})
    if status != 200 or not result or not result.get("success"):
        print("Could not log in as %s with the saved password (was it changed in Music Assistant?)" % ADMIN)
        return 1
    password = new_password()
    status, _ = command(result["token"], "auth/user/update", password=password)
    command(result["token"], "auth/logout")
    if status != 200:
        print("Could not change the password")
        return 1
    write_secret(password_file, password)
    print("gave the admin user (%s) a new password" % ADMIN)
    # (a new page token, in case the change ended the old ones)
    status, result = request("/auth/login", {"credentials": {"username": ADMIN, "password": password},
                                             "device_name": TOKEN_NAME})
    if status == 200 and result and result.get("success"):
        made = make_page_token(data_path, result["token"])
        command(result["token"], "auth/logout")
        return 0 if made else 1
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("setup", "new-password") or not os.path.isdir(sys.argv[2]):
        print(__doc__)
        sys.exit(2)
    sys.exit(setup(sys.argv[2]) if sys.argv[1] == "setup" else change_password(sys.argv[2]))
