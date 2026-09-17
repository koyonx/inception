#!/bin/sh
# =============================================================================
#  MariaDB entrypoint
#  - initialises the data directory on the very first run
#  - creates the WordPress database and its user from the docker secrets
#  - then replaces itself with mariadbd, which becomes PID 1 (no tail -f,
#    no sleep infinity, no while true)
# =============================================================================
set -eu

DATADIR="/var/lib/mysql"

log() { echo "[mariadb-entrypoint] $*"; }

read_secret() {
	if [ ! -r "$1" ]; then
		echo "[mariadb-entrypoint] FATAL: missing secret $1" >&2
		exit 1
	fi
	# strip a possible trailing newline
	tr -d '\r\n' < "$1"
}

MYSQL_ROOT_PASSWORD="$(read_secret /run/secrets/db_root_password)"
MYSQL_PASSWORD="$(read_secret /run/secrets/db_password)"

: "${MYSQL_DATABASE:?MYSQL_DATABASE is not set}"
: "${MYSQL_USER:?MYSQL_USER is not set}"

mkdir -p /run/mysqld
chown -R mysql:mysql /run/mysqld "$DATADIR"

if [ ! -d "$DATADIR/mysql" ]; then
	log "empty data directory: installing the system tables"
	mariadb-install-db --user=mysql --datadir="$DATADIR" --skip-test-db \
		--auth-root-authentication-method=normal > /dev/null

	log "bootstrapping database '${MYSQL_DATABASE}' and user '${MYSQL_USER}'"
	# --bootstrap runs the SQL in a single-shot server, then exits.
	# No background daemon is ever started here.
	mariadbd --user=mysql --bootstrap <<-EOSQL
		USE mysql;
		FLUSH PRIVILEGES;

		ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';

		-- mariadb-install-db also creates root@127.0.0.1, root@::1 and
		-- root@<hostname> with NO password at all. Keep only root@localhost,
		-- which is reachable through the unix socket and now has a password.
		DELETE FROM mysql.global_priv WHERE User='root' AND Host<>'localhost';

		-- Anonymous users and the test database are entry points we do not want.
		DELETE FROM mysql.global_priv WHERE User='';
		DROP DATABASE IF EXISTS test;

		CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`
			CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

		CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
		GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%';

		FLUSH PRIVILEGES;
	EOSQL
	log "initialisation done"
else
	log "existing data directory found, skipping initialisation"
fi

log "starting mariadbd as PID 1"
exec "$@" --user=mysql
