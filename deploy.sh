#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SECONDS=0
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "Deploy interrumpido (linea %s). No se han borrado volumenes ni revertido migraciones.\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || fail 'Ejecutar: sudo bash ./deploy.sh'
cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
[[ -f docker-compose.yml ]] || fail 'Falta docker-compose.yml junto al script'
command -v flock >/dev/null || fail 'Falta util-linux (flock)'
exec 9>.deploy.lock
flock -n 9 || fail 'Ya hay un despliegue en este directorio'

# Repositorio APT firmado; nunca curl | sh ni eliminar runtimes existentes.
install_docker() {
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        return
    fi
    . /etc/os-release
    [[ ${ID:-} == ubuntu ]] || fail 'Este bootstrap soporta Ubuntu 24.04/26.04'
    case "${VERSION_ID:-}" in 24.04|26.04) ;; *) fail 'Version Ubuntu no validada por este bootstrap';; esac
    for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            fail "Existe $package. Resolver el conflicto con Docker CE antes de continuar"
        fi
    done
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=120 update -qq
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq ca-certificates curl openssl
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error --retry 3 --connect-timeout 10 --max-time 60 \
        https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get -o DPkg::Lock::Timeout=120 update -qq
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}
install_docker
systemctl enable --now docker >/dev/null
docker info >/dev/null
docker compose config --help | grep -q -- '--lock-image-digests' || fail 'Actualizar Docker Compose'
if ! command -v openssl >/dev/null || ! command -v curl >/dev/null; then
    apt-get -o DPkg::Lock::Timeout=120 update -qq
    apt-get -o DPkg::Lock::Timeout=120 install -y -qq openssl curl ca-certificates
fi

ask() {
    local name=$1 label=$2 secret=${3:-false} value
    if [[ $secret == true ]]; then
        read -r -s -p "$label: " value </dev/tty
        printf '\n' >/dev/tty
    else
        read -r -p "$label: " value </dev/tty
    fi
    [[ -n $value && $value != *\'* && $value != *$'\r'* && $value != *$'\n'* ]] \
        || fail "Valor vacio o formato no admitido: $name"
    printf -v "$name" '%s' "$value"
}
if [[ ! -f .env ]]; then
    [[ -c /dev/tty ]] || fail 'Provisionar .env con permisos 600 para ejecucion sin terminal'
    ask APP_DOMAIN 'Dominio publico (ejemplo: app.example.com)'
    [[ $APP_DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $APP_DOMAIN == *.* ]] \
        || fail 'Dominio invalido: no incluir https, puerto ni ruta'
    ask APP_IMAGE 'Imagen publicada (registry/ruta@sha256:...)'
    [[ $APP_IMAGE =~ ^[a-zA-Z0-9./:_-]+@sha256:[a-f0-9]{64}$ ]] || fail 'Usar un digest SHA-256 valido'
    ask MAIL_FROM_ADDRESS 'Remitente verificado en Resend'
    ask FILAMENT_ADMIN_EMAIL 'Email del administrador de Filament'
    [[ $FILAMENT_ADMIN_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || fail 'Email de administrador invalido'
    ask RESEND_KEY 'RESEND_KEY' true
    ask TUNNEL_TOKEN 'TUNNEL_TOKEN' true
    temporary_env=$(mktemp .env.tmp.XXXXXX)
    cat > "$temporary_env" <<EOF
COMPOSE_PROJECT_NAME=laravel
PROJECT_CPUS=4
PROJECT_MEMORY=8G
APP_NAME=Laravel
APP_DOMAIN='$APP_DOMAIN'
APP_IMAGE='$APP_IMAGE'
APP_KEY='base64:$(openssl rand -base64 32)'
OCTANE_WORKERS=2
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD='$(openssl rand -hex 32)'
POSTGRES_PASSWORD='$(openssl rand -hex 32)'
REDIS_PASSWORD='$(openssl rand -hex 32)'
RESEND_KEY='$RESEND_KEY'
MAIL_FROM_ADDRESS='$MAIL_FROM_ADDRESS'
FILAMENT_ADMIN_EMAIL='$FILAMENT_ADMIN_EMAIL'
TUNNEL_TOKEN='$TUNNEL_TOKEN'
POSTGRES_IMAGE=postgres:18-bookworm
REDIS_IMAGE=redis:8-bookworm
CLOUDFLARED_IMAGE=cloudflare/cloudflared:latest
EOF
    mv -- "$temporary_env" .env
    unset RESEND_KEY TUNNEL_TOKEN
fi
chmod 0600 .env
# No ejecutar .env como codigo Bash. Compose interpreta su formato.
base=(docker compose --env-file .env -f docker-compose.yml)
"${base[@]}" --profile ops config --quiet

# Leer solo parametros no sensibles ya interpretados por Compose, sin source/eval.
# Los defaults coinciden con x-project-limits para despliegues antiguos.
project_name=laravel project_cpus=4 project_memory=8G
resource_settings=$("${base[@]}" config --environment | awk -F= \
    '$1 == "COMPOSE_PROJECT_NAME" || $1 == "PROJECT_CPUS" || $1 == "PROJECT_MEMORY"')
while IFS='=' read -r key value; do
    case "$key" in
        COMPOSE_PROJECT_NAME) project_name=${value:-laravel} ;;
        PROJECT_CPUS) project_cpus=${value:-4} ;;
        PROJECT_MEMORY) project_memory=${value:-8G} ;;
    esac
done <<< "$resource_settings"
bash docker/project-limits.sh "$project_name" "$project_cpus" "$project_memory"

# Las referencias mutables solo se resuelven la primera vez o con --refresh-images.
# El lock contiene exclusivamente imagenes de infraestructura, nunca secretos.
case "${1:-}" in ''|--refresh-images) ;; *) fail 'Uso: deploy.sh [--refresh-images]';; esac
if [[ ! -f compose.images.yml || ${1:-} == --refresh-images ]]; then
    "${base[@]}" pull postgres redis cloudflared
    image_lock=$(mktemp compose.images.yml.tmp.XXXXXX)
    printf 'services:\n' > "$image_lock"
    for service in postgres redis cloudflared; do
        reference=$("${base[@]}" config --images "$service")
        digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$reference")
        [[ $digest == *@sha256:* ]] || fail "No se pudo fijar la imagen de $service"
        printf '  %s:\n    image: %s\n' "$service" "$digest" >> "$image_lock"
    done
    mv -- "$image_lock" compose.images.yml
fi
dc=("${base[@]}" -f compose.images.yml)
"${dc[@]}" --profile ops config --quiet
"${dc[@]}" pull app queue scheduler postgres redis cloudflared
"${dc[@]}" up -d --wait --wait-timeout 120 postgres redis
"${dc[@]}" run --rm --no-deps -T release php /app/docker/check-services.php

# Una sola migracion por VPS, antes de iniciar el codigo nuevo.
# Requiere cambios de esquema compatibles con la version web anterior.
"${dc[@]}" stop queue scheduler
"${dc[@]}" run --rm --no-deps -T release
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 app
"${dc[@]}" up -d --no-deps queue scheduler cloudflared

# Confirmar que cada contenedor en ejecucion pertenece realmente a la slice.
for container in $("${dc[@]}" ps --quiet); do
    read -r parent pid < <(docker inspect --format '{{.HostConfig.CgroupParent}} {{.State.Pid}}' "$container")
    [[ $parent == "project-${project_name}.slice" && $pid -gt 0 ]] || fail 'Contenedor fuera del presupuesto del proyecto'
    process_group=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
    [[ $process_group == "/project.slice/project-${project_name}.slice/"* ]] \
        || fail 'El proceso no pertenece al cgroup esperado'
done

# La imagen cloudflared no contiene shell/curl: consultar /ready desde app.
tunnel_ready=false
for ((attempt=1; attempt<=30; attempt++)); do
    if "${dc[@]}" exec -T app php -r '
        $c = curl_init("http://cloudflared:2000/ready");
        curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 2]);
        curl_exec($c);
        exit(curl_getinfo($c, CURLINFO_RESPONSE_CODE) === 200 ? 0 : 1);
    '; then tunnel_ready=true; break; fi
    sleep 1
done
[[ $tunnel_ready == true ]] || fail 'Cloudflared no se ha conectado. Revisar token, DNS y salida 7844 TCP/UDP'
"${dc[@]}" exec -T app php -r '
    $c = curl_init(getenv("APP_URL")."/up");
    curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15]);
    curl_exec($c);
    $status = curl_getinfo($c, CURLINFO_RESPONSE_CODE);
    if ($status !== 200) { fwrite(STDERR, "Health publico devolvio HTTP $status. Revisar ruta del tunel/Access.\n"); exit(1); }
'
printf 'Stack operativo. Tiempo total: %s segundos.\n' "$SECONDS"
if ((SECONDS > 120)); then
    printf 'Se ha superado el objetivo de 120 s; revisar tiempos de APT, pulls, migraciones y healthchecks.\n'
fi
