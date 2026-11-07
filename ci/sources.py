"""
The sources of what each app's packages contain (see README.md, Sources):
what ci/sources/<app>.conf lists - each component its build downloads, its
license, and where its source is - checked against the app's build files,
and fetched for its release.

    python3 ci/sources.py check [app ...]
    python3 ci/sources.py urls <app>
    python3 ci/sources.py scan <bundle>
    python3 ci/sources.py release <app> <dist folder>

check: every URL in the app's build files (apps/<app>/build.sh,
static/<app>/build.sh and Dockerfiles) is listed in its .conf, and the .conf
lists none that aren't (default: every app). urls: each source's URL, with
the build's versions put in. scan: the copyleft Python and npm packages in a
built bundle. release: everything below, into <app>_<version>_sources.tar
(in parts if too big for GitHub) and <app>_<version>_SOURCES.md, for its
release - needs the app built (and its static build surveyed).

What a release's sources hold:

- upstream/: the .conf's sources (what its build downloads, or the source
  releases of programs included as their makers release them)
- python/, npm/: the copyleft Python and npm packages in its bundle, from
  PyPI and npm (checked against their published digests)
- debian/, ubuntu/, alpine/: the copyleft distribution packages its static
  build may have linked in or bundles (ci/survey.sh), from Debian's archives,
  Ubuntu's (Launchpad) and Alpine's aports (checked against their own
  checksums)
- what its static build kept itself (e.g. PHP's libraries' sources)
- build-files.tar.gz: this repository's files that built it

A .conf has one line per component:

    <component>  <license>  <source>  <download>

<license> is its SPDX license (an expression may have spaces). <source> is
the URL of its source, with the build's variables (${VERSION}...; a file in
an archive after #: url#path), or - when none is needed (a permissive
license, or not software). <download> is the URL as the build files write it
(- for a component that comes another way, e.g. in a Docker image).
"""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[1]
CONF = REPO / "ci" / "sources"
URL = re.compile(r"https?://[^\s\"')]+")
# The licenses whose source must be offered with the program
COPYLEFT = re.compile(r"GPL|MPL|EUPL|CDDL|EPL|OSL|SSPL", re.IGNORECASE)
USER_AGENT = "WD-NAS-App-Builder-CI"


def needs_source(license_id):
    """
    Whether a license needs the source offered with the program: a copyleft
    license, or an expression whose every choice is one (A OR B, where B is
    permissive, doesn't).

    :param str license_id: The SPDX license expression

    :return: True if it does
    """
    return all(
        COPYLEFT.search(choice) for choice in license_id.split(" OR ")
    )


def build_files(app):
    """
    The files that build an app (those whose downloads its .conf lists).

    :param str app: The app's id

    :return: Their paths
    """
    files = [REPO / "apps" / app / "build.sh"]
    static = REPO / "static" / app

    if static.is_dir():
        files.append(static / "build.sh")
        files += sorted(static.glob("*.Dockerfile"))
        # What a Dockerfile builds from, downloaded beforehand
        files.append(static / "downloads")

    return [path for path in files if path.is_file()]


def downloads(app):
    """
    The URLs in an app's build files.

    :param str app: The app's id

    :return: The URLs, as written there
    """
    found = set()

    for path in build_files(app):
        found |= set(URL.findall(path.read_text(encoding="utf-8")))

    return found


def read_conf(app):
    """
    An app's .conf.

    :param str app: The app's id

    :return: Its components: dicts of component, license, source, download
    """
    path = CONF / f"{app}.conf"
    components = []

    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            # The license may have spaces (an SPDX expression: A OR B)
            fields = line.split()
            components.append({
                "component": fields[0],
                "license": " ".join(fields[1:-2]),
                "source": fields[-2] if len(fields) >= 4 else "",
                "download": fields[-1] if len(fields) >= 4 else "",
            })

    return components


def check(app):
    """
    Checks an app's .conf against its build files.

    :param str app: The app's id

    :return: The problems found
    """
    if not (CONF / f"{app}.conf").is_file():
        return [f"{app}: no ci/sources/{app}.conf (see ci/README.md)"]

    problems = []
    components = read_conf(app)
    listed = {item.get("download", "") for item in components}

    for item in components:
        if not item["license"] or not item["source"]:
            problems.append(
                f"{app}: {item['component']}: needs 4 fields (component,"
                " license, source, download)"
            )
        elif item["source"] == "-" and needs_source(item["license"]):
            problems.append(
                f"{app}: {item['component']} is {item['license']}: its"
                " source must be listed"
            )

    for url in sorted(downloads(app) - listed):
        problems.append(f"{app}: ci/sources/{app}.conf doesn't list {url}")

    for url in sorted(listed - downloads(app) - {"-"}):
        problems.append(
            f"{app}: ci/sources/{app}.conf lists {url}, which its build"
            " files don't download any more"
        )

    return problems


def variables(app):
    """
    The shell assignments of an app's build scripts, which its sources'
    URLs use (VERSION and the components' versions), plus its own version.

    :param str app: The app's id

    :return: The assignments, as shell lines
    """
    rc = (REPO / "apps" / app / "apkg.rc").read_text(encoding="utf-8")
    version = re.search(r"^Version:\s*(\S+)", rc, re.MULTILINE).group(1)
    lines = [
        f"APKG_VERSION='{version}'",
        f"APP_UPSTREAM_VERSION='{re.sub(r'-[0-9]+$', '', version)}'",
    ]
    scripts = [
        REPO / "apps" / app / "build.sh",
        REPO / "static" / app / "build.sh",
    ]

    for path in scripts:
        if path.is_file():
            lines += [
                line
                for line in path.read_text(encoding="utf-8").splitlines()
                # Plain values only (versions, names): no quotes, spaces or
                # commands
                if re.match(r"^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/@+%{}$-]*$", line)
                and "$(" not in line
            ]

    return lines


def source_urls(app):
    """
    The URLs of an app's sources, with its build's variables put in.

    :param str app: The app's id

    :return: (component, license, URL) for each source
    """
    wanted = [item for item in read_conf(app) if item["source"] != "-"]

    if not wanted:
        return []

    script = "\n".join(
        variables(app)
        + [f'printf "%s\\n" "{item["source"]}"' for item in wanted]
    )
    expanded = subprocess.run(
        ["bash", "-c", script], check=True, capture_output=True, text=True
    ).stdout.splitlines()

    return [
        (item["component"], item["license"], url)
        for item, url in zip(wanted, expanded)
    ]


def download(url, path):
    """
    Downloads a file.

    :param str          url:  Its URL
    :param pathlib.Path path: Where to write it

    :raises OSError: When it can't be downloaded
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    # Three tries, for a server's passing failures (not a missing file)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(
                request, timeout=600
            ) as response, open(path, "wb") as out:
                while True:
                    block = response.read(1 << 20)

                    if not block:
                        break

                    out.write(block)

            return
        except urllib.error.HTTPError as error:
            if error.code < 500 or attempt == 2:
                raise OSError(f"{url}: {error}") from error
        except OSError as error:
            if attempt == 2:
                raise OSError(f"{url}: {error}") from error

        time.sleep(10 * (attempt + 1))


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


def file_name(component, url):
    """
    The name a source is kept under: its component, then the file's own name
    (GitHub's archives are only named after their tag, e.g. v1.2.tar.gz).

    :param str component: The component
    :param str url:       The source's URL (url#path for a file in an archive)

    :return: The name
    """
    name = url.split("#")[-1].rstrip("/").rsplit("/", 1)[-1]
    name = re.sub(r"[^A-Za-z0-9._+-]", "_", name)

    return name if name.startswith(component) else f"{component}-{name}"


def fetch(app, folder):
    """
    Downloads the sources its .conf lists for an app into <folder>/upstream/.

    :param str          app:    The app's id
    :param pathlib.Path folder: Where to put them

    :return: The rows of SOURCES.md's table (component, license, file,
             origin, sha256)
    """
    upstream = folder / "upstream"
    upstream.mkdir(parents=True, exist_ok=True)
    rows = []

    for component, license_id, url in source_urls(app):
        target = upstream / file_name(component, url)
        print(f"{app}: {component} ({license_id}) from {url}", file=sys.stderr)

        if "#" in url:
            archive_url, member = url.split("#", 1)

            with tempfile.TemporaryDirectory() as temp:
                archive = pathlib.Path(temp) / "archive"
                download(archive_url, archive)

                with tarfile.open(archive) as tar:
                    extracted = tar.extractfile(member)

                    if extracted is None:
                        raise OSError(
                            f"{member} isn't a file in {archive_url}"
                        )

                    with open(target, "wb") as out:
                        while True:
                            block = extracted.read(1 << 20)

                            if not block:
                                break

                            out.write(block)
        else:
            download(url, target)

        rows.append((
            component, license_id, f"upstream/{target.name}", url,
            sha256(target),
        ))

    return rows


def license_of_python(metadata):
    """
    A Python package's license, from its METADATA: License-Expression, else
    its license classifiers and License field together.

    :param str metadata: The METADATA file's text (its headers)

    :return: The license (an SPDX expression, or the classifiers' words)
    """
    headers = metadata.split("\n\n", 1)[0]
    expression = re.search(r"^License-Expression:\s*(.+)$", headers, re.M)

    if expression:
        return expression.group(1).strip()

    found = re.findall(r"^Classifier:\s*License :: (.+)$", headers, re.M)
    field = re.search(r"^License:\s*(.+)$", headers, re.M)

    if field and len(field.group(1)) < 100:
        found.append(field.group(1).strip())

    return "; ".join(found) or "unknown"


def license_of_npm(package):
    """
    An npm package's license, from its package.json.

    :param dict package: The package.json

    :return: The license (an SPDX expression, as the package states it)
    """
    value = package.get("license") or package.get("licenses") or "unknown"

    if isinstance(value, dict):
        value = value.get("type", "unknown")

    if isinstance(value, list):
        value = " OR ".join(
            item.get("type", "unknown") if isinstance(item, dict) else item
            for item in value
        )

    return str(value).strip("()")


def scan(bundle):
    """
    The Python and npm packages in an app's bundle (its amd64 .tar.gz - what
    its packages contain) whose license needs their source offered.

    :param pathlib.Path bundle: The bundle

    :return: (kind, name, version, license) for each, kind being python or
             npm, sorted
    """
    found = set()

    with tarfile.open(bundle) as tar:
        for member in tar:
            if not member.isfile():
                continue

            path = member.name

            if path.endswith(".dist-info/METADATA"):
                text = tar.extractfile(member).read().decode(
                    "utf-8", "replace"
                )
                name = re.search(r"^Name:\s*(\S+)", text, re.M)
                version = re.search(r"^Version:\s*(\S+)", text, re.M)

                if name and version:
                    license_id = license_of_python(text)

                    if needs_source(license_id):
                        found.add((
                            "python", name.group(1), version.group(1),
                            license_id,
                        ))
            elif re.search(
                r"node_modules/(@[^/]+/)?[^/@]+/package\.json$", path
            ):
                try:
                    package = json.load(tar.extractfile(member))
                except ValueError:
                    continue

                if not isinstance(package, dict):
                    continue

                name, version = package.get("name"), package.get("version")
                license_id = license_of_npm(package)

                # Packages' own test fixtures have package.json files too
                folder = path.rsplit("node_modules/", 1)[1]

                if name and version and needs_source(license_id) and (
                    folder[:-len("/package.json")] == name
                ):
                    found.add(("npm", name, version, license_id))

    return sorted(found)


def json_url(url):
    """
    Reads JSON from a URL.

    :param str url: The URL

    :return: The JSON
    """
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})

    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def package_source(kind, name, version):
    """
    Where a Python or npm package's source is published: PyPI's sdist (or,
    without one, its pure Python wheel - its .py files are the source), or
    npm's tarball.

    :param str kind:    python or npm
    :param str name:    The package's name
    :param str version: Its version

    :return: The URL and its published digest (algorithm, value)

    :raises OSError: When it has no published source
    """
    if kind == "npm":
        dist = json_url(
            f"https://registry.npmjs.org/{name.replace('/', '%2F')}/{version}"
        )["dist"]
        algorithm, value = dist["integrity"].split("-", 1)

        return dist["tarball"], (algorithm, value)

    files = json_url(f"https://pypi.org/pypi/{name}/{version}/json")["urls"]
    chosen = [item for item in files if item["packagetype"] == "sdist"] or [
        item for item in files if item["filename"].endswith("-none-any.whl")
    ]

    if not chosen:
        raise OSError(f"{name} {version} has no source on PyPI")

    return chosen[0]["url"], ("sha256", chosen[0]["digests"]["sha256"])


def fetch_packages(bundle, folder):
    """
    Downloads the source of each copyleft Python and npm package in an app's
    bundle into <folder>/python/ and <folder>/npm/, checked against the
    digest its registry publishes.

    :param pathlib.Path bundle: The app's amd64 bundle
    :param pathlib.Path folder: Where to put them

    :return: SOURCES.md's rows for them (component, license, file, origin,
             sha256)

    :raises OSError: When one can't be fetched or doesn't match
    """
    import base64

    rows = []

    for kind, name, version, license_id in scan(bundle):
        url, (algorithm, digest) = package_source(kind, name, version)
        target = folder / kind / url.rsplit("/", 1)[1]
        target.parent.mkdir(parents=True, exist_ok=True)
        print(
            f"{kind} {name} {version} ({license_id}) from {url}",
            file=sys.stderr,
        )
        download(url, target)
        actual = hashlib.new(algorithm, target.read_bytes()).digest()
        expected = (
            bytes.fromhex(digest) if algorithm == "sha256"
            else base64.b64decode(digest)
        )

        if actual != expected:
            raise OSError(f"{url} doesn't match its registry's {algorithm}")

        rows.append((
            f"{name} {version}", license_id, f"{kind}/{target.name}", url,
            sha256(target),
        ))

    return rows


# Packages whose license has an exception for what's built with them (GCC's
# runtime library exception: libgcc, libstdc++, libgomp)
RUNTIME_EXCEPTION = re.compile(r"^gcc(-\d+)?$")
# Where Alpine packages' APKBUILDs are read (see alpine_files)
ALPINE_IMAGE = "alpine:3.22"
# Debian's pools, current and archived (security updates are in
# pool/updates/main)
DEBIAN_POOLS = (
    "https://deb.debian.org/debian/pool/main",
    "https://deb.debian.org/debian-security/pool/updates/main",
    "https://archive.debian.org/debian/pool/main",
    "https://archive.debian.org/debian-security/pool/updates/main",
)


def distro_packages(survey):
    """
    The distribution packages a static build's survey recorded whose source
    must be offered: copyleft ones, apart from GCC's runtime libraries.

    :param pathlib.Path survey: The survey (distro.tsv)

    :return: (os, source package, version, license, aports commit, why)
             for each, sorted
    """
    found = {}

    for line in survey.read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")

        if len(fields) < 8:
            continue

        os_id, _, _, source, version, license_id, why, commit = fields[:8]

        if RUNTIME_EXCEPTION.match(source):
            continue

        if os_id == "alpine" and not needs_source(license_id):
            continue

        if os_id != "alpine" and license_id != "copyleft":
            continue

        found.setdefault(
            (os_id, source, version), (license_id, commit, why)
        )

    return sorted(key + value for key, value in found.items())


def dsc_files(base, source, bare):
    """
    A source package's files, from its .dsc in a folder that has them all.

    :param str base:   The folder's address
    :param str source: The source package
    :param str bare:   Its version, without any epoch

    :return: (name, URL, algorithm, digest) for each file, or None if the
             .dsc isn't there
    """
    try:
        request = urllib.request.Request(
            f"{base}/{source}_{bare}.dsc",
            headers={"User-Agent": USER_AGENT},
        )

        with urllib.request.urlopen(request, timeout=60) as response:
            dsc = response.read().decode("utf-8", "replace")
    except OSError:
        return None

    sums = re.search(r"^Checksums-Sha256:\n((?: .+\n)+)", dsc, re.MULTILINE)
    files = [(f"{source}_{bare}.dsc", f"{base}/{source}_{bare}.dsc", None,
              None)]

    for digest, _, name in re.findall(
        r"^ (\w{64}) (\d+) (\S+)$", sums.group(1), re.MULTILINE
    ):
        files.append((name, f"{base}/{name}", "sha256", digest))

    return files


def ubuntu_files(source, version):
    """
    Where an Ubuntu source package's files are: Launchpad, which keeps every
    version published (Ubuntu's pools drop superseded ones).

    :param str source:  The source package
    :param str version: Its version (with any epoch: Launchpad's addresses
                        keep it)

    :return: (name, URL, algorithm, digest) for each file

    :raises OSError: When it can't be found
    """
    files = dsc_files(
        "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/"
        f"{source}/{urllib.parse.quote(version, safe=':~+')}",
        source,
        version.split(":", 1)[-1],
    )

    if not files:
        raise OSError(f"Ubuntu's source of {source} {version} wasn't found")

    return files


def debian_files(source, version):
    """
    Where a Debian source package's files are: its .dsc in Debian's pools
    (current and archived), else Debian's permanent snapshot archive.

    :param str source:  The source package
    :param str version: Its version (with any epoch)

    :return: (name, URL, algorithm, digest) for each file

    :raises OSError: When it can't be found
    """
    bare = version.split(":", 1)[-1]
    prefix = source[:4] if source.startswith("lib") else source[0]

    for pool in DEBIAN_POOLS:
        files = dsc_files(f"{pool}/{prefix}/{source}", source, bare)

        if files:
            return files

    snapshot = "https://snapshot.debian.org"
    info = json_url(
        f"{snapshot}/mr/package/{source}/"
        f"{urllib.parse.quote(version, safe='')}/srcfiles?fileinfo=1"
    )
    files = []

    for item in info["result"]:
        name = info["fileinfo"][item["hash"]][0]["name"]
        files.append(
            (name, f"{snapshot}/file/{item['hash']}", "sha1", item["hash"])
        )

    if not files:
        raise OSError(f"Debian's source of {source} {version} wasn't found")

    return files


def aports_from_gitlab(origin, commit, target):
    """
    Copies an Alpine package's aports folder from Alpine's GitLab (an archive
    of just that folder). It seems to refuse some machines (GitHub's runners
    among them), so a failure is only reported.

    :param str          origin: The package's origin (its aports folder)
    :param str          commit: The aports commit
    :param pathlib.Path target: Where its files go

    :return: True if its APKBUILD is there now
    """
    archive = target.parent / f".{origin}.tar.gz"
    errors = []

    for repository in ("main", "community"):
        url = (
            "https://gitlab.alpinelinux.org/alpine/aports/-/archive/"
            f"{commit}/aports-{commit}.tar.gz?path={repository}/{origin}"
        )

        try:
            download(url, archive)

            with tarfile.open(archive) as tar:
                prefix = f"aports-{commit}-{repository}-{origin}/{repository}/"
                members = [
                    member for member in tar.getmembers()
                    if member.name.startswith(prefix + origin + "/")
                    and member.isfile()
                ]

                for member in members:
                    path = target / member.name[len(prefix) + len(origin) + 1:]
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(tar.extractfile(member).read())
        except (OSError, tarfile.TarError) as error:
            errors.append(f"{repository}: {error}")
        finally:
            archive.unlink(missing_ok=True)

        if (target / "APKBUILD").is_file():
            return True

    print(f"  aports {origin} from GitLab failed ({'; '.join(errors)})")

    return False


def aports_from_github(origin, commit, target):
    """
    Copies an Alpine package's aports folder from Alpine's mirror of aports
    on GitHub: just that folder, at the commit (a sparse, shallow fetch).

    :param str          origin: The package's origin (its aports folder)
    :param str          commit: The aports commit
    :param pathlib.Path target: Where its files go

    :return: True if its APKBUILD is there now
    """
    with tempfile.TemporaryDirectory() as work:
        def git(*args):
            subprocess.run(
                ["git", "-C", work, *args], check=True, capture_output=True
            )

        try:
            git("init", "-q")
            git(
                "remote", "add", "origin",
                "https://github.com/alpinelinux/aports",
            )
            git(
                "sparse-checkout", "set", "--no-cone",
                f"/main/{origin}/", f"/community/{origin}/",
            )
            git(
                "fetch", "-q", "--depth", "1", "--filter=blob:none",
                "origin", commit,
            )
            git("checkout", "-q", "FETCH_HEAD")
        except subprocess.CalledProcessError as error:
            reason = error.stderr.decode().strip()
            print(f"  aports {origin} from GitHub: {reason}")

            return False

        for repository in ("main", "community"):
            source = pathlib.Path(work) / repository / origin

            if (source / "APKBUILD").is_file():
                for path in source.rglob("*"):
                    if path.is_file():
                        copy = target / path.relative_to(source)
                        copy.parent.mkdir(parents=True, exist_ok=True)
                        copy.write_bytes(path.read_bytes())

                return True

    return False


def alpine_files(origin, version, commit, folder):
    """
    Downloads an Alpine package's source: its aports folder (APKBUILD and
    patches) at the commit it was built from, and the upstream files its
    APKBUILD names (from upstream, else Alpine's own copies), checked against
    its sha512sums.

    :param str          origin:  The package's origin (its aports folder)
    :param str          version: Its version (e.g. 1.2.3-r0)
    :param str          commit:  The aports commit it was built from
    :param pathlib.Path folder:  Where to put them (a folder for it is made)

    :return: The folder made

    :raises OSError: When something can't be found or doesn't match
    """
    target = folder / f"{origin}-{version}"
    target.mkdir(parents=True, exist_ok=True)

    if not (
        aports_from_gitlab(origin, commit, target)
        or aports_from_github(origin, commit, target)
    ):
        raise OSError(f"aports {commit} has no {origin}")

    # The APKBUILD is a shell script setting source and sha512sums: it's read
    # in a throwaway Alpine container, without a network, from a read-only
    # copy - never run on this machine
    listing = subprocess.run(
        [
            "docker", "run", "--rm", "--network", "none", "--read-only",
            "-e", "CARCH=x86_64", "-e", "CTARGET_ARCH=x86_64",
            "-e", "CBUILD=x86_64-alpine-linux-musl",
            "-v", f"{target}:/aport:ro", "-w", "/aport", ALPINE_IMAGE,
            "sh", "-c",
            '. ./APKBUILD > /dev/null 2>&1; printf "%s\n" $source;'
            ' echo ---; printf "%s\n" "$sha512sums"',
        ],
        check=True, capture_output=True, text=True,
    ).stdout
    entries, sums = listing.split("---\n", 1)
    digests = dict(
        (name, digest)
        for digest, name in re.findall(r"(\w{128})\s+(\S+)", sums)
    )
    branch = "v" + ".".join(version.split(".")[:2])

    for entry in entries.split():
        name, _, url = entry.rpartition("::")
        name = name or url.rsplit("/", 1)[-1]

        if "://" not in url:
            continue

        path = target / name

        for candidate in (
            url,
            f"https://distfiles.alpinelinux.org/distfiles/{branch}/{name}",
        ):
            try:
                download(candidate, path)

                if digests.get(name) in (
                    None, hashlib.sha512(path.read_bytes()).hexdigest()
                ):
                    break
            except OSError:
                pass
        else:
            raise OSError(f"{origin}: {name} couldn't be fetched")

    return target


def fetch_distro(survey, folder):
    """
    Downloads the sources of the distribution packages a static build's
    survey recorded, that need them, into <folder>/debian/,
    <folder>/ubuntu/ and <folder>/alpine/.

    :param pathlib.Path survey: The survey (distro.tsv)
    :param pathlib.Path folder: Where to put them

    :return: SOURCES.md's rows for them

    :raises OSError: When one can't be fetched or doesn't match
    """
    rows = []

    for os_id, source, version, license_id, commit, why in distro_packages(
        survey
    ):
        print(f"{os_id} {source} {version} ({why})", file=sys.stderr)

        if os_id == "alpine":
            made = alpine_files(source, version, commit, folder / "alpine")
            rows.append((
                f"{source} {version}", license_id, f"alpine/{made.name}/",
                f"aports {commit}", "-",
            ))
            continue

        # Ubuntu's (e.g. MongoDB's build on Ubuntu 20.04) or Debian's
        ubuntu = os_id == "ubuntu"
        target = (
            folder / ("ubuntu" if ubuntu else "debian")
            / f"{source}-{version.replace(':', '_')}"
        )
        target.mkdir(parents=True, exist_ok=True)
        where = ubuntu_files if ubuntu else debian_files

        for name, url, algorithm, digest in where(source, version):
            path = target / name
            download(url, path)

            if algorithm and hashlib.new(
                algorithm, path.read_bytes()
            ).hexdigest() != digest:
                raise OSError(f"{url} doesn't match its {algorithm}")

        rows.append((
            f"{source} {version}", "see its debian/copyright",
            f"{target.parent.name}/{target.name}/",
            "Ubuntu's archive (Launchpad)" if ubuntu else "Debian's archive",
            "-",
        ))

    return rows


# The repository's files every app's build uses (archived with the app's own)
SHARED_BUILD_FILES = (
    "build.sh",
    "build_static.sh",
    "apps/helpers.sh",
    "apps/apkg_helpers.sh",
    "apps/build_helpers.sh",
    "apps/manage_helpers.php",
    "docker",
)
# GitHub's limit for a release asset, less a margin
PART_BYTES = 1900 * 1024 * 1024


def static_sources(app):
    """
    The folder where an app's static build left what it records for its
    sources (ci/survey.sh's distro.tsv, and any sources the build kept), or
    None if it has no static build.

    :param str app: The app's id

    :return: The folder

    :raises OSError: When it has a static build without one (built before
                     surveys, or restored from an older build cache)
    """
    script = REPO / "static" / app / "build.sh"

    if not script.is_file():
        return None

    version = re.search(r"^VERSION=(\S+)", script.read_text(), re.M).group(1)
    folder = REPO / "packages" / "static" / app / version / "amd64.sources"

    if not (folder / "distro.tsv").is_file():
        raise OSError(
            f"{app}: its static build has no survey ({folder}/distro.tsv):"
            " rebuild it (./build_static.sh)"
        )

    return folder


def write_markdown(app, version, rows, commit, parts):
    """
    SOURCES.md: what the sources archive holds.

    :param str  app:     The app's id
    :param str  version: Its version
    :param list rows:    (component, license, file, origin, sha256) for each
    :param str  commit:  The commit the packages were built from
    :param list parts:   The archive's files (several when split)

    :return: The Markdown
    """
    archive = f"{app}_{version}_sources.tar"
    lines = [
        f"# Sources of {app} {version}",
        "",
        f"The sources of what the packages of {app} {version} contain under"
        " a license that asks for them to be offered (GPL, LGPL, AGPL, MPL"
        f"...), in `{archive}`, with the files that built them"
        f" (`build-files.tar.gz`, from commit {commit}).",
        "",
    ]

    if len(parts) > 1:
        lines += [
            f"The archive is in {len(parts)} parts (GitHub's limit for a"
            f" file): `cat {archive}.* > {archive}` joins them.",
            "",
        ]

    lines += [
        "Programs included as their makers release them (not built here)"
        " are listed with their makers' source release; the components"
        " within them are covered by their makers' own source offers.",
        "",
        "| Component | License | In the archive | From | SHA256 |",
        "|---|---|---|---|---|",
    ]

    for component, license_id, file, origin, digest in rows:
        lines.append(
            f"| {component} | {license_id} | `{file}` | {origin} |"
            f" {digest if digest != '-' else ''} |"
        )

    return "\n".join(lines) + "\n"


def release(app, dist):
    """
    Gets everything an app's release needs for its sources (see the module's
    description) and packs it into <dist>/<app>_<version>_sources.tar (in
    parts if it's too big for GitHub) and <dist>/<app>_<version>_SOURCES.md.

    :param str          app:  The app's id
    :param pathlib.Path dist: The release's folder

    :raises OSError: When a source can't be fetched or doesn't match
    """
    rc = (REPO / "apps" / app / "apkg.rc").read_text(encoding="utf-8")
    version = re.search(r"^Version:\s*(\S+)", rc, re.MULTILINE).group(1)
    bundle = (
        REPO / "packages" / app / version / f"{app}_{version}_amd64.tar.gz"
    )
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=REPO, check=True,
        capture_output=True, text=True,
    ).stdout.strip()

    with tempfile.TemporaryDirectory() as temp:
        work = pathlib.Path(temp) / f"{app}_{version}_sources"
        work.mkdir()
        rows = fetch(app, work)
        rows += fetch_packages(bundle, work)
        static = static_sources(app)

        if static:
            rows += fetch_distro(static / "distro.tsv", work)

            # What the build kept itself (e.g. PHP's libraries' sources)
            for kept in sorted(static.iterdir()):
                if kept.is_dir():
                    subprocess.run(
                        ["cp", "-r", str(kept), str(work / kept.name)],
                        check=True,
                    )
                    rows.append((
                        kept.name, "see each source", f"{kept.name}/",
                        "kept by its static build", "-",
                    ))

        paths = [
            path for path in SHARED_BUILD_FILES + (
                f"apps/{app}", f"static/{app}", f"ci/sources/{app}.conf",
            )
            # At the commit (git archive's), not as they are on disk
            if subprocess.run(
                ["git", "cat-file", "-e", f"HEAD:{path}"], cwd=REPO,
                capture_output=True,
            ).returncode == 0
        ]
        subprocess.run(
            ["git", "archive", "--format=tar.gz", "-o",
             str(work / "build-files.tar.gz"), "HEAD", "--", *paths],
            cwd=REPO, check=True,
        )
        archive = dist / f"{app}_{version}_sources.tar"
        subprocess.run(
            ["tar", "-cf", str(archive), "-C", temp, work.name], check=True
        )

    parts = [archive]

    if archive.stat().st_size > PART_BYTES:
        subprocess.run(
            ["split", "-b", str(PART_BYTES), "-d", "-a", "2", str(archive),
             f"{archive}."],
            check=True,
        )
        archive.unlink()
        parts = sorted(dist.glob(f"{archive.name}.*"))

    (dist / f"{app}_{version}_SOURCES.md").write_text(
        write_markdown(app, version, rows, commit, parts)
    )
    print(
        f"{app}: sources in {', '.join(part.name for part in parts)}"
        f" ({len(rows)} components)",
        file=sys.stderr,
    )


def main():
    """
    Runs the command the command line names.
    """
    parser = argparse.ArgumentParser(description="The apps' sources")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("check")
    command.add_argument("apps", nargs="*")
    command = commands.add_parser("urls")
    command.add_argument("app")
    command = commands.add_parser("scan")
    command.add_argument("bundle")
    command = commands.add_parser("release")
    command.add_argument("app")
    command.add_argument("dist")
    args = parser.parse_args()

    if args.command == "check":
        sys.path.insert(0, str(REPO / "ci"))
        import plan

        problems = []

        for app in args.apps or plan.apps():
            problems += check(app)

        for problem in problems:
            print(problem)

        sys.exit(1 if problems else 0)
    elif args.command == "scan":
        for row in scan(pathlib.Path(args.bundle)):
            print("\t".join(row))
    elif args.command == "urls":
        for component, license_id, url in source_urls(args.app):
            print(f"{component}\t{license_id}\t{url}")
    else:
        release(args.app, pathlib.Path(args.dist))


if __name__ == "__main__":
    main()
