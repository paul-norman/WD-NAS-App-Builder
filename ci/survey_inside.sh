#!/bin/sh
# Lists the distribution packages a static build may have put into its output (see README.md, Sources), from inside one
# stage of its Dockerfile (Debian or Alpine): those holding static libraries (.a - what it may have linked into its
# programs), and those holding the shared libraries its output bundles (the .so files in /out, matched by name). Run by
# ci/survey.sh:
#
#     sh /survey_inside.sh <stage>
#
# Prints one tab separated line per package: os, os version, stage, source package, source version, license (Alpine's
# own field; on Debian "copyleft" or "other", from its copyright file), why (static, or bundled:<file>), aports commit
# (Alpine) and package name.

STAGE="$1"
. /etc/os-release
OS="${ID}"
OS_VERSION="${VERSION_ID:-unknown}"

# The bundled shared libraries' names: every .so file in the output.
#
# Prints one name a line
bundled_names() {
    [ -d /out ] || return 0

    find /out -type f \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null | sed 's#.*/##' | sort -u
}

if [ "${OS}" = 'alpine' ]; then
    BUNDLED="$(bundled_names | tr '\n' ' ')"
    # Alpine's database: a paragraph per package (P name, V version, o origin, c aports commit, L license, F folder, R
    # file)
    awk -v os="${OS}" -v osv="${OS_VERSION}" -v stage="${STAGE}" -v bundled=" ${BUNDLED} " '
        function flush() {
            if (name != "" && why != "") {
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", os, osv, stage, origin, version, license, why, commit,
                    name
            }
            name = ""; version = ""; origin = ""; commit = ""; license = ""; folder = ""; why = ""
        }
        /^$/ { flush(); next }
        /^P:/ { name = substr($0, 3) }
        /^V:/ { version = substr($0, 3) }
        /^o:/ { origin = substr($0, 3) }
        /^c:/ { commit = substr($0, 3) }
        /^L:/ { license = substr($0, 3) }
        /^F:/ { folder = substr($0, 3) }
        /^R:/ {
            file = substr($0, 3)

            if (file ~ /\.a$/ && folder ~ /^(usr\/)?lib/ && why == "") {
                why = "static"
            }

            if (index(bundled, " " file " ") && (file ~ /\.so$/ || file ~ /\.so\./)) {
                why = "bundled:" file
            }
        }
        END { flush() }
    ' /lib/apk/db/installed

    exit 0
fi

if [ "${OS}" = 'debian' ] || [ "${OS}" = 'ubuntu' ]; then
    {
        dpkg -S '/usr/lib/*.a' '/lib/*.a' 2>/dev/null | sed 's/: .*//; s/, /\n/g' | sed 's/$/\tstatic/'

        for file in $(bundled_names); do
            dpkg -S "*/${file}" 2>/dev/null | head -n 1 | sed "s/: .*//; s/, .*//; s/\$/\tbundled:${file}/"
        done
    } | sort -u | while IFS="$(printf '\t')" read -r package why; do
        package="${package%%:*}"
        source="$(dpkg-query -W -f '${source:Package}\t${source:Version}' "${package}" 2>/dev/null)"
        [ -n "${source}" ] || continue
        copyright="/usr/share/doc/${package}/copyright"
        license='other'

        if grep -qE 'GPL|MPL|Mozilla Public' "${copyright}" 2>/dev/null; then
            license='copyleft'
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n' "${OS}" "${OS_VERSION}" "${STAGE}" "${source}" "${license}" "${why}" \
            "${package}"
    done

    exit 0
fi

echo "unknown distribution: ${OS}" >&2

exit 1
