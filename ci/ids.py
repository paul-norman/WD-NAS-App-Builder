"""
The user and group IDs the apps give their own users (each app's control
script creates them on the NAS with BusyBox's adduser / addgroup), checked
against the list in apps/README.md (User and group IDs) - so that no two apps,
nor an app and the NAS itself, ever share one.

    python3 ci/ids.py check
    python3 ci/ids.py list
    python3 ci/ids.py next

check: every app's IDs are its own (no other app's, none reserved, in the
ranges apps use), and the README's list says exactly what the apps' scripts
do (CI's plan job runs this). list: each app's IDs, from its scripts. next:
the ID a new app should take (the highest free one, 51-99 first).
"""

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
README = REPO / "apps" / "README.md"

# The ranges apps take their IDs from, in turn (each counting down from its
# top). 51-99: lower ones are the systems' own (e.g. Debian's staff group is
# 50), 100 is users. 400-499, once that was full: clear of WD's own accounts
# (admin 500, nobody 501, the NAS's users and their groups from 1000, WD's
# services' groups counting down from 999 - restsdk 990), checked on a NAS
RANGES = ((51, 99), (400, 499))


def in_ranges(number):
    """
    Whether an ID is in one of the ranges apps take theirs from.

    :param number: The ID
    :return: True if it is
    """
    return any(low <= number <= high for low, high in RANGES)


def ranges_text():
    """
    The ranges apps take their IDs from, for messages.

    :return: e.g. "51-99 and 400-499"
    """
    return " and ".join(f"{low}-{high}" for low, high in RANGES)


def app_ids():
    """
    Each app's IDs, from the adduser / addgroup lines in its shell scripts
    (with the variables they use resolved).

    :return: A dict of app: {"ids": set of int, "users": set of str}
    """
    found = {}

    for folder in sorted((REPO / "apps").iterdir()):
        files = sorted(folder.glob("*.sh")) + sorted(folder.glob("lib/*.sh"))
        text = "\n".join(f.read_text(encoding="utf-8") for f in files)
        values = dict(
            re.findall(
                r"^\s*([A-Z_]+)=[\"']?([A-Za-z0-9_-]+)[\"']?\s*$",
                text,
                re.M,
            )
        )
        values["APP_NAME"] = folder.name
        ids = set()
        users = set()

        for line in text.splitlines():
            if line.lstrip().startswith("#"):
                continue

            for command, flag in (("adduser", "-u"), ("addgroup", "-g")):
                match = re.search(
                    rf"\b{command}\b.*?\s{flag}\s+\$?\{{?(\w+)\}}?(.*)$", line
                )

                if not match:
                    continue

                value = values.get(match.group(1), match.group(1))

                if not value.isdigit():
                    raise SystemExit(
                        f"{folder.name}: can't tell the ID in: {line.strip()}"
                    )

                ids.add(int(value))
                name = match.group(2).split()[-1].strip("\"'")
                name = re.sub(
                    r"^\$\{?(\w+)\}?$",
                    lambda m: values.get(m.group(1), m.group(0)),
                    name,
                )

                if command == "adduser":
                    users.add(name)

        if ids:
            found[folder.name] = {"ids": ids, "users": users}

    return found


def listed():
    """
    The README's list of IDs: its table's rows (ID, who has it).

    :return: A tuple: a dict of app: set of int, and a dict of reserved
             ID: its reason
    """
    text = README.read_text(encoding="utf-8")
    section = text.split("## User and group IDs", 1)

    if len(section) < 2:
        raise SystemExit(f"{README}: no 'User and group IDs' section")

    apps = {}
    reserved = {}

    for line in section[1].split("\n## ", 1)[0].splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]

        if len(cells) < 2 or not cells[0].isdigit():
            continue

        match = re.match(r"\[`([\w.-]+)`\]", cells[1])

        if match:
            apps.setdefault(match.group(1), set()).add(int(cells[0]))
        else:
            reserved[int(cells[0])] = cells[1]

    return apps, reserved


def check():
    """
    Checks the apps' IDs: each its own, none reserved, in the range apps use,
    and the README's list matching the scripts.

    :return: A list of problems (none if all is well)
    """
    problems = []
    found = app_ids()
    table, reserved = listed()
    owners = {}

    for app, info in found.items():
        for number in sorted(info["ids"]):
            owners.setdefault(number, []).append(app)

            if number in reserved:
                problems.append(
                    f"{app}: its ID {number} is reserved ({reserved[number]})"
                    " - take the one 'python3 ci/ids.py next' gives"
                )

            if not in_ranges(number):
                problems.append(
                    f"{app}: its ID {number} is outside {ranges_text()}"
                )

        if table.get(app) != info["ids"]:
            ids = ", ".join(str(n) for n in sorted(info["ids"]))
            listed_ids = ", ".join(str(n) for n in sorted(table.get(app, [])))
            problems.append(
                f"{app}: its scripts use ID {ids}, but apps/README.md (User"
                f" and group IDs) lists {listed_ids or 'none'}"
            )

    for number, apps in sorted(owners.items()):
        if len(apps) > 1:
            problems.append(
                f"ID {number} is used by more than one app: {', '.join(apps)}"
            )

    for app in sorted(set(table) - set(found)):
        problems.append(
            f"{app}: listed in apps/README.md (User and group IDs), but no"
            " app of that name creates a user"
        )

    return problems


def next_free():
    """
    The ID a new app should take: the highest one in the first range with one
    left that no app uses and that isn't reserved.

    :return: The ID, or None if there's none left
    """
    used = {n for info in app_ids().values() for n in info["ids"]}
    used |= set(listed()[1])

    for low, high in RANGES:
        for number in range(high, low - 1, -1):
            if number not in used:
                return number


    return None


def main():
    """
    Runs the command given (check, list or next).
    """
    command = sys.argv[1] if len(sys.argv) > 1 else "check"

    if command == "check":
        problems = check()

        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)

        sys.exit(1 if problems else 0)

    if command == "list":
        for app, info in sorted(
            app_ids().items(), key=lambda item: -max(item[1]["ids"])
        ):
            ids = "/".join(str(n) for n in sorted(info["ids"]))
            print(f"{ids:>6}  {app}  ({', '.join(sorted(info['users']))})")

        return

    if command == "next":
        number = next_free()

        if number is None:
            sys.exit(f"No free ID left in {ranges_text()}")

        print(number)

        return

    sys.exit("Usage: ci/ids.py check | list | next")


if __name__ == "__main__":
    main()
