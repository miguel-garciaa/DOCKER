# Laravel 13, React y Octane en un VPS con Docker Compose

**FrankenPHP incorpora Caddy**, que recibe HTTP, sirve assets y ejecuta Octane en modo worker. La [integracion oficial de Octane](https://laravel.com/docs/13.x/octane) contempla FrankenPHP en Docker.

```text
Visitante --HTTPS--> Cloudflare --tunel cifrado--> cloudflared
                                                     |
                                        HTTP por red Docker privada
                                                     |
                                     Caddy gateway :8000
                                        /       |       \
                              Laravel app-1  app-2   Reverb :8080
                                        \       /
                                  PostgreSQL 18 + Redis 8

app-1 / app-2 / gateway / queue / scheduler / Reverb reutilizan la misma imagen.
```

El repositorio incluye una aplicacion Laravel 13 completa basada en el starter oficial de React: React 19, TypeScript, Inertia 3, Tailwind 4, autenticacion, Octane, Filament 5, Resend y Laravel Reverb para WebSockets. Puede construirse en el VPS o publicarse manualmente como imagen OCI con Buildx. No usa Vercel ni GitHub Actions.

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

Caddy mantiene limites de cuerpo/cabeceras, timeouts, bloqueo de dotfiles y PHP directo, cabeceras basicas y restriccion de host. Un gateway Caddy interno recibe exclusivamente desde cloudflared y balancea las replicas Laravel.

**Un contenedor no corrige XSS, IDOR, SQL injection ni fallos de autorizacion.** Comparte kernel con el host y no es una frontera equivalente a otra VM. Aqui no hay puertos publicados, Docker socket, modo privilegiado ni usuarios root en los servicios. `cloudflared` puede llegar a la app, pero no pertenece a la red de PostgreSQL/Redis. La app conserva salida a Internet para Resend y APIs: la separacion de redes no es un firewall de salida completo. El usuario con acceso al daemon Docker tiene privilegios elevados sobre el host.

## Archivos

```text
Dockerfile                       # PHP, Composer y Vite en etapas separadas
docker-compose.yml               # todos los servicios del proyecto
deploy.sh                        # bootstrap y despliegue
publish-image.sh                 # publicacion manual mediante Buildx
.env.example                     # referencia; deploy genera .env
.dockerignore / .gitignore / .gitattributes
app/ bootstrap/ config/ routes/  # aplicacion Laravel 13
resources/                       # React, TypeScript y Tailwind
composer.lock / package-lock.json
docker/
  Caddyfile                      # HTTP interno, assets y Octane
  Gateway.Caddyfile             # balanceo app-1/app-2 y entrada a Reverb
  php.ini
  entrypoint.sh                  # web, queue, scheduler y Reverb
  health.php / reverb-health.php / check-services.php
  postgres-init.sh / redis-start.sh
  project-limits.sh              # presupuesto CPU/RAM/swap mediante systemd
```

`bootstrap/app.php` ya habilita `/up` y confia exclusivamente en la IP fija del gateway para `X-Forwarded-For` y `X-Forwarded-Proto`; el gateway solo confia esos datos cuando proceden de cloudflared. El acceso a `/admin` exige que el email del usuario coincida con `FILAMENT_ADMIN_EMAIL`.

Antes de desplegar cambios ejecuta:

```bash
composer ci:check
```

Este comando ejecuta tests, Pint, PHPStan, comprobaciones TypeScript, formato y el build frontend configurados en el proyecto.

## Imagen de aplicacion

Los servicios web, Reverb, migraciones, colas y scheduler reutilizan exactamente una imagen de aplicacion. Node, npm, Composer y las dependencias de compilacion no quedan en la etapa final. Hay dos modos:

- Sin `APP_IMAGE`, `deploy.sh` construye `laravel-app:local` desde el repositorio.
- Con `APP_IMAGE`, descarga la release del registro y no necesita el codigo Laravel en el VPS.

Para construir sin desplegar:

```bash
docker compose --env-file .env build app
```

El build utiliza locks, `composer install --no-dev`, Node 24, `npm ci`, assets compilados y cache de descargas. No se hace `config:cache` con secretos durante la construccion: se ejecuta al arrancar cada proceso con su entorno real. El dominio y la clave publica de Reverb tambien se entregan en tiempo de ejecucion, por lo que una misma imagen sirve para varios dominios. El codigo permanece de solo lectura y no se monta el repositorio del host sobre `/app`.

Para reconstrucciones reproducibles tambien fija `PHP_IMAGE`, `COMPOSER_IMAGE` y `NODE_IMAGE` mediante `--build-arg NOMBRE=imagen@sha256:...`. Programa actualizaciones probadas de esas referencias. Las etiquetas por defecto facilitan el primer build, pero por si solas no son inmutables. No pases secretos como `ARG`.

### Publicar manualmente con Buildx

Una imagen no puede contener y administrar PostgreSQL, Redis y cloudflared como si fueran un unico contenedor. La imagen publicada contiene Laravel, FrankenPHP, Reverb, el frontend compilado y un paquete minimo de despliegue. Compose sigue creando procesos y volumenes separados, que es lo que permite actualizar, reiniciar y respaldar cada componente correctamente.

No se usa GitHub Actions. Crea un Personal Access Token classic de GitHub con `write:packages`, inicia sesion sin escribir el token en el historial y publica una etiqueta inmutable:

```bash
read -r -s -p 'Token GHCR: ' GHCR_TOKEN; echo
printf '%s' "$GHCR_TOKEN" | sudo docker login ghcr.io -u miguel-garciaa --password-stdin
unset GHCR_TOKEN

DOCKER_SUDO=1 ./publish-image.sh v1.0.0
```

Por defecto publica `ghcr.io/miguel-garciaa/docker:v1.0.0` para `linux/amd64`. Para VPS ARM y x86 en la misma release:

```bash
DOCKER_SUDO=1 PLATFORMS=linux/amd64,linux/arm64 ./publish-image.sh v1.0.0
```

Buildx sube el resultado directamente al registro y adjunta procedencia y SBOM. Usa un tag nuevo por release y, para maxima reproducibilidad, configura `APP_IMAGE` con el digest mostrado por `docker buildx imagetools inspect`. Documentacion oficial: [push con Buildx](https://docs.docker.com/build/exporters/), [builds multiplataforma](https://docs.docker.com/build/building/multi-platform/) y [autenticacion de GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).

## Preparar Cloudflare: una vez por aplicacion/VPS

En un tunel administrado remotamente crea una ruta publica:

```text
Hostname:  app.tudominio.com
Service:   http://app:8000
```

`app` es un alias DNS del gateway dentro de la red privada de cloudflared. **No uses `localhost:8000`**, que dentro de `cloudflared` apuntaria al propio conector. La ruta existente no cambia al añadir replicas. El token permite conectar el tunel; no crea por si solo DNS ni su configuracion remota. [Configuracion oficial](https://developers.cloudflare.com/tunnel/setup/).

Activa redireccion a HTTPS en Cloudflare. El tramo publico usa HTTPS y Cloudflare transporta el trafico por el tunel cifrado; el ultimo salto HTTP ocurre en la red Docker de este host. No son necesarias claves TLS en Caddy para este diseño. Evita cachear sesiones, HTML autenticado, `/admin`, `/livewire`, APIs privadas y respuestas con cookies. Conserva CSRF y cookies seguras.

El firewall del proveedor debe permitir SSH solo desde tus IP/VPN y bloquear el resto de entrada. Permite DNS, HTTPS saliente para APT/registry/Resend y salida TCP/UDP 7844 para el tunel. No hay que abrir 80, 443, 8000, 5432 ni 6379. El script no modifica reglas SSH/firewall existentes ni apaga servicios nativos. La [instalacion oficial de Docker](https://docs.docker.com/engine/install/ubuntu/) advierte que publicar puertos puede saltarse reglas UFW; este Compose no publica ninguno.

Cada app con datos independientes debe tener su propio tunel. Reutilizar un token en varios VPS los convierte en replicas del mismo tunel: podrian recibir trafico indistintamente. No hacerlo con bases de datos independientes. Esta plantilla contempla una aplicacion por VPS. Si alojas varias, asigna nombres y subredes diferentes y ajusta simultaneamente Caddy y TrustProxies.

### WebSockets con Laravel Reverb

No hace falta crear otra ruta en Cloudflare. El navegador abre `wss://APP_DOMAIN/app/...` por el mismo hostname; el gateway envia solo `/app` al servicio `reverb:8080` y balancea el resto entre las replicas web. El endpoint interno `/apps`, usado por Laravel para publicar eventos, no se expone directamente. Reverb solo acepta el origen configurado en `APP_DOMAIN`, rechaza eventos enviados directamente por el navegador, tiene healthcheck, un maximo inicial de 500 conexiones y comparte el presupuesto de CPU/RAM/swap del proyecto.

Los cambios de calendario o citas deben entrar por controladores Laravel autenticados y autorizados; despues, los eventos que implementan `ShouldBroadcast` se procesan por el worker de Redis existente. Autoriza cada canal privado en `routes/channels.php`; un usuario nunca debe poder suscribirse al calendario o citas de otra cuenta. En React estan disponibles `useEcho`, `useEchoPublic`, `useEchoPresence` y los demas hooks de `@laravel/echo-react`. Consulta la [documentacion oficial de broadcasting](https://laravel.com/docs/13.x/broadcasting) y [Laravel Reverb](https://laravel.com/docs/13.x/reverb).

### Replicas web, queue y scheduler

`APP_REPLICAS=2` crea `laravel-app-1` y `laravel-app-2`. Caddy consulta Docker DNS, aplica `least_conn` y deja temporalmente fuera una replica que falla. Las conexiones rechazadas antes de enviar la peticion pueden probar la otra replica; una respuesta fallida de un POST no se repite automaticamente para evitar duplicar operaciones. No hace falta afinidad de sesion: ambos procesos usan la misma sesion/cache Redis, la misma base PostgreSQL y el volumen `uploads`. No guardes estado funcional en memoria global de Octane porque esa memoria no se comparte entre replicas.

`queue` ejecuta trabajos asincronos de Redis: correos, broadcasts, importaciones o tareas pesadas. La web puede seguir respondiendo si se detiene, pero esos trabajos quedan pendientes. Laravel puede reintentar un job, por lo que los jobs con efectos externos deben ser idempotentes. `QUEUE_REPLICAS=1` es el valor inicial y puede aumentarse despues si la carga lo exige.

`scheduler` mantiene `php artisan schedule:work` y dispara las tareas definidas en `routes/console.php`. Se conserva **una sola replica** para evitar ejecuciones duplicadas. Si algun dia replicas schedulers entre varios hosts, las tareas sensibles deben usar bloqueos compartidos como `onOneServer` sobre Redis.

Esto da continuidad cuando cae un proceso `app`; no es alta disponibilidad completa. Gateway, Reverb, Redis, PostgreSQL, cloudflared y el propio VPS siguen siendo puntos unicos. Cubrir la perdida del VPS exige al menos otro host, varios conectores del tunel y servicios de datos replicados. Caddy soporta balanceo, reintentos y comprobacion pasiva de fallos; las replicas de Compose se controlan mediante `scale`. Referencias: [reverse_proxy de Caddy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy) y [scale en Compose](https://docs.docker.com/reference/compose-file/services/#scale).

## Desplegar

Desde un clon del repositorio, en Ubuntu 26.04 LTS o 24.04:

```bash
sudo bash ./deploy.sh
```

Para desplegar la imagen sin clonar Laravel, primero instala Docker, descarga la release y extrae unicamente los cinco archivos pequenos incluidos en `/opt/laravel-deploy`:

```bash
APP_IMAGE='ghcr.io/miguel-garciaa/docker:v1.0.0'
sudo docker pull "$APP_IMAGE"
container=$(sudo docker create "$APP_IMAGE")
mkdir -p "$HOME/miapp"
sudo docker cp "$container:/opt/laravel-deploy/." "$HOME/miapp/"
sudo docker rm "$container"
sudo chown -R "$USER:$USER" "$HOME/miapp"
cd "$HOME/miapp"
sudo env APP_IMAGE="$APP_IMAGE" bash ./deploy.sh
```

Si el paquete GHCR es privado, ejecuta antes `sudo docker login ghcr.io` con un token classic limitado a `read:packages`. Si lo haces publico, los VPS pueden descargarlo sin credenciales. `deploy.sh` guarda `APP_IMAGE`, el dominio y los secretos en `.env`, descarga la release en cada despliegue y omite completamente el build. En actualizaciones posteriores cambia `APP_IMAGE` en `.env` y ejecuta otra vez `sudo bash ./deploy.sh`.

Tras el primer `deploy.sh` puedes usar `docker compose up -d`; el script sigue siendo necesario inicialmente y cuando cambies el presupuesto porque `docker compose up` por si solo no crea el limite agregado de systemd.

### Limite conjunto de RAM y CPU por proyecto

La imagen es reutilizable. Los recursos se limitan **al ejecutar** sus contenedores. Configura en el `.env` del despliegue:

```dotenv
COMPOSE_PROJECT_NAME=laravel
PROJECT_CPUS=4
PROJECT_MEMORY=6G
PROJECT_SWAP=1G
APP_REPLICAS=2
QUEUE_REPLICAS=1
```

Es un **techo compartido** de 6 GiB de RAM y 1 GiB adicional de swap para las dos apps, gateway, Reverb, PostgreSQL, Redis, queue, scheduler, cloudflared y migraciones. No reserva RAM ni nucleos fisicos. Cada servicio puede usar CPU disponible, pero todos juntos quedan limitados al tiempo de CPU equivalente a cuatro nucleos. Los limites se aplican a todos los procesos hijos y a la memoria contabilizada por cgroups, incluidos tmpfs y cache de archivos imputada al grupo. El SO, daemon Docker y la construccion BuildKit quedan fuera de este presupuesto.

`deploy.sh` crea `project-laravel.slice` en systemd con `CPUQuota=400%`, `MemoryMax=6G` y `MemorySwapMax=1G`; todos los servicios utilizan el mismo `cgroup_parent`. Si el host no tiene al menos 1 GiB de swap, crea `/var/lib/laravel-docker/swapfile`, lo activa y lo registra en `/etc/fstab`. Comprueba los valores efectivos del kernel y la pertenencia de los contenedores al grupo. Requiere Docker rootful, driver systemd y cgroups v2; se detiene si no se cumplen. La unidad se conserva tras reiniciar el VPS. Referencias: [cgroup_parent en Compose](https://docs.docker.com/reference/compose-file/services/#cgroup_parent) y [control de recursos de systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html).

Se han retirado los techos anteriores por contenedor para compartir el presupuesto sin un reparto fijo. Los ajustes internos de PHP, Redis y PostgreSQL siguen existiendo: subir el presupuesto no cambia automaticamente el numero de workers ni Redis `maxmemory`. Al agotar CPU hay throttling. El swap reduce la probabilidad de un OOM durante picos breves, pero su uso sostenido aumenta mucho la latencia; no sustituye RAM ni una configuracion correcta. Monitoriza antes de bajar RAM: el script rechaza un nuevo techo inferior al consumo actual.

Para cambiar el presupuesto, modifica estas dos variables y repite `sudo bash ./deploy.sh`; **no hay que reconstruir la imagen**. En un despliegue ya actualizado, si solo quieres ajustar los recursos en vivo sin migraciones/recreaciones, puedes usar:

```bash
# Cambia primero .env a los mismos valores para conservarlos en futuros deploys.
sudo bash docker/project-limits.sh laravel 2 6G 1G
```

Para otro proyecto utiliza otro `COMPOSE_PROJECT_NAME` (minusculas, numeros y `_`, sin guiones), con su propio presupuesto. No cambies el nombre de un despliegue existente sin planificar la migracion: tambien identifica sus volumenes y redes. La separacion de recursos no resuelve las subredes/dominios de varias apps en el mismo VPS; ajustalos como se indica al final.

Si **8 GB y 4 vCPU son la capacidad fisica total del VPS**, el techo de 6G deja margen al SO y Docker. La CPU se comparte con el host; 4 CPU es una cuota maxima, no cuatro nucleos reservados.

Verificacion en Ubuntu (para el proyecto `laravel`):

```bash
systemctl show project-laravel.slice -p MemoryCurrent -p MemoryMax -p CPUQuotaPerSecUSec
cat /sys/fs/cgroup/project.slice/project-laravel.slice/cpu.max
cat /sys/fs/cgroup/project.slice/project-laravel.slice/memory.max
cat /sys/fs/cgroup/project.slice/project-laravel.slice/memory.swap.max
systemd-cgtop
```

Con la configuracion inicial, `memory.max` debe ser `6442450944`, `memory.swap.max` debe ser `1073741824` y el cociente cuota/periodo de `cpu.max` debe ser 4 (normalmente `400000 100000`). `docker stats` por contenedor no expresa por si solo este techo agregado. Si creas otro servicio o replicas uno existente, debe conservar el mismo `cgroup_parent` para quedar incluido. Ejecutar Compose sin haber preparado la slice no garantiza que haya limite: utiliza `deploy.sh`.

El primer uso pide dominio y remitente, y solicita `RESEND_KEY`/`TUNNEL_TOKEN` con entrada oculta. Genera `APP_KEY` y passwords aleatorios; los guarda en `.env` con permisos 600 para reinicios y siguientes deploys. Para ejecucion no interactiva, provisiona previamente un `.env` completo mediante tu gestor de secretos. **No borres ni regeneres este archivo en cada despliegue.**

El script instala Docker CE y Compose mediante APT firmado si faltan, construye la app o descarga `APP_IMAGE`, fija las imagenes de infraestructura en `compose.images.yml`, espera PostgreSQL/Redis, valida conexiones de Laravel, detiene workers/Reverb, ejecuta una migracion y recrea Reverb, las dos apps, gateway, cola y scheduler. Comprueba healthchecks, `/up`, la conexion de cloudflared y `/up` por el dominio publico. El endpoint `/up` debe poder devolver 200 al monitor, sin un challenge o login de Access; si proteges toda la aplicacion, adapta el monitor con autenticacion de servicio.

`TUNNEL_TOKEN` solo se inyecta en cloudflared. No se imprime ni se pasa por `--token` en la lista de procesos. `.env` y variables Docker son accesibles a root/administradores Docker: no son un vault. La [opcion token-file](https://developers.cloudflare.com/tunnel/reference/run-parameters/) permite evolucionar a un secreto montado cuando dispongas de un gestor.

En otros VPS, copia tambien `compose.images.yml` para mantener **los mismos digests**. El script conserva ese lock. Las actualizaciones deliberadas de infraestructura se hacen con:

```bash
sudo bash ./deploy.sh --refresh-images
```

No cambia las versiones mayores de PostgreSQL/Redis salvo que tu cambies sus referencias. Prueba las nuevas imagenes antes de refrescar en produccion. En modo de build local, `--refresh-images` tambien actualiza las imagenes base de la aplicacion; en modo `APP_IMAGE`, la release ya esta construida y se descarga directamente.

### El objetivo de 120 segundos

**Es un objetivo medible, no una garantia desde un VPS vacio.** APT, locks de cloud-init, ancho de banda, descompresion de capas, inicializacion de BD, migraciones y propagacion de DNS pueden superarlo. El script mide el tiempo real y lo informa; no impone un timeout global que corte una migracion.

Para acercarse a 120 segundos: usa una imagen de VPS con Docker/Compose preinstalados, publica previamente `APP_IMAGE`, prepara el tunel/DNS y mantén breves las migraciones. El primer bootstrap puede durar varios minutos; las actualizaciones que solo descargan capas nuevas suelen ser mucho mas rapidas, pero hay que medirlo en el proveedor.

Las dos replicas reducen el corte por fallo de un proceso, pero Compose no promete actualizaciones progresivas sin interrupcion ni rollback transaccional. Las migraciones deben ser aditivas/compatibles con la version anterior (expandir, migrar datos, retirar despues). No ejecutar `migrate:fresh`. Si una migracion falla, el script se detiene y deja los volumenes intactos. Para volver al codigo anterior, cambia `APP_IMAGE` a una release conocida solo si el esquema sigue siendo compatible; no ejecutes `migrate:rollback` automaticamente.

## Persistencia, recursos y operacion

`postgres_data` monta `/var/lib/postgresql` y PGDATA es `/var/lib/postgresql/18/docker`, conforme a la [imagen PostgreSQL 18](https://hub.docker.com/_/postgres). Laravel utiliza un rol no superusuario, propietario de su BD para poder migrar. Para requisitos mas estrictos, separa posteriormente las credenciales de migracion/DDL y runtime. Cambiar passwords en `.env` **no modifica usuarios de una BD ya inicializada**: la rotacion exige cambiar el rol en PostgreSQL y recrear los servicios afectados.

`redis_data` conserva AOF con fsync cada segundo; un fallo brusco puede perder aproximadamente el ultimo segundo. Redis comparte cache, sesiones y colas: `noeviction` impide expulsar jobs/sesiones al llenarse, pero entonces las nuevas escrituras pueden fallar. Usa TTL en cache y monitoriza memoria. Para una carga que lo justifique, separa Redis de cache del de colas. AOF no sustituye un backup.

`uploads` persiste `storage/app`; el enlace `public/storage` se construye en la imagen. Los caches de codigo, vistas y estado Octane son privados de cada contenedor para evitar mezclar releases. Archivos temporales de Livewire/Filament en `storage/app` persisten tambien; conserva su limpieza programada. No se garantiza continuidad de una subida HTTP en curso durante un restart.

El presupuesto inicial es **4 CPU, 6 GiB de RAM y 1 GiB de swap compartidos**, con 4 workers web en total (2 por replica) y un queue worker. Es un techo configurable, no una capacidad garantizada de peticiones. PostgreSQL puede necesitar ajustes internos y un job puede exceder el limite PHP de 256 MB. Deja margen para SO, Docker, page cache, tmpfs y forks AOF. Usa disco SSD y monitoriza RAM real, swap, OOM, CPU, espacio e I/O. Si la aplicacion consume demasiada memoria en reposo, baja `OCTANE_WORKERS=1` para tener 2 workers web totales. Redis recomienda revisar [`vm.overcommit_memory` para sus forks](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/); aplica el ajuste en el host conforme a tu politica.

Para operar desde la carpeta del despliegue, abre una sesion administrativa y define:

```bash
sudo -i
cd /opt/miapp
dc() { docker compose --env-file .env -f docker-compose.yml -f compose.images.yml "$@"; }
dc ps
dc logs --tail=100 gateway app reverb queue scheduler cloudflared
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
   sudo bash docker/project-limits.sh laravel 4 6G 1G
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

Prueba en un VPS de staging: primer arranque, segundo deploy sobre los mismos volumenes, reparto entre replicas, parada manual de `laravel-app-1`, login/CSRF y URLs HTTPS, IP real y limites de acceso, assets Vite/Filament, canales privados y reconexion WebSocket, upload privado/publico, envio Resend en cola, scheduler, reinicio del host, recuperacion de Redis/PostgreSQL y restauracion de backup. Comprueba que no hay puertos publicados con `docker ps` y el firewall del proveedor. Si las subredes 172.30.91.0/29 o 172.30.92.0/29 colisionan con rutas de tu host/VPN, cambialas coherentemente en Compose, ambos Caddyfile y TrustProxies antes de arrancar.

Mide la misma app y datos, PHP/motor/version/workers equivalentes, misma carga y cache caliente/fria: throughput, errores, p50/p95/p99, RSS por proceso, CPU e I/O de BD. Compara primero acceso interno para aislar el origen y despues el dominio Cloudflare. No atribuyas a Docker un cambio causado por pasar de Swoole/RoadRunner a FrankenPHP o por cambiar de hardware.
