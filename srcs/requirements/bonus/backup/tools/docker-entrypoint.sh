#!/bin/sh
# =============================================================================
#  Backup entrypoint
#  Installs the crontab (cron does not inherit the container environment, so
#  the variables are written into the job), runs one dump immediately so the
#  service is verifiable right away, then `exec cron -f` (PID 1).
# =============================================================================
set -eu

: "${MYSQL_HOST:?}" "${MYSQL_DATABASE:?}" "${MYSQL_USER:?}"

HOUR="${BACKUP_SCHEDULE_HOUR:-3}"

log() { echo "[backup-entrypoint] $*"; }

cat > /etc/cron.d/inception-backup <<-EOF
	MYSQL_HOST=${MYSQL_HOST}
	MYSQL_PORT=${MYSQL_PORT:-3306}
	MYSQL_DATABASE=${MYSQL_DATABASE}
	MYSQL_USER=${MYSQL_USER}
	BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
	0 ${HOUR} * * * root /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1
EOF
chmod 0644 /etc/cron.d/inception-backup

log "first dump on start-up"
/usr/local/bin/backup.sh || log "WARNING: the initial dump failed"

log "cron scheduled every day at ${HOUR}:00"
exec "$@"
