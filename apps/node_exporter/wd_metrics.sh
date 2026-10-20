#!/bin/sh
# WD's own view of the storage, as Prometheus metrics for Node Exporter's textfile collector: disk health and
# temperatures, RAID and volume state, from the records WD's firmware keeps in its sysinfo database (dumped with xmldbc,
# which reads WD's records rather than the disks, so sleeping disks aren't woken)
#
# Usage: wd_metrics.sh <output dir> [<seconds between runs>]  (without the interval, it writes wd.prom once)
#  - CAP_LOG=<file> also keeps that file (Node Exporter's log) under 1MB, between runs
#  - WD_METRICS_SOURCE=<dir> reads disks.xml, raids.xml and vols.xml from <dir> instead (for tests)

OUT_DIR="$1"
INTERVAL="$2"
SOCKET="/var/run/xmldb_sock_sysinfo"
WORK="/tmp/node_exporter-wd"

collect() {
	mkdir -p "${WORK}"
	ok=1
	for tree in disks raids vols; do
		if [ -n "${WD_METRICS_SOURCE}" ]; then
			cp "${WD_METRICS_SOURCE}/${tree}.xml" "${WORK}/${tree}.xml" 2>/dev/null || ok=0
		else
			rm -f "${WORK}/${tree}.xml"
			xmldbc -p "/${tree}" "${WORK}/${tree}.xml" -S "${SOCKET}" >/dev/null 2>&1
			[ -s "${WORK}/${tree}.xml" ] || ok=0
		fi
	done

	# The NAS model and firmware version, for wd_info
	model="$(cat /usr/local/modules/files/model 2>/dev/null)"
	firmware="$(xmldbc -g /sw_ver_2 2>/dev/null)"
	[ -n "${firmware}" ] || firmware="$(cat /etc/version 2>/dev/null)"

	cat "${WORK}/disks.xml" "${WORK}/raids.xml" "${WORK}/vols.xml" 2>/dev/null | awk -v ok="${ok}" -v model="${model}" -v firmware="${firmware}" '
	function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\n/, " ", s); return s }
	function unxml(s) { gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s); gsub(/&apos;/, "\047", s); gsub(/&amp;/, "\\&", s); return s }
	function words(s,  a) { return s == "" ? 0 : split(s, a, " ") }
	# Samples are kept per metric, so each metric is written as one block with its HELP and TYPE lines
	function add(name, help, labels, value) {
		if (!(name in samples)) { order[++count] = name; helps[name] = help; samples[name] = "" }
		# (BusyBox awk before 1.34 takes a name followed by a bracket for a function call, hence braces in a variable)
		braced = labels == "" ? "" : "{" labels "}"
		samples[name] = samples[name] name braced " " value "\n"
	}
	function n(v) { return v == "" ? 0 : v + 0 }

	{
		line = $0
		sub(/^[ \t]+/, "", line); sub(/[ \t\r]+$/, "", line)
		if (line == "") { next }
	}

	# Opening and closing tags of the records
	line ~ /^<disk id="/ { kind = "disk"; split(line, p, "\""); id = p[2]; delete f; smart = 0; next }
	line ~ /^<raid id="/ { kind = "raid"; delete f; next }
	line ~ /^<vol id="/ { kind = "vol"; delete f; next }
	line == "<smart>" { smart = 1; next }
	line == "</smart>" { smart = 0; next }
	line == "<raids>" { tree = "raids"; next }
	line == "<vols>" { tree = "vols"; next }

	line == "</disk>" {
		if (f["connected"] != "0") {
			l = "disk=\"" esc(f["name"]) "\",bay=\"" esc(id) "\""
			add("wd_disk_info", "A disk, with its model and firmware (always 1)", l ",vendor=\"" esc(f["vendor"]) "\",model=\"" esc(f["model"]) "\",firmware=\"" esc(f["rev"]) "\"", 1)
			if (f["temp"] != "") { add("wd_disk_temperature_celsius", "Disk temperature, as WD last read it", l, n(f["temp"])) }
			add("wd_disk_healthy", "Whether WD considers the disk healthy", l, n(f["healthy"]))
			add("wd_disk_failed", "Whether WD has marked the disk as failed", l, n(f["failed"]))
			add("wd_disk_over_temperature", "Whether the disk is over WD'"'"'s temperature limit", l, n(f["over_temp"]))
			add("wd_disk_sleeping", "Whether the disk is asleep (spun down)", l, n(f["sleep"]))
			add("wd_disk_size_bytes", "Disk size", l, n(f["size"]))
			if (f["smart_result"] != "") {
				add("wd_disk_smart_passed", "Whether the last SMART test WD ran passed", l, f["smart_result"] ~ /^Pass/ ? 1 : 0)
			}
			disks++
			if (f["failed"] == "1") { critical++ }
			else if (f["healthy"] != "1" || f["over_temp"] == "1") { warning++ }
		}
		kind = ""; next
	}

	line == "</raid>" {
		dev = f["dev"]; sub(/^\/dev\//, "", dev)
		state = tolower(f["state"])
		# WD'"'"'s small system RAID (md0, about 2 GB) is kept apart from the data RAIDs
		sys_raid = n(f["size"]) < 17179869184 ? 1 : 0
		l = "raid=\"" esc(dev) "\""
		add("wd_raid_info", "A RAID array, with its level (always 1); system is WD'"'"'s own small system array", l ",level=\"" esc(f["level"]) "\",system=\"" sys_raid "\"", 1)
		add("wd_raid_state", "The RAID array'"'"'s state, as the state label (always 1)", l ",state=\"" esc(state) "\"", 1)
		add("wd_raid_disks", "The RAID array'"'"'s disks, by state", l ",state=\"total\"", n(f["num_of_total_disks"]))
		add("wd_raid_disks", "", l ",state=\"active\"", n(f["num_of_active_disks"]))
		add("wd_raid_disks", "", l ",state=\"working\"", n(f["num_of_working_disks"]))
		add("wd_raid_disks", "", l ",state=\"spare\"", n(f["num_of_spare_disks"]))
		add("wd_raid_disks", "", l ",state=\"failed\"", n(f["num_of_failed_disks"]))
		add("wd_raid_disks", "", l ",state=\"rebuilding\"", words(f["rebuilding_disks"]))
		add("wd_raid_dirty", "Whether WD has marked the RAID array dirty", l, n(f["dirty"]))
		add("wd_raid_size_bytes", "RAID array size", l, n(f["size"]))
		if (!sys_raid) {
			if (n(f["num_of_failed_disks"]) > 0 || f["failed_disks"] != "" || state ~ /^(degraded|inactive|failed|fail|broken)$/) { critical++ }
			else if (f["rebuilding_disks"] != "" || f["dirty"] == "1" || state ~ /(recover|resync|rebuild|reshap|check)/) { warning++ }
		}
		kind = ""; next
	}

	line == "</vol>" {
		dev = f["dev"]; sub(/^\/dev\//, "", dev)
		l = "volume=\"" esc(f["name"]) "\""
		add("wd_volume_info", "A volume, with its label, mount point and RAID (always 1)", l ",label=\"" esc(f["label"]) "\",mountpoint=\"" esc(f["mnt"]) "\",raid=\"" esc(dev) "\",raid_level=\"" esc(f["raid_level"]) "\"", 1)
		add("wd_volume_mounted", "Whether the volume is mounted", l, n(f["mounted"]))
		add("wd_volume_encrypted", "Whether the volume is encrypted", l, n(f["encrypted"]))
		add("wd_volume_unlocked", "Whether the volume is unlocked (always 1 for unencrypted volumes)", l, n(f["unlocked"]))
		add("wd_volume_size_bytes", "Volume size", l, n(f["size"]))
		add("wd_volume_used_bytes", "Space used on the volume", l, n(f["used_size"]))
		if (f["dev"] != "" && f["mounted"] != "1") { critical++ }
		kind = ""; next
	}

	# A field: <tag>value</tag>, of the current record (or of the raids tree itself)
	line ~ /^<[a-z_]+>.*<\/[a-z_]+>$/ {
		tag = substr(line, 2, index(line, ">") - 2)
		value = substr(line, index(line, ">") + 1)
		value = unxml(substr(value, 1, length(value) - length(tag) - 3))
		if (kind != "") { f[(smart ? "smart_" : "") tag] = value }
		else if (tree == "raids" && tag == "dirty" && value == "1") { warning++ }
		next
	}

	END {
		if (ok == 1) {
			add("wd_info", "The NAS model and firmware version (always 1)", "model=\"" esc(model) "\",firmware=\"" esc(firmware) "\"", 1)
			add("wd_health", "Overall storage health from WD'"'"'s records: 0 healthy, 1 degraded (a warning), 2 critical", "", critical ? 2 : (warning ? 1 : 0))
		}
		add("wd_collector_success", "Whether WD'"'"'s storage records could all be read", "", ok == 1 ? 1 : 0)
		for (i = 1; i <= count; i++) {
			name = order[i]
			print "# HELP " name " " helps[name]
			print "# TYPE " name " gauge"
			printf "%s", samples[name]
		}
	}' > "${OUT_DIR}/wd.prom.$$"

	# Replaced in one step, so Node Exporter never reads a half-written file
	mv -f "${OUT_DIR}/wd.prom.$$" "${OUT_DIR}/wd.prom"
}

mkdir -p "${OUT_DIR}"
if [ -z "${INTERVAL}" ]; then
	collect
	exit 0
fi

# Runs until stopped, removing its files on the way out
trap 'rm -f "${OUT_DIR}/wd.prom" "${OUT_DIR}"/wd.prom.*; rm -rf "${WORK}"; exit 0' TERM INT
while :; do
	collect
	# Keeps Node Exporter's log (CAP_LOG, in RAM) under 1MB
	if [ -n "${CAP_LOG}" ] && [ "$(wc -c < "${CAP_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
		: > "${CAP_LOG}"
	fi
	sleep "${INTERVAL}" &
	wait $!
done
