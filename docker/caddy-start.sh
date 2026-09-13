#!/bin/sh
set -eu
# Resolver el peer exacto al arrancar: sin confiar en todas las redes privadas.
CLOUDFLARED_IPS=$(nslookup cloudflared 127.0.0.11 | awk '/^Name:/ {answer=1; next} answer && /^Address/ {print $NF}')
test -n "$CLOUDFLARED_IPS"
export CLOUDFLARED_IPS
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
