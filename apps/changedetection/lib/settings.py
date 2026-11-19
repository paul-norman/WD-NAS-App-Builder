"""
changedetection.io's settings that the app manages, run by
changedetection_ctl.sh as root (with the app's own Python, written for 3.9
like the project's other NAS code) while changedetection.io is stopped:

    settings.py salted <password file>
        prints the password as changedetection.io's SALTED_PASS expects it
    settings.py notify <changedetection.json> <url>
        makes <url> the app's own alert address (the ntfy app's topic) among
        changedetection.io's alert addresses, or removes it if <url> is empty

The app's alert address is told apart from the ones added in
changedetection.io by the ntfy app's address on the NAS itself
(127.0.0.1:2586).
"""
import base64
import hashlib
import json
import os
import sys

# The ntfy app's address on the NAS itself: an alert address holding it is
# the app's own
NTFY_ADDRESS = "@127.0.0.1:2586/"


def salted(password_file):
    """
    Prints a password as changedetection.io keeps it: base64 of a new 32-byte
    salt and the PBKDF2-SHA256 key (100,000 rounds) - what its SALTED_PASS
    setting holds.

    :param str password_file: The file holding the password (its first line)

    :return: 0 once printed, 1 if the file is empty
    """
    with open(password_file, encoding="utf-8") as handle:
        password = handle.readline().rstrip("\n")

    if not password:
        return 1

    salt = os.urandom(32)
    key = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, 100000
    )
    print(base64.b64encode(salt + key).decode("ascii"))

    return 0


def is_ours(url):
    """
    Whether an alert address is the app's own (the ntfy app's, on the NAS).

    :param str url: The address

    :return: True if it is
    """
    return url.startswith("ntfy://") and NTFY_ADDRESS in url


def notify(settings_file, url):
    """
    Puts the app's own alert address among changedetection.io's alert
    addresses (in place of an earlier one), or removes it - keeping the
    file's owner and mode. Nothing happens before changedetection.io's first
    start (no file yet).

    :param str settings_file: changedetection.io's settings (its datastore's
                              changedetection.json)
    :param str url:           The address (Apprise's ntfy:// form), or "" to
                              remove it

    :return: 0 once done, 1 if the file isn't changedetection.io's settings
    """
    if not os.path.isfile(settings_file):
        return 0

    with open(settings_file, encoding="utf-8") as handle:
        data = json.load(handle)

    try:
        application = data["settings"]["application"]
    except (KeyError, TypeError):
        return 1

    before = application.get("notification_urls") or []
    urls = [each for each in before if not is_ours(each)]

    if url:
        urls.append(url)

    if urls == before:
        return 0

    application["notification_urls"] = urls
    status = os.stat(settings_file)
    temporary = f"{settings_file}.app"

    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)

    os.chown(temporary, status.st_uid, status.st_gid)
    os.chmod(temporary, status.st_mode & 0o777)
    os.replace(temporary, settings_file)

    return 0


def main():
    """
    Runs the command given (see the module's description).

    :return: The exit code
    """
    if len(sys.argv) == 3 and sys.argv[1] == "salted":
        return salted(sys.argv[2])

    if len(sys.argv) == 4 and sys.argv[1] == "notify":
        return notify(sys.argv[2], sys.argv[3])

    print(__doc__.strip(), file=sys.stderr)

    return 2


if __name__ == "__main__":
    sys.exit(main())
