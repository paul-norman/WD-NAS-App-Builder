# All `apkg.rc` variables
APKG_PACKAGE="$(awk -F: '/Package:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_VERSION="$(awk -F: '/Version:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_PACKAGER="$(awk -F: '/Packager:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_EMAIL="$(awk -F: '/Email:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_HOMEPAGE="$(awk -F: '/Homepage:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_DESCRIPTION="$(awk -F: '/Description:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ICON="$(awk -F: '/Icon:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ADDON_SHOW_NAME="$(awk -F: '/AddonShowName:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ADDON_INDEX_PAGE="$(awk -F: '/AddonIndexPage:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ADDON_USED_PORT="$(awk -F: '/AddonUsedPort:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ADDON_DEFAULT_PORT="$(awk -F: '/AddonDefaultPort:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ADDON_DEFAULT_GROUP="$(awk -F: '/AddonDefaultGroup:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_ADDON_DEFAULT_USER="$(awk -F: '/AddonDefaultUser:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_INST_DEPEND="$(awk -F: '/InstDepend:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_INST_CONFLICT="$(awk -F: '/InstConflict:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_START_DEPEND="$(awk -F: '/StartDepend:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_START_CONFLICT="$(awk -F: '/StartConflict:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_CENTER_TYPE="$(awk -F: '/CenterType:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_USER_CONTROL="$(awk -F: '/UserControl:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_MIN_FW_VER="$(awk -F: '/MinFWVer:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_MAX_FW_VER="$(awk -F: '/MaxFWVer:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_INDIVIDUAL_FLAG="$(awk -F: '/IndividualFlag:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"
APKG_HIDDEN="$(awk -F: '/Hidden:/ {gsub(/^[ \t]+/, "", $2); gsub(/[ \t]+$/, "", $2); print $2}' ${APP_PATH}/apkg.rc)"

check_apkg_variables() {
	# Check that the name is valid
	if [[ "${APKG_PACKAGE}" != "${APP_NAME}" ]]; then
		echo "CRITICAL ERROR: the app folder and the package name in the apkg.rc file must match"
		exit 1
	fi

	# TODO: Add all checks outlined by the WD Guide
}
