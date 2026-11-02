#!/bin/sh
# Runs Calibre-Web (e-book library) as its own user, with its data in the persistent path (Nas_Prog/_calibre-web - kept
# across reinstalls) and the book library on a share:
#   cw_ctl.sh setup                 - create its user and folders (where missing)
#   cw_ctl.sh start                 - start it (on port 8083: the network, or the NAS itself only). The first time, it
#                                     also creates the library (if there isn't one) and the admin user's password
#   cw_ctl.sh stop                  - stop Calibre-Web
#   cw_ctl.sh restart               - stop, then start
#   cw_ctl.sh new-password          - give the admin user a new (generated) password
#   cw_ctl.sh library <path>        - use (or create) the library in a folder, then restart
#   cw_ctl.sh ingest                - add the books in the ingest folder to the library (every minute, from cron)
#   cw_ctl.sh daily                 - the daily job: backups of Calibre-Web's settings and the library's database
#   cw_ctl.sh nginx                 - add / update Calibre-Web's site in the Nginx app (and reload it)
#   cw_ctl.sh run <program> [args]  - run a program as Calibre-Web's user, with its environment (e.g. Calibre's
#                                     binaries/calibre/ebook-convert, to try a conversion by hand)
#
# Calibre's own programs (conversion, the library) need a newer glibc than the NAS's: they're patched to use the one in
# binaries/runtime, by its full path - so the app only works from where the NAS installs it (Nas_Prog on the first
# volume)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_calibre-web"
# PHP finds the Nginx app's address: wherever it is, also when run with a minimal PATH, e.g. from the management page
PATH="${PATH}:/usr/bin:/usr/local/bin"
BIN="${APP_PATH}/binaries"
EXPECTED_BIN=/mnt/HD/HD_a2/Nas_Prog/calibre-web/binaries
CW_DATA="${DATA_PATH}/data"
BACKUP_DIR="${DATA_PATH}/backups"
SETTINGS_FILE="${DATA_PATH}/settings"
PASSWORD_FILE="${DATA_PATH}/admin_password"
INGEST_LOG="${DATA_PATH}/ingest.log"
VERSIONS_FILE="${DATA_PATH}/versions"
PID_FILE=/var/run/calibre-web.pid
LOCK_DIR=/var/run/calibre-web-ingest.lock
PORT=8083
ADMIN=admin
# Its own user and group (created if missing): the IDs used when creating them
CW_ID=80
LOG=/tmp/debug_apkg

# Writes a line to the NAS's app log (/tmp/debug_apkg), with the time and the script's name, and prints it.
#
# $* The line
#
# Prints the line
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') calibre-web/cw_ctl.sh $*" >> ${LOG}
    echo "$*"
}

# A setting from the app's settings file (KEY=value lines, written by its management page).
#
# $1 name    The setting (e.g. LISTEN)
# $2 default What to print if it isn't set
#
# Prints its value, or the default
setting() {
    value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
    echo "${value:-$2}"
}

# Whether the app's process is running (its PID file's process).
#
# Returns 0 if it is
running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

# The user's ID and group ID, from the NAS's own user list
cw_ids() {
    awk -F: '$1 == "calibreweb" { print $3 " " $4 }' /etc/passwd
}

# A random string of letters and digits: $1 its length
random_text() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"
}

# Runs a program as Calibre-Web's user, with the environment its programs need (Calibre's converter: a writable home and
# settings folder, Chromium - for PDFs - without a sandbox or a GPU, and with its shared memory in the temporary folder:
# WD's /dev/shm isn't writable by other users; ImageMagick, Ghostscript and libmagic: where their files are; the
# certificate authorities to trust for HTTPS - certifi's, bundled: its Python looks in /etc/ssl, where the NAS has none
# it can use - e.g. for the book details it looks up). With CW_EXEC=exec, it replaces the shell (so that the PID started
# is Calibre-Web's)
as_cw() {
    set -- $(cw_ids) "$@"
    ${CW_EXEC} env -i PATH="${BIN}/bin:${BIN}/calibre:/usr/sbin:/usr/bin:/sbin:/bin" LANG=C.UTF-8 HOME="${CW_DATA}/home" \
        TMPDIR="${CW_DATA}/tmp" CALIBRE_DBPATH="${CW_DATA}" CALIBRE_CONFIG_DIRECTORY="${CW_DATA}/calibre-config" \
        CALIBRE_TEMP_DIR="${CW_DATA}/tmp" QTWEBENGINE_CHROMIUM_FLAGS='--no-sandbox --disable-gpu --disable-dev-shm-usage' \
        MAGICK_HOME="${BIN}/magick" MAGICK_CONFIGURE_PATH="${BIN}/magick/etc" \
        MAGICK_CODER_MODULE_PATH="${BIN}/magick/modules-Q16/coders" MAGICK_CODER_FILTER_PATH="${BIN}/magick/modules-Q16/filters" \
        GS_LIB="${BIN}/ghostscript/Resource/Init:${BIN}/ghostscript/lib:${BIN}/ghostscript/Resource/Font" \
        GS_OPTIONS="-sICCProfilesDir=${BIN}/ghostscript/iccprofiles/" \
        MAGIC="${BIN}/magic.mgc" PYTHONDONTWRITEBYTECODE=1 SSL_CERT_FILE="${BIN}/python/lib/python3.14/site-packages/certifi/cacert.pem" \
        "${BIN}/cw_runas" "$@"
}

# The app's helper (lib/cw.py), run by root with the app's Python
helper() {
    "${BIN}/python/bin/python3" "${APP_PATH}/lib/cw.py" "$@"
}

setup() {
    # The programs find their runtime by its full path: the app must be where it was prepared for
    if [ "${BIN}" != "${EXPECTED_BIN}" ]; then
        log "Calibre-Web must be installed in ${EXPECTED_BIN%/binaries} (it's in ${APP_PATH}): Calibre's programs can't run elsewhere"

        return 1
    fi

    # Its own user (the NAS's user list is in RAM, so this is redone at every boot)
    grep -q '^calibreweb:' /etc/group || addgroup -g ${CW_ID} calibreweb
    grep -q '^calibreweb:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${CW_ID} -G calibreweb calibreweb

    if [ -z "$(cw_ids)" ]; then
        log "Could not create the calibreweb user (are ID ${CW_ID}'s user or group already taken?)"

        return 1
    fi

    set -- $(cw_ids)

    # Chromium (Calibre's PDF output) needs to read the system's random numbers, which WD's firmware lets only root read
    # (standard Linux: everyone). Reading them is harmless, so other users get read access - as on any other Linux
    # system
    for device in /dev/urandom /dev/random; do
        if [ -c "${device}" ] && [ "$(stat -c %A "${device}" | cut -c 8)" != r ]; then
            chmod o+r "${device}" && log "made ${device} readable by all users (as on standard Linux): Calibre's PDF output needs it"
        fi
    done

    # Its data (settings and users, its log, Calibre's settings, temporary files) belongs to its user; the backups, the
    # page's settings and the admin password to root
    mkdir -p "${CW_DATA}/home" "${CW_DATA}/calibre-config" "${CW_DATA}/tmp" "${BACKUP_DIR}"
    chmod 711 "${DATA_PATH}"
    chown -R "$1:$2" "${CW_DATA}"
    chmod 700 "${CW_DATA}" "${BACKUP_DIR}"

    if [ ! -f "${SETTINGS_FILE}" ]; then
        log "creating the default settings: ${SETTINGS_FILE}"
        printf 'LIBRARY=%s\nLISTEN=all\nINGEST=0\nINGEST_FOLDER=%s\nINGEST_CONVERT=none\n' \
            '/mnt/HD/HD_a2/Public/Books/Calibre Library' '/mnt/HD/HD_a2/Public/Books/Add to library' > "${SETTINGS_FILE}"
    fi

    chmod 600 "${SETTINGS_FILE}"
    touch "${INGEST_LOG}"
    chmod 600 "${INGEST_LOG}"
    versions
}

# The versions of Calibre-Web, Calibre and kepubify (for the management page): found once per version of the app
versions() {
    app_version="$(sed -n 's/^Version:[[:space:]]*//p' "${APP_PATH}/apkg.rc" | tr -d '\r')"
    grep -q "^APP=${app_version}$" "${VERSIONS_FILE}" 2>/dev/null && return 0
    calibre="$(as_cw "${BIN}/calibre/ebook-convert" --version 2>/dev/null | sed -n 's/.*(calibre \([^)]*\)).*/\1/p' | head -n 1)"
    kepubify="$("${BIN}/kepubify-linux-64bit" --version 2>/dev/null | sed -n 's/^kepubify v\{0,1\}//p' | head -n 1)"
    printf 'APP=%s\nCALIBRE_WEB=%s\nCALIBRE=%s\nKEPUBIFY=%s\n' "${app_version}" "$(echo "${app_version}" | sed 's/-[0-9]*$//')" \
        "${calibre}" "${kepubify}" > "${VERSIONS_FILE}"
}

# The library: created in its folder if there isn't one (an empty Calibre library), and Calibre-Web's user must be able
# to change it - books are added, edited and converted in it
library_setup() {
    library="$(setting LIBRARY)"
    set -- $(cw_ids)
    mkdir -p "${library}" || return 1

    if [ ! -f "${library}/metadata.db" ]; then
        log "creating a new library in: ${library}"
        chown "$1:$2" "${library}"
        as_cw "${BIN}/calibre/calibredb" --library-path "${library}" list > /dev/null 2>&1

        if [ ! -f "${library}/metadata.db" ]; then
            log "Could not create a library in ${library}"

            return 1
        fi
    fi

    # An existing library, e.g. copied from a computer, is given to Calibre-Web's user: only it changes the library
    if [ "$(stat -c %u "${library}/metadata.db")" != "$1" ]; then
        log "giving Calibre-Web's user the library: ${library}"
        chown -R "$1:$2" "${library}"
    fi
}

# Calibre-Web's settings that the app looks after (before every start): the library, Calibre's programs and kepubify
# (the ones in the app - the only ones that run here), uploads on
configure() {
    set -- $(cw_ids)
    helper configure "${CW_DATA}/app.db" "$(setting LIBRARY)" "${BIN}/calibre" "${BIN}/kepubify-linux-64bit" || return 1
    chown "$1:$2" "${CW_DATA}/app.db"
}

# Waits up to 90 seconds for Calibre-Web to answer
wait_up() {
    waited=0

    while [ ${waited} -lt 90 ]; do
        curl -sf -o /dev/null "http://127.0.0.1:${PORT}/login" && return 0
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

start() {
    if running; then
        log "Calibre-Web is already running with PID: $(cat ${PID_FILE})"

        return 0
    fi

    setup || return 1
    library_setup || return 1

    # The first time: Calibre-Web's settings (it creates them, with the admin user) and the admin user's password
    if [ ! -f "${CW_DATA}/app.db" ] || [ ! -s "${PASSWORD_FILE}" ]; then
        new_password || return 1
    fi

    configure || return 1

    host=''
    [ "$(setting LISTEN all)" = local ] && host='-i 127.0.0.1'

    log "starting Calibre-Web on port ${PORT} (log: ${CW_DATA}/calibre-web.log)"
    cd "${CW_DATA}" || return 1
    ( CW_EXEC=exec; as_cw "${BIN}/python/bin/python3" -m calibreweb -p "${CW_DATA}/app.db" ${host} ) > "${CW_DATA}/console.log" 2>&1 &
    echo $! > "${PID_FILE}"
    log "Calibre-Web started with PID: $(cat ${PID_FILE})"
    wait_up || log "Calibre-Web did not answer within 90 seconds (see ${CW_DATA}/console.log)"
}

stop() {
    if running; then
        pid="$(cat "${PID_FILE}")"
        log "stopping Calibre-Web (PID ${pid})"
        kill "${pid}"
        waited=0

        while kill -0 "${pid}" 2>/dev/null; do
            if [ ${waited} -ge 20 ]; then
                log 'Calibre-Web did not stop within 20 seconds, killing it'
                kill -9 "${pid}" 2>/dev/null
                break
            fi

            sleep 1
            waited=$((waited + 1))
        done
    fi

    rm -f "${PID_FILE}"
}

# A new generated password for the admin user (Calibre-Web's own -s option, which also creates its settings the first
# time). Calibre-Web's password rules want a lower and an upper case letter, a digit and another character: two random
# parts joined by a hyphen, with one of each kind of letter and a digit added
new_password() {
    password="$(random_text 10)-$(random_text 7)$(tr -dc 'a-z' < /dev/urandom | head -c 1)$(tr -dc 'A-Z' < /dev/urandom | head -c 1)$(tr -dc '0-9' < /dev/urandom | head -c 1)"

    if as_cw "${BIN}/python/bin/python3" -m calibreweb -p "${CW_DATA}/app.db" -s "${ADMIN}:${password}" > /dev/null 2>&1; then
        ( umask 077; printf '%s\n' "${password}" > "${PASSWORD_FILE}.tmp" ) && mv -f "${PASSWORD_FILE}.tmp" "${PASSWORD_FILE}"
        log "gave the admin user (${ADMIN}) a new password"
    else
        log "Could not change the admin user's password (is there still a user called ${ADMIN}?)"

        return 1
    fi
}

# Uses (or creates) the library in a folder: the page checks the folder first
set_library() {
    setup || return 1

    if [ -f "${SETTINGS_FILE}" ]; then
        grep -v '^LIBRARY=' "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp"
    fi

    printf 'LIBRARY=%s\n' "$1" >> "${SETTINGS_FILE}.tmp" && chmod 600 "${SETTINGS_FILE}.tmp" && mv -f "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
    stop
    start
}

# Moves a file into a folder, without overwriting one with the same name (the date goes in front)
move_into() {
    target="$2/$(basename "$1")"
    [ -e "${target}" ] && target="$2/$(date '+%Y-%m-%d %H%M%S') $(basename "$1")"
    mv -f "$1" "${target}"
}

ingest_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "${INGEST_LOG}"
}

# Books copied into the ingest folder (e.g. over the network) are added to the library, then moved into its "Added"
# folder - or "Not added", with a note saying why. Files changed in the last minute are left for the next run (they may
# still be being copied)
ingest() {
    [ "$(setting INGEST 0)" = 1 ] || return 0

    folder="$(setting INGEST_FOLDER)"
    library="$(setting LIBRARY)"

    [ -d "${folder}" ] && [ -f "${library}/metadata.db" ] || return 0

    # One at a time
    mkdir "${LOCK_DIR}" 2>/dev/null || return 0
    trap 'rmdir "${LOCK_DIR}"' EXIT
    set -- $(cw_ids)
    uid=$1
    gid=$2
    now=$(date +%s)

    for file in "${folder}"/*; do
        [ -f "${file}" ] || continue
        name="$(basename "${file}")"

        case "${name}" in .*) continue ;; esac

        [ $((now - $(stat -c %Y "${file}"))) -ge 60 ] || continue
        mkdir -p "${folder}/Added" "${folder}/Not added"
        chmod 777 "${folder}/Added" "${folder}/Not added"
        extension="$(echo "${name##*.}" | tr '[:upper:]' '[:lower:]')"

        case "${extension}" in
            epub|kepub|mobi|azw|azw1|azw3|azw4|pdf|cbz|cbr|cb7|cbc|fb2|fbz|docx|odt|rtf|txt|txtz|htmlz|html|htm|djvu|djv|lit|lrf|pdb|prc|pml|rb|snb|tcr|chm|md|markdown) ;;
            *)
                move_into "${file}" "${folder}/Not added"
                echo "Not an e-book format Calibre reads (.${extension})" > "${folder}/Not added/${name}.why.txt"
                ingest_log "not added: ${name} (not an e-book format Calibre reads)"
                continue
                ;;
        esac

        # A copy Calibre-Web's user can read, whoever owns the file
        work="${CW_DATA}/tmp/ingest"
        rm -rf "${work}"
        mkdir -p "${work}"
        cp "${file}" "${work}/${name}" && chown -R "${uid}:${gid}" "${work}"
        output="$(as_cw "${BIN}/calibre/calibredb" --library-path "${library}" add "${work}/${name}" 2>&1)"
        id="$(echo "${output}" | sed -n 's/^Added book ids: \([0-9]*\).*/\1/p')"

        if [ -n "${id}" ]; then
            note=''

            if [ "$(setting INGEST_CONVERT none)" = epub ] && [ "${extension}" != epub ] && [ "${extension}" != kepub ]; then
                if as_cw "${BIN}/calibre/ebook-convert" "${work}/${name}" "${work}/converted.epub" > "${work}/convert.log" 2>&1 \
                    && as_cw "${BIN}/calibre/calibredb" --library-path "${library}" add_format "${id}" "${work}/converted.epub" > /dev/null 2>&1; then
                    note=', with an EPUB made from it'
                else
                    note=" (an EPUB couldn't be made from it)"
                fi
            fi

            move_into "${file}" "${folder}/Added"
            ingest_log "added: ${name} (book ${id}${note})"
        else
            if echo "${output}" | grep -q 'already exist'; then
                why='Already in the library (a book with the same title and authors)'
            else
                why="Calibre couldn't add it: $(echo "${output}" | grep -v '^\s*$' | tail -n 1)"
            fi

            move_into "${file}" "${folder}/Not added"
            echo "${why}" > "${folder}/Not added/${name}.why.txt"
            ingest_log "not added: ${name} (${why})"
        fi

        rm -rf "${work}"
    done
}

# The daily job: backups of Calibre-Web's settings and users (app.db) and of the library's database (metadata.db - the
# books' details; the book files themselves aren't in them), keeping 7 days; the ingest log kept small
daily() {
    day="$(date +%Y-%m-%d)"
    mkdir -p "${BACKUP_DIR}/${day}"
    helper backup "${CW_DATA}/app.db" "${BACKUP_DIR}/${day}/app.db"
    helper backup "$(setting LIBRARY)/metadata.db" "${BACKUP_DIR}/${day}/metadata.db"
    ls -1d "${BACKUP_DIR}"/????-??-?? 2>/dev/null | sort | head -n -7 | while read -r old; do rm -rf "${old}"; done

    if [ "$(wc -c < "${INGEST_LOG}" 2>/dev/null || echo 0)" -gt 262144 ]; then
        tail -n 500 "${INGEST_LOG}" > "${INGEST_LOG}.tmp" && mv -f "${INGEST_LOG}.tmp" "${INGEST_LOG}"
        chmod 600 "${INGEST_LOG}"
    fi
}

# The Nginx app finds Calibre-Web by its folder and serves it at https://books.<its domain>: rewrite its sites
nginx_site() {
    nginx_app="${APPS_PATH}/nginx"

    if [ -f "${nginx_app}/lib/sites.php" ] && [ -d "${APPS_PATH}/_nginx/sites" ]; then
        php "${nginx_app}/lib/sites.php" generate "${APPS_PATH}/_nginx" && sh "${nginx_app}/nginx_ctl.sh" reload > /dev/null 2>&1
    fi

    return 0
}

case "$1" in
    setup) setup ;;
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    # Calibre-Web keeps its users in memory: it's restarted for the new password to count
    new-password) setup > /dev/null || exit 1; if running; then stop; new_password && start; else new_password; fi ;;
    library) set_library "$2" ;;
    ingest) ingest ;;
    daily) daily ;;
    nginx) nginx_site ;;
    run) shift; setup > /dev/null && as_cw "$@" ;;
    *)
        echo "Usage: $0 setup|start|stop|restart|new-password|library <path>|ingest|daily|nginx|run <program> [args]" >&2

        exit 1
        ;;
esac
