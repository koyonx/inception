#!/bin/sh
# =============================================================================
#  WordPress entrypoint
#  - waits (with a bounded number of attempts, never an infinite loop) for
#    MariaDB to accept connections
#  - downloads, configures and installs WordPress on the first run
#  - creates the two required users (an administrator + a regular one)
#  - enables the redis object cache when the bonus is on
#  - then `exec php-fpm -F` => php-fpm is PID 1
# =============================================================================
set -eu

WP_PATH="/var/www/html"
MAX_TRIES=30

log() { echo "[wordpress-entrypoint] $*"; }

read_secret() {
	if [ ! -r "$1" ]; then
		echo "[wordpress-entrypoint] FATAL: missing secret $1" >&2
		exit 1
	fi
	tr -d '\r\n' < "$1"
}

wp_run() { wp --path="$WP_PATH" --allow-root "$@"; }

# ---- credentials ------------------------------------------------------------
MYSQL_PASSWORD="$(read_secret /run/secrets/db_password)"

# credentials contains WP_ADMIN_PASSWORD=... and WP_USER_PASSWORD=...
# shellcheck disable=SC1091
. /run/secrets/credentials

: "${MYSQL_HOST:?}" "${MYSQL_DATABASE:?}" "${MYSQL_USER:?}"
: "${DOMAIN_NAME:?}" "${WP_TITLE:?}"
: "${WP_ADMIN_USER:?}" "${WP_ADMIN_EMAIL:?}" "${WP_ADMIN_PASSWORD:?}"
: "${WP_USER:?}" "${WP_USER_EMAIL:?}" "${WP_USER_PASSWORD:?}"

case "$WP_ADMIN_USER" in
	*[Aa]dmin*|*[Aa]dministrator*)
		echo "[wordpress-entrypoint] FATAL: WP_ADMIN_USER must not contain 'admin'" >&2
		exit 1
		;;
esac

# ---- wait for MariaDB (bounded retry, not `while true`) ---------------------
log "waiting for ${MYSQL_HOST}:${MYSQL_PORT:-3306}"
i=1
while [ "$i" -le "$MAX_TRIES" ]; do
	if mariadb -h "$MYSQL_HOST" -P "${MYSQL_PORT:-3306}" \
		-u "$MYSQL_USER" -p"$MYSQL_PASSWORD" \
		-e "SELECT 1" "$MYSQL_DATABASE" > /dev/null 2>&1; then
		log "database is up (attempt $i)"
		break
	fi
	if [ "$i" -eq "$MAX_TRIES" ]; then
		echo "[wordpress-entrypoint] FATAL: database unreachable after $MAX_TRIES attempts" >&2
		exit 1
	fi
	i=$((i + 1))
	sleep 2
done

# ---- install ----------------------------------------------------------------
if [ ! -f "$WP_PATH/wp-config.php" ]; then
	log "downloading WordPress ${WP_VERSION:-latest-release}"
	wp_run core download --version="${WP_VERSION:-6.7.1}" --locale=en_US

	log "writing wp-config.php"
	wp_run config create \
		--dbname="$MYSQL_DATABASE" \
		--dbuser="$MYSQL_USER" \
		--dbpass="$MYSQL_PASSWORD" \
		--dbhost="${MYSQL_HOST}:${MYSQL_PORT:-3306}" \
		--dbcharset="utf8mb4" \
		--dbcollate="utf8mb4_unicode_ci" \
		--skip-check \
		--extra-php <<-'PHP'
			/* Behind the nginx TLS termination */
			if (isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
				&& $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
				$_SERVER['HTTPS'] = 'on';
			}
			/* defined() guards: wp-cli evaluates this block twice */
			defined('FS_METHOD')          or define('FS_METHOD', 'direct');
			defined('DISALLOW_FILE_EDIT') or define('DISALLOW_FILE_EDIT', true);
			defined('WP_REDIS_HOST')      or define('WP_REDIS_HOST', getenv('REDIS_HOST') ?: 'redis');
			defined('WP_REDIS_PORT')      or define('WP_REDIS_PORT', (int) (getenv('REDIS_PORT') ?: 6379));
			defined('WP_CACHE_KEY_SALT')  or define('WP_CACHE_KEY_SALT', getenv('DOMAIN_NAME') ?: 'inception');
		PHP

	log "installing WordPress at https://${DOMAIN_NAME}"
	wp_run core install \
		--url="https://${DOMAIN_NAME}" \
		--title="$WP_TITLE" \
		--admin_user="$WP_ADMIN_USER" \
		--admin_password="$WP_ADMIN_PASSWORD" \
		--admin_email="$WP_ADMIN_EMAIL" \
		--skip-email

	log "creating the second user '${WP_USER}'"
	wp_run user create "$WP_USER" "$WP_USER_EMAIL" \
		--role="${WP_USER_ROLE:-author}" \
		--user_pass="$WP_USER_PASSWORD"

	wp_run option update blogdescription "42 - Inception"
	wp_run rewrite structure '/%postname%/' --hard
else
	log "WordPress is already installed, skipping the setup"
fi

# ---- redis object cache (bonus) --------------------------------------------
if [ "${ENABLE_BONUS:-0}" = "1" ]; then
	if ! wp_run plugin is-installed redis-cache > /dev/null 2>&1; then
		log "installing the redis object cache plugin"
		wp_run plugin install redis-cache --activate || \
			log "WARNING: could not install redis-cache (no network?)"
	fi
	if wp_run plugin is-active redis-cache > /dev/null 2>&1; then
		wp_run redis enable > /dev/null 2>&1 || \
			log "WARNING: could not enable the redis object cache yet"
	fi
fi

chown -R www-data:www-data "$WP_PATH"
mkdir -p /run/php

log "starting php-fpm as PID 1 on 0.0.0.0:9000"
exec "$@"
