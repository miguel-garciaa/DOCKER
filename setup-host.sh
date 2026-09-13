#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Ejecutar con sudo'
[[ $# -eq 1 && $1 =~ ^(prepare|lockdown)$ ]] || fail 'Uso: setup-host.sh prepare|lockdown'
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 26.04 ]] || fail 'Requiere Ubuntu Server 26.04 LTS'
exec 9>/run/laravel-setup.lock
flock -n 9 || fail 'Ya hay otra preparacion del host'
state=/var/lib/laravel-host
install -d -m 0700 "$state"

check_docker_origin() {
    local package
    for package in docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin podman-docker moby-engine; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
            fail "Paquete incompatible: $package. No se ha desinstalado nada."
        fi
    done
    if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
        fail 'Existe Docker Snap. Resolver manualmente; no se desinstala.'
    fi
    if grep -Rqs 'download.docker.com' /etc/apt/sources.list /etc/apt/sources.list.d; then
        fail 'Existe un repositorio Docker CE. Resolver manualmente antes de actualizar.'
    fi
}
check_admin() {
    [[ $(getent passwd miguel | cut -d: -f6-7) == /home/miguel:/bin/bash ]] || fail 'Home/shell inesperados para miguel'
    ! id -nG miguel | tr ' ' '\n' | grep -qx docker || fail 'miguel pertenece al grupo docker; retirarlo manualmente'
    sudo -l -U miguel | grep -q 'NOPASSWD' && fail 'Eliminar reglas NOPASSWD aplicables a miguel'
    [[ $(passwd -S miguel | awk '{print $2}') == P ]] || fail 'Configurar una contraseña local: sudo passwd miguel'
    [[ -s /home/miguel/.ssh/authorized_keys ]] || fail 'Instalar authorized_keys de miguel'
    grep -q 'ssh-ed25519 ' /home/miguel/.ssh/authorized_keys || fail 'Falta llave ED25519'
    [[ $(stat -c '%U %a' /home/miguel/.ssh) == 'miguel 700' ]] || fail '/home/miguel/.ssh: propietario miguel, modo 700'
    [[ $(stat -c '%U %a' /home/miguel/.ssh/authorized_keys) == 'miguel 600' ]] || fail 'authorized_keys: miguel, modo 600'
    [[ $(stat -c '%U %a' /home/miguel/.google_authenticator 2>/dev/null) == 'miguel 600' ]] || fail 'Configurar TOTP como miguel y permisos 600'
    grep -q '^" TOTP_AUTH$' /home/miguel/.google_authenticator || fail 'El autenticador debe usar TOTP'
}
check_cidrs() {
    [[ -n ${ADMIN_CIDRS:-} ]] || fail 'Definir ADMIN_CIDRS (IPv4/IPv6 separados por espacios)'
    python3 - "$ADMIN_CIDRS" "${SSH_CONNECTION:-}" <<'PY'
import ipaddress, sys
nets = [ipaddress.ip_network(v, strict=True) for v in sys.argv[1].split()]
if not nets or any(n.prefixlen == 0 for n in nets):
    sys.exit("ADMIN_CIDRS no puede contener la ruta universal")
if sys.argv[2] and not any(ipaddress.ip_address(sys.argv[2].split()[0]) in n for n in nets):
    sys.exit("La IP de esta sesion no esta incluida en ADMIN_CIDRS")
PY
}
write_ssh_config() {
    cat > "$state/sshd.conf" <<'EOF'
Port 4040
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication yes
AuthenticationMethods publickey,keyboard-interactive:pam
UsePAM yes
AllowUsers miguel
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
Subsystem sftp internal-sftp
EOF
    /usr/sbin/sshd -t -f "$state/sshd.conf"
}
stage_ssh() {
    check_admin
    check_cidrs
    write_ssh_config
    # PAM es compartido por los dos daemons. Guardar el original antes del cambio.
    if [[ ! -f $state/pam-sshd.original ]]; then
        cp -a /etc/pam.d/sshd "$state/pam-sshd.original"
    fi
    if ! grep -qx 'auth required pam_google_authenticator.so' /etc/pam.d/sshd; then
        grep -Eq '^@include[[:space:]]+common-auth$' /etc/pam.d/sshd || fail 'PAM no estandar: revisar antes de continuar'
        sed -i 's/^@include[[:space:]]\+common-auth$/auth required pam_google_authenticator.so/' /etc/pam.d/sshd
    fi
    for cidr in $ADMIN_CIDRS; do ufw allow from "$cidr" to any port 4040 proto tcp; done
    cat > /etc/systemd/system/laravel-ssh-test.service <<EOF
[Unit]
Description=Prueba SSH ED25519 y TOTP en 4040
After=network.target
[Service]
ExecStart=/usr/sbin/sshd -D -f $state/sshd.conf
Restart=on-failure
KillMode=process
EOF
    systemctl daemon-reload
    systemctl start laravel-ssh-test.service
    printf 'Abre una SEGUNDA sesion: ssh -p 4040 miguel@IP_VPS\n'
    printf 'Prueba sudo -v. Ejecuta lockdown desde esa sesion manteniendo abierta la original.\n'
}

if [[ $1 == prepare ]]; then
    check_docker_origin
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
    add-apt-repository -y universe
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        htop nano git curl ca-certificates openssl jq unzip rsync lsof bash-completion \
        iproute2 iputils-ping dnsutils net-tools traceroute mtr-tiny \
        ufw fail2ban chrony unattended-upgrades libpam-google-authenticator \
        restic docker.io docker-compose-v2 docker-buildx openssh-server apparmor apparmor-utils python3
    systemctl enable --now docker.service chrony.service fail2ban.service
    docker version
    docker compose version
    [[ $(docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}') == 'systemd 2' ]] || fail 'Docker debe usar systemd y cgroups v2'
    chronyc waitsync 30 0.1
    aa-enabled
    id miguel >/dev/null 2>&1 || useradd --create-home --shell /bin/bash miguel
    [[ $(getent passwd miguel | cut -d: -f6-7) == /home/miguel:/bin/bash ]] || fail 'Home/shell inesperados'
    usermod -aG sudo miguel
    ! id -nG miguel | tr ' ' '\n' | grep -qx docker || fail 'Retirar miguel de docker manualmente'
    # Los timers root ejecutan scripts de este directorio; no debe ser escribible por miguel.
    install -d -o root -g miguel -m 0750 /srv/laravel-stack
    [[ -z $(find /srv/laravel-stack -mindepth 1 \( ! -user root -o \( ! -type l -a -perm /022 \) \) -print -quit) ]] \
        || fail 'El despliegue debe pertenecer a root y no permitir escritura a grupo/otros'
    runuser -u miguel -- env HOME=/home/miguel git config --global user.name miguel
    runuser -u miguel -- env HOME=/home/miguel git config --global user.email miguel2006ngl@gmail.com
    runuser -u miguel -- env HOME=/home/miguel git config --global core.editor nano
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    cat > /etc/apt/apt.conf.d/52laravel-security <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    # Swap pertenece al host. No crear ni redimensionar swap durante deploy.
    printf 'vm.overcommit_memory=1\n' > /etc/sysctl.d/60-laravel.conf
    sysctl --system >/dev/null
    install -d -m 0755 /var/lib/laravel-backup-status
    cat > /etc/systemd/system/laravel-backup.service <<'EOF'
[Unit]
Description=Backup diario de Laravel con Restic
Requires=docker.service
After=docker.service network-online.target
ConditionPathExists=/etc/laravel-backup.env
[Service]
Type=oneshot
EnvironmentFile=/etc/laravel-backup.env
WorkingDirectory=/srv/laravel-stack
ExecStart=/bin/bash /srv/laravel-stack/docker/backup.sh backup
UMask=0077
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=6h
EOF
    cat > /etc/systemd/system/laravel-backup.timer <<'EOF'
[Unit]
Description=Backup diario de Laravel
[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/laravel-backup-check.service <<'EOF'
[Unit]
Description=Verificacion semanal del repositorio Restic
After=network-online.target
ConditionPathExists=/etc/laravel-backup.env
[Service]
Type=oneshot
EnvironmentFile=/etc/laravel-backup.env
WorkingDirectory=/srv/laravel-stack
ExecStart=/bin/bash /srv/laravel-stack/docker/backup.sh check
UMask=0077
Nice=10
TimeoutStartSec=12h
EOF
    cat > /etc/systemd/system/laravel-backup-check.timer <<'EOF'
[Timer]
OnCalendar=Sun *-*-* 05:00:00
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now laravel-backup.timer laravel-backup-check.timer
    if [[ -e /var/run/reboot-required ]]; then
        printf 'REINICIO REQUERIDO. Reinicia manualmente antes de deploy o lockdown.\n'
        exit 2
    fi
    if [[ -e $state/locked ]]; then
        printf 'Host preparado; SSH ya esta bloqueado.\n'
    elif [[ -s /home/miguel/.google_authenticator && -n ${ADMIN_CIDRS:-} ]]; then
        stage_ssh
    else
        printf 'Configura passwd miguel, su llave ED25519 y TOTP con: sudo -iu miguel google-authenticator\n'
        printf 'Despues repite prepare con ADMIN_CIDRS para iniciar la prueba SSH en 4040.\n'
    fi
    exit 0
fi

[[ ! -e /var/run/reboot-required ]] || fail 'Reiniciar primero; no se modificara SSH'
check_admin
check_cidrs
connection=${SSH_CONNECTION:-}
[[ ${SUDO_USER:-} == miguel && ${connection##* } == 4040 ]] || fail 'Ejecutar desde la segunda sesion SSH de miguel en 4040'
[[ -s $state/pam-sshd.original ]] || fail 'Completar antes la prueba de prepare'
if [[ -e $state/locked ]]; then
    /usr/sbin/sshd -t
    printf 'Lockdown ya aplicado.\n'
    exit 0
fi
systemctl is-active --quiet laravel-ssh-test.service || fail 'Falta daemon SSH de prueba'
[[ ! -e /etc/ssh/sshd_config.d/00-laravel.conf ]] || fail 'Ya existe 00-laravel.conf; revisar su procedencia'
write_ssh_config
# Recuperacion automatica si la recarga, firewall o nueva conexion fallan.
cp -a /etc/ssh/sshd_config "$state/sshd_config.original"
install -d "$state/ufw.original" "$state/jail.original"
rsync -a --delete /etc/ufw/ "$state/ufw.original/"
cp -a /etc/default/ufw "$state/ufw-default.original"
rsync -a --delete /etc/fail2ban/jail.d/ "$state/jail.original/"
systemctl is-enabled ssh.socket > "$state/socket-state" 2>/dev/null || true
cat > "$state/rollback.sh" <<'EOF'
#!/bin/bash
set -eu
state=/var/lib/laravel-host
cp -a "$state/sshd_config.original" /etc/ssh/sshd_config
rm -f /etc/ssh/sshd_config.d/00-laravel.conf
cp -a "$state/pam-sshd.original" /etc/pam.d/sshd
ufw --force disable
cp -a "$state/ufw.original/." /etc/ufw/
cp -a "$state/ufw-default.original" /etc/default/ufw
if grep -qx ENABLED=yes /etc/ufw/ufw.conf; then ufw --force enable; fi
rm -f /etc/fail2ban/jail.d/laravel-sshd.local
cp -a "$state/jail.original/." /etc/fail2ban/jail.d/
systemctl restart fail2ban.service
systemctl daemon-reload
if grep -qx enabled "$state/socket-state"; then systemctl enable --now ssh.socket; fi
systemctl restart ssh.service
rm -f "$state/locked"
EOF
chmod 0700 "$state/rollback.sh"
systemd-run --collect --unit=laravel-ssh-rollback --on-active=5m \
    --timer-property=RemainAfterElapse=no /bin/bash "$state/rollback.sh"
install -m 0644 "$state/sshd.conf" /etc/ssh/sshd_config.d/00-laravel.conf
printf 'Include /etc/ssh/sshd_config.d/00-laravel.conf\n' > /etc/ssh/sshd_config
/usr/sbin/sshd -t
[[ $(/usr/sbin/sshd -T | awk '$1 == "port" {print $2}') == 4040 ]] || fail 'Puerto efectivo inesperado'
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl stop laravel-ssh-test.service
systemctl enable ssh.service
systemctl restart ssh.service
# Este VPS es dedicado: sustituir las reglas de entrada anteriores.
ufw --force reset
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
for cidr in $ADMIN_CIDRS; do ufw allow from "$cidr" to any port 4040 proto tcp; done
ufw --force enable
cat > /etc/fail2ban/jail.d/laravel-sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
port = 4040
maxretry = 3
findtime = 10m
bantime = 1h
banaction = ufw
EOF
fail2ban-client -t
systemctl restart fail2ban.service
touch "$state/locked"
printf 'Abre OTRA sesion nueva en 4040, prueba sudo y cancela la recuperacion antes de 5 minutos:\n'
printf 'sudo systemctl stop laravel-ssh-rollback.timer\n'
printf 'Conservar consola del proveedor y codigos TOTP fuera del VPS.\n'
