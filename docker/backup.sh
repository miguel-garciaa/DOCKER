#!/usr/bin/env bash
set -euo pipefail
umask 077

cd "$(dirname "$0")/.."

[[ $EUID -eq 0 ]] || { echo "Ejecuta: sudo ./docker/backup.sh"; exit 1; }
[[ -f .env ]] || { echo "Falta el archivo .env"; exit 1; }
command -v age >/dev/null || { echo "Instala age: sudo apt install -y age"; exit 1; }

recipient=$(sed -n 's/^BACKUP_AGE_RECIPIENT=//p' .env | tail -n 1)
retention_days=$(sed -n 's/^BACKUP_RETENTION_DAYS=//p' .env | tail -n 1)

[[ $recipient == age1* ]] || { echo "Configura BACKUP_AGE_RECIPIENT en .env"; exit 1; }
retention_days=${retention_days:-30}

backup_root=/var/lib/.laravel-backups
day=$(date -u +%Y-%m-%d)
time=$(date -u +%H-%M-%S)
day_dir="$backup_root/$day"

install -d -m 700 "$backup_root" "$day_dir" \
    "$day_dir/database" "$day_dir/laravel" "$day_dir/system" "$day_dir/logs"
trap 'find "$day_dir" -type f -name "*.tmp" -delete' EXIT

echo "[1/6] Base de datos PostgreSQL"
database="$day_dir/database/database-$time.dump.age"
docker compose --env-file .env exec -T postgres sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$DB_DATABASE" --format=custom --compress=gzip:9' \
    | age -r "$recipient" -o "$database.tmp"
mv "$database.tmp" "$database"

globals="$day_dir/database/globals-$time.sql.gz.age"
docker compose --env-file .env exec -T postgres sh -c \
    'pg_dumpall -U "$POSTGRES_USER" --globals-only' \
    | gzip -9 | age -r "$recipient" -o "$globals.tmp"
mv "$globals.tmp" "$globals"

echo "[2/6] Codigo y configuracion Laravel"
code="$day_dir/laravel/code-$time.tar.gz.age"
tar -C "$PWD" -czf - \
    --exclude=.git --exclude=laravel/vendor --exclude=laravel/node_modules \
    --exclude=laravel/public/build --exclude=.deploy.lock \
    --exclude=backup-age-key.txt . \
    | age -r "$recipient" -o "$code.tmp"
mv "$code.tmp" "$code"

echo "[3/6] Archivos subidos por la aplicacion"
uploads="$day_dir/laravel/uploads-$time.tar.gz.age"
docker compose --env-file .env exec -T app-1 \
    tar -C /app/storage/app -czf - . \
    | age -r "$recipient" -o "$uploads.tmp"
mv "$uploads.tmp" "$uploads"

echo "[4/6] Configuracion e inventario del sistema"
system_config="$day_dir/system/etc-$time.tar.gz.age"
tar -C / -czf - etc | age -r "$recipient" -o "$system_config.tmp"
mv "$system_config.tmp" "$system_config"

system_info="$day_dir/system/inventory-$time.txt.gz.age"
{
    date -u
    uname -a
    lsblk
    df -h
    dpkg-query -W
    systemctl list-unit-files --no-pager
    docker version
} | gzip -9 | age -r "$recipient" -o "$system_info.tmp"
mv "$system_info.tmp" "$system_info"

echo "[5/6] Logs del sistema y contenedores"
system_logs="$day_dir/logs/system-$time.txt.gz.age"
journalctl --since "24 hours ago" --no-pager \
    | gzip -9 | age -r "$recipient" -o "$system_logs.tmp"
mv "$system_logs.tmp" "$system_logs"

container_logs="$day_dir/logs/containers-$time.txt.gz.age"
docker compose --env-file .env logs --no-color \
    | gzip -9 | age -r "$recipient" -o "$container_logs.tmp"
mv "$container_logs.tmp" "$container_logs"

echo "[6/6] Retencion y metrica de estado"
find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
    -mtime "+$retention_days" -exec rm -rf -- {} +

install -d -m 755 /var/lib/laravel-backup-status
printf 'laravel_backup_last_success_timestamp_seconds %s\n' "$(date +%s)" \
    > /var/lib/laravel-backup-status/laravel_backup_last_success_timestamp_seconds.prom

echo "Backup completado: $day_dir"
