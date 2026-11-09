"""
The daily update check (see README.md, Updates): compares each app with its
upstream releases (ci/updates.conf) and brings one up to date:

    python3 ci/updates.py check [--json] [<target> ...]
    python3 ci/updates.py apply <target> <version>
    python3 ci/updates.py run [--limit <n>]

check: each target's current version, the newest upstream one it may move
to, and what an update to it would be - patch, minor or major, its release
date, whether its notes mention a security fix, whether it may be merged by
itself (see policy()). Prints a table, or JSON with --json (for the
workflow).

apply: makes the update in the working tree - the version in the app's
apkg.rc (its packaging revision dropped: a new upstream version starts
again) and its static build, the other values its line sets, a new SHA256
for every download whose address uses a value that changed (downloaded and
hashed - the static builds check them), the old version in the app's test
suite, and its lock file removed (its static build writes it again: the
workflow runs it). Prints what it changed, and "lock" if a static build is
needed.

run: the workflow's work - a pull request per update, auto-merge where the
policy allows, stale update pull requests closed (see run()).

Network access: GitHub through gh (GH_TOKEN), the rest over HTTPS.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "ci"))

import plan  # noqa: E402

CONF = REPO / "ci" / "updates.conf"
USER_AGENT = "wd-nas-app-builder-updates/1.0"
# An update merges by itself only once its release is this many hours old
# (unless it's a security fix): time for upstream to withdraw a bad one
WAIT_HOURS = 24
SECURITY = re.compile(r"\bCVE-\d{4}-\d+|\bGHSA-|\bsecurity\b", re.IGNORECASE)
PRERELEASE = re.compile(r"(alpha|beta|rc|dev|pre|preview|nightly|canary)",
                        re.IGNORECASE)


def load_conf():
    """
    The update check's settings: one line per target (an app), with its
    feed, its source and its options (key=value).

    :return: The targets by name: {"feed", "source", "options"}
    """
    targets = {}

    for line in CONF.read_text().splitlines():
        line = line.strip()

        if not line or line.startswith("#"):
            continue

        name, feed, source, *rest = line.split()
        options = {}

        for item in rest:
            key, _, value = item.partition("=")
            options[key] = value

        targets[name] = {"feed": feed, "source": source, "options": options}

    return targets


def http_json(url):
    """
    Fetches a JSON document over HTTPS.

    :param str url: Its address

    :return: The document
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def gh_json(path):
    """
    Fetches one of GitHub's API documents with gh (authenticated: more
    requests allowed).

    :param str path: Its path (e.g. repos/owner/repo/releases)

    :return: The document
    """
    output = subprocess.run(
        ["gh", "api", path], check=True, capture_output=True, text=True
    ).stdout

    return json.loads(output)


def parse_date(text):
    """
    A release date, from the various forms feeds give.

    :param str text: The date (ISO 8601, possibly with Z), or empty

    :return: The date (UTC), or None
    """
    if not text:
        return None

    text = text.replace("Z", "+00:00")
    date = datetime.datetime.fromisoformat(text)

    if date.tzinfo is None:
        date = date.replace(tzinfo=datetime.timezone.utc)

    return date


def releases(target):
    """
    A target's upstream releases (stable ones only): what its feed lists.

    :param dict target: The target's settings

    :return: A list of {"name", "date", "url", "notes"} (name: the tag or
             version as published)
    """
    feed, source = target["feed"], target["source"]
    found = []

    if feed == "github":
        for release in gh_json(f"repos/{source}/releases?per_page=40"):
            if release["draft"] or release["prerelease"]:
                continue

            found.append({
                "name": release["tag_name"],
                "date": parse_date(release["published_at"]),
                "url": release["html_url"],
                "notes": release["body"] or "",
            })
    elif feed == "tags":
        url = source if "://" in source else f"https://github.com/{source}"
        output = subprocess.run(
            ["git", "ls-remote", "--tags", "--refs", url],
            check=True, capture_output=True, text=True,
        ).stdout

        for line in output.splitlines():
            found.append({
                "name": line.split("refs/tags/", 1)[1],
                "date": None,
                "url": url,
                "notes": "",
            })
    elif feed == "pypi":
        data = http_json(f"https://pypi.org/pypi/{source}/json")

        for version, files in data["releases"].items():
            if not files or all(file.get("yanked") for file in files):
                continue

            found.append({
                "name": version,
                "date": parse_date(files[0].get("upload_time_iso_8601")),
                "url": f"https://pypi.org/project/{source}/{version}/",
                "notes": "",
            })
    elif feed == "npm":
        data = http_json(f"https://registry.npmjs.org/{source}")

        for version in data["versions"]:
            found.append({
                "name": version,
                "date": parse_date(data["time"].get(version)),
                "url": f"https://www.npmjs.com/package/{source}/v/{version}",
                "notes": "",
            })
    elif feed == "listing":
        # A download folder's page: every file name its pattern matches
        request = urllib.request.Request(
            source, headers={"User-Agent": USER_AGENT}
        )

        with urllib.request.urlopen(request, timeout=60) as response:
            page = response.read().decode("utf-8", errors="replace")

        pattern = re.compile(target["options"]["match"].strip("^$"))

        for name in sorted({match.group(0)
                            for match in pattern.finditer(page)}):
            found.append({"name": name, "date": None, "url": source,
                          "notes": ""})
    elif feed == "nodejs":
        for release in http_json("https://nodejs.org/dist/index.json"):
            found.append({
                "name": release["version"],
                "date": parse_date(release["date"]),
                "url": "https://nodejs.org/en/blog/release/"
                + release["version"],
                "notes": "security" if release.get("security") else "",
            })
    else:
        raise ValueError(f"Unknown feed: {feed}")

    return found


def candidates(target):
    """
    The versions a target may move to: its releases whose name matches its
    pattern (stable ones), on its line if it has one.

    :param dict target: The target's settings

    :return: A list of releases, each with "version" and "groups" added
    """
    options = target["options"]
    pattern = re.compile(options.get("match", r"^v?(\d+(?:\.\d+)+)$"))
    shape = options.get("version", "{1}")
    line = options.get("line", "")
    found = []

    for release in releases(target):
        match = pattern.match(release["name"])

        if not match or PRERELEASE.search(release["name"]):
            continue

        groups = ("",) + match.groups()
        version = shape.format(*groups)

        if line and version != line and not version.startswith(line + "."):
            continue

        found.append(dict(release, version=version, groups=groups))

    return found


def current_version(name):
    """
    An app's current upstream version: its apkg.rc's, without its packaging
    revision.

    :param str name: The app

    :return: The version
    """
    text = (REPO / "apps" / name / "apkg.rc").read_text()
    version = plan.read_rc_version(text)

    return re.sub(r"-\d+$", "", version)


def kind(old, new):
    """
    What an update is: major (its first number changes - or its second, for
    a 0.x version), minor (its second) or patch (anything less).

    :param str old: The current version
    :param str new: The new one

    :return: major, minor or patch
    """
    old_parts = re.split(r"[.\-+]", old)
    new_parts = re.split(r"[.\-+]", new)

    if old_parts[0] != new_parts[0]:
        return "major"

    if len(old_parts) > 1 and len(new_parts) > 1:
        if old_parts[1] != new_parts[1]:
            return "major" if old_parts[0] == "0" else "minor"

    return "patch"


def tested(name):
    """
    Whether an app is tested beyond the shared package test (Tier 2): by a
    suite of its own, or one that installs it with others (e.g. Prometheus,
    in the monitoring apps' suite) - only those merge by themselves.

    :param str name: The app

    :return: True if it is
    """
    suites = plan.suites()

    return name in suites or any(
        name in needs for lines in suites.values() for needs, _ in lines
    )


def policy(name, target, update):
    """
    Whether an update may merge by itself once CI passes: a patch or minor
    one, of an app with a test suite of its own that isn't always reviewed by
    hand (manual=yes in updates.conf), whose release is WAIT_HOURS old - or
    a security fix. A release without a date counts from when its pull request
    was opened (the workflow checks that).

    :param str  name:   The app
    :param dict target: Its settings
    :param dict update: The update (kind, date, security)

    :return: (decision, reason): decision is yes, no or wait
    """
    if target["options"].get("manual") == "yes":
        return "no", "always reviewed by hand (updates.conf)"

    if update["kind"] == "major":
        return "no", "a major version"

    if not tested(name):
        return "no", "no test suite of its own"

    if update["security"]:
        return "yes", "a security fix"

    if update["date"] is None:
        return "wait", f"{WAIT_HOURS} hours after its pull request was opened"

    hours = hours_since(update["date"])

    if hours < WAIT_HOURS:
        return "wait", f"its release is {hours} hour(s) old"

    return "yes", f"a {update['kind']} update, released {hours} hours ago"


def hours_since(date):
    """
    How long ago something happened, in whole hours.

    :param datetime.datetime date: When (UTC)

    :return: The hours
    """
    age = datetime.datetime.now(datetime.timezone.utc) - date

    return int(age.total_seconds() // 3600)


def check(names):
    """
    Each target's update, if it has one.

    :param list names: The targets (all if empty)

    :return: A list of updates (dicts), and a list of problems (text)
    """
    targets = load_conf()
    updates = []
    problems = []

    for name in names or sorted(targets):
        target = targets[name]

        if target["feed"] == "none":
            continue

        try:
            current = current_version(name)
            found = candidates(target)
        except (OSError, subprocess.CalledProcessError, ValueError,
                KeyError) as error:
            problems.append(f"{name}: {error}")
            continue

        if not found:
            problems.append(f"{name}: no releases found upstream")
            continue

        newest = max(found, key=lambda item: plan.version_key(item["version"]))

        if plan.version_key(newest["version"]) < plan.version_key(current):
            problems.append(
                f"{name}: upstream's newest ({newest['version']}) is older "
                f"than {current} - is its feed right?"
            )
            continue

        if newest["version"] == current:
            continue

        update = {
            "target": name,
            "current": current,
            "version": newest["version"],
            "kind": kind(current, newest["version"]),
            "date": newest["date"],
            "url": newest["url"],
            "security": bool(SECURITY.search(newest["notes"])),
            "lock": bool(lock_file(name)),
        }
        update["auto"], update["reason"] = policy(name, target, update)
        updates.append(update)

    return updates, problems


def lock_file(name):
    """
    An app's lock file (its static build's packages, each version with its
    checksum), if its static build keeps one.

    :param str name: The app

    :return: Its path, or None
    """
    script = REPO / "static" / name / "build.sh"

    if not script.is_file():
        return None

    match = re.search(r"^LOCK=/data/(\S+)", script.read_text(), re.M)

    return REPO / match.group(1) if match else None


def set_variable(path, variable, value):
    """
    Sets a shell variable's value where a build script assigns it (VAR=...,
    at the start of a line).

    :param pathlib.Path path:     The script
    :param str          variable: The variable (e.g. VERSION, or
                                  NODE_SHA256[x64])
    :param str          value:    Its new value

    :return: True if it was there
    """
    text = path.read_text()
    pattern = re.compile(rf"^({re.escape(variable)}=)\S*$", re.M)

    if not pattern.search(text):
        return False

    path.write_text(pattern.sub(lambda match: match.group(1) + value, text))

    return True


def assignments(text):
    """
    A build script's plain assignments (VAR=value, no commands), as shell
    lines - to work out its download addresses.

    :param str text: The script

    :return: The lines
    """
    return [
        line for line in text.splitlines()
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=[^ ;&|`$(]*$", line)
    ]


def expand(text, template):
    """
    A download address, as the build script would make it.

    :param str text:     The build script
    :param str template: The address, with its variables (e.g.
                         https://.../v${VERSION}/...)

    :return: The address
    """
    script = "\n".join(assignments(text) + [f'printf "%s" "{template}"'])

    return subprocess.run(
        ["bash", "-c", script], check=True, capture_output=True, text=True
    ).stdout


def downloads(text):
    """
    A static build's downloads: each fetch (or fetch.sh) call's address and
    the variable holding its SHA256.

    :param str text: The build script

    :return: A list of (address template, SHA256 variable)
    """
    found = []
    joined = text.replace("\\\n", " ")

    for line in joined.splitlines():
        line = line.strip()

        if not re.match(r"^(fetch|sh /data/static/fetch\.sh) ", line):
            continue

        url = re.search(r'"(https?://[^"]+)"', line)
        sha = re.search(r"\$\{([A-Z0-9_]+SHA256)\}", line)

        if url and sha:
            found.append((url.group(1), sha.group(1)))

    return found


def sha256_of(url):
    """
    Downloads a file and hashes it.

    :param str url: Its address

    :return: Its SHA256 (hex)
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()

    with urllib.request.urlopen(request, timeout=600) as response:
        while True:
            block = response.read(1 << 20)

            if not block:
                break

            digest.update(block)

    return digest.hexdigest()


def wheel_sha256(package, version):
    """
    A PyPI package's wheel's SHA256, as PyPI publishes it.

    :param str package: The package
    :param str version: Its version

    :return: The SHA256 (hex)

    :raises ValueError: When the version has no wheel for any platform
    """
    data = http_json(f"https://pypi.org/pypi/{package}/{version}/json")

    for file in data["urls"]:
        if file["packagetype"] == "bdist_wheel" and file["filename"].endswith(
                "-none-any.whl"):
            return file["digests"]["sha256"]

    raise ValueError(f"{package} {version} has no wheel for any platform")


def set_apkg_version(name, version):
    """
    Sets an app's version in its apkg.rc (its tab-aligned Version line), with
    no packaging revision.

    :param str name:    The app
    :param str version: The version
    """
    path = REPO / "apps" / name / "apkg.rc"
    text = path.read_text()
    path.write_text(
        re.sub(r"^(Version:\s*)\S+$", lambda m: m.group(1) + version, text,
               count=1, flags=re.M)
    )


def apply(name, version):
    """
    Updates an app to a version in the working tree (see the module's
    description).

    :param str name:    The app
    :param str version: The version (one check() offered)

    :return: The files changed, and whether its lock file was removed
    """
    targets = load_conf()
    target = targets[name]
    options = target["options"]
    old = current_version(name)
    release = next(
        (item for item in candidates(target) if item["version"] == version),
        None,
    )

    if release is None:
        raise ValueError(f"{name}: {version} isn't one of its releases")

    changed = set()
    set_apkg_version(name, version)
    changed.add(f"apps/{name}/apkg.rc")
    values = {}

    if options.get("static", "yes") == "yes":
        values["VERSION"] = version

    # Other values its version sets (e.g. OpenSSH's 10.6p2 next to 10.6.2)
    for key, shape in options.items():
        if key.startswith("set."):
            values[key[4:]] = shape.format(*release["groups"])

    scripts = [
        path for path in (REPO / "static" / name / "build.sh",
                          REPO / "apps" / name / "build.sh")
        if path.is_file()
    ]

    for path in scripts:
        for variable, value in values.items():
            if set_variable(path, variable, value):
                changed.add(str(path.relative_to(REPO)))

    # The checksums of the downloads whose addresses changed
    for path in scripts:
        text = path.read_text()

        for template, sha_variable in downloads(text):
            uses = re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", template)

            if not any(variable in values for variable in uses):
                continue

            url = expand(text, template)
            set_variable(path, sha_variable, sha256_of(url))
            changed.add(str(path.relative_to(REPO)))

        # Its wheel's checksum, as PyPI publishes it (wheel=<VAR>)
        if "wheel" in options:
            if set_variable(path, options["wheel"],
                            wheel_sha256(target["source"], version)):
                changed.add(str(path.relative_to(REPO)))

        # Pins the app's own build checks (pin.<VAR>=<address with
        # {version}>)
        for key, url in options.items():
            if key.startswith("pin."):
                if set_variable(path, key[4:], sha256_of(
                        url.replace("{version}", version))):
                    changed.add(str(path.relative_to(REPO)))

    # The old version in its test suite (where it checks what it runs)
    pattern = re.compile(rf"(?<![0-9.]){re.escape(old)}(?![0-9])")

    for path in sorted((REPO / "tests" / name).glob("**/*")):
        if path.is_file():
            text = path.read_text(errors="replace")

            if pattern.search(text):
                path.write_text(pattern.sub(version, text))
                changed.add(str(path.relative_to(REPO)))

    lock = lock_file(name)

    if lock and lock.is_file():
        lock.unlink()
        changed.add(str(lock.relative_to(REPO)))

    return sorted(changed), bool(lock)


def git(*args):
    """
    Runs git in the repository.

    :param str args: Its arguments

    :return: Its output
    """
    return subprocess.run(
        ["git", *args], cwd=REPO, check=True, capture_output=True, text=True
    ).stdout.strip()


def gh(*args):
    """
    Runs gh in the repository (GH_TOKEN: the bot's, so that its pull
    requests run CI).

    :param str args: Its arguments

    :return: Its output
    """
    return subprocess.run(
        ["gh", *args], cwd=REPO, check=True, capture_output=True, text=True
    ).stdout.strip()


def pr_body(update, decision, reason):
    """
    An update's pull request description.

    :param dict update:   The update
    :param str  decision: Whether it merges by itself (yes, no, wait)
    :param str  reason:   Why

    :return: The description (Markdown)
    """
    date = update["date"]
    released = date.strftime("%Y-%m-%d") if date else "not given"
    merge = {
        "yes": "Merged by the update check once CI passes",
        "wait": "Merged by the update check once CI passes and it's old "
        "enough",
        "no": "Waits for you to review and merge it",
    }[decision]

    return "\n".join([
        f"**{update['target']}**: {update['current']} → "
        f"**{update['version']}** ({update['kind']} update"
        f"{', security fix' if update['security'] else ''})",
        "",
        f"- Released: {released} - [release notes]({update['url']})",
        f"- {merge}: {reason}.",
        "- Made by the daily update check (`ci/updates.py`, settings in "
        "`ci/updates.conf`). A newer release replaces this pull request's "
        "changes.",
    ])


def labels_for(update, decision):
    """
    An update's pull request labels.

    :param dict update:   The update
    :param str  decision: Whether it merges by itself (yes, no, wait)

    :return: The labels
    """
    labels = ["automatic update"]

    if update["security"]:
        labels.append("security")

    if decision == "no":
        labels.append("review needed")

    return labels


LABELS = {
    "automatic update": ("0e8a16", "Made by the daily update check"),
    "security": ("d93f0b", "A security fix"),
    "review needed": ("fbca04", "An update that doesn't merge by itself"),
}


def run(limit):
    """
    The update check's work, in CI (see README.md, Updates): a pull request
    per update (branch update/<app>, replaced by a newer release, and made
    again from main when it conflicts with it), merged where the policy
    allows once CI has passed; update pull requests no longer needed (the
    app updated another way) closed.

    :param int limit: At most this many pull requests made or changed

    :return: The problems found (text)
    """
    updates, problems = check([])

    for name, (colour, text) in LABELS.items():
        gh("label", "create", name, "--color", colour, "--description", text,
           "--force")

    open_prs = {
        pr["headRefName"]: pr
        for pr in json.loads(gh(
            "pr", "list", "--state", "open", "--label", "automatic update",
            "--json", "number,headRefName,title,createdAt", "--limit", "200",
        ))
    }
    wanted = {f"update/{update['target']}" for update in updates}

    for branch, pr in open_prs.items():
        if branch not in wanted:
            gh("pr", "close", str(pr["number"]), "--delete-branch",
               "--comment", "No longer needed: the app is up to date.")

    touched = 0

    for update in updates:
        name, version = update["target"], update["version"]
        branch = f"update/{name}"
        title = f"Update {name} to {version}"
        decision, reason = update["auto"], update["reason"]
        pr = open_prs.get(branch)
        # Its pull request made again from main when main has changed the
        # same lines since (e.g. the app's packaging revision raised by hand):
        # it can't be merged as it is, and would wait for ever
        conflicting = (
            pr is not None
            and pr["title"] == title
            and pr_state(pr["number"]).get("mergeable") == "CONFLICTING"
        )

        if conflicting:
            print(f"{name} {version}: #{pr['number']} conflicts with main -"
                  " made again from it")

        if pr is None or pr["title"] != title or conflicting:
            if touched >= limit:
                continue

            touched += 1
            git("checkout", "-B", branch, "origin/main")

            try:
                changed, lock = apply(name, version)

                # Its lock file, written again by its static build
                if lock:
                    subprocess.run(
                        ["./build_static.sh", name, "amd64"], cwd=REPO,
                        check=True,
                    )
                    changed.append(str(lock_file(name).relative_to(REPO)))
            except (OSError, subprocess.CalledProcessError,
                    ValueError) as error:
                problems.append(f"{name} {version}: {error}")
                git("checkout", "-f", "origin/main")
                continue

            git("add", "--all", "--", *changed)
            git("commit", "-m", f"{title}\n\n{update['url']}")
            git("push", "--force", "origin", branch)
            body = pr_body(update, decision, reason)

            if pr is None:
                gh("pr", "create", "--base", "main", "--head", branch,
                   "--title", title, "--body", body,
                   *[arg for label in labels_for(update, decision)
                     for arg in ("--label", label)])
                pr = json.loads(gh("pr", "view", branch, "--json",
                                   "number,createdAt"))
            else:
                gh("pr", "edit", str(pr["number"]), "--title", title,
                   "--body", body,
                   *[arg for label in labels_for(update, decision)
                     for arg in ("--add-label", label)])

            git("checkout", "-f", "origin/main")

        # A release without a date: counted from its pull request
        if decision == "wait" and update["date"] is None:
            if hours_since(parse_date(pr["createdAt"])) >= WAIT_HOURS:
                decision = "yes"

        if decision != "yes":
            print(f"{name} {version}: not merged ({reason})")
            continue

        passed, why = ci_passed(pr["number"])

        if passed:
            gh("pr", "merge", str(pr["number"]), "--squash",
               "--delete-branch")
            print(f"{name} {version}: merged (#{pr['number']})")
        else:
            print(f"{name} {version}: not merged yet (#{pr['number']}: {why})")

    return problems


def pr_state(number):
    """
    A pull request's checks and whether it can be merged. GitHub works out
    whether a pull request can be merged only when it's asked (UNKNOWN until
    then - e.g. the first time after main has changed), so an UNKNOWN answer
    is asked again, for up to a minute.

    :param int number: The pull request

    :return: Its statusCheckRollup and mergeable (MERGEABLE, CONFLICTING or
             UNKNOWN), as gh gives them
    """
    for _ in range(12):
        checks = json.loads(gh(
            "pr", "view", str(number), "--json", "statusCheckRollup,mergeable"
        ))

        if checks.get("mergeable") != "UNKNOWN":
            break

        time.sleep(5)

    return checks


def ci_passed(number):
    """
    Whether a pull request's required check (build-test-release's result
    job) has passed on its latest changes. The bot may bypass the branch's
    rules, so GitHub's own auto-merge isn't used: it merges itself, only
    then.

    :param int number: The pull request

    :return: (passed, why not): passed is True if it has
    """
    checks = pr_state(number)

    if checks.get("mergeable") != "MERGEABLE":
        return False, f"GitHub says: {checks.get('mergeable')}"

    result = [
        check.get("conclusion") or check.get("status") or "?"
        for check in checks["statusCheckRollup"]
        if check.get("name") == "result"
    ]

    if "SUCCESS" in result:
        return True, ""

    return False, f"CI's result: {', '.join(result) or 'not run yet'}"


def main():
    """
    Runs the command the command line names.
    """
    parser = argparse.ArgumentParser(description="The daily update check")
    steps = parser.add_subparsers(dest="step", required=True)
    step = steps.add_parser("check")
    step.add_argument("--json", action="store_true")
    step.add_argument("targets", nargs="*")
    step = steps.add_parser("run")
    step.add_argument("--limit", type=int, default=10)
    step = steps.add_parser("apply")
    step.add_argument("target")
    step.add_argument("version")
    args = parser.parse_args()

    if args.step == "check":
        updates, problems = check(args.targets)

        if args.json:
            for update in updates:
                date = update["date"]
                update["date"] = date.isoformat() if date else None

            print(json.dumps({"updates": updates, "problems": problems},
                             indent=2))
        else:
            for update in updates:
                print(f"{update['target']}: {update['current']} -> "
                      f"{update['version']} ({update['kind']}"
                      f"{', security' if update['security'] else ''}) "
                      f"auto merge: {update['auto']} - {update['reason']}")

            for problem in problems:
                print(f"PROBLEM {problem}")
    elif args.step == "run":
        problems = run(args.limit)

        for problem in problems:
            print(f"PROBLEM {problem}")
    else:
        changed, lock = apply(args.target, args.version)

        for path in changed:
            print(path)

        if lock:
            print("lock")


if __name__ == "__main__":
    main()
