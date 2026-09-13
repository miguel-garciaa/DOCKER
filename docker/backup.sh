#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Se requiere root'
[[ $# -eq 1 && $1 =~ ^(backup|check)$ ]] || fail 'Uso: backup.sh backup|check'
cd /srv/laravel-stack
[[ -n ${RESTIC_REPOSITORY:-} && -n ${RESTIC_PASSWORD_FILE:-} ]] || fail 'Configurar /etc/laravel-backup.env'
[[ $(stat -c '%U %a' /etc/laravel-backup.env) == 'root 600' ]] || fail 'backup.env: root, 600'
[[ $(stat -c '%U %a' "$RESTIC_PASSWORD_FILE") == 'root 600' ]] || fail 'Contraseña Restic: root, 600'
exec 9>.deploy.lock
flock -w 300 9 || fail 'Deploy o backup activo durante mas de cinco minutos'
record_success() {
    local metric=$1 directory=/var/lib/laravel-backup-status temporary
    install -d -m 0755 "$directory"
    temporary=$(mktemp "$directory/.success.XXXXXX")
    printf '%s %s\n' "$metric" "$(date +%s)" > "$temporary"
    chmod 0644 "$temporary"
    mv "$temporary" "$directory/$metric.prom"
}
if [[ $1 == check ]]; then
    restic check --read-data
    record_success laravel_backup_check_last_success_timestamp_seconds
    exit 0
fi
dc=(docker compose --env-file .env -f docker-compose.yml)
stage=/var/lib/laravel-backup
install -d -m 0700 "$stage"
# La ruta se mantiene estable para agrupar snapshots y aplicar la retencion.
[[ -z $(find "$stage" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail 'Hay un backup incompleto en /var/lib/laravel-backup; revisar y retirarlo manualmente'
cleanup() { find "$stage" -mindepth 1 -delete; }
trap cleanup EXIT
# shellcheck disable=SC2016 # Las variables se expanden dentro del contenedor.
"${dc[@]}" exec -T postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$DB_DATABASE" --format=custom --no-owner --no-acl' > "$stage/database.dump"
mkdir "$stage/uploads"
"${dc[@]}" cp app-1:/app/storage/app/. "$stage/uploads"
# Restic cifra datos y secretos. Nunca subir este staging a almacenamiento sin cifrar.
restic backup --tag laravel "$stage" /srv/laravel-stack \
    --exclude /srv/laravel-stack/.git --exclude '**/node_modules' --exclude '**/vendor' \
    --exclude /srv/laravel-stack/laravel/storage --exclude /srv/laravel-stack/laravel/public/build
restic forget --tag laravel --group-by host,tags --keep-within 30d --prune
record_success laravel_backup_last_success_timestamp_seconds
printf 'Backup y retencion completados.\n'
