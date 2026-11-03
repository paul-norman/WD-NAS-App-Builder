#!/bin/bash
# Builds store.json for the commit CI is on (see README.md), signs it and commits it (with store.json.sig) to main, if
# anything in it changed besides the commit it points to:
#
#     ci/publish_store.sh <signing key>
#
# Run by the release job, after ci/release.py publish (the packages it just released are in packages/). Apps not built
# here keep their entries from the store.json on main (or are indexed from their releases). Needs GITHUB_REPOSITORY,
# gh (GH_TOKEN), and git credentials allowed to push to main.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

KEY="$1"
SLUG="${GITHUB_REPOSITORY}"
SHA="$(git rev-parse HEAD)"
TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci-store"
rm -rf "${TEMP}"
mkdir -p "${TEMP}"

# The store.json on main now (not this commit's: a later run may have published since)
git fetch -q origin main || exit 1
git show origin/main:store.json > "${TEMP}/previous.json" 2>/dev/null || rm -f "${TEMP}/previous.json"

python3 ci/release.py index --previous "${TEMP}/previous.json" --output "${TEMP}/released.json" || exit 1
python3 store/tools/build_store.py --output "${TEMP}/store.json" \
    --base-url "https://raw.githubusercontent.com/${SLUG}/${SHA}/" \
    --package-url "https://github.com/${SLUG}/releases/download/{id}-v{version}/{file}" \
    --sources-url "https://github.com/${SLUG}/tree/${SHA}/{path}" \
    --release-url "https://github.com/${SLUG}/releases/tag/{id}-v{version}" \
    --previous "${TEMP}/previous.json" --released "${TEMP}/released.json" \
    --sign-key "${KEY}" --external || exit 1

# The same apart from when it was built and the commit it points to: nothing to publish
if python3 - "${TEMP}/previous.json" "${TEMP}/store.json" <<'EOF'
import json
import pathlib
import sys


def content(path):
    """
    A store.json without the fields every build changes.

    :param str path: The file

    :return: Its content, or None if it doesn't exist
    """
    if not pathlib.Path(path).is_file():
        return None

    store = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    store.pop("updated", None)
    store.pop("base_url", None)

    for app in store.get("apps", []):
        app.pop("sources", None)

    return store


sys.exit(0 if content(sys.argv[1]) == content(sys.argv[2]) else 1)
EOF
then
    echo 'store.json: nothing changed'

    exit 0
fi

# Commit it on top of main as it is now, trying again if main moves meanwhile
for attempt in 1 2 3; do
    git fetch -q origin main || exit 1
    rm -rf "${TEMP}/main"
    git worktree add -q --detach "${TEMP}/main" origin/main || exit 1
    cp "${TEMP}/store.json" "${TEMP}/store.json.sig" "${TEMP}/main/"
    (
        cd "${TEMP}/main" || exit 1
        git add store.json store.json.sig
        git commit -q -m "Update store.json for ${SHA:0:12} [skip ci]" || exit 1
        git push -q origin HEAD:main
    )
    STATUS=$?
    git worktree remove --force "${TEMP}/main"

    if [ "${STATUS}" = 0 ]; then
        echo "store.json: published for ${SHA:0:12}"

        exit 0
    fi

    echo "store.json: the push failed (attempt ${attempt}) - trying again"
    sleep 10
done

echo '::error::store.json could not be pushed to main'

exit 1
