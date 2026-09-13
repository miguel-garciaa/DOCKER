#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail 'Uso: ./publish-image.sh [tag]'
command -v docker >/dev/null || fail 'Docker no esta instalado'
case ${DOCKER_SUDO:-0} in
    0) docker_command=(docker); docker_display=docker ;;
    1) command -v sudo >/dev/null || fail 'sudo no esta disponible'; docker_command=(sudo docker); docker_display='sudo docker' ;;
    *) fail 'DOCKER_SUDO admite 0 o 1' ;;
esac
"${docker_command[@]}" buildx version >/dev/null 2>&1 || fail 'Docker Buildx no esta disponible'

repository=${IMAGE_REPOSITORY:-ghcr.io/miguel-garciaa/docker}
tag=${1:-$(git rev-parse --short=12 HEAD)}
platforms=${PLATFORMS:-linux/amd64}
revision=$(git rev-parse HEAD)

[[ $repository =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || fail 'IMAGE_REPOSITORY invalido o con mayusculas'
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'Tag OCI invalido'
[[ $platforms =~ ^linux/(amd64|arm64)(,linux/(amd64|arm64))?$ ]] || fail 'PLATFORMS admite linux/amd64, linux/arm64 o ambos'
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n $(git ls-files --others --exclude-standard) ]]; then
    fail 'Publica solo desde un arbol Git limpio'
fi

reference="${repository}:${tag}"
if "${docker_command[@]}" buildx imagetools inspect "$reference" >/dev/null 2>&1; then
    fail "La release $reference ya existe; usa un tag nuevo"
fi
printf 'Publicando %s para %s\n' "$reference" "$platforms"
"${docker_command[@]}" buildx build \
    --platform "$platforms" \
    --target runtime \
    --tag "$reference" \
    --label "org.opencontainers.image.source=https://github.com/miguel-garciaa/DOCKER" \
    --label "org.opencontainers.image.revision=$revision" \
    --label "org.opencontainers.image.version=$tag" \
    --provenance=mode=max \
    --sbom=true \
    --push \
    .

printf 'Release publicada: %s\n' "$reference"
printf 'Para ver su digest: %s buildx imagetools inspect %s\n' "$docker_display" "$reference"
