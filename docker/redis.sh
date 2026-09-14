#!/bin/sh
set -eu
umask 077
# La plantilla usa una clave hexadecimal: no se interpola entrada libre en config.
case "$REDIS_PASSWORD" in *[!a-f0-9]*|'') echo 'REDIS_PASSWORD debe ser hexadecimal' >&2; exit 1;; esac
test "${#REDIS_PASSWORD}" -ge 32
REDIS_MAXMEMORY=${REDIS_MAXMEMORY:-256mb}
case "$REDIS_MAXMEMORY" in *[!0-9mgkb]*|'') echo 'REDIS_MAXMEMORY invalido' >&2; exit 1;; esac
cat > /tmp/redis.conf <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
requirepass $REDIS_PASSWORD
dir /data
appendonly yes
appendfsync everysec
maxmemory $REDIS_MAXMEMORY
maxmemory-policy noeviction
save ""
EOF
exec redis-server /tmp/redis.conf
