#!/bin/sh
# Whether Entware's programs can run on this NAS, and removing Entware from one where they can't. Entware's ARM packages
# (armv7sf-k3.2) are laid out for the usual 4KB memory pages, but some WD ARM models' kernels use larger ones (32KB on
# the My Cloud EX2 Ultra): there, its programs - opkg itself, its grep, bash, busybox... - crash ("Segmentation fault")
# as soon as they start. Installed anyway, Entware then silently breaks the NAS: its commands come first in the PATH, so
# every script that runs grep, for one, gets a crash instead (which most read as "nothing found"). Run by the app's
# install.sh, init.sh and start.sh (as root):
#   compat.sh check           - exit 0 if Entware's programs can run on this NAS; else exit 1, printing why
#   compat.sh remove <root>... - undo Entware's set-up (its PATH lines, /opt) and delete the Entware roots given

# Entware's packages are laid out for this page size (bytes)
ENTWARE_PAGE_SIZE=4096
PROFILE_MARK='# added by the entware app'

# The kernel's memory page size: from getconf, else the kernel's own figures for a process (smaps), else the values it
# hands every program when it starts (auxv: AT_PAGESZ, 6 - read on the 32-bit ARM models only, whose words are 4
# bytes). PAGE_SIZE in the environment overrides it (for the app's tests).
#
# Prints it in bytes, or nothing if it can't be found
page_size() {
    local size

    if [ -n "${PAGE_SIZE:-}" ]; then
        echo "${PAGE_SIZE}"

        return
    fi

    size="$(getconf PAGESIZE 2>/dev/null)"

    case "${size}" in
        ''|*[!0-9]*) size="$(awk '/^KernelPageSize:/ { print $2 * 1024; exit }' /proc/self/smaps 2>/dev/null)" ;;
    esac

    case "${size}" in
        ''|*[!0-9]*)
            case "$(uname -m)" in
                arm*)
                    size="$(od -An -v -tu4 /proc/self/auxv 2>/dev/null \
                        | awk '{ for (i = 1; i <= NF; i++) w[++n] = $i }
                            END { for (i = 1; i < n; i += 2) if (w[i] == 6) { print w[i + 1]; exit } }')"
                    ;;
                *) size='' ;;
            esac
            ;;
    esac

    case "${size}" in
        ''|*[!0-9]*) ;;
        *) echo "${size}" ;;
    esac
}

# Whether Entware's programs can run here: the kernel's page size is the one they're laid out for, and (when Entware
# is mounted on /opt) its opkg doesn't crash when started.
#
# Prints why not; returns 0 if they can
check() {
    local size code

    size="$(page_size)"

    if [ -n "${size}" ] && [ "${size}" -gt "${ENTWARE_PAGE_SIZE}" ]; then
        echo "this NAS's kernel uses $((size / 1024))KB memory pages, and Entware's programs are built for" \
            "$((ENTWARE_PAGE_SIZE / 1024))KB ones: they crash on it"

        return 1
    fi

    if [ -x /opt/bin/opkg ]; then
        /opt/bin/opkg --version > /dev/null 2>&1
        code=$?

        # (killed by a signal as it started: illegal instruction, abort, bus error or segmentation fault)
        case "${code}" in
            132|134|135|139)
                echo "Entware's own programs crash on this NAS (opkg was killed by signal $((code - 128)))"

                return 1
                ;;
        esac
    fi

    return 0
}

# Undoes Entware's set-up and deletes it: its lines in the PATH, /opt (unmounted - WD's own /opt comes back), and each
# Entware root given (only a folder that is one: with opkg, or its settings, in it). Its services aren't stopped: its
# programs can't have started.
#
# $@ The Entware roots (e.g. Nas_Prog/_entware/opt)
remove() {
    local root

    sed -i "/${PROFILE_MARK}/d" /etc/profile 2>/dev/null

    if grep -q ' /opt ' /proc/mounts; then
        umount /opt 2>/dev/null || umount -l /opt 2>/dev/null
    fi

    for root in "$@"; do
        case "${root}" in
            ''|/|/opt) continue ;;
        esac

        if [ -e "${root}/bin/opkg" ] || [ -f "${root}/etc/opkg.conf" ]; then
            echo "removing Entware from: ${root}"
            rm -rf "${root}"
        fi
    done
}

case "$1" in
    check) check ;;
    remove)
        shift
        remove "$@"
        ;;
    *)
        echo "Usage: $0 check | remove <root>..." >&2

        exit 2
        ;;
esac
