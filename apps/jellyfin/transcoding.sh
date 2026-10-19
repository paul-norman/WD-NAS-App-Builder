#!/bin/sh
# Picks Jellyfin's hardware transcoding settings from what the NAS's GPU can really do (as listed by vainfo), and writes
# them to Jellyfin's encoding.xml. Jellyfin only reads the file when it starts, so apply it while Jellyfin is stopped.
#
#   transcoding.sh detect                      - prints the GPU's driver, then the recommended settings (Name=value)
#   transcoding.sh apply <encoding.xml>        - writes the recommended settings into the file (creating it if needed)

APP_PATH="$(dirname "$(readlink -f "$0")")"
FFMPEG_PATH="${APP_PATH}/binaries/ffmpeg"
DEVICE=/dev/dri/renderD128

# What the GPU supports: one "<profile> : <entrypoint>" line each (VLD = decode, EncSlice = encode, EncSliceLP = the
# low power encoder)
VAINFO="$(LD_LIBRARY_PATH="${FFMPEG_PATH}/lib" "${FFMPEG_PATH}/vainfo" --display drm --device "${DEVICE}" 2>&1)"

supports() {
	echo "${VAINFO}" | grep -Eq "VAProfile($1)[[:space:]]*:[[:space:]]*VAEntrypoint$2[[:space:]]*\$"
}

is_ihd() {
	echo "${VAINFO}" | grep -q "Driver version: Intel iHD"
}

yes_no() {
	if "$@"; then echo true; else echo false; fi
}

detect() {
	echo "Driver=$(echo "${VAINFO}" | sed -n 's/.*Driver version: //p' | head -n 1)"

	if ! supports "H264(Main|High|ConstrainedBaseline)" VLD; then
		# No usable GPU: transcode in software
		echo "HardwareAccelerationType=none"
		echo "HardwareDecodingCodecs="
		for name in EnableDecodingColorDepth10Hevc EnableDecodingColorDepth10Vp9 EnableDecodingColorDepth10HevcRext \
			EnableDecodingColorDepth12HevcRext EnableHardwareEncoding EnableIntelLowPowerH264HwEncoder \
			EnableIntelLowPowerHevcHwEncoder AllowHevcEncoding AllowAv1Encoding EnableTonemapping EnableVppTonemapping; do
			echo "${name}=false"
		done
		return
	fi

	codecs="h264"
	supports "HEVCMain" VLD && codecs="${codecs},hevc"
	supports "MPEG2(Simple|Main)" VLD && codecs="${codecs},mpeg2video"
	supports "VC1(Simple|Main|Advanced)" VLD && codecs="${codecs},vc1"
	supports "VP8Version0_3" VLD && codecs="${codecs},vp8"
	supports "VP9Profile0" VLD && codecs="${codecs},vp9"
	supports "AV1Profile0" VLD && codecs="${codecs},av1"

	echo "HardwareAccelerationType=vaapi"
	echo "VaapiDevice=${DEVICE}"
	echo "HardwareDecodingCodecs=${codecs}"
	# Jellyfin enables 10-bit HEVC / VP9 decoding by default, which fails on GPUs that can't (e.g. the PR4100's)
	echo "EnableDecodingColorDepth10Hevc=$(yes_no supports "HEVCMain10" VLD)"
	echo "EnableDecodingColorDepth10Vp9=$(yes_no supports "VP9Profile2" VLD)"
	echo "EnableDecodingColorDepth10HevcRext=$(yes_no supports "HEVCMain(422_10|444_10)" VLD)"
	echo "EnableDecodingColorDepth12HevcRext=$(yes_no supports "HEVCMain(12|422_12|444_12)" VLD)"

	# Encoding: the normal encoder where there is one, otherwise the low power one
	h264=false; h264_lp=false; hevc=false; hevc_lp=false; av1=false
	if supports "H264(Main|High|ConstrainedBaseline)" EncSlice; then h264=true
	elif supports "H264(Main|High|ConstrainedBaseline)" EncSliceLP; then h264=true; h264_lp=true; fi
	if supports "HEVCMain" EncSlice; then hevc=true
	elif supports "HEVCMain" EncSliceLP; then hevc=true; hevc_lp=true; fi
	supports "AV1Profile0" "EncSlice(LP)?" && av1=true
	echo "EnableHardwareEncoding=${h264}"
	echo "EnableIntelLowPowerH264HwEncoder=${h264_lp}"
	echo "EnableIntelLowPowerHevcHwEncoder=${hevc_lp}"
	echo "AllowHevcEncoding=${hevc}"
	echo "AllowAv1Encoding=${av1}"

	# HDR tone mapping needs OpenCL (not available on the NAS) or Intel's newer iHD driver
	echo "EnableTonemapping=false"
	echo "EnableVppTonemapping=$(yes_no is_ihd)"
}

# Replaces (or adds) each setting in the file, keeping everything else as it is
apply() {
	file="$1"
	settings="$(detect | grep -v '^Driver=')"

	if [ ! -s "${file}" ]; then
		printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' \
			'<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">' \
			'</EncodingOptions>' > "${file}"
	fi

	echo "${settings}" | awk -F= '
		NR == FNR { value[$1] = substr($0, length($1) + 2); order[++count] = $1; next }

		function write(name,    n, codecs, i) {
			if (name == "HardwareDecodingCodecs") {
				n = split(value[name], codecs, ",")
				if (n == 0) { print "  <" name " />"; return }
				print "  <" name ">"
				for (i = 1; i <= n; i++) print "    <string>" codecs[i] "</string>"
				print "  </" name ">"
			} else {
				print "  <" name ">" value[name] "</" name ">"
			}
			done[name] = 1
		}

		# Skip the rest of a list being replaced
		skipping != "" { if ($0 ~ "</" skipping ">") skipping = ""; next }

		match($0, /^[ \t]*<[A-Za-z0-9]+/) {
			name = substr($0, RSTART, RLENGTH); sub(/^[ \t]*</, "", name)
			if (name in value) {
				write(name)
				if (name == "HardwareDecodingCodecs" && $0 !~ "/>" && $0 !~ "</" name ">") skipping = name
				next
			}
		}

		/<\/EncodingOptions>/ { for (i = 1; i <= count; i++) if (!(order[i] in done)) write(order[i]) }
		{ print }
	' - "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

case "$1" in
	detect) detect ;;
	apply) [ -n "$2" ] && apply "$2" ;;
	*) echo "Usage: $0 detect | apply <encoding.xml>"; exit 1 ;;
esac
