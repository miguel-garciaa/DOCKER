#!/bin/sh
set -eu
umask 077
# La plantilla usa una clave hexadecimal: no se interpola entrada libre en config.
case "$REDIS_PASSWORD" in *[!a-f0-9]*|'') echo 'REDIS_PASSWORD debe ser hexadecimal' >&2; exit 1;; esac
test "${#REDIS_PASSWORD}" -ge 32
cat > /tmp/redis.conf <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
requirepass $REDIS_PASSWORD
dir /data
appendonly yes
appendfsync everysec
maxmemory 256mb
maxmemory-policy noeviction
save ""
EOF
exec redis-server /tmp/redis.conf
