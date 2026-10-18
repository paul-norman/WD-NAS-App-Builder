# Read a field from the `apkg.rc` file
#  - only the first colon separates the name from the value (e.g. URLs are kept whole)
#  - surrounding whitespace and Windows line endings are removed
apkg_value() {
	sed -n "s/^$1:[[:space:]]*//p" "${APP_PATH}/apkg.rc" | tr -d '\r' | sed 's/[[:space:]]*$//' | head -n 1
}

# All `apkg.rc` variables
APKG_PACKAGE="$(apkg_value Package)"
APKG_VERSION="$(apkg_value Version)"
APKG_PACKAGER="$(apkg_value Packager)"
APKG_EMAIL="$(apkg_value Email)"
APKG_HOMEPAGE="$(apkg_value Homepage)"
APKG_DESCRIPTION="$(apkg_value Description)"
APKG_ICON="$(apkg_value Icon)"
APKG_ADDON_SHOW_NAME="$(apkg_value AddonShowName)"
APKG_ADDON_INDEX_PAGE="$(apkg_value AddonIndexPage)"
APKG_ADDON_USED_PORT="$(apkg_value AddonUsedPort)"
APKG_ADDON_DEFAULT_PORT="$(apkg_value AddonDefaultPort)"
APKG_ADDON_DEFAULT_GROUP="$(apkg_value AddonDefaultGroup)"
APKG_ADDON_DEFAULT_USER="$(apkg_value AddonDefaultUser)"
APKG_INST_DEPEND="$(apkg_value InstDepend)"
APKG_INST_CONFLICT="$(apkg_value InstConflict)"
APKG_START_DEPEND="$(apkg_value StartDepend)"
APKG_START_CONFLICT="$(apkg_value StartConflict)"
APKG_CENTER_TYPE="$(apkg_value CenterType)"
APKG_USER_CONTROL="$(apkg_value UserControl)"
APKG_MIN_FW_VER="$(apkg_value MinFWVer)"
APKG_MAX_FW_VER="$(apkg_value MaxFWVer)"
APKG_INDIVIDUAL_FLAG="$(apkg_value IndividualFlag)"
APKG_HIDDEN="$(apkg_value Hidden)"

check_apkg_variables() {
	# Check that the name is valid
	if [ "${APKG_PACKAGE}" != "${APP_NAME}" ]; then
		echo "CRITICAL ERROR: the app folder and the package name in the apkg.rc file must match"
		exit 1
	fi

	# TODO: Add all checks outlined by the WD Guide
}
