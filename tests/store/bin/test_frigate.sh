# The real Frigate recipe through the Store (a copy without the GPU and USB devices, with a lower disk requirement, made
# by run_tests.sh): its first settings, the admin password from the wizard, the Nginx site, a test camera detected on
# the CPU, then a change of settings to the recipe's remote detector server (run here, on the CPU) - asked which model
# it runs, and used by Frigate over the network - and removal, keeping the recordings
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
IMAGE=ghcr.io/blakeblackshear/frigate:0.18.2
post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.3\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
mkdir -p $V/Cameras
python3 /tbin/repotool.py add-recipe /www/repo /tfix/frigate-small; post refresh >/dev/null
D=$P/_frigate; R=$V/Cameras/Frigate; F=http://127.0.0.1:8971
get details "&kind=recipes&repo=$REPO&id=frigate" >/dev/null
echo "  problems: $(j '$d["problems"]')"; echo "  wizard: $(j 'implode(", ", array_map(function($f){return $f["key"].(empty($f["advanced"])?"":"(adv)")."=".json_encode($f["value"]);}, $d["wizard"]))' | cut -c1-400)"
ANS='{"RECORDINGS":"'$R'","DETECTOR":"cpu","REMOTE_DETECTOR":"","ADMIN_PASSWORD":"Test-pass-123","TZ":"Europe/London","FRIGATE_VERSION":"0.18.2"}'
post start -d job=recipe_install -d repo=$REPO -d id=frigate --data-urlencode "answers=$ANS" >/dev/null; job_wait
get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | grep -E "^n?(Ports|Wrote|Object|Restarting|Setting|Frigate's)" | sed 's/^n//; s/^/  /' | cut -c1-160
[ "$JOB_STATE" = '"done"' ] && pass "Frigate installed through the Store: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG"; j '$d["log"]' | tr '\\' '\n' | tail -30; }

echo '== its settings and password'
[ "$(stat -c %a $D/.env)" = 600 ] && grep -q '^ADMIN_PASSWORD=Test-pass-123' $D/.env && [ "$(stat -c %a $D/config/config.yml)" = 600 ] \
    && pass "its .env and settings root's only; recordings in $R" || fail "files: $(ls -la $D $D/config)"
grep -q '^  enabled: false' $D/config/config.yml && grep -q '^tls:' $D/config/config.yml && grep -q '^    type: cpu' $D/config/config.yml \
    && pass 'first settings: TLS off (the Nginx app does HTTPS), the CPU detector' || fail "config: $(cat $D/config/config.yml)"
# Logs in to Frigate's API (cookie in /tmp/fc), printing the HTTP code - $1 the password
login() { curl -s -o /dev/null -w '%{http_code}' -c /tmp/fc -H 'Content-Type: application/json' -d '{"user":"admin","password":"'"$1"'"}' $F/api/login; }

for i in $(seq 1 60); do [ "$(login Test-pass-123)" = 200 ] && break; sleep 5; done
[ "$(login Test-pass-123)" = 200 ] && [ "$(login wrong-pass-1)" = 401 ] && login Test-pass-123 >/dev/null \
    && pass "admin logs in with the wizard's password, not another (port 8971)" || fail "login: $(login Test-pass-123) $(docker logs frigate 2>&1 | tail -n 5)"
[ "$(curl -s -o /dev/null -w '%{http_code}' $F/api/stats)" = 401 ] && pass 'its API needs the login' || fail 'unauthenticated api'
SITE=$P/_nginx/sites/60-app-cameras.conf
grep -q 'proxy_pass       http://127.0.0.1:8971' $SITE 2>/dev/null && pass 'Nginx cameras site' || fail "nginx: $(ls $P/_nginx/sites 2>&1)"

echo '== a test camera (a looping video), detected on the CPU'
docker exec frigate /usr/lib/ffmpeg/7.0/bin/ffmpeg -v error -f lavfi -i testsrc2=size=640x360:rate=5 -t 20 -c:v libx264 -pix_fmt yuv420p -y /media/frigate/test.mp4
docker exec frigate python3 -c '
from ruamel.yaml import YAML
y = YAML(); y.indent(mapping=2, sequence=4, offset=2)
c = y.load(open("/config/config.yml"))
c["cameras"] = {"test": {"ffmpeg": {"hwaccel_args": [], "inputs": [{"path": "/media/frigate/test.mp4", "input_args": "-re -stream_loop -1 -fflags +genpts", "roles": ["detect"]}]}, "detect": {"width": 640, "height": 360, "fps": 5}}}
y.dump(c, open("/config/config.yml", "w"))'
docker restart frigate >/dev/null
# Frigate's statistics (logged in): $1 a PHP expression on them ($d)
stats() { curl -s -b /tmp/fc $F/api/stats > /tmp/stats; php -r '$d=json_decode(file_get_contents("/tmp/stats"),true); echo json_encode(eval("return $argv[1];"));' "$1"; }
# Waits (up to 3 minutes) until detector $1 has measured its speed, then prints it
detector_speed() {
    for i in $(seq 1 36); do
        login Test-pass-123 >/dev/null; speed=$(stats '$d["detectors"]["'$1'"]["inference_speed"] ?? 0')
        [ "$speed" != 0 ] && [ "$speed" != '0.0' ] && [ "$speed" != 'null' ] && break; sleep 5
    done
    echo "$speed"
}
SPEED=$(detector_speed cpu)
[ "$SPEED" != 0 ] && [ -n "$SPEED" ] && pass "test camera at $(stats '$d["cameras"]["test"]["camera_fps"] ?? null') fps, detected on the CPU ($SPEED ms each)" || fail "cpu detection: $(head -c 600 /tmp/stats) $(docker logs frigate 2>&1 | tail -n 8)"

echo '== changed to a remote detector (the recipe server, here on the CPU)'
docker rm -f frigate-detector-test >/dev/null 2>&1
docker run -d --name frigate-detector-test -p 15555:5555 -e DETECTOR=cpu -w /opt/frigate --entrypoint python3 \
    -v $PROJ/recipes/frigate/remote-detector/detector_server.py:/server/detector_server.py:ro $IMAGE -u /server/detector_server.py >/dev/null
HOST=$(python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("1.1.1.1", 53)); print(s.getsockname()[0])')
sleep 5
CHG='{"RECORDINGS":"'$R'","DETECTOR":"remote","REMOTE_DETECTOR":"'$HOST':15999","TZ":"Europe/London","FRIGATE_VERSION":"0.18.2"}'
post start -d job=recipe_change -d id=frigate --data-urlencode "answers=$CHG" >/dev/null; job_wait
get job >/dev/null; j '$d["log"]' | grep -q "didn't answer" && grep -q '^    type: cpu' $D/config/config.yml \
    && pass "a detector that doesn't answer (port 15999): said so, settings left as they were ($JOB_STATE)" || fail "no answer: $JOB_STATE $(j '$d["log"]' | tr '\\' '\n' | tail -8)"
CHG='{"RECORDINGS":"'$R'","DETECTOR":"remote","REMOTE_DETECTOR":"'$HOST':15555","TZ":"Europe/London","FRIGATE_VERSION":"0.18.2"}'
post start -d job=recipe_change -d id=frigate --data-urlencode "answers=$CHG" >/dev/null; job_wait
get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | grep -E '^n?(The remote|Object|Restarting|Note)' | sed 's/^n//; s/^/  /' | cut -c1-160
[ "$JOB_STATE" = '"done"' ] && grep -q "endpoint: tcp://$HOST:15555" $D/config/config.yml && grep -q '^    type: zmq' $D/config/config.yml \
    && grep -q '^  path: /cpu_model.tflite' $D/config/config.yml && docker logs frigate-detector-test 2>&1 | grep -q 'Described the model' \
    && pass "remote detector asked for its model, written to Frigate's settings: $JOB_MSG" || fail "remote: $JOB_STATE $JOB_MSG $(sed -n '/^detectors/,$p' $D/config/config.yml)"
SPEED=$(detector_speed remote)
[ "$SPEED" != 0 ] && [ -n "$SPEED" ] && pass "the test camera detected over the network by the remote detector ($SPEED ms each)" || fail "remote detection: $(head -c 600 /tmp/stats) $(docker logs frigate 2>&1 | grep -i zmq | tail -n 5)"
docker rm -f frigate-detector-test >/dev/null

echo '== removed'
post start -d job=recipe_uninstall -d id=frigate -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ ! -d $D ] && [ -f $R/test.mp4 ] && [ -z "$(docker ps -aq --filter name=^frigate$)" ] \
    && pass "removed; the recordings folder kept: $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG"
true
