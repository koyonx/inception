#!/bin/sh
# Makes the persistence directory writable, then drops the root privileges and
# hands the process over to redis-server (which becomes PID 1 of the container).
set -eu

chown -R redis:redis /data

echo "[redis-entrypoint] starting redis-server in the foreground"
exec setpriv --reuid=redis --regid=redis --init-groups "$@"
