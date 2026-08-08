# Bonus - Redis object cache for WordPress
FROM debian:bookworm

LABEL maintainer="Inception - Redis"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        redis-server \
        util-linux && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY conf/redis.conf /etc/redis/redis.conf
COPY tools/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /data && \
    chown -R redis:redis /data /etc/redis

WORKDIR /data

EXPOSE 6379

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# `daemonize no` in redis.conf: redis-server stays in the foreground as PID 1.
CMD ["redis-server", "/etc/redis/redis.conf"]
