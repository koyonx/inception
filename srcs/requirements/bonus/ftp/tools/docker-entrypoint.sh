#!/bin/sh
# =============================================================================
#  vsftpd entrypoint
#  Creates the FTP user from the environment + the docker secret, points its
#  home to the WordPress volume, then `exec vsftpd` (PID 1, foreground).
# =============================================================================
set -eu

: "${FTP_USER:?FTP_USER is not set}"

FTP_PASSWORD="$(tr -d '\r\n' < /run/secrets/ftp_password)"

log() { echo "[ftp-entrypoint] $*"; }

if ! id "$FTP_USER" > /dev/null 2>&1; then
	log "creating the FTP user '${FTP_USER}'"
	useradd -M -d /var/www/html -s /usr/sbin/nologin "$FTP_USER"
fi

echo "${FTP_USER}:${FTP_PASSWORD}" | chpasswd
echo "$FTP_USER" > /etc/vsftpd.userlist

# The FTP user needs to write inside the WordPress volume, which belongs to
# www-data; putting it in that group is enough.
usermod -aG www-data "$FTP_USER"
chmod g+w /var/www/html || true

# Apply the passive settings coming from the .env file. pasv_address is the
# address the *client* must dial back; it is the host running docker, not the
# container, hence 127.0.0.1 when the client is on the VM itself.
sed -i "s/^pasv_min_port=.*/pasv_min_port=${FTP_PASV_MIN:-21000}/" /etc/vsftpd.conf
sed -i "s/^pasv_max_port=.*/pasv_max_port=${FTP_PASV_MAX:-21010}/" /etc/vsftpd.conf
sed -i "s/^pasv_address=.*/pasv_address=${FTP_PASV_ADDRESS:-127.0.0.1}/" /etc/vsftpd.conf

log "starting vsftpd in the foreground (user: ${FTP_USER}, root: /var/www/html)"
exec "$@"
