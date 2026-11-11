#!/bin/sh
# MongoDB from its package (tests/common/nas.sh): its first start as its own user, only on the NAS itself, logins always
# needed, its administrator made with the page's password, a JavaScript query ($where - its JavaScript engine, built
# without AVX2), a database with a login of its own (no rights elsewhere), a new password, backups and a restore, the
# network and memory settings, a restart keeping its data, removal
. /t/common/nas.sh mongodb
BIN=$P/mongodb/binaries/bin
# mongosh against it: as nobody (no login), or as a user in its database (then the script's db) - the password in its
# environment: sh_as <user> <password> <db> <script>, sh_anon <script>
sh_as() { (MONGO_PW="$2" HOME=/tmp $BIN/mongosh --quiet --norc --port 27017 --eval "db = db.getSiblingDB('$3'); db.auth('$1', process.env.MONGO_PW); $4" 2>&1); }
sh_anon() { (HOME=/tmp $BIN/mongosh --quiet --norc --port 27017 --eval "$1" 2>&1); }
listens_beyond() { awk 'NR > 1 && $4 == "0A" && index($2, ":6989") { print $2 }' /proc/net/tcp /proc/net/tcp6 | grep -qv '^0100007F:'; }

echo '== first start'
install_app
wait_port 27017 120 && pass 'answering on 27017' || { fail "not answering: $(tail -n 10 /tmp/start.log; tail -n 10 /tmp/debug_apkg; tail -n 5 $D/log/console.log; tail -n 6 $D/log/mongod.log | cut -c1-400)"; exit 1; }
i=0; until [ -s $D/password ] || [ $i -ge 60 ]; do sleep 2; i=$((i + 2)); done
PID=$(cat /var/run/mongodb.pid)
[ "$(awk '/^Uid:/ { print $2 }' /proc/$PID/status)" = 67 ] && pass 'runs as its own user (67)' || fail "user: $(awk '/^Uid:/' /proc/$PID/status)"
listens_beyond && fail 'listens beyond the NAS' || pass 'listens only on the NAS itself (127.0.0.1)'
[ "$(stat -c %A /dev/urandom | cut -c 8)" = r ] && [ "$(stat -c %A /dev/random | cut -c 8)" = r ] \
    && pass "the system's random numbers readable by its user (WD lets only root read them; MongoDB stops without them)" || fail "random: $(ls -l /dev/urandom /dev/random)"
[ "$(stat -c '%U %G %a' $D/conf/mongod.conf)" = 'root mongodb 640' ] && [ "$(stat -c '%U %a' $D/db)" = 'mongodb 700' ] && [ "$(stat -c '%u %a' $D/password)" = '0 600' ] \
    && grep -q 'authorization: enabled' $D/conf/mongod.conf && grep -q 'cacheSizeGB: 0.50' $D/conf/mongod.conf \
    && pass "its configuration root's (its group reads it: logins required, a 512MB cache), its data its own, its password root's" \
    || fail "files: $(stat -c '%n %U %G %a' $D/conf/mongod.conf $D/db $D/password)"
$BIN/mongod --version | grep -q 'db version v8.0.38' && ldd $BIN/mongod | grep -q "mongodb/binaries/bin/../lib/libssl.so.3" \
    && pass "MongoDB $($BIN/mongod --version | sed -n 's/^db version v//p'), with its own OpenSSL 3" || fail "version: $($BIN/mongod --version | head -n 3) $(ldd $BIN/mongod)"

echo '== logins'
PW=$(cat $D/password)
R=$(sh_anon 'print(JSON.stringify(db.adminCommand({ listDatabases: 1 })))')
echo "$R" | grep -qi 'requires authentication\|Unauthorized' && pass 'nothing without a login' || fail "no login: $R"
R=$(sh_as admin "$PW" admin 'print(db.adminCommand({ listDatabases: 1 }).ok)')
[ "$R" = 1 ] && pass "its administrator (admin) logs in with the app's password" || fail "admin: $R"
# (the suite's seccomp profile hides rseq, as the NAS's kernel lacks it: MongoDB refuses to start on newer kernels when its
# allocator uses rseq - tests/common/seccomp-no-rseq.json)
R=$(sh_as admin "$PW" admin 'print(db.serverStatus({ tcmalloc: 1 }).tcmalloc.usingPerCPUCaches)')
[ "$R" = false ] && pass "its allocator without per-CPU caches, as on the NAS (no rseq)" || fail "per-CPU caches: $R"
R=$(sh_as admin wrong-password-1 admin 'print("x")')
echo "$R" | grep -qi 'Authentication failed' && pass 'a wrong password refused' || fail "wrong password: $R"
R=$(sh_as admin "$PW" admin "const t = db.getSiblingDB('family').recipes; t.insertMany([{ name: 'Soup', mins: 30 }, { name: 'Cake', mins: 75 }, { name: 'Tea', mins: 5 }]);
    print(t.countDocuments({ mins: { \$lt: 60 } }) + ' ' + t.find({ \$where: 'this.mins % 5 == 0 && this.name.length == 4' }).count())")
[ "$R" = '2 2' ] && pass "documents stored and queried - also in JavaScript (\$where, its JavaScript engine): $R" || fail "queries: $R"
tr '\0' ' ' < /proc/$PID/cmdline | grep -q "$PW" && fail 'its password on its command line' || pass 'no password on its command line'

echo '== its page'
page_up mongodb
ST=$(get status)
[ "$(echo "$ST" | j '$d["answering"]')" = true ] && [ "$(echo "$ST" | j '$d["version"]')" = '"8.0.38"' ] && echo "$ST" | j '$d["databases"]' | grep -q '"family"' \
    && pass "the page: MongoDB 8.0.38 answering, its databases (family among them)" || fail "status: $(echo "$ST" | head -c 400)"
[ "$(post password | j '$d["password"]')" = "\"$PW\"" ] && pass 'the page shows the password' || fail 'password not shown'
R=$(post set_password -d password=Brand.New-Password_1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ "$(sh_as admin Brand.New-Password_1 admin 'print(db.runCommand({ connectionStatus: 1 }).authInfo.authenticatedUsers.length)')" = 1 ] \
    && sh_as admin "$PW" admin 'print(1)' | grep -qi 'Authentication failed' && pass 'a new password from the page: in use at once, the old one refused' || fail "new password: $R"
PW=Brand.New-Password_1
R=$(post create_db -d name=myapp); U=$(echo "$R" | j '$d["user"]' | tr -d '"'); UP=$(echo "$R" | j '$d["password"]' | tr -d '"')
W=$(sh_as myapp "$UP" myapp "db.notes.insertOne({ text: 'hello' }); print(db.notes.countDocuments())")
O=$(sh_as myapp "$UP" myapp "print(db.getSiblingDB('family').recipes.countDocuments())")
[ "$U" = myapp ] && [ "$W" = 1 ] && echo "$O" | grep -qi 'not authorized\|Unauthorized' \
    && pass "a database with a login of its own (myapp): it writes there, and can't read other databases" || fail "create_db: $R / $W / $O"
R=$(post create_db -d name=admin)
[ "$(echo "$R" | j '$d["ok"]')" = false ] && pass 'admin refused as a database of your own' || fail "admin db: $R"

echo '== backups'
R=$(post backup_now)
F=$(ls $D/backups/mongodb-*.archive.gz 2>/dev/null | head -n 1)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && [ -s "$F" ] && [ "$(stat -c '%u %a' "$F")" = '0 600' ] \
    && pass "a backup from the page (mongodump, root's only): $(basename "$F")" || fail "backup: $R $(ls -l $D/backups 2>&1) $(tail -n 3 /tmp/debug_apkg)"
sh_as admin "$PW" admin "db.getSiblingDB('family').dropDatabase()" > /dev/null
printf 'password: "%s"\n' "$PW" > /tmp/restore.yml
$BIN/mongorestore --config /tmp/restore.yml --host 127.0.0.1 --username admin --authenticationDatabase admin --gzip --archive="$F" > /tmp/restore.log 2>&1
[ "$(sh_as admin "$PW" admin "print(db.getSiblingDB('family').recipes.countDocuments())")" = 3 ] \
    && pass 'a dropped database restored from it (mongorestore, as the README says)' || fail "restore: $(tail -n 3 /tmp/restore.log)"
mkdir -p $V/Public/MongoBackups
post backup_settings -d dir=$V/Public/MongoBackups -d keep=2 > /dev/null
for i in 1 2 3; do sh $P/mongodb/mongodb_ctl.sh backup > /dev/null 2>&1; sleep 1; done
[ "$(ls $V/Public/MongoBackups/mongodb-*.archive.gz 2>/dev/null | wc -l)" = 2 ] && pass 'backups in the folder chosen, the newest 2 kept' || fail "kept: $(ls $V/Public/MongoBackups)"

echo '== settings'
R=$(post settings -d listen=all -d cache_mb=256)
[ "$(echo "$R" | j '$d["ok"]')" = true ] && listens_beyond && grep -q 'cacheSizeGB: 0.25' $D/conf/mongod.conf \
    && [ "$(sh_as admin "$PW" admin "print(db.getSiblingDB('family').recipes.countDocuments())")" = 3 ] \
    && pass 'on the network too (0.0.0.0:27017), a 256MB cache: restarted, its data kept' || fail "settings: $R"
post settings -d listen=local -d cache_mb=512 > /dev/null
! listens_beyond && pass 'and back to the NAS only' || fail 'listen local'

echo '== removal'
finish_app
! grep -q mongodb- /var/spool/cron/crontabs/root && [ -d $D/db ] && [ ! -f /var/run/mongodb.pid ] && pass 'its cron lines gone, stopped, its data kept' || fail 'left behind'
