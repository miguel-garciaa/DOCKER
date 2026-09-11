# Laravel 13, React y Octane en un VPS con Docker Compose

**FrankenPHP incorpora Caddy**, que recibe HTTP, sirve assets y ejecuta Octane en modo worker. La [integracion oficial de Octane](https://laravel.com/docs/13.x/octane) contempla FrankenPHP en Docker.

```text
Visitante --HTTPS--> Cloudflare --tunel cifrado--> cloudflared
                                                     |
                                        HTTP por red Docker privada
                                                     |
                                          FrankenPHP/Caddy :8000
                                                     |
                                              Laravel Octane
                                                /         \
                                         PostgreSQL 18   Redis 8

queue / scheduler: misma imagen y datos de la aplicacion, procesos independientes.
```

El repositorio incluye una aplicacion Laravel 13 completa basada en el starter oficial de React: React 19, TypeScript, Inertia 3, Tailwind 4, autenticacion, Octane, Filament 5 y Resend. Tambien contiene el build de produccion y los servicios Docker. No usa Vercel, GitHub Actions ni un registry para desplegar.

## Sistema base y frontend

La imagen usa **Debian Bookworm** en las etapas PHP/FrankenPHP y Node, y las variantes Bookworm oficiales de PostgreSQL 18 y Redis 8. Se prioriza compatibilidad con extensiones PHP, bibliotecas del sistema y dependencias npm nativas. Alpine puede reducir el tamaño descargado, pero usa `musl` y puede exigir compilaciones o ajustes especificos; para aplicaciones web de produccion variadas no compensa ese riesgo operativo. La propia [documentacion de FrankenPHP](https://frankenphp.dev/docs/docker/) ofrece ambas variantes y recomienda Debian.

El frontend completo se construye en una etapa separada con **Node.js 24**:

```text
React + TypeScript + HTML/Blade + CSS + Tailwind + Vite
                         |
                    npm ci
                         |
                  npm run build
                         |
                public/build
                         |
        imagen final PHP/FrankenPHP
```

`npm ci` instala las `devDependencies`, donde normalmente estan Vite, TypeScript, Tailwind, PostCSS y sus plugins. `npm run build` transpila TypeScript/JSX, procesa CSS/Tailwind, optimiza los assets y genera el manifiesto de Vite. El codigo Laravel, plantillas Blade/HTML y los assets compilados quedan en la imagen final.

Node y `node_modules` no quedan en la imagen de ejecucion porque una SPA React o una aplicacion Laravel con Vite sirve archivos ya compilados. Esto reduce tamaño y superficie de ataque sin quitar ninguna funcionalidad al frontend. Si una aplicacion concreta usa SSR de React/Inertia o ejecuta un servidor Node en produccion, necesita un servicio Node 24 independiente; no debe incorporarse al proceso de FrankenPHP por defecto.

## Decision de arquitectura

| Aspecto | Instalacion nativa en VPS | Docker en el mismo VPS |
|---|---|---|
| CPU | Acceso al mismo kernel | Tambien comparte el kernel; aislamiento de procesos |
| RAM | Sin daemon Docker/containerd | Añade estos procesos; no duplica un sistema operativo por servicio |
| Latencia | Menos intermediarios | Bridge/red interna añade trabajo; medir p95/p99 para cuantificar |
| Disco de BD | Sistema de archivos del host | Volumen Docker sobre el host; evita escribir la BD en la capa del contenedor |
| Actualizaciones | Paquetes/configuracion del servidor | Imagenes probadas, identificadas por digest y recreacion de procesos |
| Portabilidad | Depende de automatizar el host | Misma imagen de aplicacion en cada servidor |
| Recuperacion | Restaurar datos y reconstruir entorno | Restaurar datos, secretos y referencias de imagen |

Un VPS normalmente ya es una VM. Docker se ejecuta dentro: no estas eliminando la virtualizacion del proveedor. Migraria por repetibilidad y mantenimiento; **no prometeria menos RAM ni mas rendimiento**. El numero de workers, consultas SQL, memoria de PostgreSQL y extensiones PHP pesan mas que la decision de empaquetado. La documentacion explica el [aislamiento de contenedores y su relacion con las VM](https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-a-container/).

Recomiendo FrankenPHP para este caso por su servidor HTTP integrado y la imagen oficial extensible. RoadRunner tambien es valido, especialmente si ya tienes operaciones y pruebas asentadas sobre el. Cambiar de motor debe comprobar compatibilidad de paquetes y rendimiento; no hay un ganador universal.

Caddy mantiene limites de cuerpo/cabeceras, timeouts, bloqueo de dotfiles y PHP directo, cabeceras basicas, restriccion de host y acceso exclusivo desde cloudflared.

**Un contenedor no corrige XSS, IDOR, SQL injection ni fallos de autorizacion.** Comparte kernel con el host y no es una frontera equivalente a otra VM. Aqui no hay puertos publicados, Docker socket, modo privilegiado ni usuarios root en los servicios. `cloudflared` puede llegar a la app, pero no pertenece a la red de PostgreSQL/Redis. La app conserva salida a Internet para Resend y APIs: la separacion de redes no es un firewall de salida completo. El usuario con acceso al daemon Docker tiene privilegios elevados sobre el host.

## Archivos

```text
Dockerfile                       # PHP, Composer y Vite en etapas separadas
docker-compose.yml               # todos los servicios del proyecto
deploy.sh                        # bootstrap y despliegue
.env.example                     # referencia; deploy genera .env
.dockerignore / .gitignore / .gitattributes
app/ bootstrap/ config/ routes/  # aplicacion Laravel 13
resources/                       # React, TypeScript y Tailwind
composer.lock / package-lock.json
docker/
  Caddyfile                      # HTTP interno, assets y Octane
  php.ini
  entrypoint.sh                  # web, queue y scheduler
  health.php / check-services.php
  postgres-init.sh / redis-start.sh
  project-limits.sh              # presupuesto CPU/RAM comun mediante systemd
```

`bootstrap/app.php` ya habilita `/up` y confia exclusivamente en la IP fija de `cloudflared` para `X-Forwarded-For` y `X-Forwarded-Proto`. El acceso a `/admin` exige que el email del usuario coincida con `FILAMENT_ADMIN_EMAIL`.

Antes de desplegar cambios ejecuta:

```bash
composer ci:check
```

Este comando ejecuta tests, Pint, PHPStan, comprobaciones TypeScript, formato y el build frontend configurados en el proyecto.

## Construccion local

`deploy.sh` construye en el VPS una unica imagen local llamada `laravel-app:local`. Los servicios web, migraciones, colas y scheduler reutilizan exactamente esa imagen; Node, npm, Composer y las dependencias de compilacion no quedan en la etapa final.

Para construir sin desplegar:

```bash
docker compose --env-file .env build app
```

El build utiliza locks, `composer install --no-dev`, Node 24, `npm ci`, assets compilados y cache de descargas. No se hace `config:cache` con secretos durante la construccion: se ejecuta al arrancar cada proceso con su entorno real. El codigo permanece de solo lectura y no se monta el repositorio del host sobre `/app`.

Para reconstrucciones reproducibles tambien fija `PHP_IMAGE`, `COMPOSER_IMAGE` y `NODE_IMAGE` mediante `--build-arg NOMBRE=imagen@sha256:...`. Programa actualizaciones probadas de esas referencias. Las etiquetas por defecto facilitan el primer build, pero por si solas no son inmutables. No pases secretos como `ARG` ni como `VITE_*`.

## Preparar Cloudflare: una vez por aplicacion/VPS

En un tunel administrado remotamente crea una ruta publica:

```text
Hostname:  app.tudominio.com
Service:   http://app:8000
```

`app` es el nombre DNS del servicio Docker. **No uses `localhost:8000`**, que dentro de `cloudflared` apuntaria al propio conector. El token permite conectar el tunel; no crea por si solo DNS ni su configuracion remota. [Configuracion oficial](https://developers.cloudflare.com/tunnel/setup/).

Activa redireccion a HTTPS en Cloudflare. El tramo publico usa HTTPS y Cloudflare transporta el trafico por el tunel cifrado; el ultimo salto HTTP ocurre en la red Docker de este host. No son necesarias claves TLS en Caddy para este diseño. Evita cachear sesiones, HTML autenticado, `/admin`, `/livewire`, APIs privadas y respuestas con cookies. Conserva CSRF y cookies seguras.

El firewall del proveedor debe permitir SSH solo desde tus IP/VPN y bloquear el resto de entrada. Permite DNS, HTTPS saliente para APT/registry/Resend y salida TCP/UDP 7844 para el tunel. No hay que abrir 80, 443, 8000, 5432 ni 6379. El script no modifica reglas SSH/firewall existentes ni apaga servicios nativos. La [instalacion oficial de Docker](https://docs.docker.com/engine/install/ubuntu/) advierte que publicar puertos puede saltarse reglas UFW; este Compose no publica ninguno.

Cada app con datos independientes debe tener su propio tunel. Reutilizar un token en varios VPS los convierte en replicas del mismo tunel: podrian recibir trafico indistintamente. No hacerlo con bases de datos independientes. Esta plantilla contempla una aplicacion por VPS. Si alojas varias, asigna nombres y subredes diferentes y ajusta simultaneamente Caddy y TrustProxies.

## Desplegar: un comando

En un VPS Ubuntu 26.04 LTS nuevo (tambien admite 24.04), clona este repositorio completo, entra en su directorio y ejecuta:

```bash
sudo bash ./deploy.sh
```

### Limite conjunto de RAM y CPU por proyecto

La imagen es reutilizable. Los recursos se limitan **al ejecutar** sus contenedores. Configura en el `.env` del despliegue:

```dotenv
COMPOSE_PROJECT_NAME=laravel
PROJECT_CPUS=4
PROJECT_MEMORY=8G
```

`8G` representa 8 GiB (8192 MiB). Es un **techo compartido** para app, PostgreSQL, Redis, queue, scheduler, cloudflared y migraciones. No reserva RAM ni nucleos fisicos. Cada servicio puede usar CPU disponible, pero todos juntos quedan limitados al tiempo de CPU equivalente a cuatro nucleos. Los limites se aplican a todos los procesos hijos y a la memoria contabilizada por cgroups, incluidos tmpfs y cache de archivos imputada al grupo. El SO, daemon Docker y la construccion BuildKit quedan fuera de este presupuesto.

`deploy.sh` crea `project-laravel.slice` en systemd con `CPUQuota=400%`, `MemoryMax=8G` y `MemorySwapMax=0`; todos los servicios utilizan el mismo `cgroup_parent`. Comprueba los valores efectivos del kernel y la pertenencia de los contenedores al grupo. Requiere Docker rootful, driver systemd y cgroups v2; se detiene si no se cumplen, sin cambiar ni reiniciar el daemon. La unidad se conserva tras reiniciar el VPS. Referencias: [cgroup_parent en Compose](https://docs.docker.com/reference/compose-file/services/#cgroup_parent) y [control de recursos de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html).

Se han retirado los techos anteriores por contenedor para compartir el presupuesto sin un reparto fijo. Los ajustes internos de PHP, Redis y PostgreSQL siguen existiendo: subir el presupuesto no cambia automaticamente el numero de workers ni Redis `maxmemory`. Al agotar CPU hay throttling; al agotar RAM puede actuar el OOM killer sobre procesos del grupo. No se añade swap por encima del limite. Monitoriza antes de bajar RAM: el script rechaza un nuevo techo inferior al consumo actual.

Para cambiar el presupuesto, modifica estas dos variables y repite `sudo bash ./deploy.sh`; **no hay que reconstruir la imagen**. En un despliegue ya actualizado, si solo quieres ajustar los recursos en vivo sin migraciones/recreaciones, puedes usar:

```bash
# Cambia primero .env a los mismos valores para conservarlos en futuros deploys.
sudo bash docker/project-limits.sh laravel 2 6G
```

Para otro proyecto utiliza otro `COMPOSE_PROJECT_NAME` (minusculas, numeros y `_`, sin guiones), con su propio presupuesto. No cambies el nombre de un despliegue existente sin planificar la migracion: tambien identifica sus volumenes y redes. La separacion de recursos no resuelve las subredes/dominios de varias apps en el mismo VPS; ajustalos como se indica al final.

Si **8 GB y 4 vCPU son la capacidad fisica total del VPS**, deja RAM al SO y Docker: un techo de 6G o 7G para el proyecto es un punto de partida mas prudente. Un techo de 8G no garantiza que el host disponga de 8G libres para el proyecto. La CPU se comparte con el host; 4 CPU es una cuota maxima, no cuatro nucleos reservados.

Verificacion en Ubuntu (para el proyecto `laravel`):

```bash
systemctl show project-laravel.slice -p MemoryCurrent -p MemoryMax -p CPUQuotaPerSecUSec
cat /sys/fs/cgroup/project.slice/project-laravel.slice/cpu.max
cat /sys/fs/cgroup/project.slice/project-laravel.slice/memory.max
cat /sys/fs/cgroup/project.slice/project-laravel.slice/memory.swap.max
systemd-cgtop
```

Con la configuracion inicial, `memory.max` debe ser `8589934592`, swap `0` y el cociente cuota/periodo de `cpu.max` debe ser 4 (normalmente `400000 100000`). `docker stats` por contenedor no expresa por si solo este techo agregado. Si creas otro servicio o replicas uno existente, debe conservar el mismo `cgroup_parent` para quedar incluido. Ejecutar Compose sin haber preparado la slice no garantiza que haya limite: utiliza `deploy.sh`.

El primer uso pide dominio y remitente, y solicita `RESEND_KEY`/`TUNNEL_TOKEN` con entrada oculta. Genera `APP_KEY` y passwords aleatorios; los guarda en `.env` con permisos 600 para reinicios y siguientes deploys. Para ejecucion no interactiva, provisiona previamente un `.env` completo mediante tu gestor de secretos. **No borres ni regeneres este archivo en cada despliegue.**

El script instala Docker CE y Compose mediante APT firmado si faltan, descarga imagenes, fija las de infraestructura en `compose.images.yml`, espera PostgreSQL/Redis, valida conexiones de Laravel, detiene workers, ejecuta una migracion y recrea la app/colas/scheduler. Comprueba `/up`, la conexion de cloudflared y `/up` por el dominio publico. El endpoint `/up` debe poder devolver 200 al monitor, sin un challenge o login de Access; si proteges toda la aplicacion, adapta el monitor con autenticacion de servicio.

`TUNNEL_TOKEN` solo se inyecta en cloudflared. No se imprime ni se pasa por `--token` en la lista de procesos. `.env` y variables Docker son accesibles a root/administradores Docker: no son un vault. La [opcion token-file](https://developers.cloudflare.com/tunnel/reference/run-parameters/) permite evolucionar a un secreto montado cuando dispongas de un gestor.

En otros VPS, copia tambien `compose.images.yml` para mantener **los mismos digests**. El script conserva ese lock. Las actualizaciones deliberadas de infraestructura se hacen con:

```bash
sudo bash ./deploy.sh --refresh-images
```

No cambia las versiones mayores de PostgreSQL/Redis salvo que tu cambies sus referencias. Prueba las nuevas imagenes antes de refrescar en produccion. `--refresh-images` tambien actualiza las imagenes base usadas al reconstruir la aplicacion.

### El objetivo de 120 segundos

**Es un objetivo medible, no una garantia desde un VPS vacio.** APT, locks de cloud-init, ancho de banda, descompresion de capas, inicializacion de BD, migraciones y propagacion de DNS pueden superarlo. El script mide el tiempo real y lo informa; no impone un timeout global que corte una migracion.

Para acercarse a 120 segundos: usa una imagen de VPS con Docker/Compose preinstalados, conserva la cache de BuildKit, prepara el tunel/DNS y mantén breves las migraciones. El primer bootstrap y la primera compilacion pueden durar varios minutos; las actualizaciones con capas en cache pueden encajar en 120 segundos, pero hay que medirlo en el proveedor.

Compose con una sola replica tiene una breve interrupcion al recrear la app. No promete despliegues sin downtime ni rollback transaccional. Las migraciones deben ser aditivas/compatibles con la version anterior (expandir, migrar datos, retirar despues). No ejecutar `migrate:fresh`. Si una migracion falla, el script se detiene y deja los volumenes intactos. Para volver al codigo anterior, restaura un commit conocido, reconstruye y despliega solo si el esquema sigue siendo compatible; no ejecutes `migrate:rollback` automaticamente.

## Persistencia, recursos y operacion

`postgres_data` monta `/var/lib/postgresql` y PGDATA es `/var/lib/postgresql/18/docker`, conforme a la [imagen PostgreSQL 18](https://hub.docker.com/_/postgres). Laravel utiliza un rol no superusuario, propietario de su BD para poder migrar. Para requisitos mas estrictos, separa posteriormente las credenciales de migracion/DDL y runtime. Cambiar passwords en `.env` **no modifica usuarios de una BD ya inicializada**: la rotacion exige cambiar el rol en PostgreSQL y recrear los servicios afectados.

`redis_data` conserva AOF con fsync cada segundo; un fallo brusco puede perder aproximadamente el ultimo segundo. Redis comparte cache, sesiones y colas: `noeviction` impide expulsar jobs/sesiones al llenarse, pero entonces las nuevas escrituras pueden fallar. Usa TTL en cache y monitoriza memoria. Para una carga que lo justifique, separa Redis de cache del de colas. AOF no sustituye un backup.

`uploads` persiste `storage/app`; el enlace `public/storage` se construye en la imagen. Los caches de codigo, vistas y estado Octane son privados de cada contenedor para evitar mezclar releases. Archivos temporales de Livewire/Filament en `storage/app` persisten tambien; conserva su limpieza programada. No se garantiza continuidad de una subida HTTP en curso durante un restart.

El presupuesto inicial solicitado es **4 CPU y 8 GiB compartidos**, con 2 workers web y un queue worker. Es un techo configurable, no una capacidad garantizada de peticiones. PostgreSQL puede necesitar ajustes internos y un job puede exceder el limite PHP de 256 MB. Deja margen para SO, Docker, page cache, tmpfs y forks AOF. Usa disco SSD y monitoriza RAM real, OOM, CPU, espacio e I/O. Redis recomienda revisar [`vm.overcommit_memory` para sus forks](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/); aplica el ajuste en el host conforme a tu politica.

Para operar desde la carpeta del despliegue, abre una sesion administrativa y define:

```bash
sudo -i
cd /opt/miapp
dc() { docker compose --env-file .env -f docker-compose.yml -f compose.images.yml "$@"; }
dc ps
dc logs --tail=100 app queue scheduler cloudflared
docker stats --no-stream
dc exec app php artisan make:filament-user
```

Los logs se envian a stdout/stderr con rotacion. No publiques la salida de `docker compose config` sin `--quiet`, ni `docker inspect`: pueden contener secretos. El estado unhealthy no provoca por si solo un restart de Compose; añade monitorizacion externa y alertas. `restart: unless-stopped` recupera procesos que terminan, no cualquier bloqueo logico.

## Migrar datos de la VM actual

El despliegue nuevo **no copia automaticamente los datos existentes**. Antes del cambio de trafico:

1. Conserva la `APP_KEY` actual, configura dominio/credenciales y comprueba integraciones. Generar otra clave invalida datos cifrados y sesiones.
2. Deten las escrituras y drena los jobs de la VM original durante la copia final. Haz `pg_dump --format=custom` con credenciales seguras y copia `storage/app`. No copies un directorio PGDATA en caliente. Si no puedes pausar escrituras, hay que diseñar replicacion/corte incremental aparte.
3. En destino, con `.env` completo, arranca solo la infraestructura en volumenes nuevos:

   ```bash
   # Antes de crear contenedores manualmente: usa el nombre/limites de tu .env.
   sudo bash docker/project-limits.sh laravel 4 8G
   docker compose --env-file .env -f docker-compose.yml up -d --wait postgres redis
   docker compose --env-file .env -f docker-compose.yml exec -T postgres sh -c \
     'PGPASSWORD="$DB_PASSWORD" pg_restore -h 127.0.0.1 -U "$DB_USERNAME" -d "$DB_DATABASE" --no-owner --no-privileges --exit-on-error' \
     < /ruta/segura/app.dump
   ```

   La BD debe estar vacia, no tener ya tablas creadas por un primer deploy. Revisa extensiones y objetos que requieran privilegios adicionales. Restaura el archivo de `storage/app` con el usuario de la app:

   ```bash
   docker compose --env-file .env -f docker-compose.yml run --rm --no-deps -T release \
     tar -xpf - -C /app/storage/app < /ruta/segura/storage-app.tar
   ```

   El tar debe contener el contenido de `storage/app`, no la ruta absoluta del sistema anterior. Usa un archivo creado por ti y comprobado. Cambiar de Redis puede cerrar sesiones y perder jobs pendientes; drena estos ultimos o planifica su migracion.
4. Ejecuta `sudo bash ./deploy.sh`, verifica datos, permisos y correo; cambia el trafico y manten la VM anterior disponible para recuperacion sin aceptar nuevas escrituras en ambos sitios. El tiempo de copia/restauracion queda fuera del objetivo de despliegue de 120 s.

## Backups y validacion previa a produccion

Los volumenes sobreviven a recreaciones, **no** a la perdida del VPS. No uses `docker compose down -v` en produccion: elimina volumenes. Ejemplo de backup logico con la funcion `dc` anterior:

```bash
umask 077
install -d -m 0700 /var/backups/miapp
dc exec -T postgres sh -c \
  'PGPASSWORD="$DB_PASSWORD" pg_dump -h 127.0.0.1 -U "$DB_USERNAME" -d "$DB_DATABASE" -Fc' \
  > "/var/backups/miapp/db-$(date -u +%Y%m%dT%H%M%SZ).dump"
```

Haz tambien backups de uploads y una copia cifrada de secretos/APP_KEY y digests. Programa copia cifrada **fuera del VPS**, retencion y restauraciones de prueba; define RPO/RTO. Para recuperacion a un instante concreto, añade backup fisico/WAL de PostgreSQL con una herramienta dedicada. Esta plantilla no configura un proveedor de backup que no has indicado.

Prueba en un VPS de staging: primer arranque, segundo deploy sobre los mismos volumenes, login/CSRF y URLs HTTPS, IP real y limites de acceso, assets Vite/Filament, upload privado/publico, envio Resend en cola, scheduler, reinicio del host, recuperacion de Redis/PostgreSQL y restauracion de backup. Comprueba que no hay puertos publicados con `docker ps` y el firewall del proveedor. Si la subred 172.30.91.0/29 colisiona con rutas de tu host/VPN, cambiala coherentemente en Compose, Caddy y TrustProxies antes de arrancar.

Mide la misma app y datos, PHP/motor/version/workers equivalentes, misma carga y cache caliente/fria: throughput, errores, p50/p95/p99, RSS por proceso, CPU e I/O de BD. Compara primero acceso interno para aislar el origen y despues el dominio Cloudflare. No atribuyas a Docker un cambio causado por pasar de Swoole/RoadRunner a FrankenPHP o por cambiar de hardware.
