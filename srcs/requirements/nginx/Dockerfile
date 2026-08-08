# Penultimate stable Debian release. The `latest` tag is forbidden.
FROM debian:bookworm

LABEL maintainer="Inception - NGINX (TLSv1.2 / TLSv1.3 only)"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        nginx \
        openssl \
        gettext-base \
        curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Both files are templates: ${DOMAIN_NAME} is substituted at container start.
COPY conf/default.conf   /etc/nginx/templates/default.conf.template
COPY conf/bonus.conf     /etc/nginx/templates/bonus.conf.template
COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    rm -f /etc/nginx/sites-enabled/default && \
    mkdir -p /etc/nginx/ssl /var/www/html && \
    # The nginx package drops a placeholder page in /var/www/html; docker would
    # copy it into the (empty) wordpress volume on the very first start.
    rm -rf /var/www/html/*

EXPOSE 443

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# nginx in the foreground => it is PID 1 and receives the signals directly.
CMD ["nginx", "-g", "daemon off;"]
