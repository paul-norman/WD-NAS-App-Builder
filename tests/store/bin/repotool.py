"""
Changes the test repositories' store.json (and re-signs it):

    add-recipe <repo> <fixture> | add-app <repo> <id> <keeps_data>
    | set-app <repo> <id> <field> <json> | sign <repo> <key>
    | tamper <repo> | evil <dir>

add-app adds a test app (version 1.0, with a small package for the PR4100 -
WD's installer's stand-in never opens it), with or without keeps_data
(true / false).
"""
import base64, hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile

cmd, repo = sys.argv[1], pathlib.Path(sys.argv[2])
store_file = repo / "store.json"


def load():
    """
    The repository's store.json.

    :return: Its catalogue
    """
    return json.loads(store_file.read_text())


def keypair(key):
    """
    The seed of an Ed25519 private key: the last 32 bytes of its DER. It's
    signed with PHP's sodium, which the test container has - its OpenSSL 1.1
    can't sign Ed25519 data directly.

    :param str key: The key's PEM file

    :return: The seed
    """
    der = base64.b64decode(
        "".join(
            line
            for line in pathlib.Path(key).read_text().splitlines()
            if "-----" not in line
        )
    )

    return der[-32:]


def php_sign(seed, path):
    """
    Signs a file with PHP's sodium.

    :param bytes seed: The key's seed
    :param str   path: The file

    :return: [the signature, the public key] in base64 - the key as a
        SubjectPublicKeyInfo
    """
    code = (
        "$k=sodium_crypto_sign_seed_keypair(hex2bin($argv[1]));"
        " echo base64_encode(sodium_crypto_sign_detached("
        "file_get_contents($argv[2]), sodium_crypto_sign_secretkey($k))),"
        ' "|", base64_encode(hex2bin("302a300506032b6570032100")'
        " . sodium_crypto_sign_publickey($k));"
    )
    out = subprocess.run(
        ["php", "-r", code, seed.hex(), path],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    return out.split("|")


def save(store, key=None):
    """
    Writes the repository's store.json, signed with the key if one is given
    (its public key added first).

    :param dict     store: The catalogue
    :param str|None key:   The signing key's PEM file, or None
    """
    if key:
        seed = keypair(key)
        store_file.write_text("{}")
        store["public_key"] = (
            "ed25519:" + php_sign(seed, str(store_file))[1]
        )

    store_file.write_text(json.dumps(store, indent=4) + "\n")

    if key:
        (repo / "store.json.sig").write_text(
            php_sign(seed, str(store_file))[0] + "\n"
        )


key = (
    (repo / ".key").read_text().strip()
    if (repo / ".key").exists()
    else None
)

if cmd == "add-recipe":
    fixture = pathlib.Path(sys.argv[3])
    r = json.loads((fixture / "recipe.json").read_text())
    target = repo / "recipes" / r["id"]

    if target.is_symlink():
        target.unlink()

    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(fixture, target)
    # The files the real repository lists - build_store.py's choice - so that a file a recipe needs but doesn't list fails here too
    sys.path.insert(
        0, os.path.join(os.environ["STORE_TEST_PROJECT"], "store", "tools")
    )
    from build_store import recipe_file_names

    files = {
        name: hashlib.sha256((target / name).read_bytes()).hexdigest()
        for name in sorted(recipe_file_names(target, r))
        if (target / name).is_file()
    }
    entry = {k: r[k] for k in ("id", "name", "version", "summary")}
    entry.update({
        "categories": ["development"],
        "requires": r.get("requires", {}),
        "path": f"recipes/{r['id']}/",
        "files": files,
    })
    store = load()
    store["recipes"] = [
        e for e in store["recipes"] if e["id"] != r["id"]
    ] + [entry]
    save(store, key)
elif cmd == "add-app":
    app_id, keeps = sys.argv[3], sys.argv[4] == "true"
    version, model = "1.0", "MyCloudPR4100"
    name = f"{app_id}_{version}_{model}.bin"
    package = repo / "packages" / app_id / version / name
    package.parent.mkdir(parents=True, exist_ok=True)
    package.write_bytes(f"{app_id} {version} test package\n".encode() * 64)
    entry = {
        "id": app_id,
        "name": app_id.capitalize(),
        "version": version,
        "summary": f"A test app ({'keeps' if keeps else 'without'} its data)",
        "categories": ["development"],
        "license": "MIT",
        "packages": [{
            "model": model,
            "url": f"https://repo.test:8443/releases/{app_id}/{version}/{name}",
            "size": package.stat().st_size,
            "sha256": hashlib.sha256(package.read_bytes()).hexdigest(),
        }],
    }

    if keeps:
        entry.update({"data_folder": f"_{app_id}", "keeps_data": True})

    store = load()
    store["apps"] = [
        a for a in store["apps"] if a["id"] != app_id
    ] + [entry]
    save(store, key)
elif cmd == "set-app":
    store = load()

    for a in store["apps"]:
        if a["id"] == sys.argv[3]:
            a[sys.argv[4]] = json.loads(sys.argv[5])

    save(store, key)
elif cmd == "sign":
    (repo / ".key").write_text(sys.argv[3])
    save(load(), sys.argv[3])
elif cmd == "tamper":
    store_file.write_text(
        store_file.read_text().replace(
            '"summary": "', '"summary": "Changed: ', 1
        )
    )
elif cmd == "evil":
    # Third-party repositories: evil = a catalogue with a path escaping its
    # recipe (refused as a whole); evil2 = valid, with a recipe whose file
    # doesn't match its checksum, and an app whose package doesn't match its
    # checksum
    repo.mkdir(parents=True, exist_ok=True)
    base = {
        "store_version": 1,
        "name": "Evil",
        "summary": "Test",
        "updated": "2026-10-22T00:00:00Z",
        "base_url": "https://evil.test:8443/",
    }
    bad = dict(
        base,
        recipes=[{
            "id": "bad",
            "name": "Bad",
            "version": "1",
            "summary": "x",
            "path": "recipes/bad/",
            "files": {
                "recipe.json": "0" * 64,
                "../../../tmp/pwn.sh": "0" * 64,
            },
        }],
    )
    (repo / "store.json").write_text(json.dumps(bad))
    two = repo / "two"
    (two / "recipes" / "tampered").mkdir(parents=True, exist_ok=True)
    hello = pathlib.Path(sys.argv[3])

    for f in ("recipe.json", "compose.yaml"):
        shutil.copy(hello / f, two / "recipes" / "tampered" / f)

    rj = json.loads((two / "recipes/tampered/recipe.json").read_text())
    rj["id"] = "tampered"
    rj.pop("hooks")
    rj.pop("description")
    (two / "recipes/tampered/recipe.json").write_text(json.dumps(rj))
    files = {
        f: hashlib.sha256(
            (two / "recipes/tampered" / f).read_bytes()
        ).hexdigest()
        for f in ("recipe.json", "compose.yaml")
    }
    files["compose.yaml"] = "1" * 64
    (two / "packages").mkdir(exist_ok=True)
    (two / "packages/x.bin").write_bytes(b"not the real package")
    store2 = dict(
        base,
        name="Evil two",
        base_url="https://evil.test:8443/two/",
        recipes=[{
            "id": "tampered",
            "name": "Tampered",
            "version": "1",
            "summary": "x",
            "path": "recipes/tampered/",
            "files": files,
        }],
        apps=[
            {
                "id": "badpkg",
                "name": "Bad package",
                "version": "1.0",
                "summary": "x",
                "packages": [{
                    "model": "MyCloudPR4100",
                    "url": "packages/x.bin",
                    "size": 20,
                    "sha256": "2" * 64,
                }],
            },
            {
                "id": "downgrade",
                "name": "Downgrade",
                "version": "1.0",
                "summary": "x",
                "packages": [{
                    "model": "MyCloudPR4100",
                    "url": "https://repo.test:8443/downgrade/x.bin",
                    "size": 20,
                    "sha256": "2" * 64,
                }],
            },
            {
                "id": "nomodel",
                "name": "Other model",
                "version": "1.0",
                "summary": "x",
                "packages": [{
                    "model": "WDMyCloudEX2100",
                    "url": "packages/x.bin",
                    "size": 20,
                    "sha256": "2" * 64,
                }],
            },
        ],
    )
    (two / "store.json").write_text(json.dumps(store2))
