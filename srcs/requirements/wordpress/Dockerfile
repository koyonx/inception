# Penultimate stable Debian release. The `latest` tag is forbidden.
FROM debian:bookworm

LABEL maintainer="Inception - WordPress + php-fpm (no nginx here)"

# php-fpm and the PHP extensions WordPress needs, plus the mariadb client
# (used to wait for the database) and curl (to fetch wp-cli).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        php8.2-fpm \
        php8.2-mysql \
        php8.2-curl \
        php8.2-gd \
        php8.2-mbstring \
        php8.2-xml \
        php8.2-zip \
        php8.2-intl \
        php8.2-redis \
        mariadb-client \
        curl \
        ca-certificates \
        procps && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# wp-cli: used to install and configure WordPress without any manual step.
RUN curl -fsSL -o /usr/local/bin/wp \
        https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar && \
    chmod +x /usr/local/bin/wp && \
    wp --info --allow-root > /dev/null

COPY conf/www.conf /etc/php/8.2/fpm/pool.d/www.conf
COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /run/php /var/www/html && \
    chown -R www-data:www-data /var/www/html

WORKDIR /var/www/html

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# -F keeps php-fpm in the foreground: it becomes PID 1, no daemon, no hack.
CMD ["/usr/sbin/php-fpm8.2", "-F"]
