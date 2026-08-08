#!/bin/sh
# Drops root, then hands over to the PHP built-in server (PID 1).
set -eu

echo "[adminer-entrypoint] serving Adminer on :8080 (database host: ${MYSQL_HOST:-mariadb})"
exec setpriv --reuid=www-data --regid=www-data --init-groups "$@"
