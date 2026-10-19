#!/bin/sh
LOG="/tmp/debug_apkg";

APP_SCRIPT="$(basename $1)";
APP_PATH="$(dirname $1)";

# Import the APKG file helpers (runs pre-checks)
. "${APP_PATH}/apkg_helpers.sh"

APP_NAME="${APKG_PACKAGE}"

# Without a name, paths such as /var/www/${APP_NAME} would point at whole system folders (which scripts remove)
if [ -z "${APP_NAME}" ]; then
	echo "$(date '+%Y-%m-%d %H:%M:%S') ${APP_SCRIPT}: no Package name found in ${APP_PATH}/apkg.rc - stopping" >> ${LOG}
	exit 1
fi
APP_VERSION="${APKG_VERSION}"
APP_WEB_PATH="/var/www/${APP_NAME}";
APP_MANAGE_PATH="/var/www/apps/${APP_NAME}";	# management pages: only here does nasAdmin require a NAS login
APP_PORT="${APKG_ADDON_USED_PORT}"

# Extra variable is available for the install script only, so make variables consistent for all scripts
if [ "${APP_SCRIPT}" == "install.sh" ]; then
	APP_UPLOAD_PATH="$2";
	APP_PATH="$3/${APP_NAME}";
else
	APP_UPLOAD_PATH="$(dirname ${APP_PATH})/_install/${APP_NAME}";
fi

APPS_PATH="$(dirname ${APP_PATH})";
APP_PERSISTENT_DATA_PATH="${APPS_PATH}/_${APP_NAME}";

USER_GROUP="${APKG_ADDON_DEFAULT_GROUP}"
USER_NAME="${APKG_ADDON_DEFAULT_USER}"

# Logging function
log() {
	if [ ! -f "${LOG}" ]; then
		touch ${LOG};
	fi
	
	if [ "$*" == "" ]; then
		echo "" >> ${LOG};
	elif [ "$*" == "---" ]; then
		echo "----------------------------------------------------------------" >> ${LOG};
	else
		echo "$(date '+%Y-%m-%d %H:%M:%S') ${APP_NAME}/${APP_SCRIPT} $*" >> ${LOG};
	fi
}

# Check whether the process in a PID file is running
is_running() {
	[ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

# Stop the process in a PID file, waiting up to $2 seconds (default 10) before killing it
stop_process() {
	local pid_file="$1"
	local timeout="${2:-10}"

	if ! is_running "${pid_file}"; then
		log "not running (no live PID in: ${pid_file})"
		rm -f "${pid_file}"
		return 0
	fi

	local pid="$(cat "${pid_file}")"
	local waited=0
	log "stopping PID: ${pid}"
	kill "${pid}"
	while kill -0 "${pid}" 2>/dev/null; do
		if [ ${waited} -ge ${timeout} ]; then
			log "PID ${pid} did not stop within ${timeout} seconds, killing it"
			kill -9 "${pid}" 2>/dev/null
			break
		fi
		sleep 1
		waited=$((waited + 1))
	done

	rm -f "${pid_file}"
	log "stopped PID: ${pid}"
}

if [ "${APP_SCRIPT}" == "init.sh" ]; then
	# Create a user group for this application (if specified and missing - existing groups are never removed)
	if [ "${USER_GROUP}" != "" ] && ! grep -q "^${USER_GROUP}:" /etc/group; then
		log "Create ${USER_GROUP} group";
		addgroup "${USER_GROUP}";
	fi

	# Create a locked (no password, no login shell) user for this application (if specified and missing)
	if [ "${USER_NAME}" != "" ] && [ "${USER_NAME}" != "root" ] && [ "${USER_NAME}" != "sshd" ] && ! grep -q "^${USER_NAME}:" /etc/passwd; then
		log "Create ${USER_NAME} user";
		if [ "${USER_GROUP}" != "" ]; then
			adduser -D -H -s /bin/false -G "${USER_GROUP}" "${USER_NAME}";
		else
			adduser -D -H -s /bin/false "${USER_NAME}";
		fi
	fi
fi

# Other useful paths
LDC_PATH="/etc/ld.so.conf";		# LD config file path
PROFILE_PATH="/etc/profile";	# Profile path

# Architecture determination
HARDWARE_MODEL="$(cat /usr/local/modules/files/model)";
HARDWARE_KERNEL_ARCH="$(uname -m)";	# x86_64 / armv7l
HARDWARE_DEBIAN_ARCH="";			# amd64  / armhf

if [ "${HARDWARE_MODEL}" == "MyCloudPR4100" ] || [ "${HARDWARE_MODEL}" == "WDMyCloudPR4100" ]; then
	HARDWARE_DEBIAN_ARCH="amd64";
elif [ "${HARDWARE_MODEL}" == "MyCloudPR2100" ] || [ "${HARDWARE_MODEL}" == "WDMyCloudPR2100" ]; then
	HARDWARE_DEBIAN_ARCH="amd64";
elif [ "${HARDWARE_MODEL}" == "WDMyCloudDL4100" ] || [ "${HARDWARE_MODEL}" == "MyCloudDL4100" ]; then
	HARDWARE_DEBIAN_ARCH="amd64";
elif [ "${HARDWARE_MODEL}" == "WDMyCloudDL2100" ] || [ "${HARDWARE_MODEL}" == "MyCloudDL2100" ]; then
	HARDWARE_DEBIAN_ARCH="amd64";
elif [ "${HARDWARE_MODEL}" == "WDMyCloudEX4100" ] || [ "${HARDWARE_MODEL}" == "MyCloudEX4100" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
elif [ "${HARDWARE_MODEL}" == "WDMyCloudEX2100" ] || [ "${HARDWARE_MODEL}" == "MyCloudEX2100" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
elif [ "${HARDWARE_MODEL}" == "MyCloudEX2Ultra" ] || [ "${HARDWARE_MODEL}" == "WDMyCloudEX2Ultra" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
elif [ "${HARDWARE_MODEL}" == "WDMyCloudMirror" ] || [ "${HARDWARE_MODEL}" == "MyCloudMirror" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
elif [ "${HARDWARE_MODEL}" == "WDMyCloudMirrorG2" ] || [ "${HARDWARE_MODEL}" == "MyCloudMirrorG2" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
elif [ "${HARDWARE_MODEL}" == "WDMyCloud" ] || [ "${HARDWARE_MODEL}" == "MyCloud" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
elif [ "${HARDWARE_MODEL}" == "WDCloud" ]; then
	HARDWARE_DEBIAN_ARCH="armhf";
fi;

if [ "${HARDWARE_DEBIAN_ARCH}" == "amd64" ]; then
	HARDWARE_TOOLCHAIN="x86_64-linux-gnu";
elif [ "${HARDWARE_DEBIAN_ARCH}" == "armhf" ]; then
	HARDWARE_TOOLCHAIN="arm-linux-gnueabihf";
fi;

# HDD references
DATA_VOL_1="";
DATA_VOL_2="";
DATA_VOL_3="";
DATA_VOL_4="";

if [ -d "/mnt/HD/HD_a2" ]; then
	DATA_VOL_1="/mnt/HD/HD_a2";
fi;
if [ -d "/mnt/HD/HD_b2" ]; then
	DATA_VOL_2="/mnt/HD/HD_b2";
fi;
if [ -d "/mnt/HD/HD_c2" ]; then
	DATA_VOL_3="/mnt/HD/HD_c2";
fi;
if [ -d "/mnt/HD/HD_d2" ]; then
	DATA_VOL_4="/mnt/HD/HD_d2";
fi;

# On the install script dump all the variables as a sanity check
# Otherwise just let us know what is running and when
if [ ${APP_SCRIPT} == "install.sh" ]; then
	log "";
	log "---";
	log "APP_NAME:                 ${APP_NAME}";
	log "APP_VERSION:              ${APP_VERSION}";
	log "APP_SCRIPT:               ${APP_SCRIPT}";
	log "APP_UPLOAD_PATH:          ${APP_UPLOAD_PATH}";
	log "APP_PATH:                 ${APP_PATH}";
	log "APPS_PATH:                ${APPS_PATH}";
	log "APP_WEB_PATH:             ${APP_WEB_PATH}";
	log "APP_MANAGE_PATH:          ${APP_MANAGE_PATH}";
	log "APP_PERSISTENT_DATA_PATH: ${APP_PERSISTENT_DATA_PATH}"
	log "APP_PORT:                 ${APP_PORT}";
	log "";
	log "APKG_PACKAGE:             ${APKG_PACKAGE}";
	log "APKG_VERSION:             ${APKG_VERSION}";
	log "APKG_PACKAGER:            ${APKG_PACKAGER}";
	log "APKG_EMAIL:               ${APKG_EMAIL}";
	log "APKG_HOMEPAGE:            ${APKG_HOMEPAGE}";
	log "APKG_DESCRIPTION:         ${APKG_DESCRIPTION}";
	log "APKG_ICON:                ${APKG_ICON}";
	log "APKG_ADDON_SHOW_NAME:     ${APKG_ADDON_SHOW_NAME}";
	log "APKG_ADDON_INDEX_PAGE:    ${APKG_ADDON_INDEX_PAGE}";
	log "APKG_ADDON_USED_PORT:     ${APKG_ADDON_USED_PORT}";
	log "APKG_ADDON_DEFAULT_PORT:  ${APKG_ADDON_DEFAULT_PORT}";
	log "APKG_ADDON_DEFAULT_GROUP: ${APKG_ADDON_DEFAULT_GROUP}";
	log "APKG_ADDON_DEFAULT_USER:  ${APKG_ADDON_DEFAULT_USER}";
	log "APKG_INST_DEPEND:         ${APKG_INST_DEPEND}";
	log "APKG_INST_CONFLICT:       ${APKG_INST_CONFLICT}";
	log "APKG_START_DEPEND:        ${APKG_START_DEPEND}";
	log "APKG_START_CONFLICT:      ${APKG_START_CONFLICT}";
	log "APKG_CENTER_TYPE:         ${APKG_CENTER_TYPE}";
	log "APKG_USER_CONTROL:        ${APKG_USER_CONTROL}";
	log "APKG_MIN_FW_VER:          ${APKG_MIN_FW_VER}";
	log "APKG_MAX_FW_VER:          ${APKG_MAX_FW_VER}";
	log "APKG_INDIVIDUAL_FLAG:     ${APKG_INDIVIDUAL_FLAG}";
	log "APKG_HIDDEN:              ${APKG_HIDDEN}";
	log "";
	log "HARDWARE_MODEL:           ${HARDWARE_MODEL}";
	log "HARDWARE_KERNEL_ARCH:     ${HARDWARE_KERNEL_ARCH}";
	log "HARDWARE_DEBIAN_ARCH:     ${HARDWARE_DEBIAN_ARCH}";
	log "HARDWARE_TOOLCHAIN:       ${HARDWARE_TOOLCHAIN}";
	log "";
	log "DATA_VOL_1:               ${DATA_VOL_1}";
	log "DATA_VOL_2:               ${DATA_VOL_2}";
	log "DATA_VOL_3:               ${DATA_VOL_3}";
	log "DATA_VOL_4:               ${DATA_VOL_4}";
	log "";
	log "USER_GROUP:               ${USER_GROUP}";
	log "USER_NAME:                ${USER_NAME}";
	log "---";
	log "";
else
	log "";
	log "is running";
fi
