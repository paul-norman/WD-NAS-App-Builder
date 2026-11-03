"""
Plans a run of the build-test-release workflow (see README.md): which apps
to build (or fetch from their releases, when only their tests changed),
which test suites and recipes to test, and which apps to release - from the
files changed between two commits. Checks the rules every change follows,
printing each problem: a changed app or recipe has a newer version, every
app is in the shared package test (tests/apps/apps.conf) and states
keeps_data in store/metadata.json.

    python3 ci/plan.py --event pull_request --base <sha> --head <sha>
    python3 ci/plan.py --event push --base <sha> --head <sha> --main
    python3 ci/plan.py --event workflow_dispatch --apps "nano valkey"
    python3 ci/plan.py --tests <app | recipe:id>

The plan is printed as JSON, and with --github also written to
$GITHUB_OUTPUT (matrix, recipes, build_set) and $GITHUB_STEP_SUMMARY.
--tests prints what a suite needs (its first line, the apps, space
separated) and its commands (one a line), for ci/job.sh.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "store" / "tools"))

import build_store  # noqa: E402

sys.path.insert(0, str(REPO / "ci"))

import sources  # noqa: E402

# Files every app's build uses: a change rebuilds (and tests) every app
SHARED_BUILD = (
    "apps/helpers.sh",
    "apps/apkg_helpers.sh",
    "apps/build_helpers.sh",
    "apps/manage_helpers.php",
    "build.sh",
    "build_static.sh",
    "mksapkg-OS5",
    "docker/",
    # Every static build's survey (its sources)
    "ci/survey.sh",
    "ci/survey_inside.sh",
)
# Test files every suite uses: a change runs every app's suite
SHARED_TESTS = ("tests/common/", "tests/images/")


def git(*args):
    """
    Runs git in the repository.

    :param str args: Its arguments

    :return: What it printed, stripped
    """
    return subprocess.run(
        ["git", *args], cwd=REPO, check=True, capture_output=True, text=True
    ).stdout.strip()


def read_rc_version(text):
    """
    The Version of an apkg.rc file.

    :param str text: The file's contents

    :return: The version, or "" if it has none
    """
    match = re.search(r"^Version:\s*(\S+)", text, re.MULTILINE)

    return match.group(1) if match else ""


def version_key(version):
    """
    A version's sort key: its parts compared as numbers where they are, then
    the packaging revision (2.10.7-1 is newer than 2.10.7), as the Store
    compares them.

    :param str version: The version (e.g. 2.10.7-1)

    :return: The key
    """
    match = re.match(r"^(.*?)(?:-(\d+))?$", version)
    parts = [
        (0, int(part), "") if part.isdigit() else (1, 0, part)
        for part in re.split(r"[.+~]", match.group(1))
    ]

    return parts, int(match.group(2) or 0)


def apps():
    """
    The apps: each folder of apps/ with an apkg.rc (not the template).

    :return: Their ids (folder names), sorted
    """
    return sorted(
        (
            path.parent.name
            for path in (REPO / "apps").glob("*/apkg.rc")
            if path.parent.name != "template"
        ),
        key=str.lower,
    )


def app_version(app, commit=None):
    """
    An app's version, now or at a commit.

    :param str app:    The app's id
    :param str commit: The commit (default: the working tree)

    :return: Its version, or "" if it didn't exist
    """
    if commit is None:
        return read_rc_version(
            (REPO / "apps" / app / "apkg.rc").read_text(encoding="utf-8")
        )

    try:
        return read_rc_version(git("show", f"{commit}:apps/{app}/apkg.rc"))
    except subprocess.CalledProcessError:
        return ""


def recipe_version(recipe, commit=None):
    """
    A recipe's version, now or at a commit.

    :param str recipe: The recipe's id (its folder)
    :param str commit: The commit (default: the working tree)

    :return: Its version, or "" if it didn't exist
    """
    try:
        if commit is None:
            text = (REPO / "recipes" / recipe / "recipe.json").read_text(
                encoding="utf-8"
            )
        else:
            text = git("show", f"{commit}:recipes/{recipe}/recipe.json")
    except (OSError, subprocess.CalledProcessError):
        return ""

    return json.loads(text).get("version", "")


def released(app):
    """
    Whether an app's current version is released: its tag exists.

    :param str app: The app's id

    :return: True if it is
    """
    tag = f"{app}-v{app_version(app)}"

    return git("tag", "--list", tag) == tag


def suites():
    """
    Each suite's lines in tests.conf, plus the default line of the apps with
    a suite on tests/common.

    :return: The suites by name: a list of (needs, command) for each
    """
    found = {}

    for line in (REPO / "ci" / "tests.conf").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            name, needs, command = line.split(None, 2)
            needs = [] if needs == "-" else needs.split(",")
            found.setdefault(name, []).append((needs, command.strip()))

    for path in (REPO / "tests").glob("*/test_app.sh"):
        app = path.parent.name

        if app not in found:
            with_file = path.parent / "with"
            needs = (
                with_file.read_text().split() if with_file.is_file() else []
            )
            found[app] = [(needs, f"tests/common/run.sh {app} --php both")]

    return found


def tier1_apps():
    """
    The apps in the shared package test (tests/apps/apps.conf).

    :return: Their ids
    """
    text = (REPO / "tests" / "apps" / "apps.conf").read_text()

    return {
        line.split()[0]
        for line in text.splitlines()
        if line.strip() and not line.startswith("#")
    }


def served_recipe_files(recipe):
    """
    The files of a recipe the Store downloads (build_store.py's list): a
    change to any of them needs a new version.

    :param str recipe: The recipe's id

    :return: Their paths, relative to the repository
    """
    folder = REPO / "recipes" / recipe

    if not (folder / "recipe.json").is_file():
        return set()

    data = json.loads((folder / "recipe.json").read_text(encoding="utf-8"))

    return {
        f"recipes/{recipe}/{name}"
        for name in build_store.recipe_file_names(folder, data)
    }


def check_rules(all_apps, problems):
    """
    Checks the rules that hold whatever changed: every app is in the shared
    package test, states keeps_data (true, or false on purpose), and lists
    the sources of what its build downloads (ci/sources/<app>.conf).

    :param list all_apps: The apps
    :param list problems: Where problems are added
    """
    metadata = json.loads(
        (REPO / "store" / "metadata.json").read_text(encoding="utf-8")
    )["apps"]
    tier1 = tier1_apps()

    for app in all_apps:
        if app not in tier1:
            problems.append(
                f"{app}: not in the shared package test (add it to"
                " tests/apps/apps.conf)"
            )

        problems += sources.check(app)

        if "keeps_data" not in metadata.get(app, {}):
            problems.append(
                f"{app}: store/metadata.json doesn't say whether it keeps its"
                ' data ("keeps_data": true if removing it loses nothing, so'
                " the Store can update it; false if it would)"
            )


def classify(changed, all_apps):
    """
    What a set of changed files affects.

    :param list changed:  The changed files (paths in the repository)
    :param list all_apps: The apps

    :return: A dict: content (apps whose package changed), shared_build,
             suites (suite names whose tests changed), tier1_all,
             suites_all, recipes (changed recipes: their files the Store
             serves), recipe_tests (recipes whose tests changed)
    """
    found = {
        "content": set(),
        "shared_build": False,
        "suites": set(),
        "tier1_all": False,
        "suites_all": False,
        "recipes": set(),
        "recipe_tests": set(),
    }
    known = set(all_apps)

    for path in changed:
        parts = path.split("/")

        if any(
            path == shared
            or (shared.endswith("/") and path.startswith(shared))
            for shared in SHARED_BUILD
        ):
            found["shared_build"] = True
        elif parts[0] in ("apps", "static") and len(parts) > 2:
            if parts[1] in known and parts[2:] != ["README.md"]:
                found["content"].add(parts[1])
        elif any(path.startswith(shared) for shared in SHARED_TESTS):
            found["suites_all"] = True
        elif path.startswith("tests/apps/"):
            found["tier1_all"] = True
        elif parts[0] == "tests" and len(parts) > 2:
            if parts[-1] == "README.md":
                continue

            match = re.match(r"^test_(\w+)\.sh$", parts[-1])

            if parts[1] == "store" and match and (
                REPO / "recipes" / match.group(1)
            ).is_dir():
                found["recipe_tests"].add(match.group(1))
            else:
                found["suites"].add(parts[1])
        elif parts[0] == "store":
            # Its tools build the Store's test repositories
            found["suites"].add("store")
        elif parts[0] == "recipes" and len(parts) > 2:
            if path in served_recipe_files(parts[1]) or not (
                REPO / "recipes" / parts[1]
            ).is_dir():
                found["recipes"].add(parts[1])
        elif path == "ci/tests.conf":
            found["suites_all"] = True

    return found


def plan(args):
    """
    The plan for a run (see the module's description).

    :param argparse.Namespace args: The command line's options

    :return: The plan, and the problems found (which fail the run)
    """
    all_apps = apps()
    problems = []
    warnings = []
    check_rules(all_apps, problems)
    known_suites = suites()

    if args.apps:
        wanted = all_apps if args.apps.strip() == "all" else args.apps.split()
        unknown = [app for app in wanted if app not in all_apps]

        if unknown:
            problems.append(f"no such apps: {', '.join(unknown)}")

        found = classify([], all_apps)
        found["content"] = {app for app in wanted if app in all_apps}
    else:
        # A new branch pushed (no commit before it) is all new; a manual run
        # without apps only builds what's unreleased
        new_branch = args.event == "push" and (
            not args.base or set(args.base) == {"0"}
        )

        if not args.base:
            args.base = "HEAD"


        changed = [] if new_branch else git(
            "diff", "--name-only", f"{args.base}...{args.head}"
        ).splitlines()
        found = classify(changed, all_apps)

        if new_branch:
            found["shared_build"] = True

    build = set(found["content"])

    if found["shared_build"]:
        build |= set(all_apps)

    # On main, every app whose version isn't released yet (new, or a release
    # that failed) is built and released
    unreleased = {app for app in all_apps if not released(app)}

    if args.main:
        build |= unreleased

    # Changed packages need a newer version: the Store offers only newer ones
    for app in sorted(found["content"]):
        if args.apps:
            break

        before, now = app_version(app, args.base), app_version(app)

        if before and version_key(now) <= version_key(before):
            message = (
                f"{app}: changed, but its version ({now}) isn't newer than"
                f" {before} - raise it in apps/{app}/apkg.rc (the packaging"
                " revision, e.g. 1.2.3-1, for a change to the app alone)"
            )
            (warnings if args.event == "push" else problems).append(message)

    for recipe in sorted(found["recipes"]):
        before, now = recipe_version(recipe, args.base), recipe_version(recipe)

        if before and now and version_key(now) <= version_key(before):
            message = (
                f"recipe {recipe}: changed, but its version ({now}) isn't"
                f" newer than {before} - raise it in"
                f" recipes/{recipe}/recipe.json"
            )
            (warnings if args.event == "push" else problems).append(message)

    test_only = set(found["suites"]) & set(all_apps)

    if found["tier1_all"]:
        test_only |= set(all_apps)

    if found["suites_all"]:
        test_only |= set(known_suites) & set(all_apps)

    matrix = []

    for app in all_apps:
        if app not in build and app not in test_only:
            continue

        # Fetching needs a release; without one, it's built
        mode = "build" if app in build or app in unreleased else "fetch"
        release = args.main and mode == "build" and app in unreleased
        suite = app in known_suites and (
            mode == "build"
            or app in found["suites"]
            or found["suites_all"]
        )
        matrix.append({
            "app": app,
            "mode": mode,
            "release": release,
            "suite": suite,
        })

        if args.main and mode == "build" and not release:
            if app in found["content"]:
                warnings.append(
                    f"{app}: changed without a new version ({app_version(app)}"
                    " is already released) - built and tested, not released"
                )

    recipes = sorted(
        recipe
        for recipe in found["recipes"] | found["recipe_tests"]
        | ({"immich", "pihole", "arr"} if found["suites_all"] else set())
        if f"recipe:{recipe}" in known_suites
    )
    not_released = sorted(
        item["app"] for item in matrix
        if item["mode"] == "build" and not item["release"]
        and item["app"] not in found["content"]
    )

    if args.main and not_released:
        warnings.append(
            "rebuilt and tested (shared files changed) but not released, as"
            f" their versions are already out: {', '.join(not_released)}"
            " - raise their packaging revisions to release them"
        )

    return {
        "matrix": matrix,
        "recipes": recipes,
        "build_set": " ".join(
            item["app"] for item in matrix if item["mode"] == "build"
        ),
        "warnings": warnings,
    }, problems


def summary(result, problems):
    """
    The plan as Markdown, for the run's summary page.

    :param dict result:   The plan
    :param list problems: The problems found

    :return: The Markdown
    """
    lines = ["## Plan", ""]

    for problem in problems:
        lines.append(f"- :x: {problem}")

    for warning in result["warnings"]:
        lines.append(f"- :warning: {warning}")

    if problems or result["warnings"]:
        lines.append("")

    if result["matrix"]:
        lines += [
            "| App | Package | Own suite | Release |",
            "|---|---|---|---|",
        ]

        for item in result["matrix"]:
            lines.append(
                f"| {item['app']} | {item['mode']} |"
                f" {'yes' if item['suite'] else '-'} |"
                f" {'yes' if item['release'] else '-'} |"
            )
    else:
        lines.append("No apps to build or test.")

    if result["recipes"]:
        lines += ["", f"Recipes tested: {', '.join(result['recipes'])}"]

    return "\n".join(lines) + "\n"


def print_tests(name):
    """
    Prints what a suite needs and its commands (see the module's
    description).

    :param str name: The suite (an app, or recipe:<id>)
    """
    lines = suites().get(name, [])
    needs = []

    for line_needs, _ in lines:
        needs += [need for need in line_needs if need not in needs]

    print(" ".join(needs))

    for _, command in lines:
        print(command)


def main():
    """
    Plans the run from the command line's options.
    """
    parser = argparse.ArgumentParser(description="Plans a CI run")
    parser.add_argument("--event", default="pull_request")
    parser.add_argument("--base", default="", help="the commit compared to")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument(
        "--main",
        action="store_true",
        help="a run on main: unreleased versions are built and released",
    )
    parser.add_argument("--apps", help='apps to build ("all" for every app)')
    parser.add_argument("--tests", help="print a suite's needs and commands")
    parser.add_argument("--github", action="store_true")
    args = parser.parse_args()

    if args.tests:
        print_tests(args.tests)

        return

    result, problems = plan(args)
    print(json.dumps({**result, "problems": problems}, indent=4))

    if args.github:
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"matrix={json.dumps(result['matrix'])}\n")
            output.write(f"recipes={json.dumps(result['recipes'])}\n")
            output.write(f"build_set={result['build_set']}\n")

        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as page:
            page.write(summary(result, problems))

    for problem in problems:
        print(f"::error::{problem}", file=sys.stderr)

    for warning in result["warnings"]:
        print(f"::warning::{warning}", file=sys.stderr)

    if problems:
        sys.exit(1)


if __name__ == "__main__":
    main()
