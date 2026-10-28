# Sets up the NAS stand-in inside the test container (sourced by the test scripts): the Store app installed from its built
# package, stand-ins for WD's installer, the Nginx app's files, an HTTPS test server and the page's API on 127.0.0.1:8080
# (with an admin's WD session), plus helpers for calling it
pass(){ echo "PASS $1"; }; fail(){ echo "FAIL $1"; }
echo "$STORE_TEST_VOLUME" > /etc/store_test_volume; V="$STORE_TEST_VOLUME"; P="$V/Nas_Prog"; PROJ="$STORE_TEST_PROJECT"
latest() { cat "$PROJ/packages/$1/latest"; }
ln -sf /usr/local/bin/php /usr/bin/php 2>/dev/null
echo "127.0.0.1 repo.test evil.test" >> /etc/hosts
cat /tcerts/ca.pem >> /etc/ssl/certs/ca-certificates.crt
mkdir -p "$P" "$V/Public" /usr/local/modules/files /var/www/xml /usr/local/apps_upload /etc/php /tmp/sess /var/www/apps/store /usr/libexec/docker/cli-plugins
echo "MyCloudPR4100" > /usr/local/modules/files/model
echo "date.timezone = Europe/London" > /etc/php/php.ini
cp /tbin/upload_apkg /tbin/del_apkg /usr/sbin/; sh /tbin/apkg_xml.sh
# Docker's CLI and compose (from the Docker app's package), talking to the test machine's Docker
mkdir -p /tmp/dk && tar -xzf $PROJ/packages/docker/$(latest docker)/docker_$(latest docker)_amd64.tar.gz -C /tmp/dk ./binaries/docker ./binaries/docker-compose
cp /tmp/dk/binaries/docker /usr/local/bin/; cp /tmp/dk/binaries/docker-compose /usr/libexec/docker/cli-plugins/
python3 /tbin/server.py /www/repo /www/evil /tcerts/server.pem /tcerts/server.key > /tmp/server.err 2>&1 &
# The Store app itself, installed as the NAS does
mkdir -p "$P/_install/store" && tar -xzf $PROJ/packages/store/$(latest store)/store_$(latest store)_amd64.tar.gz -C "$P/_install/store"
sh "$P/_install/store/install.sh" "$P/_install/store" "$P" && sh "$P/store/init.sh" "$P/store" && sh "$P/store/start.sh" "$P/store"
# The Nginx app's files (not started: only its sites are used), with a domain
mkdir -p "$P/_install/nginx" && tar -xzf $PROJ/packages/nginx/$(latest nginx)/nginx_$(latest nginx)_amd64.tar.gz -C "$P/_install/nginx"
sh "$P/_install/nginx/install.sh" "$P/_install/nginx" "$P" >/dev/null 2>&1; sh "$P/nginx/init.sh" "$P/nginx" >/dev/null 2>&1
php -r '$f=$argv[1]; $s=json_decode(@file_get_contents($f),true) ?: []; $s["domain"]="nas.example.test"; file_put_contents($f, json_encode($s));' "$P/_nginx/apps.json"
echo "administrators:x:1001:admin" >> /etc/group; printf 'username|s:5:"admin";' > /tmp/sess/sess_adminsession123
php -d session.save_path=/tmp/sess -S 127.0.0.1:8080 -t /var/www > /tmp/php.log 2>&1 &
sleep 1
B=http://127.0.0.1:8080/apps/store; ADMIN='Cookie: PHPSESSID=adminsession123'
req() { curl -s -o /tmp/body -w '%{http_code}' -H 'X-Requested-With: XMLHttpRequest' "$@"; }
j() { php -r '$d=json_decode(file_get_contents("/tmp/body"),true); echo json_encode(eval("return $argv[1];"), JSON_UNESCAPED_SLASHES);' "$1"; }
req -H "$ADMIN" $B/index.php >/dev/null; C=$(sed -n 's/.*var csrf = "\([0-9a-f]*\)".*/\1/p' /tmp/body)
post() { a=$1; shift; req -H "$ADMIN" -H "X-CSRF-Token: $C" -X POST "$@" "$B/api.php?action=$a"; }
get() { req -H "$ADMIN" "$B/api.php?action=$1$2"; }
# Waits for the running job, then prints its state and message
# (the job starts in the background: until its status is written, the previous job's is read - so a new job id is waited
# for first, for up to 30 seconds)
job_wait() {
	for i in $(seq 1 900); do
		get job >/dev/null
		JOB_ID=$(j '$d["job"]["id"] ?? ""')
		[ "$JOB_ID" = "${LAST_JOB_ID:-}" ] && [ "$i" -le 30 ] && { sleep 1; continue; }
		[ "$(j '$d["job"]["state"] ?? ""')" != '"running"' ] && break; sleep 1
	done
	LAST_JOB_ID=$JOB_ID; JOB_STATE=$(j '$d["job"]["state"]'); JOB_MSG=$(j '$d["job"]["message"]')
}
