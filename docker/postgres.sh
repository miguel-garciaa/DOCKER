#!/bin/bash
set -euo pipefail
# Solo se ejecuta al inicializar un volumen VACIO. El rol web no es superusuario.
psql --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 <<'SQL'
\getenv app_user DB_USERNAME
\getenv app_password DB_PASSWORD
\getenv app_database DB_DATABASE
CREATE ROLE :"app_user" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'app_password';
CREATE DATABASE :"app_database" OWNER :"app_user";
REVOKE ALL ON DATABASE :"app_database" FROM PUBLIC;
SQL
