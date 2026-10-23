"""Writes copyparty's configuration from the app's settings (settings.json, written by the management page), run as root by
cpp_ctl.sh with the app's own Python:

    python3 cpp_conf.py write <data path> <app path>   - writes <data path>/config/copyparty.conf (hashing new passwords)
    python3 cpp_conf.py default <data path>            - creates settings.json if missing (an admin user, the Public share)

The settings hold each user's password as set (root only: the management page shows them) and its argon2 hash, made here
once per password - only the hashes go into copyparty's configuration
"""
import argparse
import json
import os
import secrets
import socket
import string
import sys

PORT = 3923
SFTP_PORT = 3922
# Access levels (as the management page offers them) -> copyparty's permissions. Everyone without a login can only be
# given read or upload
LEVELS = {"read": "r", "upload": "w", "write": "rw", "full": "rwmd", "admin": "A"}
ANONYMOUS_LEVELS = ("read", "upload")
# argon2id, as copyparty recommends (3 passes, 256MB, 4 lanes)
HASHING = "argon2"


def random_text(length):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def write_private(path, text):
    """Writes a file readable by its owner only, in one step"""
    temp = path + ".tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def load(data_path):
    with open(os.path.join(data_path, "settings.json")) as f:
        return json.load(f)


def save(data_path, settings):
    write_private(os.path.join(data_path, "settings.json"), json.dumps(settings, indent=1) + "\n")


def default(data_path):
    if os.path.exists(os.path.join(data_path, "settings.json")):
        return
    public = "/mnt/HD/HD_a2/Public"
    save(data_path, {
        "users": [{"name": "admin", "password": random_text(20), "hash": ""}],
        "folders": [{"name": "public", "path": public, "access": {"admin": "admin"}}] if os.path.isdir(public) else [],
        "listen": "all",
        "sftp": False,
        "tags": False,
    })


def salt(data_path):
    """copyparty's password salt: made once (passwords are hashed with it, so it never changes)"""
    path = os.path.join(data_path, "password_salt")
    if not os.path.exists(path):
        write_private(path, random_text(24) + "\n")
    with open(path) as f:
        return f.read().strip()


def hasher(data_path):
    from copyparty.pwhash import PWHash
    return PWHash(argparse.Namespace(ah_alg=HASHING, ah_salt=salt(data_path), usernames=True))


def write(data_path, app_path):
    settings = load(data_path)
    # New passwords' hashes (with user names required, copyparty hashes "name:password"); kept in the settings so that
    # each is only made once
    pw = None
    changed = False
    for user in settings["users"]:
        if not user.get("hash"):
            pw = pw or hasher(data_path)
            user["hash"] = pw.hash(user["name"] + ":" + user["password"])
            changed = True
    if changed:
        save(data_path, settings)

    users = {user["name"] for user in settings["users"]}
    lines = [
        "# Written by the copyparty app at every start, from the settings on its management page: changes here are overwritten",
        "[global]",
        "  i: " + ("127.0.0.1" if settings.get("listen") == "local" else "0.0.0.0"),
        "  p: %d" % PORT,
        "  name: " + socket.gethostname(),
        # Logins need a user name and its password; passwords are stored hashed
        "  usernames",
        "  ah-alg: " + HASHING,
        "  ah-salt: " + salt(data_path),
        # Behind the Nginx app (on the NAS itself): the visitor's address is in its X-Real-IP header
        "  xff-hdr: x-real-ip",
        "  rproxy: 1",
        # Its database and thumbnails stay with the app's data, not in the shares
        "  hist: " + os.path.join(data_path, "hist"),
        # Search: every file by name, without reading whole files to hash them (slow on large shares) - except uploads.
        # Changes made elsewhere (e.g. over SMB) are found every 6 hours
        "  e2dsa",
        "  no-hash: .",
        "  re-maxage: 21600",
        # Files it creates are writable by the share group too (as files copied over SMB are)
        "  chmod-f: 664",
        "  chmod-d: 775",
        # Never out of a shared folder through a symbolic link
        "  xvol",
        "  no-crt",
        "  http-only",
        "  log-date: %Y-%m-%d",
        "  log-badpwd: 0",
        "  no-ansi",
    ]
    if settings.get("tags"):
        # Music tags (artist, album, title...): searchable, and shown in its music player
        lines.append("  e2ts")
    if settings.get("sftp"):
        lines += ["  sftp: %d" % SFTP_PORT, "  sftp-pw"]
        if settings.get("listen") == "local":
            lines.append("  sftp-i: 127.0.0.1")

    lines += ["", "[accounts]"]
    lines += ["  %s: %s" % (user["name"], user["hash"]) for user in settings["users"]]

    shared = False
    for folder in settings["folders"]:
        by_permission = {}
        # (the management page's PHP writes no one's access as [])
        access = folder.get("access") or {}
        for name, level in sorted(access.items() if isinstance(access, dict) else []):
            if level not in LEVELS or (name == "*" and level not in ANONYMOUS_LEVELS) or (name != "*" and name not in users):
                continue
            by_permission.setdefault(LEVELS[level], []).append(name)
        # (a folder no one may use isn't shared at all)
        if not by_permission:
            continue
        lines += ["", "[/%s]" % folder["name"], "  " + folder["path"], "  accs:"]
        for permission, names in sorted(by_permission.items()):
            lines.append("    %s: %s" % (permission, ", ".join(names)))
        shared = True
    if not shared:
        # Nothing shared: an empty folder, so that copyparty doesn't share its own working folder with everyone (what it
        # does with no folders at all)
        empty = os.path.join(data_path, "empty")
        os.makedirs(empty, exist_ok=True)
        lines += ["", "[/]", "  " + empty, "  accs:", "    g: " + ", ".join(sorted(users))]

    os.makedirs(os.path.join(data_path, "config"), exist_ok=True)
    write_private(os.path.join(data_path, "config", "copyparty.conf"), "\n".join(lines) + "\n")


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "default":
        default(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "write":
        write(sys.argv[2], sys.argv[3])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
