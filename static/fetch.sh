#!/bin/sh
# Downloads a file a static build needs and checks it against its SHA256, falling back to this repository's mirror when
# its own site fails (see ci/README.md, The source mirror). Used by the static builds (in their containers:
# /data/static/fetch.sh) and by build_static.sh for their Dockerfiles' downloads:
#
#     sh static/fetch.sh <url> <file> <sha256> [<other url> ...]
#
# Tries, in turn: the copy kept from an earlier download ($MIRROR_DIR/<sha256>, default packages/mirror under the
# repository - /data/packages/mirror in a build's container), the URL itself (three times), any other URLs given (other
# sites with the very same file, e.g. Debian's copy of an upstream release), then the mirror ($MIRROR_URL/<sha256>, a
# release of this repository). Only a file matching the SHA256 is used; it's kept in $MIRROR_DIR for next time (and for
# CI to add to the mirror). Exits non-zero if none worked.

URL="$1"
FILE="$2"
SHA256="$3"
shift 3 2>/dev/null
OTHER_URLS="$*"
MIRROR_DIR="${MIRROR_DIR:-$(cd "$(dirname "$0")/.." && pwd)/packages/mirror}"

if [ -z "${URL}" ] || [ -z "${FILE}" ] || [ "${#SHA256}" != 64 ]; then
    echo 'Usage: fetch.sh <url> <file> <sha256> [<other url> ...]' >&2

    exit 2
fi

# Downloads a URL into the file (wget or curl, whichever the build has).
#
# $1 url The URL
#
# Returns 0 if it downloaded
get() {
    if command -v wget > /dev/null 2>&1; then
        wget -q "$1" -O "${FILE}"
    else
        curl -sSfL --retry 2 "$1" -o "${FILE}"
    fi
}

# Whether the file matches the SHA256.
#
# Returns 0 if it does
matches() {
    [ -f "${FILE}" ] && [ "$(sha256sum "${FILE}" | cut -d ' ' -f 1)" = "${SHA256}" ]
}

if [ -f "${MIRROR_DIR}/${SHA256}" ]; then
    cp "${MIRROR_DIR}/${SHA256}" "${FILE}"

    if matches; then
        echo "fetch: ${FILE} (kept copy)"

        exit 0
    fi
fi

for attempt in 1 2 3; do
    if get "${URL}" && matches; then
        echo "fetch: ${FILE} from ${URL}"
        break
    fi

    rm -f "${FILE}"
    [ "${attempt}" = 3 ] || sleep $((attempt * 10))
done

for other in ${OTHER_URLS}; do
    matches && break
    echo "fetch: trying ${other}" >&2

    if get "${other}" && matches; then
        echo "fetch: ${FILE} from ${other}"
    fi
done

if ! matches && [ -n "${MIRROR_URL:-}" ]; then
    echo "fetch: ${URL} failed - trying the mirror" >&2

    if get "${MIRROR_URL}/${SHA256}" && matches; then
        echo "fetch: ${FILE} from the mirror (${MIRROR_URL})"
    fi
fi

if ! matches; then
    rm -f "${FILE}"
    echo "fetch: ${FILE} couldn't be got from ${URL}${MIRROR_URL:+ or the mirror} (or didn't match ${SHA256})" >&2

    exit 1
fi

# Kept for next time (and for CI's mirror), if there's somewhere to keep it
if mkdir -p "${MIRROR_DIR}" 2>/dev/null && [ -w "${MIRROR_DIR}" ]; then
    cp "${FILE}" "${MIRROR_DIR}/${SHA256}.part" && mv "${MIRROR_DIR}/${SHA256}.part" "${MIRROR_DIR}/${SHA256}"
fi
