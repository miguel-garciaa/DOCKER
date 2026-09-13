#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "Deploy interrumpido en linea %s; no se borran datos ni se revierten migraciones.\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || fail 'Uso: sudo ./deploy.sh'
[[ $# -eq 0 ]] || fail 'deploy.sh no admite argumentos; construir desde el checkout revisado'
cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
[[ $(stat -c '%U' .) == root && -z $(find . \( ! -user root -o \( ! -type l -a -perm /022 \) \) -print -quit) ]] \
    || fail 'El directorio desplegado debe ser root y no permitir escritura a grupo/otros'
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 26.04 ]] || fail 'Requiere Ubuntu 26.04 LTS'
[[ ! -e /var/run/reboot-required ]] || fail 'Reinicio pendiente: reiniciar antes del despliegue'
exec 9>.deploy.lock
flock -n 9 || fail 'Ya hay un deploy o backup en curso'
for command in docker jq openssl; do command -v "$command" >/dev/null || fail "Falta $command; ejecutar setup-host.sh prepare"; done
[[ -f .env && ! -L .env && $(stat -c '%U %a' .env) == 'root 600' ]] || fail '.env debe ser un archivo root:root con permisos 600'
docker version >/dev/null
docker compose version
[[ $(docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}') == 'systemd 2' ]] || fail 'Requiere systemd y cgroups v2'
dc=(docker compose --env-file .env -f docker-compose.yml)
"${dc[@]}" config --quiet
# Compose interpreta .env; nunca source ni eval. El JSON con secretos solo vive en memoria.
config=$("${dc[@]}" config --format json)
project=$(jq -r .name <<< "$config")
app_domain=$(jq -r '.services.caddy.environment.APP_DOMAIN' <<< "$config")
metrics_domain=$(jq -r '.services.caddy.environment.METRICS_DOMAIN' <<< "$config")
for domain in "$app_domain" "$metrics_domain"; do
    [[ $domain =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $domain == *.* && $domain != *..* ]] || fail 'Dominio invalido'
done
[[ $app_domain != "$metrics_domain" ]] || fail 'Los dominios de aplicacion y metricas deben ser distintos'
for key in DB_DATABASE DB_USERNAME; do
    value=$(jq -r --arg key "$key" '.services.postgres.environment[$key]' <<< "$config")
    [[ $value =~ ^[a-z][a-z0-9_]{0,62}$ && $value != postgres ]] || fail "$key invalido o reservado"
done
for pair in 'app-1 DB_PASSWORD' 'postgres POSTGRES_PASSWORD' 'redis REDIS_PASSWORD'; do
    read -r service key <<< "$pair"
    value=$(jq -r --arg s "$service" --arg k "$key" '.services[$s].environment[$k]' <<< "$config")
    [[ $value =~ ^[a-f0-9]{64}$ ]] || fail "$key requiere 64 caracteres hexadecimales"
done
key=$(jq -r '.services["app-1"].environment.APP_KEY' <<< "$config")
[[ $key =~ ^base64:[A-Za-z0-9+/]{43}=$ ]] || fail 'APP_KEY debe contener 32 bytes en base64'
username=$(jq -r '.services.caddy.environment.METRICS_USERNAME' <<< "$config")
[[ $username =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || fail 'METRICS_USERNAME invalido'
hash=$(jq -r '.services.caddy.environment.METRICS_PASSWORD_HASH' <<< "$config")
[[ $hash =~ ^\$2[aby]\$(1[0-6])\$[./A-Za-z0-9]{53}$ ]] || fail 'METRICS_PASSWORD_HASH: bcrypt con coste 10-16, entre comillas simples en .env'
image=$(jq -r '.services["app-1"].image' <<< "$config")
[[ $image == *:* && $image != *:latest && $image != *@* ]] || fail 'APP_IMAGE requiere una etiqueta explicita'
[[ $(jq '.services | length' <<< "$config") == 10 && $(jq '.networks | length' <<< "$config") == 4 ]] || fail 'Se esperaban diez servicios y cuatro redes'
jq -e 'all(.services[]; (.ports // [] | length) == 0)' <<< "$config" >/dev/null || fail 'No se permiten puertos publicados'
unset value key hash config

project_cpus=4 project_memory=6G project_swap=1G
while IFS='=' read -r key value; do
    case "$key" in
        PROJECT_CPUS) project_cpus=$value ;;
        PROJECT_MEMORY) project_memory=$value ;;
        PROJECT_SWAP) project_swap=$value ;;
    esac
done < <("${dc[@]}" config --environment | awk -F= '$1 ~ /^PROJECT_(CPUS|MEMORY|SWAP)$/')
bash docker/project-limits.sh "$project" "$project_cpus" "$project_memory" "$project_swap"
"${dc[@]}" build --pull app-1 caddy
"${dc[@]}" pull postgres redis cloudflared prometheus node-exporter cadvisor
"${dc[@]}" run --rm --no-deps -T -e CLOUDFLARED_IPS=127.0.0.1 --entrypoint caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# Datos existentes del stack anterior usaban uid 10001: detener, respaldar y migrar
# ownership de uploads a 33:33 antes de esta version (procedimiento en README).
"${dc[@]}" run --rm --no-deps -T --entrypoint /bin/promtool prometheus check config /etc/prometheus/prometheus.yml
"${dc[@]}" up -d --wait --wait-timeout 180 postgres redis
"${dc[@]}" run --rm --no-deps -T app-1 php /app/docker/check-services.php
"${dc[@]}" run --rm --no-deps -T app-1 php artisan migrate --force --no-interaction
# Actualizar de una en una; las migraciones deben ser compatibles con el codigo anterior.
"${dc[@]}" up -d --no-deps --wait --wait-timeout 180 app-1
"${dc[@]}" up -d --no-deps --wait --wait-timeout 180 app-2
"${dc[@]}" up -d --no-deps queue
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 prometheus node-exporter cadvisor
"${dc[@]}" kill --signal SIGHUP prometheus
"${dc[@]}" up -d --no-deps cloudflared
# Reevaluar DNS y Caddyfile siempre, incluso si solo cambia la IP del tunel.
"${dc[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 120 caddy
for container in $("${dc[@]}" ps --quiet); do
    read -r parent pid < <(docker inspect --format '{{.HostConfig.CgroupParent}} {{.State.Pid}}' "$container")
    [[ $parent == "project-${project}.slice" && $pid -gt 0 ]] || fail 'Contenedor fuera de la slice'
    process_group=$(awk -F: '$1 == "0" {print $3}' "/proc/$pid/cgroup")
    [[ $process_group == "/project.slice/project-${project}.slice/"* ]] || fail 'Cgroup efectivo incorrecto'
done
# Esperar a la conectividad real del tunel, no solo a que el proceso este running.
ready=false
for ((attempt=1; attempt<=30; attempt++)); do
    if "${dc[@]}" exec -T caddy wget -q -O /dev/null http://cloudflared:2000/ready; then ready=true; break; fi
    sleep 2
done
[[ $ready == true ]] || fail 'Tunel no conectado: revisar token y salida TCP/UDP 7844'
curl --fail --silent --show-error --max-time 20 "https://$app_domain/up" >/dev/null
status=$(curl --silent --show-error --max-time 20 -o /dev/null -w '%{http_code}' "https://$metrics_domain/api/v1/query?query=up")
[[ $status == 401 ]] || fail "Metricas sin credenciales devolvieron $status; se esperaba 401"
printf 'Deploy completado. Verifica acceso Grafana autenticado, Google OAuth, Resend y restauracion.\n'
