"""Builds store.json (see ../SPEC.md) from the repository: each app's apkg.rc and built packages, each recipe's
recipe.json and files, and store/metadata.json for what apkg.rc doesn't hold. Validates the result (and every
recipe.json) against the schemas when the jsonschema package is available.

    python3 store/tools/build_store.py --output store.json \
        --base-url https://raw.githubusercontent.com/<owner>/<repo>/<commit>/ \
        --package-url 'https://github.com/<owner>/<repo>/releases/download/{id}-v{version}/{file}'

Apps are listed with the packages found in packages/<id>/<version>/ (one .bin per model); apps without any built
package are skipped, with a warning.

With --external, apps published by others (metadata.json's "external": e.g. Plex Media Server, which Plex builds for WD's
NAS models) are listed too: their packages stay where their publisher hosts them, and are downloaded once (into
packages/_external/, checked against the publisher's checksum) for their sizes and SHA256.

With --sign-key (an Ed25519 private key in PEM, e.g. from `openssl genpkey -algorithm ed25519 -out key.pem`), its public
key goes in store.json and store.json.sig is written next to it (needs OpenSSL 3 and --output).
"""

import argparse
import base64
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[2]
STORE = REPO / "store"
# The files of a recipe the Store downloads: recipe.json, and the files it refers to (README.md, setup.sh and
# example.env are for using a recipe by hand)
RECIPE_FILES = ("recipe.json", "icon.svg", "icon.png")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_apkg_rc(path):
    """apkg.rc's fields (Key: value lines)."""
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z]+):\s*(.*?)\s*$", line)
        if match:
            fields[match.group(1)] = match.group(2)
    return fields


def app_entry(app_dir, metadata, args):
    rc = read_apkg_rc(app_dir / "apkg.rc")
    app_id, version = rc["Package"], rc["Version"]
    packages = []
    for package in sorted((REPO / "packages" / app_id / version).glob(f"{app_id}_{version}_*.bin")):
        model = package.name[len(f"{app_id}_{version}_"):-len(".bin")]
        packages.append({
            "model": model,
            "url": args.package_url.format(id=app_id, version=version, file=package.name),
            "size": package.stat().st_size,
            "sha256": sha256(package),
        })
    if not packages:
        print(f"warning: no packages built for {app_id} {version} - skipped", file=sys.stderr)
        return None
    entry = {
        "id": app_id,
        "name": rc.get("AddonShowName") or app_id,
        "version": version,
        "summary": rc.get("Description", "").rstrip("."),
    }
    # (WD's descriptions start with the app's name, e.g. "Navidrome: stream your music..." - redundant in the Store)
    prefix = re.match(r"^([^:]{1,40}):\s+(.)", entry["summary"])
    if prefix and prefix.group(1).lower() in (entry["name"].lower() + " " + app_id.lower()):
        entry["summary"] = prefix.group(2).upper() + entry["summary"][prefix.end():]
    if rc.get("Icon") and (app_dir / "web" / rc["Icon"]).is_file():
        entry["icon"] = f"apps/{app_dir.name}/web/{rc['Icon']}"
    if rc.get("Homepage", "").startswith("https://"):
        entry["homepage"] = rc["Homepage"]
    if args.sources_url:
        entry["sources"] = args.sources_url.format(path=f"apps/{app_dir.name}")
    if args.release_url:
        entry["release_notes"] = args.release_url.format(id=app_id, version=version)
    if rc.get("MinFWVer") or rc.get("MaxFWVer"):
        entry["firmware"] = {key: rc[field] for key, field in (("min", "MinFWVer"), ("max", "MaxFWVer")) if rc.get(field)}
    entry.update(metadata)
    entry["packages"] = packages
    return entry


# Publishers' lists of their packages for WD's NAS models: feed name -> function(metadata) -> (version, [(model, url,
# sha1)])
def plex_feed(metadata):
    """Plex's list of its downloads: the "Western Digital (OS 5)" entry has one package per model (its file name ends
    in -<model>_OS5.bin). Its version has the build's hash after a "-", which the installed app's version hasn't"""
    with urllib.request.urlopen("https://plex.tv/api/downloads/5.json", timeout=60) as response:
        feed = json.load(response)
    os5 = feed["nas"]["Western Digital (OS 5)"]
    packages = []
    for release in os5["releases"]:
        model = re.search(r"-([A-Za-z0-9]+)_OS5\.bin$", release["url"])
        if model and release["url"].startswith("https://"):
            packages.append((model.group(1), release["url"], release["checksum"]))
    return os5["version"].split("-")[0], packages


FEEDS = {"plex": plex_feed}


def external_entry(app_id, metadata):
    """An app published by someone else, from its publisher's list: its packages are downloaded once (cached in
    packages/_external/<id>/<version>/), checked against the publisher's SHA1, for their sizes and SHA256"""
    version, found = FEEDS[metadata["feed"]](metadata)
    cache = REPO / "packages" / "_external" / app_id / version
    cache.mkdir(parents=True, exist_ok=True)
    packages = []
    for model, url, sha1 in found:
        file = cache / url.rsplit("/", 1)[1]
        if not file.is_file():
            print(f"downloading {url}", file=sys.stderr)
            with urllib.request.urlopen(url, timeout=600) as response, open(str(file) + ".part", "wb") as out:
                while True:
                    block = response.read(1 << 20)
                    if not block:
                        break
                    out.write(block)
            pathlib.Path(str(file) + ".part").rename(file)
        if hashlib.sha1(file.read_bytes()).hexdigest() != sha1:
            file.unlink()
            sys.exit(f"{url} doesn't match its publisher's checksum")
        packages.append({"model": model, "url": url, "size": file.stat().st_size, "sha256": sha256(file)})
    entry = {"id": app_id, "version": version}
    entry.update({key: value for key, value in metadata.items() if key != "feed" and not key.startswith("_")})
    entry["packages"] = packages
    return entry


def recipe_entry(recipe_dir, metadata, validate):
    recipe = json.loads((recipe_dir / "recipe.json").read_text(encoding="utf-8"))
    if validate:
        validate(recipe, "recipe.schema.json", recipe_dir / "recipe.json")
    names = set(RECIPE_FILES) | {recipe["compose"]} | set(recipe.get("hooks", {}).values())
    if recipe.get("description"):
        names.add(recipe["description"])
    files = {name: sha256(recipe_dir / name) for name in sorted(names) if (recipe_dir / name).is_file()}
    missing = [name for name in names - set(RECIPE_FILES) if name not in files]
    if missing:
        raise SystemExit(f"{recipe_dir.name}: files missing: {', '.join(missing)}")
    entry = {key: recipe[key] for key in ("id", "name", "version", "summary") if key in recipe}
    for icon in ("icon.svg", "icon.png"):
        if icon in files:
            entry["icon"] = f"recipes/{recipe_dir.name}/{icon}"
            break
    entry.update(metadata)
    if recipe.get("requires"):
        entry["requires"] = recipe["requires"]
    entry["path"] = f"recipes/{recipe_dir.name}/"
    entry["files"] = files
    return entry


def make_validator():
    """A function validating a document against one of the schemas, or None without the jsonschema package."""
    try:
        import jsonschema
        import referencing
    except ImportError:
        print("warning: jsonschema isn't installed - nothing validated", file=sys.stderr)
        return None
    schemas = {name: json.loads((STORE / "schema" / name).read_text(encoding="utf-8"))
               for name in ("store.schema.json", "recipe.schema.json")}
    registry = referencing.Registry().with_resources(
        [(name, referencing.Resource.from_contents(schema)) for name, schema in schemas.items()]
        + [(schema["$id"], referencing.Resource.from_contents(schema)) for schema in schemas.values()])

    def validate(document, schema_name, label):
        validator = jsonschema.Draft202012Validator(schemas[schema_name], registry=registry,
                                                    format_checker=jsonschema.FormatChecker())
        errors = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
        for error in errors:
            print(f"{label}: {'/'.join(map(str, error.path)) or '(top)'}: {error.message}", file=sys.stderr)
        if errors:
            raise SystemExit(f"{label} isn't valid")

    return validate


def main():
    parser = argparse.ArgumentParser(description="Builds store.json from the repository")
    parser.add_argument("--output", default="-", help="where to write it (default: standard output)")
    parser.add_argument("--base-url", help="base for relative URLs (an immutable raw URL, ending in /)")
    parser.add_argument("--package-url", required=True, help="URL of a package: {id}, {version} and {file} are replaced")
    parser.add_argument("--sources-url", help="URL of an app's sources: {path} is replaced (e.g. .../tree/main/{path})")
    parser.add_argument("--release-url", help="URL of an app's release notes: {id} and {version} are replaced")
    parser.add_argument("--sign-key", help="Ed25519 private key (PEM) to sign store.json with (writes store.json.sig)")
    parser.add_argument("--external", action="store_true", help="also list the apps published by others (downloads them once)")
    args = parser.parse_args()
    if args.sign_key and args.output == "-":
        parser.error("--sign-key needs --output")

    validate = make_validator()
    metadata = json.loads((STORE / "metadata.json").read_text(encoding="utf-8"))
    # (the repository's own details - what a fork changes - are in metadata.json's "repository")
    store = {"store_version": 1}
    store.update({key: value for key, value in metadata["repository"].items() if key in ("name", "summary", "homepage", "maintainer")})
    store["updated"] = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    if args.base_url:
        store["base_url"] = args.base_url
    if args.sign_key:
        der = subprocess.run(["openssl", "pkey", "-in", args.sign_key, "-pubout", "-outform", "DER"],
                             check=True, capture_output=True).stdout
        store["public_key"] = "ed25519:" + base64.b64encode(der).decode()
    store["apps"] = []
    for app_dir in sorted((REPO / "apps").iterdir(), key=lambda path: path.name.lower()):
        if (app_dir / "apkg.rc").is_file() and app_dir.name != "template":
            entry = app_entry(app_dir, metadata["apps"].get(app_dir.name, {}), args)
            if entry:
                store["apps"].append(entry)
    if args.external:
        for app_id, app_metadata in metadata.get("external", {}).items():
            store["apps"].append(external_entry(app_id, app_metadata))
        store["apps"].sort(key=lambda app: app["id"].lower())
    store["recipes"] = [recipe_entry(path.parent, metadata["recipes"].get(path.parent.name, {}), validate)
                        for path in sorted((REPO / "recipes").glob("*/recipe.json"))]
    if validate:
        validate(store, "store.schema.json", "store.json")

    text = json.dumps(store, indent="\t", ensure_ascii=False) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        pathlib.Path(args.output).write_text(text, encoding="utf-8")
        print(f"wrote {args.output}: {len(store['apps'])} apps, {len(store['recipes'])} recipes", file=sys.stderr)
        if args.sign_key:
            # The signature of store.json's exact bytes (SPEC.md section 6)
            with tempfile.TemporaryDirectory() as temp:
                signature = pathlib.Path(temp) / "sig"
                subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", args.sign_key, "-rawin", "-in", args.output,
                                "-out", str(signature)], check=True)
                pathlib.Path(args.output + ".sig").write_text(base64.b64encode(signature.read_bytes()).decode() + "\n")
            print(f"wrote {args.output}.sig", file=sys.stderr)


if __name__ == "__main__":
    main()
