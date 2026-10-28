#!/bin/sh
# Runs Icecast (an internet radio station) as its own user, with its settings in the persistent path (Nas_Prog/_icecast
# - kept across reinstalls), and - when turned on - ezstream, broadcasting a folder of music from the NAS:
#   ice_ctl.sh setup               - create its user, folders, passwords and default settings (where missing)
#   ice_ctl.sh start               - write its configuration, then start Icecast (on port 8010: the network, or the NAS
#                                    itself only) and the station
#   ice_ctl.sh stop                - stop both
#   ice_ctl.sh restart             - stop, then start
#   ice_ctl.sh new-password <name> - a new (generated) password: admin (Icecast's admin pages) or source (broadcasting)
#   ice_ctl.sh skip                - the station's next track, now
#   ice_ctl.sh playlist            - find the music folder's tracks again (the station carries on with them)
#   ice_ctl.sh check-folder <path> - whether Icecast's user can read a folder (exit status 0 if so)
#   ice_ctl.sh daily               - the daily job: finding new music
#   ice_ctl.sh nginx               - add / update Icecast's site in the Nginx app (and reload it)

APP_PATH="$(dirname "$(readlink -f "$0")")"
APPS_PATH="$(dirname "${APP_PATH}")"
DATA_PATH="${APPS_PATH}/_icecast"
# (PHP finds the Nginx app's address: wherever it is, also when run with a minimal PATH, e.g. from the management page)
PATH="${PATH}:/usr/bin:/usr/local/bin:/usr/sbin:/sbin"
BIN="${APP_PATH}/binaries"
RUN_PATH="${DATA_PATH}/run"
SETTINGS_FILE="${DATA_PATH}/settings"
PLAYLIST="${RUN_PATH}/playlist.m3u"
ICECAST_PID=/var/run/icecast.pid
EZSTREAM_PID=/var/run/ezstream.pid
# (not 8000: the NAS's own web server has 127.0.0.1:8000)
PORT=8010
# Its own user and group (created if missing): the IDs used when creating them
ICE_ID=82
LOG=/tmp/debug_apkg
# The music formats the station plays (ffmpeg turns each into the stream's MP3)
EXTENSIONS="mp3 flac ogg oga opus m4a aac wav wma ape wv aif aiff mpc dsf tak"

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') icecast/ice_ctl.sh $*" >> ${LOG}
	echo "$*"
}

# A setting from the settings file (written by the management page), or the default given
setting() {
	value="$(sed -n "s/^$1=//p" "${SETTINGS_FILE}" 2>/dev/null | head -n 1)"
	echo "${value:-$2}"
}

running() {
	[ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

ice_ids() {
	awk -F: '$1 == "icecast" { print $3 " " $4 }' /etc/passwd
}

random_text() {
	tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"
}

# Text for the XML configurations (the settings are checked by the page, but & < > " must still be escaped)
xml() {
	printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

setup() {
	# Its own user (the NAS's user list is in RAM, so this is redone at every boot)
	grep -q '^icecast:' /etc/group || addgroup -g ${ICE_ID} icecast
	grep -q '^icecast:' /etc/passwd || adduser -D -H -h /nonexistent -s /bin/false -u ${ICE_ID} -G icecast icecast
	if [ -z "$(ice_ids)" ]; then
		log "Could not create the icecast user (are ID ${ICE_ID}'s user or group already taken?)"
		return 1
	fi
	set -- $(ice_ids)

	# Its configurations, playlist and logs belong to its user; the settings and passwords to root
	mkdir -p "${RUN_PATH}/logs"
	chmod 711 "${DATA_PATH}"
	chown -R "$1:$2" "${RUN_PATH}"
	chmod 700 "${RUN_PATH}"
	if [ ! -f "${SETTINGS_FILE}" ]; then
		# The station's music: WD's own music folder if there is one, otherwise the Public share
		music="/mnt/HD/HD_a2/Public/Shared Music"
		[ -d "${music}" ] || music="/mnt/HD/HD_a2/Public"
		log "creating the default settings: ${SETTINGS_FILE}"
		printf 'STATION_NAME=NAS Radio\nSTATION_DESCRIPTION=\nLISTEN=all\nMAX_LISTENERS=50\nAUTODJ=0\nMUSIC_FOLDER=%s\nMOUNT=radio\nBITRATE=128\nSHUFFLE=1\n' \
			"${music}" > "${SETTINGS_FILE}"
	fi
	chmod 600 "${SETTINGS_FILE}"
	for name in admin source; do
		if [ ! -s "${DATA_PATH}/${name}_password" ]; then
			( umask 077; random_text 20 > "${DATA_PATH}/${name}_password" )
		fi
	done
}

password() {
	cat "${DATA_PATH}/$1_password"
}

write_icecast_config() {
	set -- $(ice_ids)
	host=0.0.0.0
	[ "$(setting LISTEN all)" = local ] && host=127.0.0.1
	# (the address Icecast puts in its playlists and pages: the NAS's own on the home network)
	hostname="$(ip -4 route 2>/dev/null | sed -n 's/^default via .* dev \([^ ]*\).*/\1/p' | head -n 1)"
	[ -n "${hostname}" ] && hostname="$(ip -4 route 2>/dev/null | sed -n "s/.* dev ${hostname} .*src \([0-9.]*\).*/\1/p" | head -n 1)"
	[ -n "${hostname}" ] || hostname=localhost
	( umask 077; cat > "${RUN_PATH}/icecast.xml.tmp" <<EOF
<?xml version="1.0"?>
<!-- Written by the Icecast app at every start, from the settings on its management page: changes here are overwritten -->
<icecast>
    <location>$(xml "$(hostname)")</location>
    <admin>admin@localhost</admin>
    <hostname>${hostname}</hostname>
    <limits>
        <clients>$(( $(setting MAX_LISTENERS 50) + 10 ))</clients>
        <sources>4</sources>
        <burst-size>65535</burst-size>
    </limits>
    <authentication>
        <source-password>$(password source)</source-password>
        <relay-password>$(random_text 24)</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>$(password admin)</admin-password>
    </authentication>
    <listen-socket>
        <port>${PORT}</port>
        <bind-address>${host}</bind-address>
    </listen-socket>
    <mount type="default">
        <public>false</public>
        <max-listeners>$(setting MAX_LISTENERS 50)</max-listeners>
    </mount>
    <paths>
        <logdir>${RUN_PATH}/logs</logdir>
        <webroot>${BIN}/share/icecast/web</webroot>
        <adminroot>${BIN}/share/icecast/admin</adminroot>
        <alias source="/" destination="/status.xsl"/>
    </paths>
    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>warning</loglevel>
        <logsize>1024</logsize>
    </logging>
    <http-headers>
        <header type="cors" name="Access-Control-Allow-Origin" />
    </http-headers>
    <security>
        <prng-seed type="read-write" size="1024">${RUN_PATH}/prng-seed</prng-seed>
    </security>
</icecast>
EOF
	)
	chown "$1:$2" "${RUN_PATH}/icecast.xml.tmp" && mv -f "${RUN_PATH}/icecast.xml.tmp" "${RUN_PATH}/icecast.xml"
	# Its random numbers' seed, which it keeps updated (made here: WD's /dev/urandom is readable by root only)
	if [ ! -s "${RUN_PATH}/prng-seed" ]; then
		( umask 077; head -c 1024 /dev/urandom > "${RUN_PATH}/prng-seed" ) && chown "$1:$2" "${RUN_PATH}/prng-seed"
	fi
}

# The station's tracks: every music file in the folder (and its subfolders), as Icecast's user can read them
write_playlist() {
	set -- $(ice_ids)
	folder="$(setting MUSIC_FOLDER /mnt/HD/HD_a2/Public)"
	pattern=""
	for extension in ${EXTENSIONS}; do
		pattern="${pattern}${pattern:+ -o }-iname *.${extension}"
	done
	# (not following links, and not into hidden folders - e.g. other apps' caches)
	set -f
	"${BIN}/ice_runas" "$1" "$2" "$(command -v find)" "${folder}" -name '.*' -prune -o -type f \( ${pattern} \) -print 2>/dev/null \
		| sort > "${PLAYLIST}.tmp"
	set +f
	chown "$1:$2" "${PLAYLIST}.tmp" && mv -f "${PLAYLIST}.tmp" "${PLAYLIST}"
	log "the station's playlist: $(wc -l < "${PLAYLIST}") tracks from ${folder}"
}

write_ezstream_config() {
	set -- $(ice_ids)
	bitrate="$(setting BITRATE 128)"
	shuffle=No
	[ "$(setting SHUFFLE 1)" = 1 ] && shuffle=Yes
	# (ezstream refuses an empty description)
	description=""
	[ -n "$(setting STATION_DESCRIPTION '')" ] && description="            <stream_description>$(xml "$(setting STATION_DESCRIPTION '')")</stream_description>
"
	extensions=""
	for extension in ${EXTENSIONS}; do
		extensions="${extensions}            <file_ext>.${extension}</file_ext>
"
	done
	( umask 077; cat > "${RUN_PATH}/ezstream.xml.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- Written by the Icecast app at every start, from the settings on its management page: changes here are overwritten -->
<ezstream>
    <servers>
        <server>
            <protocol>HTTP</protocol>
            <hostname>127.0.0.1</hostname>
            <port>${PORT}</port>
            <user>source</user>
            <password>$(password source)</password>
            <tls>None</tls>
            <reconnect_attempts>0</reconnect_attempts>
        </server>
    </servers>
    <streams>
        <stream>
            <mountpoint>/$(setting MOUNT radio)</mountpoint>
            <public>No</public>
            <format>MP3</format>
            <encoder>MP3</encoder>
            <stream_name>$(xml "$(setting STATION_NAME 'NAS Radio')")</stream_name>
${description}            <stream_bitrate>${bitrate}</stream_bitrate>
            <stream_samplerate>44100</stream_samplerate>
            <stream_channels>2</stream_channels>
        </stream>
    </streams>
    <intakes>
        <intake>
            <type>playlist</type>
            <filename>${PLAYLIST}</filename>
            <shuffle>${shuffle}</shuffle>
            <stream_once>No</stream_once>
        </intake>
    </intakes>
    <!-- (ffmpeg logs only what stops it: skipping a track always breaks its pipe) -->
    <decoders>
        <decoder>
            <name>ffmpeg</name>
            <program>${BIN}/ffmpeg -nostdin -loglevel fatal -i @T@ -vn -f s16le -acodec pcm_s16le -ar 44100 -ac 2 -</program>
${extensions}        </decoder>
    </decoders>
    <encoders>
        <encoder>
            <name>MP3</name>
            <format>MP3</format>
            <program>${BIN}/ffmpeg -nostdin -loglevel fatal -f s16le -ar 44100 -ac 2 -i - -c:a libmp3lame -b:a ${bitrate}k -f mp3 -</program>
        </encoder>
    </encoders>
</ezstream>
EOF
	)
	chown "$1:$2" "${RUN_PATH}/ezstream.xml.tmp" && mv -f "${RUN_PATH}/ezstream.xml.tmp" "${RUN_PATH}/ezstream.xml"
}

# Waits up to 20 seconds for Icecast to answer
wait_up() {
	waited=0
	while [ ${waited} -lt 20 ]; do
		# (Icecast itself, by its Server header: not whatever else answers on the port)
		running "${ICECAST_PID}" || return 1
		curl -s -o /dev/null -D - "http://127.0.0.1:${PORT}/status-json.xsl" 2>/dev/null | grep -qi '^server: icecast' && return 0
		sleep 1
		waited=$((waited + 1))
	done
	return 1
}

start_station() {
	[ "$(setting AUTODJ 0)" = 1 ] || return 0
	running "${EZSTREAM_PID}" && return 0
	set -- $(ice_ids)
	write_playlist
	if [ ! -s "${PLAYLIST}" ]; then
		log "The station's folder has no music Icecast can read: $(setting MUSIC_FOLDER '')"
		return 0
	fi
	write_ezstream_config
	log "starting the station (ezstream) on /$(setting MOUNT radio)"
	cd "${RUN_PATH}" || return 1
	( exec "${BIN}/ice_runas" "$1" "$2" "${BIN}/ezstream" -c "${RUN_PATH}/ezstream.xml" ) >> "${RUN_PATH}/logs/ezstream.log" 2>&1 &
	echo $! > "${EZSTREAM_PID}"
}

start() {
	if running "${ICECAST_PID}"; then
		log "Icecast is already running with PID: $(cat ${ICECAST_PID})"
		start_station
		return 0
	fi
	setup || return 1
	write_icecast_config || return 1
	set -- $(ice_ids)
	log "starting Icecast on port ${PORT}"
	cd "${RUN_PATH}" || return 1
	( exec "${BIN}/ice_runas" "$1" "$2" "${BIN}/icecast" -c "${RUN_PATH}/icecast.xml" ) >> "${RUN_PATH}/logs/console.log" 2>&1 &
	echo $! > "${ICECAST_PID}"
	if ! wait_up; then
		log "Icecast did not start (see ${RUN_PATH}/logs): $(tail -n 2 "${RUN_PATH}/logs/console.log" 2>/dev/null | tr '\n' ' ')"
		return 1
	fi
	log "Icecast started with PID: $(cat ${ICECAST_PID})"
	start_station
}

stop_one() {
	if running "$1"; then
		pid="$(cat "$1")"
		kill "${pid}"
		waited=0
		while kill -0 "${pid}" 2>/dev/null; do
			if [ ${waited} -ge 10 ]; then
				kill -9 "${pid}" 2>/dev/null
				break
			fi
			sleep 1
			waited=$((waited + 1))
		done
	fi
	rm -f "$1"
}

stop() {
	log "stopping Icecast"
	stop_one "${EZSTREAM_PID}"
	stop_one "${ICECAST_PID}"
}

new_password() {
	case "$1" in
		admin|source) ;;
		*) echo "Usage: $0 new-password admin|source" >&2; return 1 ;;
	esac
	( umask 077; random_text 20 > "${DATA_PATH}/$1_password.tmp" ) && mv -f "${DATA_PATH}/$1_password.tmp" "${DATA_PATH}/$1_password"
	log "a new $1 password"
}

check_folder() {
	set -- $(ice_ids) "$1"
	[ -d "$3" ] && "${BIN}/ice_runas" "$1" "$2" /bin/ls "$3" > /dev/null 2>&1
}

# ezstream reads its playlist again when told to (SIGHUP), and skips to the next track on SIGUSR1
playlist() {
	running "${ICECAST_PID}" || return 0
	if running "${EZSTREAM_PID}"; then
		write_playlist
		kill -HUP "$(cat "${EZSTREAM_PID}")"
	else
		start_station
	fi
}

# The Nginx app finds Icecast by its folder and serves it at https://radio.<its domain>: rewrite its sites
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
	new-password) new_password "$2" ;;
	skip) running "${EZSTREAM_PID}" && kill -USR1 "$(cat "${EZSTREAM_PID}")" ;;
	playlist|daily) playlist ;;
	check-folder) setup > /dev/null && check_folder "$2" ;;
	nginx) nginx_site ;;
	*)
		echo "Usage: $0 setup|start|stop|restart|new-password <admin|source>|skip|playlist|check-folder <path>|daily|nginx" >&2
		exit 1
		;;
esac
