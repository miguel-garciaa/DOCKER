#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail 'Uso: ./publish-image.sh [tag]'
command -v docker >/dev/null || fail 'Docker no esta instalado'
docker buildx version >/dev/null 2>&1 || fail 'Docker Buildx no esta disponible'

repository=${IMAGE_REPOSITORY:-ghcr.io/miguel-garciaa/docker}
tag=${1:-$(git rev-parse --short=12 HEAD)}
platforms=${PLATFORMS:-linux/amd64}
revision=$(git rev-parse HEAD)

[[ $repository =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || fail 'IMAGE_REPOSITORY invalido o con mayusculas'
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || fail 'Tag OCI invalido'
[[ $platforms =~ ^linux/(amd64|arm64)(,linux/(amd64|arm64))?$ ]] || fail 'PLATFORMS admite linux/amd64, linux/arm64 o ambos'
git diff --quiet && git diff --cached --quiet || fail 'Publica solo desde un arbol Git limpio'

reference="${repository}:${tag}"
if docker buildx imagetools inspect "$reference" >/dev/null 2>&1; then
    fail "La release $reference ya existe; usa un tag nuevo"
fi
printf 'Publicando %s para %s\n' "$reference" "$platforms"
docker buildx build \
    --platform "$platforms" \
    --target app \
    --tag "$reference" \
    --label "org.opencontainers.image.source=https://github.com/miguel-garciaa/DOCKER" \
    --label "org.opencontainers.image.revision=$revision" \
    --label "org.opencontainers.image.version=$tag" \
    --provenance=mode=max \
    --sbom=true \
    --push \
    .

printf 'Release publicada: %s\n' "$reference"
printf 'Para ver su digest: docker buildx imagetools inspect %s\n' "$reference"
