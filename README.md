# Laravel en un VPS Ubuntu 26.04

Diez servicios: Caddy, app-1, app-2, queue, PostgreSQL, Redis, cloudflared, Prometheus, node-exporter y cAdvisor. Cuatro redes: edge, application, data y monitoring. Las dos últimas son internas. Ningún servicio publica puertos.

Laravel, Filament, React, Vite/Wayfinder, Fortify, passkeys y Socialite están en `laravel/`. El Dockerfile tiene tres etapas y ejecuta FrankenPHP/Octane como www-data (UID 33), sin herramientas de build en runtime. Los dos servidores web y queue comparten únicamente uploads; sus cachés viven en tmpfs. No hay tareas programadas Laravel actualmente.

Caddy usa un build inline de dos instrucciones que retira la capability del binario oficial; permite ejecutarlo como usuario 1000 con todas las capabilities eliminadas, sin otro Dockerfile.

## Preparar el host

En un VPS dedicado Ubuntu Server 26.04 LTS actualizado:

```bash
sudo bash setup-host.sh prepare
```

Instala Docker y Compose desde Ubuntu, nunca Snap ni Docker CE. Detecta conflictos antes de actualizar paquetes. No añade miguel al grupo docker, no configura NOPASSWD y no reinicia el servidor. Si devuelve código 2 por `reboot-required`, reinicia manualmente y repite prepare.

Configura una contraseña local para sudo e instala **tu clave pública**, nunca la privada:

```bash
sudo passwd miguel
sudo install -d -o miguel -g miguel -m 700 /home/miguel/.ssh
sudo install -o miguel -g miguel -m 600 /ruta/a/authorized_keys /home/miguel/.ssh/authorized_keys
sudo -iu miguel google-authenticator
sudo chmod 600 /home/miguel/.google_authenticator
```

Usa TOTP con prevención de reutilización y límite de intentos. Guarda los códigos de recuperación fuera de la VPS y comprueba la consola del proveedor. Cada VPS tendrá su propio TOTP.

Repite prepare con tus rangos administrativos reales (los siguientes son ejemplos):

```bash
sudo env ADMIN_CIDRS="203.0.113.10/32 2001:db8:1234::/64" \
  SSH_CONNECTION="$SSH_CONNECTION" bash setup-host.sh prepare
```

Cuando existen contraseña, llave y TOTP, prepare arranca un daemon de prueba en 4040. Conserva el puerto SSH anterior. Cambia exclusivamente el bloque auth de PAM SSH a TOTP, sin modificar PAM sudo; a partir de ese momento una autenticación SSH interactiva anterior también queda sujeta a TOTP. Si UFW estaba desactivado, la prueba no lo habilita: restringe también 4040 en el firewall del proveedor durante esta fase.

Abre una segunda terminal, comprueba llave + TOTP y `sudo -v`:

```bash
ssh -p 4040 miguel@IP_VPS
sudo -v
cd /srv/laravel-stack
sudo env ADMIN_CIDRS="203.0.113.10/32 2001:db8:1234::/64" \
  SSH_CONNECTION="$SSH_CONNECTION" bash setup-host.sh lockdown
```

Lockdown exige esa sesión de miguel en 4040. Sustituye la configuración SSH activa y las reglas UFW del VPS dedicado, permite exclusivamente miguel por llave + TOTP, desactiva root/contraseñas/puertos anteriores y ajusta Fail2ban. Desactiva ssh.socket para evitar listeners heredados de la activación por socket.

Tiene recuperación automática a los cinco minutos. Abre **otra conexión nueva**, prueba sudo y cancela el temporizador:

```bash
sudo systemctl stop laravel-ssh-rollback.timer
sudo sshd -t
sudo sshd -T
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo ss -lntup
```

Si pierdes acceso, espera la recuperación y utiliza la consola del proveedor. Las copias originales se guardan en `/var/lib/laravel-host`. La prueba no es una simulación del host: validar prepare dos veces y lockdown en un VPS de ensayo antes de producción.

## Secretos y Cloudflare

Trabaja con Git como miguel en su home. La identidad configurada es miguel <miguel2006ngl@gmail.com>; la autenticación Git se configura por separado. Instala el checkout revisado en `/srv/laravel-stack` con propietario root: los timers ejecutan scripts como root y los secretos no deben poder sustituirse renombrando archivos desde una cuenta sin sudo.

```bash
# Después de clonar y revisar el repositorio en /home/miguel/laravel-stack:
sudo rsync -a --chown=root:root --chmod=D755,F644 \
  --exclude .git --exclude '.env' --exclude node_modules --exclude vendor \
  /home/miguel/laravel-stack/ /srv/laravel-stack/
sudo chown root:miguel /srv/laravel-stack
sudo chmod 750 /srv/laravel-stack
```

```bash
cd /srv/laravel-stack
sudo install -o root -g root -m 600 .env.example .env
openssl rand -base64 32       # APP_KEY: anteponer base64:
openssl rand -hex 32          # DB_PASSWORD
openssl rand -hex 32          # POSTGRES_PASSWORD, generar de nuevo
openssl rand -hex 32          # REDIS_PASSWORD, generar de nuevo
sudo docker run --rm -it caddy:2.11.2-alpine caddy hash-password
sudo nano .env
```

Completa todos los campos vacíos. Guarda el hash bcrypt en `METRICS_PASSWORD_HASH` **entre comillas simples**; la contraseña original solo la necesita Grafana. Nunca ejecutes .env con source/eval ni publiques la salida de `docker compose config`: contiene secretos. Los procesos Docker autorizados como root también pueden inspeccionar el entorno.

Configura en Cloudflare Tunnel dos hostnames, ambos con servicio `http://caddy:8000`:

| Hostname | Destino |
|---|---|
| APP_DOMAIN | Aplicación |
| METRICS_DOMAIN | Prometheus con Basic Auth |

Conserva el Host original. No configures el túnel hacia PostgreSQL, Redis, los exporters ni el puerto interno 9101. Activa HTTPS en Cloudflare y una regla de bypass de caché para METRICS_DOMAIN. Permite salida TCP/UDP 7844 y DNS desde la VPS; no abras 80, 443, 9090, 5432 ni 6379.

Grafana: datasource Prometheus con URL `https://METRICS_DOMAIN`, Basic Auth y validación TLS activada. El tráfico remoto viaja por HTTPS y el túnel cifrado; el salto cloudflared–Caddy y los scrapes son HTTP dentro del host.

Caddy resuelve la IP exacta de cloudflared al arrancar y sobrescribe X-Forwarded-For con CF-Connecting-IP validada. Laravel resuelve Caddy en cada petición para soportar Octane y cambios de IP. Después de recrear cloudflared, recrea Caddy mediante deploy.sh. Un reinicio normal conserva las IPs; una recreación fuera del script exige esa misma operación.

## Desplegar

Reserva RAM para el kernel, Docker y backups fuera del límite del proyecto. PROJECT_MEMORY no debe ocupar toda la RAM física. PROJECT_SWAP limita consumo, no crea swap: usa 0 si la VPS no tiene swap, o provisiona swap antes. No uses huge pages sin medir.

```bash
sudo bash deploy.sh
```

Valida secretos, construye una sola imagen, valida Caddy/Prometheus, levanta datos, prueba credenciales, migra una vez, actualiza app-1/app-2 de forma secuencial y arranca el resto. No instala paquetes ni modifica APT. La slice systemd aplica CPU, RAM y swap conjuntamente a los diez servicios; los temporales de Compose heredan el mismo parent.

Las migraciones deben ser compatibles con el código web y worker anterior. El deploy no revierte migraciones ni promete cero interrupciones: recrear Caddy produce una pausa breve. Usa expansión/contracción del esquema para cambios incompatibles y realiza un backup antes de migraciones importantes.

No se eliminan automáticamente contenedores huérfanos ni volúmenes. Revisa la transición de la versión anterior antes del primer despliegue. La etiqueta local APP_IMAGE se construye en el VPS; `publish-image.sh` es una utilidad opcional de publicación y requiere un checkout limpio.

## Transición desde el stack anterior

Antes de sustituir los archivos de una instalación existente, guarda su Compose/.env, haz un backup verificado y detén el Compose anterior con `docker compose down` **sin -v**. Esto elimina sus contenedores y redes, conservando los volúmenes. Comprueba antes que todas las colas hayan drenado; el backup diario no incluye Redis ni garantiza conservar trabajos pendientes.

Mantén COMPOSE_PROJECT_NAME y los nombres de volúmenes. Renombra PROMETHEUS_DOMAIN/USERNAME/PASSWORD_HASH a METRICS_DOMAIN/USERNAME/PASSWORD_HASH y elimina las variables Reverb. No cambies contraseñas PostgreSQL esperando que el init script actualice una BD ya creada.

La aplicación anterior escribía con UID 10001. Tras detenerla y construir la nueva imagen, adapta **solo** el volumen de uploads existente:

```bash
sudo docker compose build app-1
sudo bash docker/project-limits.sh laravel 4 6G 0
sudo docker volume inspect laravel_uploads
sudo docker run --rm --network none --user 0 --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true \
  --cgroup-parent project-laravel.slice \
  -v laravel_uploads:/uploads --entrypoint chown laravel-app:local -R 33:33 /uploads
sudo bash deploy.sh
```

Sustituye proyecto/imagen/límites si no usas los defaults. No arranques esta versión contra volúmenes de otra versión mayor de PostgreSQL; requiere pg_dump/restore o pg_upgrade planificado.

## Backups y restauración

Prepare instala timers diarios y semanales. Hasta configurar Restic, sus servicios se omiten y Prometheus advierte de backups ausentes. Crea un repositorio **fuera de la VPS**, con contraseña única; el ejemplo usa SFTP con llave root y host key previamente verificada:

```bash
sudo install -m 600 /dev/null /etc/laravel-backup.env
sudo install -m 600 /dev/null /etc/laravel-restic-password
sudo nano /etc/laravel-restic-password
sudo nano /etc/laravel-backup.env
```

Contenido del EnvironmentFile systemd:

```dotenv
RESTIC_REPOSITORY=sftp:backup@backup.example.com:/backups/cliente
RESTIC_PASSWORD_FILE=/etc/laravel-restic-password
```

Inicializa una vez; no desactives la comprobación de host SSH:

```bash
sudo systemd-run --wait --pipe --collect \
  --property=EnvironmentFile=/etc/laravel-backup.env /usr/bin/restic init
sudo systemctl start laravel-backup.service
sudo systemctl start laravel-backup-check.service
sudo systemctl list-timers 'laravel-backup*'
sudo journalctl -u laravel-backup.service -u laravel-backup-check.service
```

El backup usa pg_dump consistente, copia uploads, código/configuración/.env y cifra todo con Restic. Retiene los snapshots de 30 días; verifica semanalmente todos los bloques. Necesita espacio local para el dump y una copia de uploads. No es una transacción conjunta entre BD y archivos: para una restauración con correspondencia estricta, detén escrituras web/queue durante el backup planificado. El timestamp del último backup y verificación se exporta a node-exporter.

Prueba de restauración **en otro VPS vacío**, sin conectar todavía el túnel público:

```bash
sudo systemd-run --wait --pipe --collect \
  --property=EnvironmentFile=/etc/laravel-backup.env \
  /usr/bin/restic restore latest --tag laravel --target /srv/restore-test
sudo rsync -a /srv/restore-test/srv/laravel-stack/ /srv/laravel-stack/
cd /srv/laravel-stack
sudo chmod 600 .env
# Revisar dominios/tokens para que este ensayo nunca suplante produccion.
sudo nano .env
sudo bash docker/project-limits.sh laravel 4 6G 0
sudo docker compose build app-1
sudo docker compose up -d --wait postgres redis
sudo sh -c 'cat /srv/restore-test/var/lib/laravel-backup/database.dump' | \
  sudo docker compose exec -T postgres sh -c \
  'pg_restore -U "$DB_USERNAME" -d "$DB_DATABASE" --exit-on-error --no-owner --no-acl'
sudo docker compose run --rm --no-deps -T --user 0 \
  --cap-add CHOWN --cap-add DAC_OVERRIDE \
  -v /srv/restore-test/var/lib/laravel-backup/uploads:/restore:ro \
  app-1 sh -c 'cp -a /restore/. /app/storage/app/ && chown -R 33:33 /app/storage/app'
sudo docker compose up -d --wait app-1 app-2 queue
sudo docker compose exec -T app-1 php /app/docker/check-services.php
sudo docker compose exec -T app-1 php /app/docker/health.php
```

Verifica usuarios, registros y una muestra de uploads, registra duración/RPO/RTO y solo entonces conecta el túnel del ensayo. Este procedimiento presupone BD vacía; no restaura encima de producción.

## Operación y límites

- Un único VPS, PostgreSQL, Redis, Caddy y túnel siguen siendo puntos únicos de fallo. Dos procesos web no proporcionan alta disponibilidad del host.
- restart: unless-stopped recupera procesos caídos y servicios tras reiniciar Docker; un healthcheck unhealthy no reinicia por sí solo un contenedor. Caddy retira réplicas web enfermas. Los servicios detenidos manualmente permanecen detenidos.
- Octane usa dos workers por réplica y recicla tras 1000 peticiones. Queue recicla cada hora, timeout 60s y retry_after 120s. Los jobs deben ser idempotentes.
- PostgreSQL: 60 conexiones, 256 MB de shared_buffers; Redis: AOF everysec, noeviction y 256 MB configurables. El AOF puede perder el último segundo; Redis lleno rechaza escrituras, incluyendo sesiones y colas. Medir antes de ampliar o separar.
- Prometheus: scrape cada 30s, 7 días/2 GB, cuatro consultas concurrentes. Grafana consulta Prometheus, no almacena sus métricas. Sus reglas locales no envían notificaciones: configura alertas/contact points en Grafana, incluida la pérdida total de la datasource.
- Node-exporter mide CPU, RAM y discos del host. Desactiva colectores de red que reportarían el namespace Docker; el tráfico por contenedor lo mide cAdvisor.
- cAdvisor es una excepción privilegiada con acceso de alto riesgo al host y al socket Docker. Un montaje :ro del socket no convierte su API en lectura solamente. Los exporters comparten monitoring según el plan.
- No hay exporters específicos de PostgreSQL/Redis: los diez servicios cubren host, contenedores, proxy y túnel; latencia SQL, conexiones y memoria Redis requieren consultas operativas o instrumentación adicional.
- Google OAuth se habilita al completar GOOGLE_CLIENT_ID/SECRET y registrar `https://APP_DOMAIN/auth/google/callback`. Solo acceden usuarios locales ya verificados con Gmail o Workspace verificado. No crea cuentas automáticamente y conserva el desafío TOTP local. Resend necesita remitente/dominio verificado.
- Revisa periódicamente etiquetas de imágenes y lockfiles. Las etiquetas explícitas siguen siendo mutables; reproducen dependencias de aplicación mediante locks, pero no equivalen a digests inmutables.

## Validación y desarrollo

```bash
cd laravel
cp .env.example .env
composer install
php artisan key:generate
npm ci
composer run ci:check
php artisan serve
# En otra terminal, desde laravel:
npm run dev
```

Desde la raíz, con Caddy 2.11.2, promtool y ShellCheck disponibles:

```bash
shellcheck setup-host.sh deploy.sh publish-image.sh docker/*.sh laravel/docker/entrypoint.sh
node laravel/tests/Infrastructure/proxy.mjs /ruta/a/caddy
promtool check config --syntax-only docker/prometheus/prometheus.yml
promtool check rules docker/prometheus/alerts.yml
sudo docker compose config --quiet
sudo docker compose config --services
sudo docker compose config --networks
sudo docker compose ps
sudo systemctl show project-laravel.slice -p CPUQuotaPerSecUSec -p MemoryMax -p MemorySwapMax
curl -I https://APP_DOMAIN/up
curl -I https://METRICS_DOMAIN/api/v1/query?query=up
curl --user grafana 'https://METRICS_DOMAIN/api/v1/query?query=up'
```

La petición sin credenciales debe devolver 401 y la autenticada 200. Completar en staging: prepare repetido, prueba SSH/TOTP, build y runtime readonly, reinicio del VPS, caída de una réplica, aislamiento de redes, desconexión del túnel, consumo de la slice, envío Resend, OAuth real y restauración completa.

Referencias: [SSH Ubuntu](https://ubuntu.com/server/docs/how-to/security/openssh-server/), [Caddy y proxies de confianza](https://caddyserver.com/docs/caddyfile/options), [node-exporter](https://github.com/prometheus/node_exporter).
