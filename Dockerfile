# syntax=docker/dockerfile:1.7
FROM dunglas/frankenphp:1.11.1-php8.4-bookworm AS php-base
RUN install-php-extensions pdo_pgsql redis pcntl intl zip bcmath gd opcache \
    && setcap -r /usr/local/bin/frankenphp
WORKDIR /app
COPY laravel/docker/php.ini /usr/local/etc/php/conf.d/zz-production.ini

FROM php-base AS build
COPY --from=composer:2.9.5 /usr/bin/composer /usr/local/bin/composer
COPY --from=node:24.14.0-bookworm-slim /usr/local/ /usr/local/
ENV COMPOSER_ALLOW_SUPERUSER=1
COPY laravel/composer.json laravel/composer.lock ./
RUN composer install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-autoloader
COPY laravel/package.json laravel/package-lock.json laravel/.npmrc ./
RUN npm ci --no-audit --no-fund
COPY laravel/ ./
RUN mkdir -p storage/framework/views storage/framework/sessions storage/framework/cache/data \
      storage/logs storage/app/private storage/app/public bootstrap/cache \
    && composer dump-autoload --no-dev --optimize --no-interaction \
    && composer check-platform-reqs --no-dev \
    && php artisan filament:assets --no-interaction \
    && cp vendor/laravel/octane/src/Commands/stubs/frankenphp-worker.php public/frankenphp-worker.php \
    && npm run build \
    && rm -rf node_modules tests \
    && rm -f bootstrap/cache/*.php

FROM php-base AS runtime
ENV APP_ENV=production APP_DEBUG=false \
    HOME=/tmp XDG_CONFIG_HOME=/tmp/config XDG_DATA_HOME=/tmp/data
COPY --chown=www-data:www-data --from=build /app/app ./app
COPY --chown=www-data:www-data --from=build /app/bootstrap ./bootstrap
COPY --chown=www-data:www-data --from=build /app/config ./config
COPY --chown=www-data:www-data --from=build /app/database ./database
COPY --chown=www-data:www-data --from=build /app/docker ./docker
COPY --chown=www-data:www-data --from=build /app/public ./public
COPY --chown=www-data:www-data --from=build /app/resources/views ./resources/views
COPY --chown=www-data:www-data --from=build /app/routes ./routes
COPY --chown=www-data:www-data --from=build /app/storage ./storage
COPY --chown=www-data:www-data --from=build /app/vendor ./vendor
COPY --chown=www-data:www-data --from=build /app/artisan /app/composer.json ./
RUN ln -s /app/storage/app/public /app/public/storage \
    && chmod 0755 docker/entrypoint.sh
USER www-data
EXPOSE 8000
ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["web"]
