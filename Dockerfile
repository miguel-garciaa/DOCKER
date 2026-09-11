# syntax=docker/dockerfile:1.7
# CI: fijar estos argumentos a referencias @sha256 tras validar actualizaciones.
# Debian Bookworm prioriza compatibilidad con extensiones PHP y modulos npm nativos.
ARG PHP_IMAGE=dunglas/frankenphp:1-php8.4-bookworm
ARG COMPOSER_IMAGE=composer:2
ARG NODE_IMAGE=node:24-bookworm-slim

FROM ${COMPOSER_IMAGE} AS composer-bin
FROM ${NODE_IMAGE} AS node-bin
FROM ${PHP_IMAGE} AS php-base
RUN install-php-extensions pdo_pgsql redis pcntl intl zip bcmath gd opcache \
    && if command -v getcap >/dev/null && getcap /usr/local/bin/frankenphp | grep -q .; then \
         setcap -r /usr/local/bin/frankenphp; \
       fi \
    && groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY docker/php.ini /usr/local/etc/php/conf.d/zz-production.ini

FROM php-base AS dependencies
COPY --from=composer-bin /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1
COPY composer.json composer.lock ./
RUN --mount=type=cache,target=/root/.composer/cache \
    composer install --no-dev --prefer-dist --no-interaction --no-progress --no-scripts --no-autoloader
COPY . .
# Los scripts Composer deben poder arrancar sin secretos ni BD durante el build.
RUN mkdir -p storage/framework/views storage/framework/sessions storage/framework/cache/data \
      storage/logs storage/app/private storage/app/public bootstrap/cache \
    && composer dump-autoload --no-dev --optimize --no-interaction \
    && composer check-platform-reqs --no-dev \
    && php artisan filament:assets --no-interaction \
    && cp vendor/laravel/octane/src/Commands/stubs/frankenphp-worker.php public/frankenphp-worker.php

FROM dependencies AS frontend
# Wayfinder genera rutas TypeScript ejecutando `php artisan` durante el build,
# por lo que esta etapa necesita PHP y Node 24 en el mismo entorno.
COPY --from=node-bin /usr/local/ /usr/local/
ARG VITE_REVERB_APP_KEY
ARG VITE_REVERB_HOST
ARG VITE_REVERB_PORT=443
ARG VITE_REVERB_SCHEME=https
# Instala tambien devDependencies: Vite, TypeScript y Tailwind viven normalmente ahi.
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund
RUN npm run build

FROM php-base AS app
ENV APP_ENV=production APP_DEBUG=false \
    HOME=/tmp XDG_CONFIG_HOME=/tmp/config XDG_DATA_HOME=/tmp/data
COPY --from=dependencies /app /app
COPY --from=frontend /app/public/build /app/public/build
RUN mkdir -p storage/app/private storage/app/public storage/framework/views \
      storage/framework/sessions storage/framework/cache/data storage/logs bootstrap/cache \
    && ln -sfn /app/storage/app/public /app/public/storage \
    && chown -R 10001:10001 storage bootstrap/cache \
    && chmod 0755 docker/entrypoint.sh \
    && rm -f bootstrap/cache/config.php bootstrap/cache/routes-*.php bootstrap/cache/events.php
USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["web"]
