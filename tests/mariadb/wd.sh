#!/bin/sh
# Sets the stand-in out as the NAS has its MariaDB 10.5 (none of WD's own files - stand-ins for them): its server at
# /usr/local/modules/mysql/libexec/mariadbd behind /usr/libexec/mariadbd, WD's startup-mysql (mysqld_safe as root, on the
# data folder on the small HD_a4 partition), an /etc/my.cnf with only WD's bind-address, the socket where WD's build has
# it, root without a password - and some data of the user's own
DATADIR=/mnt/HD_a4/.@database@
mkdir -p /usr/local/modules/mysql/libexec /usr/local/modules/etc /usr/libexec /var/lib/mysql /run/lock $DATADIR
cp /usr/sbin/mariadbd /usr/local/modules/mysql/libexec/mariadbd
ln -sf /usr/local/modules/mysql/libexec/mariadbd /usr/libexec/mariadbd
rm -rf /etc/mysql
# (the [mariadb-10.5] socket only for the stand-in: WD's 10.5 has it built in)
printf '[mysqld]\nbind-address=127.0.0.1\n[mariadb-10.5]\nsocket=/var/lib/mysql/mysql.sock\n' > /etc/my.cnf
cp /etc/my.cnf /usr/local/modules/etc/my.cnf
cat > /usr/bin/startup-mysql <<EOF2
#!/bin/sh
exec /usr/bin/mysqld_safe --user=root --basedir=/usr/share/mysql --ledir=/usr/libexec --mysqld=mariadbd --datadir=$DATADIR
EOF2
chmod 755 /usr/bin/startup-mysql
mariadb-install-db --user=root --datadir=$DATADIR --auth-root-authentication-method=normal --skip-test-db > /tmp/wd-install-db.log 2>&1
startup-mysql > /dev/null 2>&1 &
i=0; until mysql --socket=/var/lib/mysql/mysql.sock -uroot -e 'SELECT 1' > /dev/null 2>&1 || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
mysql --socket=/var/lib/mysql/mysql.sock -uroot -e "CREATE DATABASE family; CREATE TABLE family.recipes (name varchar(50)) DEFAULT CHARSET utf8mb4; INSERT INTO family.recipes VALUES ('Crème brûlée')"
