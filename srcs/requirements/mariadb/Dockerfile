# Penultimate stable Debian release (13 "trixie" is stable, 12 "bookworm" is
# the previous one). The `latest` tag is forbidden by the subject.
FROM debian:bookworm

LABEL maintainer="Inception - MariaDB"

# mariadb-server only: no nginx, no php, nothing else.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        mariadb-server \
        mariadb-client \
        procps && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Server configuration (listen on the docker network, no unix-socket-only mode)
COPY conf/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf

# Entrypoint: first-run initialisation, then `exec mariadbd` (PID 1, foreground)
COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /var/run/mysqld && \
    # The Debian package already seeds /var/lib/mysql with system tables.
    # Docker would copy them into the empty named volume on the first start,
    # and the entrypoint would then wrongly believe the database is already
    # initialised. The image must ship an EMPTY data directory.
    rm -rf /var/lib/mysql/* && \
    chown -R mysql:mysql /var/run/mysqld /var/lib/mysql

EXPOSE 3306

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["mariadbd"]
