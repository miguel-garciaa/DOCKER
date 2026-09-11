#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
fail() { printf 'ERROR de recursos: %s\n' "$*" >&2; exit 1; }
print_only=false
if [[ ${1:-} == --print ]]; then print_only=true; shift; fi
[[ $# -eq 3 ]] || fail 'Uso: project-limits.sh [--print] PROYECTO CPU RAM'
project=$1 cpus=$2 memory=$3
# Evita inyeccion en unidades y jerarquias accidentales entre nombres con guiones.
[[ $project =~ ^[a-z0-9][a-z0-9_]{0,47}$ ]] || fail 'Proyecto: 1-48 letras minusculas, numeros o _, sin guiones'
[[ $cpus =~ ^([1-9][0-9]{0,3}|0)(\.[0-9]{1,2})?$ ]] || fail 'CPU: numero positivo, hasta 2 decimales'
awk -v n="$cpus" 'BEGIN { exit !(n > 0 && n <= 1024) }' || fail 'CPU fuera de rango (0, 1024]'
[[ $memory =~ ^[1-9][0-9]{0,6}[MG]$ ]] || fail 'RAM: entero positivo con M o G; ejemplo 8192M u 8G'
quota=$(awk -v n="$cpus" 'BEGIN { printf "%.0f", n * 100 }')
memory_bytes=$(awk -v n="${memory%?}" -v unit="${memory: -1}" 'BEGIN { printf "%.0f", n * (unit == "G" ? 1073741824 : 1048576) }')
slice="project-${project}.slice"
unit="# Managed by laravel-docker deploy.sh
[Unit]
Description=Shared container budget for ${project}

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
CPUQuota=${quota}%
MemoryMax=${memory}
MemorySwapMax=0"
if [[ $print_only == true ]]; then printf '%s\n' "$unit"; exit 0; fi
[[ $EUID -eq 0 ]] || fail 'Se requiere root'
[[ $(docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}') == 'systemd 2' ]] \
    || fail 'Se requiere Docker con driver systemd y cgroups v2; no se modifica el daemon automaticamente'
unit_path="/etc/systemd/system/$slice"
if [[ -e $unit_path ]]; then
    grep -qx '# Managed by laravel-docker deploy.sh' "$unit_path" \
        || fail "La unidad $slice ya existe y no pertenece a este despliegue"
fi
current=$(systemctl show "$slice" --property=MemoryCurrent --value 2>/dev/null || true)
if [[ $current =~ ^[0-9]+$ ]] && ((current > memory_bytes)); then
    fail 'El consumo actual supera el nuevo limite. Reducir carga antes de bajar la RAM'
fi
temporary=$(mktemp /etc/systemd/system/project-budget.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n' "$unit" > "$temporary"
chmod 0644 "$temporary"
mv -- "$temporary" "$unit_path"
systemctl daemon-reload
systemctl start "$slice"
# Aplicar cambios en vivo sin reiniciar la slice ni matar todos sus contenedores.
# El archivo anterior conserva la misma configuracion tras reiniciar el VPS.
systemctl set-property --runtime "$slice" \
    "CPUQuota=${quota}%" "MemoryMax=$memory" MemorySwapMax=0
group=$(systemctl show "$slice" --property=ControlGroup --value)
[[ $group == /project.slice/"$slice" ]] || fail 'Jerarquia cgroup inesperada'
[[ $(cat "/sys/fs/cgroup$group/memory.max") == "$memory_bytes" ]] || fail 'MemoryMax no aplicado'
[[ $(cat "/sys/fs/cgroup$group/memory.swap.max") == 0 ]] || fail 'MemorySwapMax no aplicado'
read -r actual_quota period < "/sys/fs/cgroup$group/cpu.max"
[[ $actual_quota != max ]] || fail 'CPUQuota no aplicado'
awk -v q="$actual_quota" -v p="$period" -v expected="$cpus" \
    'BEGIN { delta = q / p - expected; exit !(delta > -0.00001 && delta < 0.00001) }' \
    || fail 'CPUQuota efectiva distinta de la solicitada'
printf 'Proyecto %s: limite conjunto de %s CPU y %s RAM, sin swap.\n' "$project" "$cpus" "$memory"
