# Bonus - "service of my choice": scheduled MariaDB backups.
# Rationale: the whole point of the two named volumes is persistence, but a
# volume protects against a container crash, not against a bad SQL statement
# or a corrupted table. This container takes a daily logical dump of the
# WordPress database into its own volume, and rotates the old ones.
FROM debian:bookworm

LABEL maintainer="Inception - database backup"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        mariadb-client \
        cron \
        gzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY tools/backup.sh            /usr/local/bin/backup.sh
COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /backups

VOLUME ["/backups"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# cron -f: a real foreground daemon, not a `sleep infinity` loop.
CMD ["cron", "-f", "-L", "2"]
