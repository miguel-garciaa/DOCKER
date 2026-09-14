# Laravel con Docker Compose

El stack ejecuta Laravel Octane/FrankenPHP, PostgreSQL, Redis, Nginx,
Cloudflare Tunnel, Prometheus, node-exporter y cAdvisor. No publica puertos del
VPS: Cloudflare llega a Nginx por la red privada de Docker.

Nginx es el proxy y balanceador del stack. FrankenPHP conserva su servidor
interno basado en Caddy únicamente para ejecutar Laravel Octane dentro de cada
contenedor de aplicación.

## Despliegue

Solo se utiliza `deploy.sh`. El script actualiza Ubuntu, instala los paquetes
básicos, configura SSH, UFW, Fail2ban, Docker y finalmente despliega la
aplicación.

Primera ejecución:

```bash
cd ~/DOCKER
cp .env.example .env
nano .env
sudo ./deploy.sh
```

El archivo `.env` debe estar completo antes de ejecutar el script. El
despliegue no crea ni modifica sus variables.

El acceso SSH queda configurado para el usuario `miguel`, usando su contraseña
normal y el puerto 4040. El acceso de root queda deshabilitado. Mantén abierta
la sesión actual hasta comprobar una segunda conexión:

```bash
ssh miguel@IP_DEL_SERVIDOR -p 4040
```

Estado de SSH, firewall y bloqueos:

```bash
sudo systemctl status ssh --no-pager
sudo ufw status verbose
sudo fail2ban-client status sshd
```

Para retirar un bloqueo accidental de tu IP:

```bash
sudo fail2ban-client set sshd unbanip TU_IP
```

Completa todas las variables obligatorias de `.env` antes de desplegar.

Configura al menos estas variables:

```dotenv
APP_DOMAIN=comput.uk
APP_KEY=
DB_PASSWORD=
POSTGRES_PASSWORD=
REDIS_PASSWORD=
RESEND_KEY=TOKEN_RESEND
MAIL_FROM_ADDRESS=no-reply@comput.uk
FILAMENT_ADMIN_EMAIL=admin@comput.uk
TUNNEL_TOKEN=TOKEN_CLOUDFLARE
METRICS_DOMAIN=metrics.comput.uk
METRICS_USERNAME=grafana
METRICS_PASSWORD_HASH='$2y$...'
```

Genera el hash de la contraseña de Grafana con el siguiente comando y cópialo
completo en `METRICS_PASSWORD_HASH`, entre comillas simples:

```bash
htpasswd -nbB grafana 'TU_CONTRASEÑA' | cut -d: -f2
```

Google OAuth es opcional. No ejecutes `.env` con `source` y no lo subas a Git.

En el túnel administrado de Cloudflare configura los dos hostnames con el mismo
servicio privado:

| Hostname | Servicio |
|---|---|
| `comput.uk` | `http://nginx:8000` |
| `metrics.comput.uk` | `http://nginx:8000` |

Después ejecuta el mismo comando:

```bash
sudo ./deploy.sh
```

También se utiliza para actualizaciones posteriores. Los volúmenes de
PostgreSQL, Redis, uploads y Prometheus se conservan entre despliegues.

## Operación básica

```bash
sudo docker compose ps
sudo docker compose logs -f --tail=100
sudo docker compose restart
sudo docker compose exec app-1 php artisan about
```

Las métricas están en `https://metrics.comput.uk` con Basic Auth. Configura esa
URL como datasource Prometheus en Grafana.

## Backups cifrados

Genera una clave de cifrado y muestra su clave pública:

```bash
cd ~
age-keygen -o backup-age-key.txt
age-keygen -y backup-age-key.txt
```

Copia `backup-age-key.txt` a un lugar seguro fuera del VPS y elimínalo del
servidor. Copia únicamente la clave pública `age1...` en `~/DOCKER/.env`:

```dotenv
BACKUP_AGE_RECIPIENT=age1...
BACKUP_RETENTION_DAYS=30
```

Ejecuta el backup:

```bash
sudo ./docker/backup.sh
```

Las copias quedan en `/var/lib/.laravel-backups/YYYY-MM-DD/`, separadas en
`database`, `laravel`, `system` y `logs`. Cada archivo está comprimido y cifrado.

Para comprobar un dump sin restaurarlo:

```bash
age --decrypt -i backup-age-key.txt \
  /var/lib/.laravel-backups/YYYY-MM-DD/database/database-HH-MM-SS.dump.age \
  | sudo docker compose exec -T postgres pg_restore --list
```
