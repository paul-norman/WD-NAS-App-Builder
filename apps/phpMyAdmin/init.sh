#!/bin/sh

# Called upon app installation
	#	 1. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 2. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 3. $INSTALL_PATH/start.sh $INSTALL_PATH

# Called upon app reinstallation
	#	 1. $INSTALL_PATH/stop.sh
	#	 2. $INSTALL_PATH/clean.sh
	#	 3. $INSTALL_PATH/preinst.sh $INSTALL_PATH
	#	 4. $INSTALL_PATH/remove.sh $INSTALL_PATH
	#	 5. $UPLOAD_PATH/install.sh $UPLOAD_PATH $INSTALL_PATH
	# -> 6. $INSTALL_PATH/init.sh $INSTALL_PATH
	#	 7. $INSTALL_PATH/start.sh $INSTALL_PATH

# Load all the useful variables
. "$1/helpers.sh" "$0" "$1";

# ----------------------------------------------------------------------
# Initialisation script: prepares app icon, index page and paths
#  - Use this to restore custom paths and settings on reinstall / reboot
# ----------------------------------------------------------------------

# Allow a local login without password
log "updating ${APP_NAME} config file";
PMA_PASSWORD="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)";
SQL_SECRET="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32; echo '')";
mv "${APP_PATH}/binaries/config.sample.inc.php" "${APP_PATH}/binaries/config.inc.php"
sed -i "s/\['blowfish_secret'\] = ''/\['blowfish_secret'\] = \'${SQL_SECRET}\'/g" "${APP_PATH}/binaries/config.inc.php";
sed -i "s/\['host'\] = 'localhost'/\['host'\] = '127.0.0.1'/g" "${APP_PATH}/binaries//config.inc.php";
sed -i "s/\['AllowNoPassword'\] = false/\['AllowNoPassword'\] = true/g" "${APP_PATH}/binaries/config.inc.php";

# Start MySQL (symlink to MariaDB 10.5.19 - 6 Feb 2023) if it isn't already running
log "starting MySQL";
log "deny remote access and restart MySQL service";
python3 /usr/bin/mysql_reset.py -d;
sleep 1

# Create MySQL system users
log "creating MySQL system users";
mysql --user=root --password= -N -e "DROP USER IF EXISTS 'admin'@'localhost';";
mysql --user=root --password= -N -e "CREATE USER 'admin'@'localhost' IDENTIFIED BY 'admin';";
mysql --user=root --password= -N -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, RELOAD, SHUTDOWN, PROCESS, FILE, REFERENCES, INDEX, ALTER, SHOW DATABASES, SUPER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, REPLICATION SLAVE, REPLICATION CLIENT, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, CREATE USER, EVENT, TRIGGER, DELETE HISTORY ON *.* TO 'admin'@'localhost' IDENTIFIED BY 'admin' WITH GRANT OPTION;";
mysql --user=root --password= -N -e "FLUSH PRIVILEGES;";
