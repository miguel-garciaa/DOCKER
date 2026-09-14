# syntax=docker/dockerfile:1.7
FROM dunglas/frankenphp:1.11.1-php8.4-bookworm AS php
WORKDIR /app
RUN install-php-extensions pdo_pgsql redis pcntl intl zip bcmath gd opcache \
    && setcap -r /usr/local/bin/frankenphp
COPY laravel/docker/php.ini /usr/local/etc/php/conf.d/production.ini

FROM php AS build
COPY --from=composer:2.9.5 /usr/bin/composer /usr/local/bin/composer
COPY --from=node:24.14.0-bookworm-slim /usr/local/ /usr/local/
ENV COMPOSER_ALLOW_SUPERUSER=1

COPY laravel/composer.json laravel/composer.lock \
    laravel/package.json laravel/package-lock.json laravel/.npmrc ./
RUN composer install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-autoloader \
    && npm ci --no-audit --no-fund

COPY laravel/ ./
RUN rm -f bootstrap/cache/*.php \
    && mkdir -p storage/framework/views storage/framework/sessions \
        storage/framework/cache/data storage/logs storage/app/private \
        storage/app/public bootstrap/cache \
    && composer dump-autoload --no-dev --optimize --no-interaction \
    && composer check-platform-reqs --no-dev \
    && php artisan filament:assets --no-interaction \
    && cp vendor/laravel/octane/src/Commands/stubs/frankenphp-worker.php public/frankenphp-worker.php \
    && npm run build \
    && rm -rf node_modules tests bootstrap/cache/*.php

FROM php AS runtime
ENV APP_ENV=production APP_DEBUG=false \
    HOME=/tmp XDG_CONFIG_HOME=/tmp/config XDG_DATA_HOME=/tmp/data
COPY --from=build --chown=www-data:www-data /app /app
RUN ln -s /app/storage/app/public /app/public/storage \
    && chmod 0755 docker/entrypoint.sh
USER www-data
EXPOSE 8000
ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["web"]
