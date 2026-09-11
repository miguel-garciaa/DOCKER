#!/bin/sh
set -eu
umask 027
mkdir -p /tmp/config /tmp/data storage/framework/views storage/framework/sessions \
  storage/framework/cache/data storage/logs bootstrap/cache
case "${1:-web}" in
  web|queue|scheduler)
    php artisan config:cache --no-interaction
    php artisan route:cache --no-interaction
    php artisan view:cache --no-interaction
    php artisan filament:optimize --no-interaction
    ;;
esac
case "${1:-web}" in
  web)
    exec php artisan octane:frankenphp --host=0.0.0.0 --port=8000 \
      --admin-host=127.0.0.1 --admin-port=2019 \
      --workers="${OCTANE_WORKERS:-2}" --max-requests=500 \
      --caddyfile=/app/docker/Caddyfile --log-level=info
    ;;
  queue)
    exec php artisan queue:work redis --queue=default --sleep=1 --tries=3 \
      --timeout=60 --max-time=3600 --memory=256 --no-interaction
    ;;
  scheduler) exec php artisan schedule:work --no-interaction ;;
  *) exec "$@" ;;
esac
