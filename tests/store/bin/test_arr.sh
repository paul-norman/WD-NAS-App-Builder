# The real Arr stack recipe through the Store (a copy with a lower disk requirement, made by run_tests.sh), with every
# optional app on: everything connected by its hook - checked with the apps' own connection tests - then a change of
# settings (two apps switched off, a new password) and removal, keeping the library
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null; post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
mkdir -p $V/Media
python3 /tbin/repotool.py add-recipe /www/repo /tfix/arr-small; post refresh >/dev/null
D=$P/_arr; M=$V/Media
get details "&kind=recipes&repo=$REPO&id=arr" >/dev/null
echo "  problems: $(j '$d["problems"]')"; echo "  wizard: $(j 'implode(", ", array_map(function($f){return $f["key"].(empty($f["advanced"])?"":"(adv)")."=".json_encode($f["value"]);}, $d["wizard"]))' | cut -c1-400)"
ANS='{"DATA_ROOT":"'$M'","ADMIN_USER":"admin","ADMIN_PASSWORD":"Test-pass-123","LIDARR":true,"BOOKS":true,"SABNZBD":true,"FLARESOLVERR":true,"SUBTITLE_LANGUAGE":"en","TORRENT_PORT":6881,"TZ":"Europe/London"}'
post start -d job=recipe_install -d repo=$REPO -d id=arr --data-urlencode "answers=$ANS" >/dev/null; job_wait
get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | grep -E "^n?(qBittorrent|SABnzbd|Sonarr|Radarr|Lidarr|Bookshelf|Prowlarr|Bazarr|Seerr|Problem|Everything|Finished):" | sed 's/^n//' | sed 's/^/  /' | cut -c1-200
[ "$JOB_STATE" = '"done"' ] && j '$d["log"]' | grep -q "Everything is connected" && pass "installed through the Store, everything connected by its hook: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG"; j '$d["log"]' | tr '\\' '\n' | tail -30; }
set -a; . $D/.env; set +a
RUNNING=$(docker ps --format '{{.Names}}' | grep -cxE 'qbittorrent|prowlarr|sonarr|radarr|bazarr|seerr|lidarr|bookshelf|sabnzbd|flaresolverr')
[ "$RUNNING" = 10 ] && pass "all 10 containers running" || fail "running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"

echo "== the data folder"
[ "$(stat -c '%u:%g %a' $M/media/tv $M/torrents/movies $M/usenet/complete/books)" = "$(printf '84:1000 2775\n84:1000 2775\n84:1000 2775')" ] \
	&& pass "torrents/, usenet/ and media/ with a folder per app: the apps' user, the share group, setgid" || fail "folders: $(ls -la $M $M/media)"
[ "$(docker exec --user 84:1000 sonarr sh -c 'umask 002; echo x > /data/torrents/tv/h.txt && ln /data/torrents/tv/h.txt /data/media/tv/h.txt && stat -c %h /data/media/tv/h.txt')" = 2 ] \
	&& [ "$(stat -c '%g %a' $M/media/tv/h.txt)" = "1000 664" ] && pass "downloads hard-link into the library (one file system); files group-writable for SMB" || fail "hardlink: $(ls -lan $M/media/tv $M/torrents/tv)"
rm -f $M/torrents/tv/h.txt $M/media/tv/h.txt

echo "== qBittorrent and SABnzbd"
Q=http://127.0.0.1:8090
[ "$(curl -s -o /dev/null -w '%{http_code}' -c /tmp/qc -H "Referer: $Q" --data 'username=admin&password=Test-pass-123' $Q/api/v2/auth/login)" = 204 ] \
	&& [ "$(curl -s -b /tmp/qc $Q/api/v2/app/preferences | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["save_path"]." ".$d["listen_port"];')" = "/data/torrents 6881" ] \
	&& [ "$(curl -s -b /tmp/qc $Q/api/v2/torrents/categories | php -r 'echo implode(",", array_map(function($c){return $c["name"]."=".$c["savePath"];}, json_decode(stream_get_contents(STDIN),true)));')" = "books=/data/torrents/books,movies=/data/torrents/movies,music=/data/torrents/music,tv=/data/torrents/tv" ] \
	&& pass "qBittorrent: the user name and password, /data/torrents, a category per app" || fail "qbittorrent"
SK=$(docker exec sabnzbd sed -n 's/^api_key = //p' /config/sabnzbd.ini)
curl -s "http://127.0.0.1:8085/api?mode=get_config&section=categories&apikey=$SK&output=json" | grep -q '"name": *"tv", *"order"\|"name":"tv"\|"name": "tv"' \
	&& curl -s "http://127.0.0.1:8085/api?mode=get_config&section=misc&apikey=$SK&output=json" | grep -q '"complete_dir": *"/data/usenet/complete"' \
	&& pass "SABnzbd: /data/usenet, a category per app" || fail "sabnzbd: $(curl -s "http://127.0.0.1:8085/api?mode=get_config&section=categories&apikey=$SK&output=json" | head -c 300)"

echo "== Sonarr, Radarr, Lidarr, Bookshelf (their own connection tests)"
# An app's API: $1 port, $2 version, $3 key, $4 path, then curl's options
arr() { p=$1; v=$2; k=$3; path=$4; shift 4; curl -s -H "X-Api-Key: $k" -H 'Content-Type: application/json' "$@" "http://127.0.0.1:$p/api/$v$path"; }
for a in "Sonarr 8989 v3 $SONARR_API_KEY tv" "Radarr 7878 v3 $RADARR_API_KEY movies" "Lidarr 8686 v1 $LIDARR_API_KEY music" "Bookshelf 8787 v1 $BOOKSHELF_API_KEY books"; do
	set -- $a
	ok=1
	arr $2 $3 $4 /downloadclient > /tmp/clients
	for i in 0 1; do
		php -r '$d=json_decode(file_get_contents("/tmp/clients"),true); echo json_encode($d['$i']);' > /tmp/client
		[ "$(arr $2 $3 $4 /downloadclient/test -X POST -d @/tmp/client -o /dev/null -w '%{http_code}')" = 200 ] || { ok=0; echo "  $1 client $i: $(arr $2 $3 $4 /downloadclient/test -X POST -d @/tmp/client | head -c 300)"; }
	done
	clients=$(php -r 'echo implode("+", array_map(function($c){return $c["implementation"];}, json_decode(file_get_contents("/tmp/clients"),true)));')
	root=$(arr $2 $3 $4 /rootfolder | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d[0]["path"]." ".json_encode($d[0]["accessible"]);')
	login=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --data 'username=admin&password=Test-pass-123&rememberMe=on' "http://127.0.0.1:$2/login")
	[ $ok = 1 ] && [ "$clients" = "QBittorrent+Sabnzbd" ] && [ "$root" = "/data/media/$5 true" ] && [ "${login%% *}" = 302 ] && ! echo "$login" | grep -q loginFailed \
		&& pass "$1: qBittorrent and SABnzbd connect, library /data/media/$5, its login page takes the password" || fail "$1: clients=$clients root=$root login=$login"
done

echo "== Prowlarr, Bazarr, Seerr"
arr 9696 v1 $PROWLARR_API_KEY /applications > /tmp/apps
ok=1; for i in 0 1 2 3; do
	php -r '$d=json_decode(file_get_contents("/tmp/apps"),true); echo json_encode($d['$i']);' > /tmp/app
	[ "$(arr 9696 v1 $PROWLARR_API_KEY /applications/test -X POST -d @/tmp/app -o /dev/null -w '%{http_code}')" = 200 ] || { ok=0; echo "  app $i: $(arr 9696 v1 $PROWLARR_API_KEY /applications/test -X POST -d @/tmp/app | head -c 300)"; }
done
arr 9696 v1 $PROWLARR_API_KEY /indexerproxy | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)[0]);' > /tmp/proxy
[ $ok = 1 ] && [ "$(php -r '$n=array_map(function($a){return $a["name"];}, json_decode(file_get_contents("/tmp/apps"),true)); sort($n); echo implode(",", $n);')" = "Bookshelf,Lidarr,Radarr,Sonarr" ] \
	&& [ "$(arr 9696 v1 $PROWLARR_API_KEY /indexerproxy/test -X POST -d @/tmp/proxy -o /dev/null -w '%{http_code}')" = 200 ] \
	&& pass "Prowlarr: Sonarr, Radarr, Lidarr and Bookshelf connect; FlareSolverr connects" || fail "prowlarr: $(head -c 300 /tmp/apps)"
BK=$(docker exec bazarr sed -n '/^auth:/,/^[a-z]/s/^  apikey: //p' /config/config/config.yaml | tr -d "'")
BS=$(curl -s -H "X-API-KEY: $BK" http://127.0.0.1:6767/api/system/settings)
echo "$BS" | php -r '$s=json_decode(stream_get_contents(STDIN),true)["general"]; exit($s["use_sonarr"] && $s["use_radarr"] && $s["serie_default_enabled"] && in_array("podnapisi", $s["enabled_providers"]) ? 0 : 1);' \
	&& [ "$(echo "$BS" | php -r 'echo json_decode(stream_get_contents(STDIN),true)["sonarr"]["apikey"];')" = "$SONARR_API_KEY" ] \
	&& [ "$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-KEY: $BK" http://127.0.0.1:6767/api/series)" = 200 ] \
	&& [ "$(curl -s -H "X-API-KEY: $BK" http://127.0.0.1:6767/api/system/languages/profiles | php -r 'echo json_decode(stream_get_contents(STDIN),true)[0]["items"][0]["language"];')" = en ] \
	&& pass "Bazarr: Sonarr and Radarr, English subtitles for everything, sources needing no account" || fail "bazarr: $(echo "$BS" | head -c 300)"
docker exec seerr cat /app/config/settings.json | php -r '$s=json_decode(stream_get_contents(STDIN),true); exit($s["sonarr"][0]["hostname"]==="sonarr" && $s["sonarr"][0]["activeDirectory"]==="/data/media/tv" && $s["radarr"][0]["apiKey"]===getenv("RADARR_API_KEY") ? 0 : 1);' \
	&& [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5055/api/v1/status)" = 200 ] && grep -q 'proxy_pass       http://127.0.0.1:5055' $P/_nginx/sites/60-app-requests.conf \
	&& pass "Seerr: Sonarr and Radarr already set (its setup only asks for the media server); Nginx requests site" || fail "seerr: $(docker exec seerr cat /app/config/settings.json | head -c 300)"

echo "== a change of settings: Lidarr and FlareSolverr off, a new password"
CHG='{"DATA_ROOT":"'$M'","ADMIN_USER":"admin","ADMIN_PASSWORD":"New-pass-456","LIDARR":false,"BOOKS":true,"SABNZBD":true,"FLARESOLVERR":false,"TORRENT_PORT":6881,"TZ":"Europe/London"}'
post start -d job=recipe_change -d id=arr --data-urlencode "answers=$CHG" >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ -z "$(docker ps -aq --filter name=^lidarr$)" ] && [ -z "$(docker ps -aq --filter name=^flaresolverr$)" ] \
	&& [ "$(arr 9696 v1 $PROWLARR_API_KEY /applications | php -r '$n=array_map(function($a){return $a["name"];}, json_decode(stream_get_contents(STDIN),true)); sort($n); echo implode(",", $n);')" = "Bookshelf,Radarr,Sonarr" ] \
	&& [ "$(arr 9696 v1 $PROWLARR_API_KEY /indexerproxy)" = "[]" ] && pass "Lidarr and FlareSolverr removed, and from Prowlarr (post_change hook)" || fail "change: $JOB_STATE $JOB_MSG; $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
login=$(curl -s -o /dev/null -w '%{redirect_url}' --data 'username=admin&password=New-pass-456' http://127.0.0.1:8989/login)
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Referer: $Q" --data 'username=admin&password=New-pass-456' $Q/api/v2/auth/login)" = 204 ] && ! echo "$login" | grep -q loginFailed \
	&& pass "the new password in qBittorrent and Sonarr" || fail "new password: sonarr $login"

echo "== removed"
post start -d job=recipe_uninstall -d id=arr -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ ! -d $D ] && [ -d $M/media/tv ] && [ -z "$(docker ps -aq --filter name=^sonarr$)" ] && [ -z "$(docker ps -aq --filter name=^bookshelf$)" ] \
	&& pass "removed; the library folder kept: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG; $(docker ps -a --format '{{.Names}}' | tr '\n' ' ')"
for c in qbittorrent prowlarr sonarr radarr bazarr seerr lidarr bookshelf sabnzbd flaresolverr; do docker rm -f $c > /dev/null 2>&1; done
true
