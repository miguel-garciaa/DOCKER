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
ask_prometheus_password() {
    read -r -s -p 'Contrasena de Grafana para Prometheus (20-64 caracteres): ' prometheus_plain_password </dev/tty
    printf '\n' >/dev/tty
    ((${#prometheus_plain_password} >= 20 && ${#prometheus_plain_password} <= 64)) \
        || fail 'La contrasena de Prometheus debe tener entre 20 y 64 caracteres'
}
read_env_value() {
    local key=$1 raw
    raw=$(sed -n "s/^${key}=//p" .env | tail -n 1)
    case "$raw" in
        \'*\') raw=${raw:1:${#raw}-2} ;;
        \"*\") raw=${raw:1:${#raw}-2} ;;
    esac
    printf '%s' "$raw"
}
write_prometheus_auth_file() {
    local username=$1 password_hash=$2 temporary_auth
    temporary_auth=$(mktemp .prometheus-auth.caddy.tmp.XXXXXX)
    printf '%s %s\n' "$username" "$password_hash" > "$temporary_auth"
    chown 10001:10001 "$temporary_auth"
    chmod 0400 "$temporary_auth"
    mv -- "$temporary_auth" .prometheus-auth.caddy
}
valid_app_image() {
    [[ $1 =~ ^[a-z0-9][a-z0-9._/-]*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})$ ]]
}
requested_app_image=${APP_IMAGE:-}
prometheus_plain_password=''
[[ -z $requested_app_image ]] || valid_app_image "$requested_app_image" \
    || fail 'APP_IMAGE no es una referencia OCI valida; usa registry/ruta:tag o registry/ruta@sha256:digest'
if [[ ! -f .env ]]; then
    [[ -c /dev/tty ]] || fail 'Provisionar .env con permisos 600 para ejecucion sin terminal'
    ask APP_DOMAIN 'Dominio publico (ejemplo: app.example.com)'
    [[ $APP_DOMAIN =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $APP_DOMAIN == *.* ]] \
        || fail 'Dominio invalido: no incluir https, puerto ni ruta'
    ask MAIL_FROM_ADDRESS 'Remitente verificado en Resend'
    ask FILAMENT_ADMIN_EMAIL 'Email del administrador de Filament'
    [[ $FILAMENT_ADMIN_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
        || fail 'Email de administrador invalido'
    ask RESEND_KEY 'RESEND_KEY' true
    ask TUNNEL_TOKEN 'TUNNEL_TOKEN' true
    ask_prometheus_password
    temporary_env=$(mktemp .env.tmp.XXXXXX)
    cat > "$temporary_env" <<EOF
COMPOSE_PROJECT_NAME=laravel
PROJECT_CPUS=4
PROJECT_MEMORY=6G
PROJECT_SWAP=1G
APP_NAME=Laravel
APP_DOMAIN='$APP_DOMAIN'
APP_KEY='base64:$(openssl rand -base64 32)'
OCTANE_WORKERS=2
APP_REPLICAS=2
QUEUE_REPLICAS=1
PROMETHEUS_DOMAIN='metrics.$APP_DOMAIN'
PROMETHEUS_USERNAME=grafana
PROMETHEUS_PASSWORD_HASH=
PROMETHEUS_RETENTION_TIME=15d
PROMETHEUS_RETENTION_SIZE=5GB
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD='$(openssl rand -hex 32)'
POSTGRES_PASSWORD='$(openssl rand -hex 32)'
REDIS_PASSWORD='$(openssl rand -hex 32)'
REVERB_APP_ID='$(openssl rand -hex 8)'
REVERB_APP_KEY='$(openssl rand -hex 16)'
REVERB_APP_SECRET='$(openssl rand -hex 32)'
REVERB_APP_MAX_CONNECTIONS=500
RESEND_KEY='$RESEND_KEY'
MAIL_FROM_ADDRESS='$MAIL_FROM_ADDRESS'
FILAMENT_ADMIN_EMAIL='$FILAMENT_ADMIN_EMAIL'
TUNNEL_TOKEN='$TUNNEL_TOKEN'
POSTGRES_IMAGE=postgres:18-bookworm
REDIS_IMAGE=redis:8-bookworm
CLOUDFLARED_IMAGE=cloudflare/cloudflared:latest
PROMETHEUS_IMAGE=prom/prometheus:v3.13.3-distroless
CADVISOR_IMAGE=ghcr.io/google/cadvisor:v0.60.5
EOF
    # Si se proporciona, el VPS descargara esta release y no necesitara el codigo fuente.
    if [[ -n $requested_app_image ]]; then
        printf "APP_IMAGE='%s'\n" "$requested_app_image" >> "$temporary_env"
    fi
    mv -- "$temporary_env" .env
    unset RESEND_KEY TUNNEL_TOKEN
fi
# Actualiza instalaciones existentes sin mostrar ni reemplazar secretos validos.
ensure_generated_env() {
    local key=$1 value=$2 existing
    existing=$(sed -n "s/^${key}=//p" .env | tail -n 1)
    case "$existing" in
        ''|"''"|'""')
            sed -i "/^${key}=/d" .env
            printf "%s='%s'\n" "$key" "$value" >> .env
            ;;
    esac
}
ensure_generated_env REVERB_APP_ID "$(openssl rand -hex 8)"
ensure_generated_env REVERB_APP_KEY "$(openssl rand -hex 16)"
ensure_generated_env REVERB_APP_SECRET "$(openssl rand -hex 32)"
if ! grep -q '^REVERB_APP_MAX_CONNECTIONS=' .env; then
    printf 'REVERB_APP_MAX_CONNECTIONS=500\n' >> .env
fi
if ! grep -q '^PROMETHEUS_DOMAIN=' .env; then
    existing_app_domain=$(read_env_value APP_DOMAIN)
    [[ $existing_app_domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $existing_app_domain == *.* ]] \
        || fail 'APP_DOMAIN invalido en .env'
    printf "PROMETHEUS_DOMAIN='metrics.%s'\n" "$existing_app_domain" >> .env
fi
if ! grep -q '^PROMETHEUS_USERNAME=' .env; then
    printf 'PROMETHEUS_USERNAME=grafana\n' >> .env
fi
prometheus_domain=$(read_env_value PROMETHEUS_DOMAIN)
[[ $prometheus_domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && $prometheus_domain == *.* ]] \
    || fail 'PROMETHEUS_DOMAIN invalido'
prometheus_username=$(read_env_value PROMETHEUS_USERNAME)
[[ $prometheus_username =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || fail 'PROMETHEUS_USERNAME invalido'
prometheus_password_hash=$(read_env_value PROMETHEUS_PASSWORD_HASH)
if [[ -n $prometheus_password_hash ]]; then
    [[ $prometheus_password_hash =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] \
        || fail 'PROMETHEUS_PASSWORD_HASH no es un hash bcrypt valido'
fi
if [[ -z $prometheus_password_hash && -z $prometheus_plain_password ]]; then
    [[ -c /dev/tty ]] || fail 'Provisionar PROMETHEUS_PASSWORD_HASH para ejecucion sin terminal'
    ask_prometheus_password
fi
chmod 0600 .env
# No ejecutar .env como codigo Bash. Compose interpreta su formato.
base=(docker compose --env-file .env -f docker-compose.yml)
"${base[@]}" --profile ops config --quiet

# APP_IMAGE es opcional: ausente construye desde el repositorio; presente descarga la release.
app_image=$("${base[@]}" config --environment | awk -F= '$1 == "APP_IMAGE" { print substr($0, index($0, "=") + 1) }')
registry_deploy=false
if [[ -n $app_image ]]; then
    valid_app_image "$app_image" || fail 'APP_IMAGE no es una referencia OCI valida; usa registry/ruta:tag o registry/ruta@sha256:digest'
    registry_deploy=true
fi

# Leer solo parametros no sensibles ya interpretados por Compose, sin source/eval.
# Los defaults coinciden con x-project-limits para despliegues antiguos.
project_name=laravel project_cpus=4 project_memory=6G project_swap=1G
resource_settings=$("${base[@]}" config --environment | awk -F= \
    '$1 == "COMPOSE_PROJECT_NAME" || $1 == "PROJECT_CPUS" || $1 == "PROJECT_MEMORY" || $1 == "PROJECT_SWAP"')
while IFS='=' read -r key value; do
    case "$key" in
        COMPOSE_PROJECT_NAME) project_name=${value:-laravel} ;;
        PROJECT_CPUS) project_cpus=${value:-4} ;;
        PROJECT_MEMORY) project_memory=${value:-6G} ;;
        PROJECT_SWAP) project_swap=${value:-1G} ;;
    esac
done <<< "$resource_settings"
bash docker/project-limits.sh "$project_name" "$project_cpus" "$project_memory" "$project_swap"

# Las referencias mutables solo se resuelven la primera vez o con --refresh-images.
# El lock contiene exclusivamente imagenes de infraestructura, nunca secretos.
case "${1:-}" in ''|--refresh-images) ;; *) fail 'Uso: deploy.sh [--refresh-images]';; esac
if [[ ! -f compose.images.yml || ${1:-} == --refresh-images ]] \
    || ! grep -q '^  prometheus:' compose.images.yml \
    || ! grep -q '^  cadvisor:' compose.images.yml; then
    "${base[@]}" pull postgres redis cloudflared prometheus cadvisor
    postgres_image=postgres:18-bookworm
    redis_image=redis:8-bookworm
    cloudflared_image=cloudflare/cloudflared:latest
    prometheus_image=prom/prometheus:v3.13.3-distroless
    cadvisor_image=ghcr.io/google/cadvisor:v0.60.5
    infra_settings=$("${base[@]}" config --environment | awk -F= \
        '$1 == "POSTGRES_IMAGE" || $1 == "REDIS_IMAGE" || $1 == "CLOUDFLARED_IMAGE" || $1 == "PROMETHEUS_IMAGE" || $1 == "CADVISOR_IMAGE"')
    while IFS='=' read -r key value; do
        case "$key" in
            POSTGRES_IMAGE) postgres_image=${value:-postgres:18-bookworm} ;;
            REDIS_IMAGE) redis_image=${value:-redis:8-bookworm} ;;
            CLOUDFLARED_IMAGE) cloudflared_image=${value:-cloudflare/cloudflared:latest} ;;
            PROMETHEUS_IMAGE) prometheus_image=${value:-prom/prometheus:v3.13.3-distroless} ;;
            CADVISOR_IMAGE) cadvisor_image=${value:-ghcr.io/google/cadvisor:v0.60.5} ;;
        esac
    done <<< "$infra_settings"
    image_lock=$(mktemp compose.images.yml.tmp.XXXXXX)
    printf 'services:\n' > "$image_lock"
    for service in postgres redis cloudflared prometheus cadvisor; do
        case "$service" in
            postgres) reference=$postgres_image ;;
            redis) reference=$redis_image ;;
            cloudflared) reference=$cloudflared_image ;;
            prometheus) reference=$prometheus_image ;;
            cadvisor) reference=$cadvisor_image ;;
        esac
        if ! digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$reference"); then
            fail "No se pudo inspeccionar la imagen de $service: $reference"
        fi
        [[ $digest == *@sha256:* ]] || fail "No se pudo fijar la imagen de $service"
        printf '  %s:\n    image: %s\n' "$service" "$digest" >> "$image_lock"
    done
    mv -- "$image_lock" compose.images.yml
fi
dc=("${base[@]}" -f compose.images.yml)
"${dc[@]}" --profile ops config --quiet
"${dc[@]}" pull postgres redis cloudflared prometheus cadvisor
# Web, gateways, Reverb, release, queue y scheduler reutilizan exactamente la misma imagen.
if [[ $registry_deploy == true ]]; then
    docker pull "$app_image"
else
    build_args=()
    [[ ${1:-} == --refresh-images ]] && build_args+=(--pull)
    "${dc[@]}" build "${build_args[@]}" app
fi
if [[ -n $prometheus_plain_password ]]; then
    resolved_app_image=${app_image:-laravel-app:local}
    prometheus_password_hash=$(printf '%s' "$prometheus_plain_password" | docker run --rm -i \
        --entrypoint php "$resolved_app_image" -r \
        '$password = stream_get_contents(STDIN); echo password_hash($password, PASSWORD_BCRYPT);')
    [[ $prometheus_password_hash =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]] \
        || fail 'No se pudo generar el hash bcrypt de Prometheus'
    temporary_env=$(mktemp .env.tmp.XXXXXX)
    grep -v '^PROMETHEUS_PASSWORD_HASH=' .env > "$temporary_env"
    printf "PROMETHEUS_PASSWORD_HASH='%s'\n" "$prometheus_password_hash" >> "$temporary_env"
    chmod 0600 "$temporary_env"
    mv -- "$temporary_env" .env
    unset prometheus_plain_password
fi
write_prometheus_auth_file "$prometheus_username" "$prometheus_password_hash"
unset prometheus_password_hash
prometheus_locked_image=$(awk '/^  prometheus:$/ { getline; sub(/^    image: /, ""); print; exit }' compose.images.yml)
[[ $prometheus_locked_image == *@sha256:* ]] || fail 'Falta el digest bloqueado de Prometheus'
docker run --rm --read-only --user 65532:65532 \
    --cgroup-parent "project-${project_name}.slice" --tmpfs /tmp:rw,noexec,nosuid,size=32m \
    --volume "$PWD/docker/prometheus:/etc/prometheus:ro" --entrypoint /bin/promtool \
    "$prometheus_locked_image" check config /etc/prometheus/prometheus.yml
"${dc[@]}" up -d --wait --wait-timeout 120 postgres redis
"${dc[@]}" run --rm --no-deps -T release php /app/docker/check-services.php

# Una sola migracion por VPS, antes de iniciar el codigo nuevo.
# Requiere cambios de esquema compatibles con la version web anterior.
"${dc[@]}" stop queue scheduler reverb
"${dc[@]}" run --rm --no-deps -T release
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 reverb
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 app
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 gateway
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 prometheus cadvisor
"${dc[@]}" up -d --no-deps --wait --wait-timeout 120 metrics-gateway
"${dc[@]}" up -d --no-deps queue scheduler cloudflared

# Confirmar que cada contenedor en ejecucion pertenece realmente a la slice.
for container in $("${dc[@]}" ps --quiet); do
    read -r parent pid < <(docker inspect --format '{{.HostConfig.CgroupParent}} {{.State.Pid}}' "$container")
    [[ $parent == "project-${project_name}.slice" && $pid -gt 0 ]] || fail 'Contenedor fuera del presupuesto del proyecto'
    process_group=$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")
    [[ $process_group == "/project.slice/project-${project_name}.slice/"* ]] \
        || fail 'El proceso no pertenece al cgroup esperado'
done

# La imagen cloudflared no contiene shell/curl: consultar /ready desde gateway.
tunnel_ready=false
for ((attempt=1; attempt<=30; attempt++)); do
    if "${dc[@]}" exec -T gateway php -r '
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
printf 'Prometheus: https://%s (usuario: %s).\n' \
    "$(read_env_value PROMETHEUS_DOMAIN)" "$(read_env_value PROMETHEUS_USERNAME)"
if ((SECONDS > 120)); then
    printf 'Se ha superado el objetivo de 120 s; revisar tiempos de APT, pulls, migraciones y healthchecks.\n'
fi
