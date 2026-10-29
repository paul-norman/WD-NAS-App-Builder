# The real Arr stack recipe through the Store (a copy with a lower disk requirement, made by run_tests.sh), with every
# optional app on: everything connected by its hook - checked with the apps' own connection tests - then a change of
# settings (two apps switched off, a new password), library folders of the user's own, how long torrents seed, names kept,
# and removal, keeping the library
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url=https://github.com/paul-norman/WD-NAS-App-Builder >/dev/null; post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
mkdir -p $V/Media
# The ntfy app on the NAS (its apps' token), and a stand-in ntfy, Plex and Jellyfin answering the apps - on this machine,
# which the apps reach as host.docker.internal
mkdir -p $P/ntfy $P/_ntfy; printf 'Package:\t\t\tntfy\nVersion:\t\t\t2.32.0-1\n' > $P/ntfy/apkg.rc
echo tk_testtoken1234567890abcdefghijk > $P/_ntfy/token; echo LISTEN=all > $P/_ntfy/settings
rm -f /tmp/ntfy-messages; python3 /tbin/fake_media.py & FAKE=$!
python3 /tbin/repotool.py add-recipe /www/repo /tfix/arr-small; post refresh >/dev/null
D=$P/_arr; M=$V/Media
get details "&kind=recipes&repo=$REPO&id=arr" >/dev/null
echo "  problems: $(j '$d["problems"]')"; echo "  wizard: $(j 'implode(", ", array_map(function($f){return $f["key"].(empty($f["advanced"])?"":"(adv)")."=".json_encode($f["value"]);}, $d["wizard"]))' | cut -c1-400)"
ANS='{"DATA_ROOT":"'$M'","ADMIN_USER":"admin","ADMIN_PASSWORD":"Test-pass-123","LIDARR":true,"BOOKS":true,"SABNZBD":true,"FLARESOLVERR":true,"SUBTITLE_LANGUAGE":"en","TORRENT_PORT":6881,"TZ":"Europe/London","TV_FOLDERS":[],"MOVIES_FOLDERS":[],"MUSIC_FOLDERS":[],"BOOKS_FOLDERS":[],"AFTER_IMPORT":"seed","SEED_RATIO":"2","SEED_DAYS":14,"RENAME":true,"FLAT_FILMS":false,"NTFY_TOPIC":"arr","MEDIA_SERVER":"none","MEDIA_SERVER_KEY":"","MEDIA_SERVER_URL":"","RECYCLARR":true,"QUALITY":"1080p"}'
post start -d job=recipe_install -d repo=$REPO -d id=arr --data-urlencode "answers=$ANS" >/dev/null; START=$(cat /tmp/body); job_wait
get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | grep -E "^n?(qBittorrent|SABnzbd|Sonarr|Radarr|Lidarr|Bookshelf|Prowlarr|Recyclarr|Bazarr|Seerr|Problem|Everything|Finished):" | sed 's/^n//' | sed 's/^/  /' | cut -c1-200
[ "$JOB_STATE" = '"done"' ] && j '$d["log"]' | grep -q "Everything is connected" && pass "installed through the Store, everything connected by its hook: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG (start: $START)"; j '$d["log"]' | tr '\\' '\n' | tail -30; }
set -a; . $D/.env; set +a
RUNNING=$(docker ps --format '{{.Names}}' | grep -cxE 'qbittorrent|prowlarr|sonarr|radarr|bazarr|seerr|lidarr|bookshelf|sabnzbd|flaresolverr|recyclarr')
[ "$RUNNING" = 11 ] && pass "all 11 containers running" || fail "running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"

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
A=""; for a in "8989 v3 $SONARR_API_KEY" "7878 v3 $RADARR_API_KEY" "9696 v1 $PROWLARR_API_KEY" "8686 v1 $LIDARR_API_KEY" "8787 v1 $BOOKSHELF_API_KEY"; do
	set -- $a; A="$A$(arr $1 $2 $3 /config/host | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["analyticsEnabled"]);') "
done
case "$A" in "false false false false false "|"false false false false null ") true;; *) false;; esac && [ "$(echo "$BS" | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["analytics"]["enabled"]);')" = false ] \
	&& pass "no anonymous usage data sent to the developers: off in Sonarr, Radarr, Prowlarr, Lidarr and Bazarr (Bookshelf has no such setting)" || fail "analytics: $A bazarr $(echo "$BS" | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["analytics"] ?? null);')"
docker exec seerr cat /app/config/settings.json | php -r '$s=json_decode(stream_get_contents(STDIN),true); exit($s["sonarr"][0]["hostname"]==="sonarr" && $s["sonarr"][0]["activeDirectory"]==="/data/media/tv" && $s["radarr"][0]["apiKey"]===getenv("RADARR_API_KEY") ? 0 : 1);' \
	&& [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5055/api/v1/status)" = 200 ] && grep -q 'proxy_pass       http://127.0.0.1:5055' $P/_nginx/sites/60-app-seerr.conf \
	&& pass "Seerr: Sonarr and Radarr already set (its setup only asks for the media server); Nginx seerr site" || fail "seerr: $(docker exec seerr cat /app/config/settings.json | head -c 300)"
# The quality rules: the TRaSH Guides' profiles (with their custom formats scored), and Seerr requesting with the chosen one
profiles() { arr $1 $2 $3 /qualityprofile | php -r '$p=array_filter(json_decode(stream_get_contents(STDIN),true), function($p){return count(array_filter($p["formatItems"], function($f){return $f["score"] != 0;})) > 0;});
	$n=array_map(function($p){return $p["name"];}, $p); sort($n); echo implode(",", $n);'; }
seerr_profiles() { docker exec seerr cat /app/config/settings.json | php -r '$s=json_decode(stream_get_contents(STDIN),true); echo $s["sonarr"][0]["activeProfileName"]."/".$s["sonarr"][0]["activeAnimeProfileName"]."/".$s["radarr"][0]["activeProfileName"];'; }
QS=$(profiles 8989 v3 $SONARR_API_KEY); QR=$(profiles 7878 v3 $RADARR_API_KEY)
[ "$QS" = "WEB-1080p,WEB-2160p" ] && [ "$QR" = "HD Bluray + WEB,UHD Bluray + WEB" ] && [ "$(seerr_profiles)" = "WEB-1080p/WEB-1080p/HD Bluray + WEB" ] \
	&& [ "$(stat -c '%u' $D/recyclarr/recyclarr.yml)" = 84 ] && ! grep -q "$SONARR_API_KEY" $D/recyclarr/recyclarr.yml \
	&& pass "quality rules: the TRaSH Guides' profiles with their scores (Sonarr $QS; Radarr $QR), Seerr requesting with the 1080p ones" \
	|| fail "quality rules: sonarr '$QS' radarr '$QR' seerr '$(seerr_profiles)'; $(docker logs recyclarr 2>&1 | tail -5)"
# ntfy: each app's connection (its server, topic, and events - filed once per release where it can, no grabs), the test
# notification each sent as it was connected (with ntfy's token), and Seerr's
notify() { arr $1 $2 $3 /notification | php -r '$n=array_values(array_filter(json_decode(stream_get_contents(STDIN),true), function($x){return $x["name"]==="ntfy (Arr stack)";}));
	foreach ($n as $x) { $f=[]; foreach ($x["fields"] as $y) if (in_array($y["name"], ["serverUrl","topics"], true)) $f[]=json_encode($y["value"], JSON_UNESCAPED_SLASHES);
	$on=array_keys(array_filter($x, function($v, $k){return substr($k,0,2)==="on" && $v===true;}, ARRAY_FILTER_USE_BOTH)); sort($on); echo implode(" ", $f)." ".implode(",", $on); }'; }
NS=$(notify 8989 v3 $SONARR_API_KEY); NR=$(notify 7878 v3 $RADARR_API_KEY); NP=$(notify 9696 v1 $PROWLARR_API_KEY); NL=$(notify 8686 v1 $LIDARR_API_KEY); NB=$(notify 8787 v1 $BOOKSHELF_API_KEY)
SN=$(docker exec seerr cat /app/config/settings.json | php -r '$a=json_decode(stream_get_contents(STDIN),true)["notifications"]["agents"]["ntfy"]; echo json_encode([$a["enabled"], $a["types"], $a["options"]["url"], $a["options"]["topic"], $a["options"]["authMethodToken"], $a["options"]["token"] === "tk_testtoken1234567890abcdefghijk"], JSON_UNESCAPED_SLASHES);')
MSGS=$(wc -l < /tmp/ntfy-messages 2>/dev/null || echo 0)
echo "  sonarr: $NS"; echo "  radarr: $NR"; echo "  prowlarr: $NP"; echo "  lidarr: $NL"; echo "  bookshelf: $NB"; echo "  seerr: $SN; messages: $MSGS"
echo "$NS" | grep -q '^"http://host.docker.internal:2586" \["arr"\] .*onImportComplete' && ! echo "$NS" | grep -q "onGrab\|onDownload[,]\|onDownload$" \
	&& echo "$NS" | grep -q onHealthIssue && echo "$NR" | grep -q '\["arr"\] .*onDownload' && echo "$NP" | grep -q '\["arr"\] .*onHealthIssue' && [ -n "$NL" ] && [ -n "$NB" ] \
	&& [ "$SN" = '[true,410,"http://host.docker.internal:2586","arr",true,true]' ] && [ "$MSGS" -ge 5 ] \
	&& pass "ntfy: Sonarr, Radarr, Lidarr, Bookshelf, Prowlarr and Seerr send to topic arr, with the ntfy app's token ($MSGS test notifications received)" \
	|| fail "ntfy: messages $MSGS; $(echo "$LOG" | tr '\\' '\n' | grep -i ntfy | head -5)"

S=$P/_nginx/sites; ok=1
for site in "radarr 7878" "sonarr 8989" "prowlarr 9696" "bazarr 6767" "qbittorrent 8090" "lidarr 8686" "bookshelf 8787" "sabnzbd 8085"; do
	set -- $site; grep -q "proxy_pass       http://127.0.0.1:$2;" $S/60-app-$1.conf 2>/dev/null || { ok=0; echo "  no site for $1"; }
done
[ $ok = 1 ] && pass "every app's own site in the Nginx app (radarr., sonarr., prowlarr., bazarr., qbittorrent., lidarr., bookshelf., sabnzbd.)" || fail "sites: $(ls $S | tr '\n' ' ')"

echo "== a change of settings: Lidarr and FlareSolverr off, a new password, Plex on the NAS, 4K requests"
# (Plex on the NAS: its token is read from its Preferences.xml)
mkdir -p "$P/plexmediaserver/Library/Plex Media Server"; printf '<?xml version="1.0" encoding="utf-8"?>\n<Preferences MachineIdentifier="m1" PlexOnlineToken="plex-tok-123" />\n' > "$P/plexmediaserver/Library/Plex Media Server/Preferences.xml"
CHG='{"DATA_ROOT":"'$M'","ADMIN_USER":"admin","ADMIN_PASSWORD":"New-pass-456","LIDARR":false,"BOOKS":true,"SABNZBD":true,"FLARESOLVERR":false,"TORRENT_PORT":6881,"TZ":"Europe/London","TV_FOLDERS":[],"MOVIES_FOLDERS":[],"MUSIC_FOLDERS":[],"BOOKS_FOLDERS":[],"AFTER_IMPORT":"seed","SEED_RATIO":"2","SEED_DAYS":14,"RENAME":true,"FLAT_FILMS":false,"NTFY_TOPIC":"arr","MEDIA_SERVER":"plex","MEDIA_SERVER_KEY":"","MEDIA_SERVER_URL":"","RECYCLARR":true,"QUALITY":"2160p"}'
post start -d job=recipe_change -d id=arr --data-urlencode "answers=$CHG" >/dev/null; job_wait
get job >/dev/null; LOG=$(j '$d["log"]')
[ "$JOB_STATE" = '"done"' ] && [ -z "$(docker ps -aq --filter name=^lidarr$)" ] && [ -z "$(docker ps -aq --filter name=^flaresolverr$)" ] \
	&& [ "$(arr 9696 v1 $PROWLARR_API_KEY /applications | php -r '$n=array_map(function($a){return $a["name"];}, json_decode(stream_get_contents(STDIN),true)); sort($n); echo implode(",", $n);')" = "Bookshelf,Radarr,Sonarr" ] \
	&& [ "$(arr 9696 v1 $PROWLARR_API_KEY /indexerproxy)" = "[]" ] && [ ! -f $P/_nginx/sites/60-app-lidarr.conf ] && [ -f $P/_nginx/sites/60-app-bookshelf.conf ] \
	&& pass "Lidarr and FlareSolverr removed, and from Prowlarr (post_change hook) - and Lidarr's site" || fail "change: $JOB_STATE $JOB_MSG; $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
login=$(curl -s -o /dev/null -w '%{redirect_url}' --data 'username=admin&password=New-pass-456' http://127.0.0.1:8989/login)
[ "$(curl -s -o /dev/null -w '%{http_code}' -H "Referer: $Q" --data 'username=admin&password=New-pass-456' $Q/api/v2/auth/login)" = 204 ] && ! echo "$login" | grep -q loginFailed \
	&& pass "the new password in qBittorrent and Sonarr" || fail "new password: sonarr $login"
# The media server's connection in an app: its implementation, then field values
media() { arr $1 $2 $3 /notification | php -r '$n=array_values(array_filter(json_decode(stream_get_contents(STDIN),true), function($x){return substr($x["name"], -18)===" (library updates)";}));
	foreach ($n as $x) { $f=[]; foreach ($x["fields"] as $y) if (in_array($y["name"], $argv, true)) $f[]=json_encode($y["value"], JSON_UNESCAPED_SLASHES); echo $x["name"]." ".$x["implementation"]." ".implode(" ", $f).($x["onDownload"] && $x["onRename"] && !$x["onGrab"] ? " events-ok" : " events-wrong")."\n"; }' -- $4; }
MS=$(media 8989 v3 $SONARR_API_KEY "host port authToken updateLibrary"); MR=$(media 7878 v3 $RADARR_API_KEY "host port authToken updateLibrary")
[ "$MS" = 'Plex (library updates) PlexServer "host.docker.internal" 32400 "********" true events-ok' ] && [ "$MR" = "$MS" ] \
	&& echo "$LOG" | grep -q "Radarr: tells Plex (host.docker.internal:32400) about new files" \
	&& pass "Plex on the NAS: Sonarr and Radarr tell it of new files (its token read from Plex's Preferences.xml; their connection tests pass)" || fail "plex: sonarr '$MS' radarr '$MR'; $(echo "$LOG" | tr '\\' '\n' | grep -i plex | head -3)"
[ "$(seerr_profiles)" = "WEB-2160p/WEB-2160p/UHD Bluray + WEB" ] && pass "4K requests: Seerr switched to the 4K profiles" || fail "4k: $(seerr_profiles)"

echo "== library folders of your own (outside the downloads folder), seeding for a while, names kept"
# (the ntfy app removed - its data folder, with the token, kept: no notifications)
rm -rf $P/ntfy
# (folders of a user's own share: the share group may write - and one it may not, which is said)
mkdir -p "$V/Me/TV" "$V/Me/Anime" "$V/Me/Films" "$V/Locked/Books"; chgrp 1000 "$V/Me/TV" "$V/Me/Anime" "$V/Me/Films"; chmod 2775 "$V/Me/TV" "$V/Me/Anime" "$V/Me/Films"
chmod 755 "$V/Locked/Books"
CHG='{"DATA_ROOT":"'$M'","ADMIN_USER":"admin","ADMIN_PASSWORD":"New-pass-456","LIDARR":false,"BOOKS":true,"SABNZBD":true,"FLARESOLVERR":false,"TORRENT_PORT":6881,"TZ":"Europe/London","TV_FOLDERS":["'$V'/Me/TV","'$V'/Me/Anime"],"MOVIES_FOLDERS":["'$V'/Me/Films"],"BOOKS_FOLDERS":["'$V'/Locked/Books"],"AFTER_IMPORT":"limit","SEED_RATIO":"1","SEED_DAYS":7,"RENAME":false,"FLAT_FILMS":false,"NTFY_TOPIC":"arr","MEDIA_SERVER":"jellyfin","MEDIA_SERVER_KEY":"jf-key-1","MEDIA_SERVER_URL":"http://host.docker.internal:18096/","RECYCLARR":true,"QUALITY":"2160p"}'
post start -d job=recipe_change -d id=arr --data-urlencode "answers=$CHG" >/dev/null; job_wait
get job >/dev/null; LOG=$(j '$d["log"]')
mounts() { docker inspect $1 --format '{{range .Mounts}}{{.Destination}} {{end}}'; }
[ "$JOB_STATE" = '"done"' ] && mounts sonarr | grep -q "/media/Me/TV /media/Me/Anime\|/media/Me/Anime /media/Me/TV\|/media/Me/TV .*/media/Me/Anime" && mounts bazarr | grep -q "/media/Me/Films" \
	&& mounts bazarr | grep -q "/media/Me/TV" && mounts radarr | grep -q "/media/Me/Films" && ! mounts radarr | grep -q "/media/Me/TV" \
	&& pass "the folders mounted where they're needed: TV in Sonarr and Bazarr, films in Radarr and Bazarr ($(mounts bazarr))" || fail "mounts: sonarr $(mounts sonarr) / bazarr $(mounts bazarr)"
roots() { arr $1 $2 $3 /rootfolder | php -r 'echo implode(",", array_map(function($r){return $r["path"].($r["accessible"] ? "" : "(!)");}, json_decode(stream_get_contents(STDIN),true)));'; }
R=$(roots 8989 v3 $SONARR_API_KEY)
echo "$R" | grep -q "/media/Me/TV" && echo "$R" | grep -q "/media/Me/Anime" && ! echo "$R" | grep -q "(!)" && roots 7878 v3 $RADARR_API_KEY | grep -q "/media/Me/Films" \
	&& [ "$(docker exec --user 84:1000 sonarr sh -c 'echo x > /media/Me/TV/w.txt && cat /media/Me/TV/w.txt')" = x ] && [ -f "$V/Me/TV/w.txt" ] \
	&& pass "Sonarr's and Radarr's library folders, accessible (and writable as the apps' user): $R" || fail "root folders: sonarr $R radarr $(roots 7878 v3 $RADARR_API_KEY)"
rm -f "$V/Me/TV/w.txt"
echo "$LOG" | grep -q "Bookshelf can't write into $V/Locked/Books" && pass "a folder the apps can't write into: said so (and left as it is - $(stat -c '%U %a' "$V/Locked/Books"))" || fail "locked folder not reported: $(echo "$LOG" | tail -c 400)"
QP=$(curl -s -c /tmp/qc2 -H "Referer: $Q" --data 'username=admin&password=New-pass-456' -o /dev/null $Q/api/v2/auth/login; curl -s -b /tmp/qc2 $Q/api/v2/app/preferences \
	| php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode([$d["max_ratio_enabled"], (string)$d["max_ratio"], $d["max_seeding_time_enabled"], $d["max_seeding_time"], $d["max_ratio_act"]]);')
[ "$QP" = '[true,"1",true,10080,0]' ] && arr 8989 v3 $SONARR_API_KEY /downloadclient | grep -q '"removeCompletedDownloads": *true' \
	&& pass "seeding for a while: qBittorrent stops at ratio 1 or 7 days; Sonarr then removes it (once filed): $QP" || fail "seeding: $QP"
[ "$(arr 8989 v3 $SONARR_API_KEY /config/naming | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["renameEpisodes"]);')" = false ] \
	&& [ "$(arr 7878 v3 $RADARR_API_KEY /config/naming | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["renameMovies"]);')" = false ] \
	&& pass "names kept as downloaded (renaming off in Sonarr and Radarr)" || fail "rename off"
MS=$(media 8989 v3 $SONARR_API_KEY "host port apiKey mapFrom mapTo"); MR=$(media 7878 v3 $RADARR_API_KEY "host port apiKey mapFrom mapTo")
[ "$MS" = "Jellyfin (library updates) MediaBrowser \"host.docker.internal\" 18096 \"********\" \"/media\" \"$V\" events-ok" ] && [ "$MR" = "$MS" ] \
	&& echo "$LOG" | grep -q "Sonarr: tells Jellyfin (host.docker.internal:18096) about new files" \
	&& [ -z "$(notify 8989 v3 $SONARR_API_KEY)$(notify 9696 v1 $PROWLARR_API_KEY)" ] && echo "$LOG" | grep -q "ntfy: the ntfy app isn't installed" \
	&& pass "ntfy app removed (its data kept): its connections gone; Jellyfin at its own address: told of new files by their paths on the NAS (/media -> $V); Plex's connection gone" || fail "jellyfin: sonarr '$MS' radarr '$MR'; $(echo "$LOG" | tr '\\' '\n' | grep -i jellyfin | head -3)"
# A server that doesn't answer: said so (the apps refuse the connection)
BAD=$(echo "$CHG" | sed 's#"MEDIA_SERVER_URL":"http://host.docker.internal:18096/"#"MEDIA_SERVER_URL":"http://host.docker.internal:18097"#')
post start -d job=recipe_change -d id=arr --data-urlencode "answers=$BAD" >/dev/null; job_wait
get job >/dev/null; j '$d["log"]' | grep -q "Problem: Sonarr: not connected to Jellyfin at host.docker.internal:18097" \
	&& pass "a media server that doesn't answer: said so - tried again at the next change" || fail "unreachable: $(j '$d["log"]' | tr '\\' '\n' | grep -i jellyfin | head -3)"
CHG=$(echo "$CHG" | sed 's/"AFTER_IMPORT":"limit"/"AFTER_IMPORT":"remove"/; s/"RENAME":false/"RENAME":true/; s/"FLAT_FILMS":false/"FLAT_FILMS":true/; s/"MEDIA_SERVER":"jellyfin"/"MEDIA_SERVER":"none"/; s/"RECYCLARR":true/"RECYCLARR":false/; s/"NTFY_TOPIC":"arr"/"NTFY_TOPIC":""/')
post start -d job=recipe_change -d id=arr --data-urlencode "answers=$CHG" >/dev/null; job_wait
QP=$(curl -s -b /tmp/qc2 $Q/api/v2/app/preferences | php -r '$d=json_decode(stream_get_contents(STDIN),true); echo json_encode([$d["max_ratio_enabled"], (string)$d["max_ratio"], $d["max_seeding_time_enabled"]]);')
[ "$QP" = '[true,"0",false]' ] && [ "$(arr 8989 v3 $SONARR_API_KEY /config/naming | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["renameEpisodes"]);')" = true ] \
	&& pass "not seeding: stopped as soon as complete (ratio 0), then removed once filed; renaming on again: $QP" || fail "remove: $QP"
[ -z "$(media 8989 v3 $SONARR_API_KEY host)$(media 7878 v3 $RADARR_API_KEY host)" ] && [ -z "$(docker ps -aq --filter name=^recyclarr$)" ] \
	&& [ -z "$(notify 8989 v3 $SONARR_API_KEY)$(notify 9696 v1 $PROWLARR_API_KEY)" ] \
	&& [ "$(docker exec seerr cat /app/config/settings.json | php -r 'echo json_encode(json_decode(stream_get_contents(STDIN),true)["notifications"]["agents"]["ntfy"]["enabled"]);')" = false ] \
	&& pass "no media server, no quality rules, no ntfy topic: the connections (and Seerr's notifications) and Recyclarr's container gone (its profiles stay)" || fail "off: $(media 8989 v3 $SONARR_API_KEY host) $(docker ps -a --format '{{.Names}}' | tr '\n' ' ')"

echo "== films without their own folder"
N=$(arr 7878 v3 $RADARR_API_KEY /notification | php -r '$n=array_values(array_filter(json_decode(stream_get_contents(STDIN),true), function($x){return $x["name"]==="Films without their own folder";}));
	if (!$n) exit; $p=array_values(array_filter($n[0]["fields"], function($f){return $f["name"]==="path";})); echo $n[0]["implementation"]." ".$p[0]["value"]." ".json_encode($n[0]["onDownload"]);')
SCRIPT=$D/radarr/scripts/films-without-folders.sh
[ "$N" = "CustomScript /config/scripts/films-without-folders.sh true" ] && [ "$(stat -c '%u %a' $SCRIPT)" = "84 755" ] \
	&& pass "Radarr runs the recipe's script after each import (Settings -> Connect): $N" || fail "custom script: '$N' $(ls -la $SCRIPT 2>&1)"
# A film added to Radarr (no search), a file filed in its folder, then the script run as Radarr runs it (its events'
# variables, in its container)
MID=$(arr 7878 v3 $RADARR_API_KEY /movie -X POST -d '{"title":"Big Buck Bunny","tmdbId":10378,"year":2008,"qualityProfileId":1,"rootFolderPath":"/media/Me/Films","monitored":false,"addOptions":{"searchForMovie":false}}' \
	| php -r '$d=json_decode(stream_get_contents(STDIN),true); echo isset($d["id"]) ? $d["id"]." ".$d["path"] : "";')
set -- $MID; ID=$1; MP=${MID#* }
if [ -n "$ID" ]; then
	docker exec --user 84:1000 radarr sh -c 'mkdir -p "$1" && echo film > "$1/Big Buck Bunny (2008).mkv" && echo subs > "$1/Big Buck Bunny (2008).en.srt"' sh "$MP"
	OUT=$(docker exec --user 84:1000 -e radarr_eventtype=Download -e "radarr_movie_path=$MP" -e "radarr_moviefile_path=$MP/Big Buck Bunny (2008).mkv" -e "radarr_movie_title=Big Buck Bunny" -e radarr_movie_id=$ID radarr sh /config/scripts/films-without-folders.sh)
	for i in $(seq 1 30); do [ "$(arr 7878 v3 $RADARR_API_KEY /movie/$ID -o /dev/null -w '%{http_code}')" = 404 ] && break; sleep 1; done
	[ -f "$V/Me/Films/Big Buck Bunny (2008).mkv" ] && [ -f "$V/Me/Films/Big Buck Bunny (2008).en.srt" ] && [ ! -d "$V/Me/Films/Big Buck Bunny (2008)" ] \
		&& [ "$(arr 7878 v3 $RADARR_API_KEY /movie/$ID -o /dev/null -w '%{http_code}')" = 404 ] \
		&& pass "a filed film moved up into the film folder (with its subtitles), its folder gone, taken off Radarr's list - its files kept: $OUT" \
		|| fail "flat film: $OUT; $(ls -la "$V/Me/Films"); radarr $(arr 7878 v3 $RADARR_API_KEY /movie/$ID -o /dev/null -w '%{http_code}')"
else
	fail "flat film: Radarr couldn't add the test film (its metadata comes from the internet)"
fi
rm -f "$V/Me/Films/Big Buck Bunny (2008)".*

echo "== removed"
post start -d job=recipe_uninstall -d id=arr -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ ! -d $D ] && [ -d $M/media/tv ] && [ -z "$(docker ps -aq --filter name=^sonarr$)" ] && [ -z "$(docker ps -aq --filter name=^bookshelf$)" ] \
	&& pass "removed; the library folder kept: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG; $(docker ps -a --format '{{.Names}}' | tr '\n' ' ')"
kill $FAKE
for c in qbittorrent prowlarr sonarr radarr bazarr seerr lidarr bookshelf sabnzbd flaresolverr recyclarr; do docker rm -f $c > /dev/null 2>&1; done
true
