#!/bin/sh
# Dumps the WordPress database into /backups and removes the old dumps.
set -eu

BACKUP_DIR="/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
TARGET="${BACKUP_DIR}/${MYSQL_DATABASE}-${STAMP}.sql.gz"

MYSQL_PASSWORD="$(tr -d '\r\n' < /run/secrets/db_password)"

mkdir -p "$BACKUP_DIR"

echo "[backup] dumping ${MYSQL_DATABASE} from ${MYSQL_HOST} -> ${TARGET}"
mariadb-dump \
	-h "$MYSQL_HOST" \
	-P "${MYSQL_PORT:-3306}" \
	-u "$MYSQL_USER" \
	-p"$MYSQL_PASSWORD" \
	--single-transaction \
	--quick \
	--routines \
	--events \
	"$MYSQL_DATABASE" | gzip -9 > "$TARGET"

echo "[backup] done: $(du -h "$TARGET" | cut -f1)"

# Rotation
find "$BACKUP_DIR" -name "${MYSQL_DATABASE}-*.sql.gz" -type f \
	-mtime "+${BACKUP_RETENTION_DAYS:-7}" -delete
echo "[backup] dumps kept: $(find "$BACKUP_DIR" -name '*.sql.gz' | wc -l)"
