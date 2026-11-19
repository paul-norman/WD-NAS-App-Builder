# The real Chrome Browser recipe through the Store: nothing but Docker needed (the changedetection.io app optional), then
# installed - Chrome answering on its DevTools port on the NAS itself only, and the app told to use it (its post_install
# hook; a stand-in for the app's control script); a page that needs JavaScript loaded through it by changedetection.io's
# own fetcher (from the app's package: Patchright), rendered, not shown as automated (navigator.webdriver, a headless
# user agent), a screenshot; removal (the app told first: its pre_uninstall hook)
. /tbin/setup.sh
REPO=https://repo.test:8443/store.json
post remove_repo -d url="$(php -r 'require $argv[1]; echo STORE_DEFAULT_REPO;' $P/store/lib/store.php)" >/dev/null; post add_repo -d url=$REPO -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
python3 /tbin/repotool.py add-recipe /www/repo $PROJ/recipes/chrome-browser; post refresh >/dev/null
D=$P/_chrome-browser
CDP=http://127.0.0.1:9222
# changedetection.io's own Python, with its fetcher and Patchright (from the app's package)
mkdir -p /tmp/cd && tar -xzf $PROJ/packages/changedetection/$(latest changedetection)/changedetection_$(latest changedetection)_amd64.tar.gz -C /tmp/cd ./binaries/python
PY=/tmp/cd/binaries/python/bin/python3

echo '== needs only Docker'
get details "&kind=recipes&repo=$REPO&id=chrome-browser" >/dev/null
[ "$(j '$d["problems"]')" = '[]' ] && pass 'installable without the changedetection.io app' || fail "requirements: $(j '$d["problems"]')"
# A stand-in for the app: its control script records what it's asked (and keeps the browser setting, as the app does)
mkdir -p $P/changedetection $P/_changedetection
printf 'Package:\t\t\tchangedetection\nVersion:\t\t\t0.70.3\nAddonShowName:\t\tchangedetection.io\n' > $P/changedetection/apkg.rc; sh /tbin/apkg_xml.sh
cat > $P/changedetection/changedetection_ctl.sh <<EOF
echo "\$*" >> /tmp/ctl.log
[ "\$*" = 'browser on' ] && echo 'BROWSER_URL=http://127.0.0.1:9222' > $P/_changedetection/settings
[ "\$*" = 'browser off' ] && echo 'BROWSER_URL=' > $P/_changedetection/settings
exit 0
EOF
get details "&kind=recipes&repo=$REPO&id=chrome-browser" >/dev/null
echo "  problems: $(j '$d["problems"]')"

echo '== installed'
post start -d job=recipe_install -d repo=$REPO -d id=chrome-browser --data-urlencode 'answers={"TZ":"Europe/London"}' >/dev/null; START=$(cat /tmp/body); job_wait
[ "$JOB_STATE" = '"done"' ] && pass "installed through the Store: $JOB_MSG" || { fail "install: $JOB_STATE $JOB_MSG $START"; get job >/dev/null; j '$d["log"]' | tr '\\' '\n' | tail -30; }
V=$(curl -s -m 5 $CDP/json/version)
echo "  $(docker inspect -f '{{.State.Status}} {{.HostConfig.NetworkMode}} {{.HostConfig.Memory}}' chrome-browser 2>&1)"
echo "$V" | grep -q '"Browser": *"Chrome/156\.' && [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' chrome-browser)" = host ] \
    && pass "Chrome answering on its DevTools port: $(echo "$V" | sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')" || fail "chrome: $V $(docker logs chrome-browser 2>&1 | tail -n 10)"
awk 'NR > 1 && $4 == "0A" && index($2, ":240E") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:' \
    && fail "its DevTools port is on the network: $(awk 'NR > 1 && index($2, ":240E")' /proc/net/tcp /proc/net/tcp6)" || pass 'its DevTools port on the NAS itself only (127.0.0.1:9222)'
grep -qx 'browser on' /tmp/ctl.log 2>/dev/null && grep -qx 'BROWSER_URL=http://127.0.0.1:9222' $P/_changedetection/settings \
    && pass 'the app told to use it (its post_install hook)' || fail "hook: $(cat /tmp/ctl.log 2>&1)"
[ "$(docker inspect -f '{{.HostConfig.Memory}}' chrome-browser)" = 1073741824 ] && pass 'its memory capped at 1GB' || fail 'memory'

echo '== a page through it, as changedetection.io loads it'
mkdir -p /tmp/www && cat > /tmp/www/page.html <<'EOF'
<html><head><title>Test page</title></head><body><p id="out">not rendered</p>
<script>
setTimeout(function () {
    document.getElementById('out').textContent = 'rendered by javascript; webdriver=' + navigator.webdriver +
        '; agent=' + navigator.userAgent;
}, 500);
</script></body></html>
EOF
(cd /tmp/www && exec python3 -m http.server 8996 --bind 127.0.0.1 > /tmp/www.log 2>&1 &)
sleep 1
OUT=$(PLAYWRIGHT_DRIVER_URL=$CDP ALLOW_IANA_RESTRICTED_ADDRESSES=true WEBDRIVER_DELAY_BEFORE_CONTENT_READY=3 $PY - http://127.0.0.1:8996/page.html <<'EOF' 2>/tmp/fetch.err
import asyncio
import sys

from changedetectionio.content_fetchers.playwright import fetcher


async def main():
    """
    Loads the page with changedetection.io's own browser fetcher, and prints
    what it got.
    """
    page = fetcher()
    await page.run(
        url=sys.argv[1], timeout=60, request_headers={},
        fetch_favicon=False, screenshot_format="JPEG",
    )
    print(f"status={page.status_code}")
    print(f"screenshot={len(page.screenshot or b'')}")
    print(page.content)


asyncio.run(main())
EOF
)
echo "$OUT" | grep -q 'status=200' && echo "$OUT" | grep -q 'rendered by javascript' && pass 'the page loaded through it by changedetection.io'"'"'s fetcher (Patchright): its JavaScript run' \
    || fail "fetch: $(echo "$OUT" | head -c 300) $(tail -n 15 /tmp/fetch.err)"
echo "$OUT" | grep -q 'webdriver=false' && ! echo "$OUT" | grep -q 'HeadlessChrome' \
    && pass 'not shown as automated: navigator.webdriver false, not a headless agent' || fail "detected: $(echo "$OUT" | grep -o 'webdriver=[^<]*')"
[ "$(echo "$OUT" | sed -n 's/^screenshot=//p')" -gt 1000 ] 2>/dev/null && pass "a screenshot ($(echo "$OUT" | sed -n 's/^screenshot=//p') bytes)" || fail "screenshot: $(echo "$OUT" | head -n 2)"

echo '== removed'
post start -d job=recipe_uninstall -d id=chrome-browser -d delete_data=1 --data-urlencode 'delete=[]' >/dev/null; job_wait
[ "$JOB_STATE" = '"done"' ] && [ -z "$(docker ps -aq --filter name=^chrome-browser$)" ] && grep -qx 'browser off' /tmp/ctl.log \
    && grep -qx 'BROWSER_URL=' $P/_changedetection/settings && pass "removed, the app told first (its pre_uninstall hook): $JOB_MSG" || fail "uninstall: $JOB_STATE $JOB_MSG $(cat /tmp/ctl.log)"
true
