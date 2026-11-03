# The page, for looking at in a browser: a Store with a few things installed, kept running for 10 minutes -
# http://127.0.0.1:8080/wrap.html (stands in for the NAS dashboard;
# ?view=app|update|wizard|installed|settings|repos|activity opens a view)
. /tbin/setup.sh
cp /tbin/wrap.html /var/www/wrap.html
REPO=https://repo.test:8443/store.json; EVIL2=https://evil.test:8443/two/store.json
post add_repo -d url=$REPO -d confirm=1 >/dev/null; post add_repo -d url=$EVIL2 -d confirm=1 >/dev/null
mkdir -p $P/docker; printf 'Package:\t\t\tdocker\nVersion:\t\t\t29.9.1\nAddonShowName:\t\tDocker\n' > $P/docker/apkg.rc; sh /tbin/apkg_xml.sh
post start -d job=app_install -d repo=$REPO -d id=plain >/dev/null; job_wait
post start -d job=app_install -d repo=$REPO -d id=keeper >/dev/null; job_wait
python3 /tbin/repotool.py set-app /www/repo keeper version '"3.14.10"'; post refresh >/dev/null
mkdir -p $V/Public/photos1
post start -d job=recipe_install -d repo=$REPO -d id=hello --data-urlencode 'answers={"SITE_FOLDER":"'$V'/Public/hello-site","EXTRA":["'$V'/Public/photos1"],"GREETING":"Hi","LOUD":false,"COLOUR":"blue","TZ":"Europe/London","ADMIN_PASSWORD":"secret-pass-1"}' >/dev/null; job_wait
echo "ready: $JOB_MSG - http://127.0.0.1:8080/wrap.html"; touch /www/.ready
sleep 600
docker rm -f storehello-web-1 >/dev/null 2>&1
