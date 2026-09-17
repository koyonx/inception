#!/bin/sh
# =============================================================================
#  NGINX entrypoint
#  - generates the self-signed TLS certificate for ${DOMAIN_NAME}
#  - renders the vhost template
#  - then `exec nginx -g "daemon off;"` => nginx is PID 1
# =============================================================================
set -eu

: "${DOMAIN_NAME:?DOMAIN_NAME is not set}"

SSL_DIR="/etc/nginx/ssl"
CRT="$SSL_DIR/inception.crt"
KEY="$SSL_DIR/inception.key"

log() { echo "[nginx-entrypoint] $*"; }

# ---- TLS certificate --------------------------------------------------------
if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
	log "generating a self-signed certificate for ${DOMAIN_NAME}"
	mkdir -p "$SSL_DIR"
	openssl req -x509 -nodes -days 365 \
		-newkey rsa:2048 \
		-keyout "$KEY" \
		-out "$CRT" \
		-subj "/C=FR/ST=Ile-de-France/L=Paris/O=42/OU=inception/CN=${DOMAIN_NAME}" \
		-addext "subjectAltName=DNS:${DOMAIN_NAME},DNS:www.${DOMAIN_NAME}" \
		2> /dev/null
	chmod 600 "$KEY"
fi

# ---- vhost ------------------------------------------------------------------
# Only ${DOMAIN_NAME} is substituted; nginx variables such as $uri or $host
# are left untouched.
envsubst '${DOMAIN_NAME}' \
	< /etc/nginx/templates/default.conf.template \
	> /etc/nginx/conf.d/default.conf

# ---- sanity check then hand over to nginx -----------------------------------
nginx -t

log "serving https://${DOMAIN_NAME} on port 443 (TLSv1.2 / TLSv1.3 only)"
exec "$@"
