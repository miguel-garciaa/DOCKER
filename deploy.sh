#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

SSH_USER=miguel
SSH_PORT=4040

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta este script con: sudo ./deploy.sh"
    exit 1
fi

echo "[1/7] Actualizando Ubuntu"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt update
apt upgrade -y

echo "[2/7] Instalando paquetes básicos y servicios"
apt install -y \
    htop nano git curl wget unzip zip jq rsync tree tmux lsof \
    ca-certificates gnupg openssl bash-completion \
    iproute2 iputils-ping dnsutils net-tools \
    openssh-server ufw fail2ban unattended-upgrades \
    apparmor apparmor-utils chrony python3-systemd \
    docker.io docker-compose-v2 apache2-utils age

systemctl enable --now docker chrony apparmor

echo "[3/7] Preparando el usuario $SSH_USER"
if ! id "$SSH_USER" >/dev/null 2>&1; then
    adduser --gecos "" "$SSH_USER"
fi

usermod -aG sudo "$SSH_USER"
gpasswd -d "$SSH_USER" docker >/dev/null 2>&1 || true

if [[ $(passwd -S "$SSH_USER" | awk '{print $2}') != P ]]; then
    echo "Configura ahora la contraseña de $SSH_USER"
    passwd "$SSH_USER"
fi

echo "[4/7] Configurando SSH en el puerto $SSH_PORT"
install -d -m 700 /var/backups/laravel-host

if [[ ! -f /var/backups/laravel-host/sshd_config.original ]]; then
    cp -a /etc/ssh/sshd_config /var/backups/laravel-host/sshd_config.original
    cp -a /etc/pam.d/sshd /var/backups/laravel-host/pam-sshd.original
fi

# Elimina el requisito TOTP anterior y restaura la autenticación normal de Ubuntu.
sed -i '/pam_google_authenticator\.so/d' /etc/pam.d/sshd
if ! grep -Eq '^@include[[:space:]]+common-auth$' /etc/pam.d/sshd; then
    sed -i '1a @include common-auth' /etc/pam.d/sshd
fi

cat > /etc/ssh/sshd_config.d/00-laravel.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PermitEmptyPasswords no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
AuthenticationMethods any
UsePAM yes
AllowUsers $SSH_USER
MaxAuthTries 5
LoginGraceTime 30
MaxSessions 4
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
UseDNS no
LogLevel VERBOSE
EOF

grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

mkdir -p /run/sshd
ssh-keygen -A
/usr/sbin/sshd -t

SSHD_EFFECTIVE=$(/usr/sbin/sshd -T)
[[ $(awk '$1 == "port" {print $2}' <<< "$SSHD_EFFECTIVE" | paste -sd " ") == "$SSH_PORT" ]] \
    || { echo "SSH tiene otro puerto configurado además de $SSH_PORT"; exit 1; }
grep -qx "permitrootlogin no" <<< "$SSHD_EFFECTIVE"
grep -qx "passwordauthentication yes" <<< "$SSHD_EFFECTIVE"
grep -qx "allowusers $SSH_USER" <<< "$SSHD_EFFECTIVE"

echo "[5/7] Configurando UFW y Fail2ban"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment SSH
ufw --force enable

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 1w
banaction = ufw
EOF

fail2ban-client -t
systemctl enable fail2ban
systemctl restart fail2ban
fail2ban-client status sshd >/dev/null

# Retira cualquier daemon de prueba que hubiera dejado la configuración TOTP.
systemctl stop laravel-ssh-test.service 2>/dev/null || true
systemctl stop laravel-ssh-rollback.timer laravel-ssh-rollback.service 2>/dev/null || true
rm -f /etc/systemd/system/laravel-ssh-test.service
systemctl daemon-reload

# Ubuntu puede activar SSH mediante ssh.socket en el puerto 22.
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service

if ! systemctl restart ssh.service; then
    systemctl enable --now ssh.socket 2>/dev/null || true
    echo "No se pudo reiniciar SSH. Se ha reactivado ssh.socket."
    exit 1
fi

if ! ss -lnt | grep -q ":$SSH_PORT "; then
    systemctl enable --now ssh.socket 2>/dev/null || true
    echo "SSH no está escuchando en el puerto $SSH_PORT."
    exit 1
fi
if ss -lnt | grep -q ":22 "; then
    echo "El puerto SSH 22 sigue activo. Revisa los servicios SSH instalados."
    exit 1
fi
ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
ufw --force delete allow OpenSSH >/dev/null 2>&1 || true

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/52laravel-unattended-upgrades <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

echo "[6/7] Comprobando .env"
if [[ ! -f .env ]]; then
    cp .env.example .env
    chmod 600 .env
    echo "Se ha creado .env. Edítalo con: nano .env"
    echo "Después ejecuta otra vez: sudo ./deploy.sh"
    exit 1
fi

chmod 600 .env

echo "[7/7] Desplegando los contenedores"
docker compose --env-file .env up -d --build --wait --remove-orphans
docker compose --env-file .env exec -T app-1 php artisan migrate --force --no-interaction
docker compose --env-file .env ps

echo
echo "Deploy completado"
echo "SSH: ssh $SSH_USER@IP_DEL_SERVIDOR -p $SSH_PORT"
echo "Mantén abierta esta sesión hasta comprobar el nuevo acceso."
