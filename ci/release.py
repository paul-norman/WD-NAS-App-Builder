"""
The release steps of the build-test-release workflow (see README.md), with
gh (GH_TOKEN):

    python3 ci/release.py publish <dist folder>
    python3 ci/release.py index --previous store.json --output released.json
    python3 ci/release.py cleanup --store store.json [--apply]

publish: a release for each app in the folder (release-<app>/: its packages,
its amd64 bundle and its version - ci/job.sh's output) whose version isn't
released yet, tagged <app>-v<version>, with a SHA256SUMS file; the packages
are then moved into packages/<app>/<version>/ for build_store.py.

index: the released packages of the apps that build_store.py can't find
elsewhere (not in packages/, nor in the published store.json at that
version), from their releases' SHA256SUMS - for its --released.

cleanup: deletes the releases no longer needed - each app keeps its newest
two, and any whose replacement is less than 14 days old, and never one
store.json uses - and the build cache's assets no static build uses any more.
Only prints what it would delete, without --apply. Git tags are kept.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "ci"))

import plan  # noqa: E402

CACHE_RELEASE = "build-cache"
KEEP_RELEASES = 2
KEEP_DAYS = 14


def gh(*args, capture=True):
    """
    Runs gh.

    :param str  args:    Its arguments
    :param bool capture: Return what it printed (else it's shown)

    :return: What it printed (or "")
    """
    result = subprocess.run(
        ["gh", *args],
        cwd=REPO,
        check=True,
        capture_output=capture,
        text=True,
    )

    return result.stdout if capture else ""


def sha256(path):
    """
    The SHA256 of a file.

    :param pathlib.Path path: The file

    :return: Its SHA256, in hex
    """
    digest = hashlib.sha256()

    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)

    return digest.hexdigest()


def release_exists(tag):
    """
    Whether a release exists.

    :param str tag: Its tag

    :return: True if it does
    """
    result = subprocess.run(
        ["gh", "release", "view", tag], cwd=REPO, capture_output=True
    )

    return result.returncode == 0


def release_notes(app, version):
    """
    A release's notes: the app, where it comes from, and the changes to it
    since its previous release.

    :param str app:     The app's id
    :param str version: Its version

    :return: The notes (Markdown)
    """
    rc = (REPO / "apps" / app / "apkg.rc").read_text(encoding="utf-8")
    fields = dict(re.findall(r"^([A-Za-z]+):\s*(.*?)\s*$", rc, re.MULTILINE))
    tags = [
        tag
        for tag in plan.git("tag", "--list", f"{app}-v*").splitlines()
        if tag != f"{app}-v{version}"
    ]
    tags.sort(key=lambda tag: plan.version_key(tag[len(app) + 2:]))
    lines = [fields.get("Description", ""), ""]

    if fields.get("Homepage"):
        lines += [f"Homepage: {fields['Homepage']}", ""]

    lines += [
        "Install it from the Store app, or with the package for your model"
        " (the dashboard's Apps page, manual install). The amd64 bundle is"
        " the packages' contents, for the tests.",
        "",
        f"Sources: `{app}_{version}_SOURCES.md` lists the sources of what"
        f" the packages contain (and where they come from), which are in"
        f" `{app}_{version}_sources.tar`, with the files that built them.",
        "",
    ]
    paths = [f"apps/{app}", f"static/{app}"]

    if tags:
        log = plan.git(
            "log", "--format=- %s (%h)", f"{tags[-1]}..HEAD", "--", *paths
        )
        lines += [f"Changes since {tags[-1]}:", "", log or "- (none)"]
    else:
        lines.append("The first release built by CI.")

    return "\n".join(lines) + "\n"


def publish(dist):
    """
    Releases each app in a dist folder whose version isn't released yet (see
    the module's description).

    :param pathlib.Path dist: The folder
    """
    head = plan.git("rev-parse", "HEAD")

    # Each app's artifact (release-<app>) is a folder of its own - unless the
    # run has only one: the workflow's download then unpacks it into dist
    # itself
    if (dist / "version").is_file():
        folders = [dist]
    else:
        folders = [
            folder for folder in sorted(dist.iterdir()) if folder.is_dir()
        ] if dist.is_dir() else []

    for folder in folders:
        version = (folder / "version").read_text().strip()

        if folder == dist:
            # Its name, from its packages' (<app>_<version>_<model>.bin)
            names = [
                path.name.split(f"_{version}_")[0]
                for path in folder.glob(f"*_{version}_*")
            ]
            app = names[0] if names else ""
        else:
            app = folder.name.replace("release-", "", 1)
        tag = f"{app}-v{version}"
        files = sorted(folder.glob(f"{app}_{version}_*"))
        packages = REPO / "packages" / app / version
        packages.mkdir(parents=True, exist_ok=True)

        if release_exists(tag):
            print(f"{tag}: already released")
        elif not (folder / f"{app}_{version}_SOURCES.md").is_file():
            # Its sources couldn't all be fetched (ci/sources.py release)
            print(f"::error::{tag}: not released - its sources are missing")
        else:
            (folder / "SHA256SUMS").write_text(
                "".join(f"{sha256(file)}  {file.name}\n" for file in files)
            )

            with tempfile.NamedTemporaryFile("w", suffix=".md") as notes:
                notes.write(release_notes(app, version))
                notes.flush()
                gh(
                    "release", "create", tag,
                    *[str(file) for file in files],
                    str(folder / "SHA256SUMS"),
                    "--target", head,
                    "--title", f"{app} {version}",
                    "--notes-file", notes.name,
                    "--latest=false",
                    capture=False,
                )

            print(f"{tag}: released")

        for file in files:
            if file.suffix == ".bin":
                file.replace(packages / file.name)


def index(previous_path, output):
    """
    Writes the index of the released packages build_store.py can't find
    elsewhere (see the module's description).

    :param str previous_path: The published store.json (may not exist)
    :param str output:        Where to write the index
    """
    previous = {}

    if previous_path and pathlib.Path(previous_path).is_file():
        previous = {
            app["id"]: app["version"]
            for app in json.loads(
                pathlib.Path(previous_path).read_text(encoding="utf-8")
            ).get("apps", [])
        }

    found = {}

    for app in plan.apps():
        version = plan.app_version(app)
        local = REPO / "packages" / app / version

        if list(local.glob("*.bin")) or previous.get(app) == version:
            continue

        tag = f"{app}-v{version}"

        if not release_exists(tag):
            continue

        assets = json.loads(gh("release", "view", tag, "--json", "assets"))
        sizes = {asset["name"]: asset["size"] for asset in assets["assets"]}

        with tempfile.TemporaryDirectory() as temp:
            gh("release", "download", tag, "-p", "SHA256SUMS", "-D", temp)
            sums = (pathlib.Path(temp) / "SHA256SUMS").read_text()

        start = f"{app}_{version}_"
        packages = []

        for digest, name in re.findall(r"^(\w{64})\s+(\S+)$", sums, re.M):
            if name.startswith(start) and name.endswith(".bin"):
                packages.append({
                    "model": name[len(start):-len(".bin")],
                    "file": name,
                    "size": sizes[name],
                    "sha256": digest,
                })

        if packages:
            found[app] = {"version": version, "packages": packages}
            print(f"{tag}: indexed from its release", file=sys.stderr)

    pathlib.Path(output).write_text(json.dumps(found, indent=4) + "\n")


def cache_assets_in_use():
    """
    The build cache's assets the static builds use now (ci/package.sh's
    names).

    :return: Their names
    """
    builders = " ".join(
        plan.git("hash-object", path)
        for path in ("build_static.sh", "ci/survey.sh", "ci/survey_inside.sh")
    )
    names = set()

    for folder in sorted((REPO / "static").iterdir()):
        script = folder / "build.sh"

        if not script.is_file():
            continue

        match = re.search(r"^VERSION=(\S+)", script.read_text(), re.M)

        if not match:
            continue

        tree = plan.git("rev-parse", f"HEAD:static/{folder.name}")
        key = hashlib.sha256(f"{tree} {builders}".encode()).hexdigest()[:16]
        names.add(f"{folder.name}_{match.group(1)}_amd64_{key}.tar.zst")

    return names


def cleanup(store_path, apply):
    """
    Deletes the releases and build cache assets no longer needed (see the
    module's description).

    :param str  store_path: The store.json just published
    :param bool apply:      Delete them (else only print them)
    """
    store = pathlib.Path(store_path).read_text(encoding="utf-8")
    in_use = set(re.findall(r"/releases/download/([^/\"]+)/", store))
    releases = json.loads(
        gh(
            "release", "list", "--limit", "1000",
            "--json", "tagName,createdAt",
        )
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    by_app = {}

    for release in releases:
        match = re.match(r"^(.+)-v(\d.*)$", release["tagName"])

        if match:
            by_app.setdefault(match.group(1), []).append(
                (match.group(2), release)
            )

    doomed = []

    for app, found in sorted(by_app.items()):
        found.sort(key=lambda item: plan.version_key(item[0]), reverse=True)

        for number, (version, release) in enumerate(found):
            if number < KEEP_RELEASES or release["tagName"] in in_use:
                continue

            # Its replacement: the next newer release
            replaced = datetime.datetime.fromisoformat(
                found[number - 1][1]["createdAt"].replace("Z", "+00:00")
            )

            if (now - replaced).days >= KEEP_DAYS:
                doomed.append(release["tagName"])

    for tag in doomed:
        print(f"{'deleting' if apply else 'would delete'} release {tag}")

        if apply:
            gh("release", "delete", tag, "--yes")

    if not release_exists(CACHE_RELEASE):
        return

    assets = json.loads(
        gh("release", "view", CACHE_RELEASE, "--json", "assets")
    )["assets"]
    keep = cache_assets_in_use()

    for asset in assets:
        if asset["name"] not in keep:
            action = "deleting" if apply else "would delete"
            print(f"{action} build cache asset {asset['name']}")

            if apply:
                gh(
                    "release", "delete-asset", CACHE_RELEASE, asset["name"],
                    "--yes",
                )


def main():
    """
    Runs the step the command line names.
    """
    parser = argparse.ArgumentParser(description="CI's release steps")
    steps = parser.add_subparsers(dest="step", required=True)
    step = steps.add_parser("publish")
    step.add_argument("dist")
    step = steps.add_parser("index")
    step.add_argument("--previous")
    step.add_argument("--output", required=True)
    step = steps.add_parser("cleanup")
    step.add_argument("--store", required=True)
    step.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    if args.step == "publish":
        publish(pathlib.Path(args.dist))
    elif args.step == "index":
        index(args.previous, args.output)
    else:
        cleanup(args.store, args.apply)


if __name__ == "__main__":
    main()
