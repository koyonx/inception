# Bonus - Adminer, a single-file database manager
FROM debian:bookworm

LABEL maintainer="Inception - Adminer"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        php8.2-cli \
        php8.2-mysql \
        php8.2-mbstring \
        curl \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Adminer is distributed as one PHP file; the version is pinned on purpose.
RUN mkdir -p /var/www/adminer && \
    curl -fsSL -o /var/www/adminer/index.php \
        https://github.com/vrana/adminer/releases/download/v4.8.1/adminer-4.8.1.php && \
    chown -R www-data:www-data /var/www/adminer

COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/adminer

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# The PHP built-in web server is a normal foreground daemon (no loop hack).
# It is reachable only from the docker network; nginx proxies /adminer/ to it.
CMD ["php", "-S", "0.0.0.0:8080", "-t", "/var/www/adminer"]
